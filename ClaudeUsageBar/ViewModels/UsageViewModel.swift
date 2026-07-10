import SwiftUI
import ServiceManagement
import UserNotifications

@MainActor
final class UsageViewModel: ObservableObject {

    enum LoadingState {
        case idle
        case loading
        case loaded(UsageSnapshot)
        case error(String)
    }

    @Published var state: LoadingState = .idle
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var usageHistory: [UsageDataPoint] = []
    @Published var needsManualRefresh: Bool = false
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { UserDefaults.standard.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode") }
    }

    private var timer: Timer?
    private var lastSnapshot: UsageSnapshot?
    private var cachedCredentials: CachedCredentials?
    private var notifiedThresholds: Set<Int> = []
    private var oauthRefreshFailures = 0

    private static let maxHistoryPoints = 288      // 24 hours of data
    private static let historySampleInterval: TimeInterval = 300 // record every 5 minutes
    private static let maxOAuthRefreshFailures = 3

    init() {
        let raw = UserDefaults.standard.string(forKey: "menuBarDisplayMode") ?? "auto"
        self.menuBarDisplayMode = MenuBarDisplayMode(rawValue: raw) ?? .auto

        if let cached = UsageSnapshot.loadCached() {
            lastSnapshot = cached
            state = .loaded(cached)
        }
        usageHistory = Self.loadHistory()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task { [weak self] in
            await self?.refresh()
        }
        scheduleTimer()
    }

    var snapshot: UsageSnapshot? {
        if case .loaded(let s) = state { return s }
        return lastSnapshot
    }

    var menuBarText: String {
        guard let active = MenuBarSelection.active(mode: menuBarDisplayMode, snapshot: snapshot) else {
            return "--%"
        }
        let countdown = Self.resetCountdown(until: active.resetsAt)
        let suffix = (countdown == "—" || countdown == "now") ? "" : " · \(countdown)"
        return "\(active.percent)%\(suffix)"
    }

    var menuBarColor: Color {
        guard let active = MenuBarSelection.active(mode: menuBarDisplayMode, snapshot: snapshot) else {
            return .primary
        }
        return Self.color(for: active.percent)
    }

    var menuBarActiveWindow: MenuBarDisplayMode {
        MenuBarSelection.active(mode: menuBarDisplayMode, snapshot: snapshot)?.window
            ?? (menuBarDisplayMode == .auto ? .fiveHour : menuBarDisplayMode)
    }

    var isStaleData: Bool {
        guard let s = snapshot else { return false }
        return Date().timeIntervalSince(s.fetchedAt) > 120
    }

    // MARK: - Adaptive Refresh

    private var refreshInterval: TimeInterval {
        guard let s = snapshot else { return 60 }
        let maxPercent = s.higherPercent
        if maxPercent >= 75 { return 30 }
        if maxPercent < 25 { return 120 }
        return 60
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
    }

    // MARK: - Refresh

    func refresh() async {
        state = .loading
        do {
            let snap = try await fetchWithRetry()
            lastSnapshot = snap
            state = .loaded(snap)
            needsManualRefresh = false
            snap.persist()
            recordHistory(snap)
            checkThresholds(snap)
            scheduleTimer()
        } catch let error as UsageAPIError {
            state = .error(error.localizedDescription)
            needsManualRefresh = error.needsKeychainRefresh
        } catch {
            state = .error(error.localizedDescription)
            needsManualRefresh = false
        }
    }

    private func fetchWithRetry() async throws -> UsageSnapshot {
        guard var creds = getCredentials() else {
            throw UsageAPIError.noToken
        }

        // Proactive refresh: if the token is expiring soon, swap it out before the first
        // call. On failure we proceed with the old token; the reactive 401/403 path below
        // stays as the safety net.
        if creds.needsRefresh(), let refreshed = await tryOAuthRefresh(using: creds) {
            cachedCredentials = refreshed
            creds = refreshed
        }

        // Retry only transient errors, with exponential backoff. Auth errors bypass the
        // loop and take the OAuth/keychain refresh path; other errors propagate as-is.
        let policy = RetryPolicy()
        var rng = SystemRandomNumberGenerator()
        var lastError: UsageAPIError?

        for attempt in 1...policy.maxAttempts {
            do {
                let response = try await UsageAPIService.fetch(token: creds.accessToken)
                return UsageSnapshot(from: response)
            } catch let error as UsageAPIError where error.isAuthError {
                // Try OAuth refresh-token flow first. On success we never touch the keychain.
                if let refreshed = await tryOAuthRefresh(using: creds) {
                    cachedCredentials = refreshed
                    let response = try await UsageAPIService.fetch(token: refreshed.accessToken)
                    return UsageSnapshot(from: response)
                }
                // Refresh failed (or no refresh token) — surface a user-actionable error
                // instead of silently prompting from the keychain.
                throw UsageAPIError.tokenExpired
            } catch let error as UsageAPIError where error.isTransient {
                lastError = error
                if attempt < policy.maxAttempts {
                    let delay = policy.delay(forAttempt: attempt, using: &rng)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        // Every attempt hit a transient failure — rethrow the last one.
        throw lastError ?? UsageAPIError.invalidResponse(-1)
    }

    // MARK: - Credentials

    private func getCredentials() -> CachedCredentials? {
        if let creds = cachedCredentials {
            return creds
        }
        let creds = KeychainService.getCredentials()
        cachedCredentials = creds
        return creds
    }

    /// User-triggered: re-reads from Claude Code's keychain. This is the only path
    /// that may produce a macOS password prompt after first install.
    func refreshFromKeychain() async {
        cachedCredentials = nil
        oauthRefreshFailures = 0
        if let creds = KeychainService.refreshFromKeychain() {
            cachedCredentials = creds
        }
        await refresh()
    }

    private func tryOAuthRefresh(using creds: CachedCredentials) async -> CachedCredentials? {
        guard oauthRefreshFailures < Self.maxOAuthRefreshFailures,
              let refreshToken = creds.refreshToken else {
            return nil
        }
        do {
            let refreshed = try await KeychainService.refreshAccessToken(using: refreshToken)
            oauthRefreshFailures = 0
            return refreshed
        } catch {
            oauthRefreshFailures += 1
            return nil
        }
    }

    // MARK: - Launch at Login

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            // Silently fail — user can retry
        }
    }

    // MARK: - Notifications

    private func checkThresholds(_ snapshot: UsageSnapshot) {
        let percent = snapshot.higherPercent
        for threshold in [80, 90] {
            if percent >= threshold && !notifiedThresholds.contains(threshold) {
                notifiedThresholds.insert(threshold)
                sendNotification(percent: percent, threshold: threshold)
            }
        }
        if percent < 80 {
            notifiedThresholds.removeAll()
        }
    }

    private nonisolated func sendNotification(percent: Int, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage Warning"
        content.body = threshold >= 90
            ? "Usage at \(percent)% — approaching limit!"
            : "Usage has reached \(percent)%"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-\(threshold)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Usage History

    private func recordHistory(_ snapshot: UsageSnapshot) {
        let point = UsageDataPoint(
            timestamp: snapshot.fetchedAt,
            fiveHourPercent: snapshot.fiveHourPercent,
            sevenDayPercent: snapshot.sevenDayPercent
        )
        let updated = HistoryBuffer.appending(
            point,
            to: usageHistory,
            maxPoints: Self.maxHistoryPoints,
            minInterval: Self.historySampleInterval
        )
        // `appending` returns the input unchanged when the sample is skipped; only
        // persist when a point was actually added (avoids redundant writes per tick).
        guard updated.last?.timestamp != usageHistory.last?.timestamp else { return }
        usageHistory = updated
        Self.saveHistory(usageHistory)
    }

    private static func loadHistory() -> [UsageDataPoint] {
        guard let data = UserDefaults.standard.data(forKey: "usageHistory") else { return [] }
        return (try? JSONDecoder().decode([UsageDataPoint].self, from: data)) ?? []
    }

    private static func saveHistory(_ history: [UsageDataPoint]) {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "usageHistory")
        }
    }

    // MARK: - Helpers

    static func color(for percent: Int) -> Color {
        switch percent {
        case ..<50: return .green
        case ..<75: return .yellow
        default:    return .red
        }
    }

    static func liveCountdown(until date: Date?) -> String {
        guard let date else { return "—" }
        let total = max(0, Int(date.timeIntervalSinceNow))
        if total == 0 { return "now" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60

        if h > 0 {
            return "\(h)h \(m)m"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }

    static func resetCountdown(until date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let days = hours / 24
        let remainingHours = hours % 24

        if days > 0 {
            return "\(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    static func lastUpdatedText(since date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

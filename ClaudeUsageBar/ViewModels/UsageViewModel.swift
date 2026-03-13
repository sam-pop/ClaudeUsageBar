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

    private var timer: Timer?
    private var lastSnapshot: UsageSnapshot?
    private var cachedToken: String?
    private var tokenFetchedAt: Date?
    private var notifiedThresholds: Set<Int> = []

    private static let tokenCacheDuration: TimeInterval = 300
    private static let maxHistoryPoints = 288      // 24 hours of data
    private static let historySampleInterval: TimeInterval = 300 // record every 5 minutes

    init() {
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
        guard let s = snapshot else { return "--%" }
        let countdown = Self.resetCountdown(until: s.fiveHourResetsAt)
        let suffix = (countdown == "—" || countdown == "now") ? "" : " · \(countdown)"
        return "\(s.fiveHourPercent)%\(suffix)"
    }

    var menuBarColor: Color {
        guard let s = snapshot else { return .primary }
        return Self.color(for: s.higherPercent)
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
            snap.persist()
            recordHistory(snap)
            checkThresholds(snap)
            scheduleTimer()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func fetchWithRetry() async throws -> UsageSnapshot {
        guard let token = getToken() else {
            throw UsageAPIError.noToken
        }

        do {
            let response = try await UsageAPIService.fetch(token: token)
            return UsageSnapshot(from: response)
        } catch let error as UsageAPIError where error.isAuthError {
            invalidateToken()
            guard let freshToken = getToken(forceRefresh: true) else {
                throw UsageAPIError.noToken
            }
            let response = try await UsageAPIService.fetch(token: freshToken)
            return UsageSnapshot(from: response)
        } catch let error as UsageAPIError where error.isTransient {
            try? await Task.sleep(for: .seconds(2))
            let response = try await UsageAPIService.fetch(token: token)
            return UsageSnapshot(from: response)
        }
    }

    // MARK: - Token Cache

    private func getToken(forceRefresh: Bool = false) -> String? {
        if !forceRefresh, let token = cachedToken, let at = tokenFetchedAt,
           Date().timeIntervalSince(at) < Self.tokenCacheDuration {
            return token
        }
        let token = KeychainService.getOAuthToken()
        cachedToken = token
        tokenFetchedAt = Date()
        return token
    }

    private func invalidateToken() {
        cachedToken = nil
        tokenFetchedAt = nil
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
        // Only sample every 5 minutes to build meaningful 24h history
        if let last = usageHistory.last {
            let elapsed = snapshot.fetchedAt.timeIntervalSince(last.timestamp)
            if elapsed < Self.historySampleInterval { return }
        }

        let point = UsageDataPoint(
            timestamp: snapshot.fetchedAt,
            fiveHourPercent: snapshot.fiveHourPercent,
            sevenDayPercent: snapshot.sevenDayPercent
        )
        usageHistory.append(point)
        if usageHistory.count > Self.maxHistoryPoints {
            usageHistory.removeFirst(usageHistory.count - Self.maxHistoryPoints)
        }
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

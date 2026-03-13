import SwiftUI
import ServiceManagement

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

    private var timer: Timer?

    init() {
        Task { [weak self] in
            await self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
    }

    var snapshot: UsageSnapshot? {
        if case .loaded(let s) = state { return s }
        return nil
    }

    var menuBarText: String {
        guard let s = snapshot else { return "--%" }
        return "\(s.higherPercent)%"
    }

    // MARK: - Refresh

    func refresh() async {
        state = .loading
        do {
            let response = try await UsageAPIService.fetch()
            state = .loaded(UsageSnapshot(from: response))
        } catch {
            state = .error(error.localizedDescription)
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

    // MARK: - Helpers

    static func color(for percent: Int) -> Color {
        switch percent {
        case ..<50: return .green
        case ..<75: return .yellow
        default:    return .red
        }
    }

    static func resetCountdown(until date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = max(0, date.timeIntervalSinceNow)
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
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

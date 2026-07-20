import Foundation

/// Pure resolution of which usage window the menu bar should display, given the
/// user's chosen display mode and the latest snapshot. Replaces the duplicated
/// `activeMenuBarValues` / `menuBarActiveWindow` logic in `UsageViewModel`.
enum MenuBarSelection {
    struct Active: Equatable {
        /// Always resolved to a concrete window (`.fiveHour` or `.sevenDay`), never `.auto`.
        let window: MenuBarDisplayMode
        let percent: Int
        let resetsAt: Date?
    }

    /// Returns the active window for the given mode, or `nil` when there is no snapshot.
    /// Auto mode picks the higher-utilization window; ties go to the 5-hour window (`>=`).
    /// Percents are the *effective* values for `now`: a window whose reset has passed reads
    /// 0, so a stale pre-reset value never sticks and auto never favors an already-reset window.
    static func active(mode: MenuBarDisplayMode, snapshot: UsageSnapshot?, now: Date = Date()) -> Active? {
        guard let s = snapshot else { return nil }

        let fiveHour = s.fiveHourEffectivePercent(now: now)
        let sevenDay = s.sevenDayEffectivePercent(now: now)

        let useFiveHour: Bool
        switch mode {
        case .fiveHour:      useFiveHour = true
        case .sevenDay:      useFiveHour = false
        // `.bars` shows both windows and doesn't use this selection; fall back to the
        // auto rule so any text path (e.g. accessibility) still resolves a sensible window.
        case .auto, .bars:   useFiveHour = fiveHour >= sevenDay
        }

        return useFiveHour
            ? Active(window: .fiveHour, percent: fiveHour, resetsAt: s.fiveHourResetsAt)
            : Active(window: .sevenDay, percent: sevenDay, resetsAt: s.sevenDayResetsAt)
    }
}

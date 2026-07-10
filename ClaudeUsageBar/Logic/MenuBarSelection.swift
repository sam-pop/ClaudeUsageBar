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
    static func active(mode: MenuBarDisplayMode, snapshot: UsageSnapshot?) -> Active? {
        guard let s = snapshot else { return nil }

        let useFiveHour: Bool
        switch mode {
        case .fiveHour: useFiveHour = true
        case .sevenDay: useFiveHour = false
        case .auto:     useFiveHour = s.fiveHourPercent >= s.sevenDayPercent
        }

        return useFiveHour
            ? Active(window: .fiveHour, percent: s.fiveHourPercent, resetsAt: s.fiveHourResetsAt)
            : Active(window: .sevenDay, percent: s.sevenDayPercent, resetsAt: s.sevenDayResetsAt)
    }
}

import Foundation

/// Whether an account's refresh-token expiry is close enough to warn about, and
/// de-duplication for the pre-expiry notification fired at 3 and 1 days remaining.
///
/// A running app's periodic refreshes keep re-arming the ~28-day refresh-token window, so
/// in practice this only has something to say after an extended stretch with no successful
/// refresh — the app closed for weeks.
enum LoginExpiry {
    private static let secondsPerDay: TimeInterval = 86400
    private static let warningWindow: TimeInterval = 7 * secondsPerDay

    /// "Login expires in Nd" once `refreshTokenExpiresAt` is under 7 days away; `nil` once
    /// it's further out, already past, or unknown. An already-past expiry is silent here —
    /// that state belongs to the dead-login pill, not this countdown.
    static func warning(refreshTokenExpiresAt: Date?, now: Date) -> String? {
        guard let refreshTokenExpiresAt else { return nil }
        let remaining = refreshTokenExpiresAt.timeIntervalSince(now)
        guard remaining > 0, remaining < warningWindow else { return nil }
        return "Login expires in \(daysRemaining(until: refreshTokenExpiresAt, now: now))d"
    }

    /// Whole days remaining until `date`, floored — never rounded up, since overstating how
    /// much time is left is the wrong direction for a deadline warning — and floored again
    /// at 1 so anything still in the future reads as "1d" rather than "0d". Exposed (not
    /// `private`) so a caller that needs the true remaining days for a notification body,
    /// as opposed to the day-bucketed threshold that triggered it, can ask for it directly.
    static func daysRemaining(until date: Date, now: Date) -> Int {
        max(1, Int((date.timeIntervalSince(now) / secondsPerDay).rounded(.down)))
    }

    /// Per-account de-duplication for the 3-day / 1-day pre-expiry notification. Mirrors
    /// `ThresholdTracker`'s hysteresis so a menu-bar app refreshing every 60 seconds doesn't
    /// re-notify at the same remaining-days count: each threshold fires once per crossing,
    /// and clears once the expiry is back above the highest threshold — which is what a
    /// successful refresh does by re-arming the window.
    struct Notifier {
        private static let thresholds = [1, 3].sorted()
        private static let clearAbove = thresholds.max() ?? 0

        private var fired: Set<Int> = []

        /// Records the current refresh-token expiry and returns the day-thresholds newly
        /// crossed this call — the threshold values (3, 1) themselves, not the true days
        /// remaining; a caller wanting the true value for display calls
        /// `LoginExpiry.daysRemaining(until:now:)` separately. Empty when the expiry is
        /// unknown, already past (the dead-login pill's case, not this notifier's), or
        /// hasn't reached a threshold that hasn't already fired.
        mutating func check(refreshTokenExpiresAt: Date?, now: Date) -> [Int] {
            guard let refreshTokenExpiresAt else { return [] }
            let remaining = refreshTokenExpiresAt.timeIntervalSince(now)
            guard remaining > 0 else { return [] }

            let days = LoginExpiry.daysRemaining(until: refreshTokenExpiresAt, now: now)
            guard days <= Self.clearAbove else {
                fired = []
                return []
            }

            var crossed: [Int] = []
            for threshold in Self.thresholds where days <= threshold {
                if fired.insert(threshold).inserted { crossed.append(threshold) }
            }
            return crossed
        }
    }
}

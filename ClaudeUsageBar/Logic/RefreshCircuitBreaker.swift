import Foundation

/// Per-account circuit breaker for OAuth refreshes. Trips after `maxFailures` consecutive
/// hard rejections and then blocks further refresh attempts until `reArmInterval` has
/// elapsed — at which point one attempt is allowed through (half-open). A success, or a
/// transient failure, clears the count so a flaky network never accumulates toward a trip.
///
/// Time is injected (`now`) so the re-arm is deterministic in tests. Pure value type: the
/// runtime owns one and mutates it on the MainActor.
struct RefreshCircuitBreaker: Equatable {
    private let maxFailures: Int
    private let reArmInterval: TimeInterval
    private var consecutiveRejections = 0
    private var trippedAt: Date?

    init(maxFailures: Int = 3, reArmInterval: TimeInterval = 600) {
        self.maxFailures = maxFailures
        self.reArmInterval = reArmInterval
    }

    /// Whether a refresh may be attempted now. False while tripped and still inside the
    /// re-arm window; true again once the window elapses (half-open).
    func allowsAttempt(now: Date) -> Bool {
        guard let trippedAt else { return true }
        return now.timeIntervalSince(trippedAt) >= reArmInterval
    }

    /// Record the outcome of a refresh attempt. Rejections accumulate toward a trip;
    /// success or a transient failure resets the breaker.
    mutating func record(_ outcome: OAuthRefreshOutcome, now: Date) {
        switch outcome {
        case .transient:
            reset()
        case .rejected:
            consecutiveRejections += 1
            if consecutiveRejections >= maxFailures {
                trippedAt = now
            }
        }
    }

    /// Record a successful refresh — always fully resets.
    mutating func recordSuccess() {
        reset()
    }

    /// Fully un-trips the breaker back to its initial state, keeping `maxFailures`/
    /// `reArmInterval` as configured (unlike reassigning a fresh `RefreshCircuitBreaker()`,
    /// which would also reset those to their defaults).
    mutating func reset() {
        consecutiveRejections = 0
        trippedAt = nil
    }
}

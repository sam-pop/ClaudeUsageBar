import Foundation

/// Exponential-backoff delay calculator for retrying transient failures. Pure and
/// RNG-injectable so the jitter is testable. Wired into `UsageViewModel` in Phase 4.
struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let jitterRange: ClosedRange<Double>

    init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 8,
        jitterRange: ClosedRange<Double> = 0.8...1.2
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterRange = jitterRange
    }

    /// Un-jittered backoff for a 1-based attempt index: `baseDelay * 2^(attempt-1)`, capped at `maxDelay`.
    func backoff(forAttempt attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2, Double(max(0, attempt - 1)))
        return min(exponential, maxDelay)
    }

    /// Jittered delay for a 1-based attempt index, multiplying the backoff by a random
    /// factor drawn from `jitterRange` using the supplied generator.
    func delay<G: RandomNumberGenerator>(forAttempt attempt: Int, using rng: inout G) -> TimeInterval {
        backoff(forAttempt: attempt) * Double.random(in: jitterRange, using: &rng)
    }
}

import Testing
import Foundation

@Suite("RefreshCircuitBreaker")
struct RefreshCircuitBreakerTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Starts closed (allows attempts)")
    func startsClosed() {
        let breaker = RefreshCircuitBreaker()
        #expect(breaker.allowsAttempt(now: t0))
    }

    @Test("Trips after maxFailures consecutive rejections")
    func tripsAfterMaxFailures() {
        var breaker = RefreshCircuitBreaker(maxFailures: 3, reArmInterval: 600)
        breaker.record(.rejected, now: t0)
        breaker.record(.rejected, now: t0)
        #expect(breaker.allowsAttempt(now: t0)) // still closed after 2
        breaker.record(.rejected, now: t0)
        #expect(!breaker.allowsAttempt(now: t0)) // tripped after 3
    }

    @Test("Re-arms (half-open) once the interval elapses")
    func reArmsAfterInterval() {
        var breaker = RefreshCircuitBreaker(maxFailures: 1, reArmInterval: 600)
        breaker.record(.rejected, now: t0)
        #expect(!breaker.allowsAttempt(now: t0))
        #expect(!breaker.allowsAttempt(now: t0.addingTimeInterval(599)))
        #expect(breaker.allowsAttempt(now: t0.addingTimeInterval(600)))
    }

    @Test("A transient failure does not count toward tripping")
    func transientDoesNotTrip() {
        var breaker = RefreshCircuitBreaker(maxFailures: 2, reArmInterval: 600)
        breaker.record(.rejected, now: t0)
        breaker.record(.transient, now: t0) // resets the count
        breaker.record(.rejected, now: t0)
        #expect(breaker.allowsAttempt(now: t0)) // only 1 consecutive rejection since reset
    }

    @Test("Success resets a partially-failed breaker")
    func successResets() {
        var breaker = RefreshCircuitBreaker(maxFailures: 2, reArmInterval: 600)
        breaker.record(.rejected, now: t0)
        breaker.recordSuccess()
        breaker.record(.rejected, now: t0)
        #expect(breaker.allowsAttempt(now: t0))
    }
}

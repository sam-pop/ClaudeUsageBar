import Testing
import Foundation

@Suite("LoginExpiry.warning")
struct LoginExpiryTests {
    @Test("Warns within 7 days, silent beyond, nil when unknown")
    func warns() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: now.addingTimeInterval(3*86400), now: now) == "Login expires in 3d")
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: now.addingTimeInterval(20*86400), now: now) == nil)
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: nil, now: now) == nil)
    }

    @Test("Silent once the expiry has already passed — that's the dead-login pill's job, not this one's")
    func silentOnceExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: now.addingTimeInterval(-1), now: now) == nil)
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: now, now: now) == nil)
    }

    @Test("A partial day still under 7 rounds up rather than reading nil at the boundary")
    func partialDayRoundsUp() {
        let now = Date(timeIntervalSince1970: 0)
        // 6.5 days out: under the 7-day window, so it must still warn, rounded to 7d rather
        // than truncating to a 6d that reads as "further along" than an even 6d expiry.
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: now.addingTimeInterval(6.5*86400), now: now) == "Login expires in 7d")
        // Exactly 7 days out is not yet "under 7 days".
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: now.addingTimeInterval(7*86400), now: now) == nil)
    }
}

@Suite("LoginExpiry.Notifier")
struct LoginExpiryNotifierTests {
    private let now = Date(timeIntervalSince1970: 0)

    @Test("Fires the 3d threshold once, then the 1d threshold once as the expiry keeps closing in")
    func firesEachThresholdOnce() {
        var notifier = LoginExpiry.Notifier()

        // Still outside every threshold: nothing fires.
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(5*86400), now: now) == [])

        // Crosses into the 3-day threshold.
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(3*86400), now: now) == [3])

        // A repeated refresh at the SAME remaining days must not re-notify — a menu-bar app
        // refreshing every 60 seconds would otherwise fire this dozens of times an hour.
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(3*86400), now: now) == [])
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(2*86400), now: now) == [])

        // Crosses into the 1-day threshold too.
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(1*86400), now: now) == [1])
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(1*86400), now: now) == [])
    }

    @Test("A refresh that re-arms the ~28-day window lets a later approach notify again")
    func rearmsAboveTheHighestThreshold() {
        var notifier = LoginExpiry.Notifier()

        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(3*86400), now: now) == [3])

        // The refresh token got renewed, pushing the expiry back out past every threshold.
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(28*86400), now: now) == [])

        // Approaching expiry again fires 3d fresh, rather than staying silenced forever.
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(3*86400), now: now) == [3])
    }

    @Test("An unknown or already-past expiry never fires — that case belongs to the dead-login pill")
    func unknownOrPastNeverFires() {
        var notifier = LoginExpiry.Notifier()
        #expect(notifier.check(refreshTokenExpiresAt: nil, now: now) == [])
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(-1), now: now) == [])
    }

    @Test("A jump straight past both thresholds in one call fires both, oldest first")
    func bigJumpFiresBothThresholds() {
        var notifier = LoginExpiry.Notifier()
        #expect(notifier.check(refreshTokenExpiresAt: now.addingTimeInterval(0.5*86400), now: now) == [1, 3])
    }
}

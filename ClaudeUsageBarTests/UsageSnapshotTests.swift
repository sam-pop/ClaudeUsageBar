import Testing
import Foundation
// App sources are compiled directly into this test target (unhosted bundle.unit-test),
// so its types are in-module — no `import ClaudeUsageBar` needed.

@Suite("UsageSnapshot(from:)")
struct UsageSnapshotTests {

    @Test("Rounds utilization and parses fractional-seconds ISO8601 reset dates")
    func parsesResponse() throws {
        let response = UsageResponse(
            fiveHour: UsagePeriod(utilization: 42.4, resetsAt: "2026-07-09T18:30:00.000Z"),
            sevenDay: UsagePeriod(utilization: 87.6, resetsAt: "2026-07-16T00:00:00.000Z")
        )

        let snapshot = UsageSnapshot(from: response)

        // Rounding: 42.4 -> 42, 87.6 -> 88
        #expect(snapshot.fiveHourPercent == 42)
        #expect(snapshot.sevenDayPercent == 88)
        #expect(snapshot.higherPercent == 88)

        // Fractional-seconds ISO8601 parses to a concrete Date.
        let fiveHourReset = try #require(snapshot.fiveHourResetsAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try #require(formatter.date(from: "2026-07-09T18:30:00.000Z"))
        #expect(abs(fiveHourReset.timeIntervalSince(expected)) < 1)
        #expect(snapshot.sevenDayResetsAt != nil)
    }

    @Test("A window past its reset reads 0%, not the stale pre-reset value")
    func effectivePercentZeroesExpiredWindow() {
        let reset = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            fiveHourPercent: 100, sevenDayPercent: 60,
            fiveHourResetsAt: reset,
            sevenDayResetsAt: Date(timeIntervalSince1970: 10_000),
            fetchedAt: Date(timeIntervalSince1970: 500)
        )

        // Before the reset: raw value stands.
        #expect(snapshot.fiveHourEffectivePercent(now: Date(timeIntervalSince1970: 999)) == 100)
        // At and after the reset: the window has rolled over to a fresh 0%.
        #expect(snapshot.fiveHourEffectivePercent(now: reset) == 0)
        #expect(snapshot.fiveHourEffectivePercent(now: Date(timeIntervalSince1970: 2_000)) == 0)
        // A different window with a future reset is unaffected.
        #expect(snapshot.sevenDayEffectivePercent(now: Date(timeIntervalSince1970: 2_000)) == 60)
    }

    @Test("A window with no known reset keeps its raw percent")
    func effectivePercentNoResetKeepsRaw() {
        let snapshot = UsageSnapshot(
            fiveHourPercent: 73, sevenDayPercent: 40,
            fiveHourResetsAt: nil, sevenDayResetsAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(snapshot.fiveHourEffectivePercent(now: Date(timeIntervalSince1970: 999_999)) == 73)
    }

    @Test("Falls back to non-fractional ISO8601 reset dates")
    func parsesNonFractionalDates() throws {
        let response = UsageResponse(
            fiveHour: UsagePeriod(utilization: 10, resetsAt: "2026-07-09T12:00:00Z"),
            sevenDay: UsagePeriod(utilization: 20, resetsAt: "2026-07-16T00:00:00Z")
        )

        let snapshot = UsageSnapshot(from: response)

        let fiveHourReset = try #require(snapshot.fiveHourResetsAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = try #require(formatter.date(from: "2026-07-09T12:00:00Z"))
        #expect(abs(fiveHourReset.timeIntervalSince(expected)) < 1)
        #expect(snapshot.sevenDayResetsAt != nil)
    }
}

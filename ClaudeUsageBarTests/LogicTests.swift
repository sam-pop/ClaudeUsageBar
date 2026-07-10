import Testing
import Foundation

// MARK: - MenuBarSelection

@Suite("MenuBarSelection.active")
struct MenuBarSelectionTests {

    private func snapshot(fiveHour: Int, sevenDay: Int) -> UsageSnapshot {
        UsageSnapshot(
            fiveHourPercent: fiveHour,
            sevenDayPercent: sevenDay,
            fiveHourResetsAt: Date(timeIntervalSince1970: 100),
            sevenDayResetsAt: Date(timeIntervalSince1970: 200),
            fetchedAt: Date()
        )
    }

    @Test("Auto picks higher window, ties go to 5h, explicit modes honored, nil snapshot")
    func selection() throws {
        // Auto picks the higher-utilization window.
        let autoHigh5h = try #require(MenuBarSelection.active(mode: .auto, snapshot: snapshot(fiveHour: 90, sevenDay: 40)))
        #expect(autoHigh5h.window == .fiveHour)
        #expect(autoHigh5h.percent == 90)
        #expect(autoHigh5h.resetsAt == Date(timeIntervalSince1970: 100))

        let autoHigh7d = try #require(MenuBarSelection.active(mode: .auto, snapshot: snapshot(fiveHour: 30, sevenDay: 70)))
        #expect(autoHigh7d.window == .sevenDay)
        #expect(autoHigh7d.percent == 70)

        // Tie goes to the 5-hour window (>=).
        let tie = try #require(MenuBarSelection.active(mode: .auto, snapshot: snapshot(fiveHour: 50, sevenDay: 50)))
        #expect(tie.window == .fiveHour)

        // Explicit modes override utilization comparison.
        let explicit5h = try #require(MenuBarSelection.active(mode: .fiveHour, snapshot: snapshot(fiveHour: 10, sevenDay: 90)))
        #expect(explicit5h.window == .fiveHour)
        #expect(explicit5h.percent == 10)

        let explicit7d = try #require(MenuBarSelection.active(mode: .sevenDay, snapshot: snapshot(fiveHour: 90, sevenDay: 10)))
        #expect(explicit7d.window == .sevenDay)
        #expect(explicit7d.percent == 10)

        // Nil snapshot yields nil.
        #expect(MenuBarSelection.active(mode: .auto, snapshot: nil) == nil)
    }
}

// MARK: - ThresholdTracker

@Suite("ThresholdTracker")
struct ThresholdTrackerTests {

    @Test("Fires once per crossing, re-fires higher tier, re-arms below floor, windows independent")
    func crossings() {
        var tracker = ThresholdTracker(thresholds: [80, 90])

        // First crossing of 80 on the 5h window only.
        let first = tracker.record(fiveHour: 85, sevenDay: 10)
        #expect(first == [ThresholdTracker.Crossing(window: .fiveHour, threshold: 80, percent: 85)])

        // Same reading again: no re-fire.
        #expect(tracker.record(fiveHour: 85, sevenDay: 10).isEmpty)

        // Rising into 90 fires only the newly-crossed tier.
        let ninety = tracker.record(fiveHour: 95, sevenDay: 10)
        #expect(ninety == [ThresholdTracker.Crossing(window: .fiveHour, threshold: 90, percent: 95)])

        // Seven-day window is tracked independently.
        let sevenDay = tracker.record(fiveHour: 95, sevenDay: 82)
        #expect(sevenDay == [ThresholdTracker.Crossing(window: .sevenDay, threshold: 80, percent: 82)])

        // Dropping the 5h window below the lowest threshold re-arms it (no crossing on the drop).
        #expect(tracker.record(fiveHour: 50, sevenDay: 82).isEmpty)
        let rearmed = tracker.record(fiveHour: 88, sevenDay: 82)
        #expect(rearmed == [ThresholdTracker.Crossing(window: .fiveHour, threshold: 80, percent: 88)])
    }

    @Test("sanitizedThresholds sorts, clamps, dedupes, drops junk, and falls back to default")
    func sanitize() {
        // Valid, already-sorted input passes through.
        #expect(ThresholdTracker.sanitizedThresholds(from: [80, 90]) == [80, 90])

        // nil and empty fall back to the default.
        #expect(ThresholdTracker.sanitizedThresholds(from: nil) == [80, 90])
        #expect(ThresholdTracker.sanitizedThresholds(from: []) == [80, 90])

        // Unsorted input is sorted; duplicates removed.
        #expect(ThresholdTracker.sanitizedThresholds(from: [90, 80, 80]) == [80, 90])

        // Junk entries dropped, out-of-range values clamped into 1...100.
        // "abc" -> dropped, 250 -> 100, 0 -> 1, plus 80 and 90.
        #expect(ThresholdTracker.sanitizedThresholds(from: ["abc", 250, 0, 90, 80]) == [1, 80, 90, 100])

        // Strings that parse as ints are accepted (defaults write stores numbers as strings).
        #expect(ThresholdTracker.sanitizedThresholds(from: ["70", "95"]) == [70, 95])
    }
}

// MARK: - HistoryBuffer

@Suite("HistoryBuffer.appending")
struct HistoryBufferTests {

    private func point(at t: TimeInterval, five: Int = 0, seven: Int = 0) -> UsageDataPoint {
        UsageDataPoint(timestamp: Date(timeIntervalSince1970: t), fiveHourPercent: five, sevenDayPercent: seven)
    }

    @Test("Skips samples within the interval")
    func skipsWithinInterval() {
        let history = [point(at: 1000)]
        let result = HistoryBuffer.appending(point(at: 1100), to: history, maxPoints: 288, minInterval: 300)
        #expect(result.count == 1)
        #expect(result.last?.timestamp == Date(timeIntervalSince1970: 1000))
    }

    @Test("Appends once the interval has elapsed, preserving order")
    func appendsAfterInterval() {
        let history = [point(at: 1000)]
        let result = HistoryBuffer.appending(point(at: 1300), to: history, maxPoints: 288, minInterval: 300)
        #expect(result.count == 2)
        #expect(result.last?.timestamp == Date(timeIntervalSince1970: 1300))
    }

    @Test("Caps at maxPoints, dropping oldest")
    func capsAtMax() {
        var history: [UsageDataPoint] = []
        for i in 0..<5 { history.append(point(at: TimeInterval(i * 1000))) }
        let result = HistoryBuffer.appending(point(at: 9000), to: history, maxPoints: 5, minInterval: 300)
        #expect(result.count == 5)
        // Oldest (t=0) dropped; newest is last.
        #expect(result.first?.timestamp == Date(timeIntervalSince1970: 1000))
        #expect(result.last?.timestamp == Date(timeIntervalSince1970: 9000))
    }

    @Test("Appends to an empty buffer")
    func appendsToEmpty() {
        let result = HistoryBuffer.appending(point(at: 500), to: [], maxPoints: 288, minInterval: 300)
        #expect(result.count == 1)
    }
}

// MARK: - RetryPolicy

/// Deterministic, seedable RNG for jitter tests (SplitMix64).
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {

    @Test("Exponential backoff caps, jitter stays in range, default attempts")
    func backoffAndJitter() {
        let policy = RetryPolicy() // base 1, cap 8, jitter 0.8...1.2, maxAttempts 3
        #expect(policy.maxAttempts == 3)

        // 1, 2, 4, then capped at 8.
        #expect(policy.backoff(forAttempt: 1) == 1)
        #expect(policy.backoff(forAttempt: 2) == 2)
        #expect(policy.backoff(forAttempt: 3) == 4)
        #expect(policy.backoff(forAttempt: 4) == 8)
        #expect(policy.backoff(forAttempt: 5) == 8)

        // Jittered delay stays within [0.8, 1.2] * backoff for a seeded RNG.
        var rng = SeededRNG(seed: 42)
        for attempt in 1...5 {
            let base = policy.backoff(forAttempt: attempt)
            let delay = policy.delay(forAttempt: attempt, using: &rng)
            #expect(delay >= base * 0.8)
            #expect(delay <= base * 1.2)
        }
    }
}

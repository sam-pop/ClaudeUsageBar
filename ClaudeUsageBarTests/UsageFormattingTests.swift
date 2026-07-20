import Testing
import Foundation

@Suite("UsageFormatting")
struct UsageFormattingTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("resetCountdown formats days/hours/minutes, now, and unknown")
    func resetCountdown() {
        #expect(UsageFormatting.resetCountdown(until: nil, now: now) == "—")
        #expect(UsageFormatting.resetCountdown(until: now.addingTimeInterval(30), now: now) == "now")
        #expect(UsageFormatting.resetCountdown(until: now.addingTimeInterval(18 * 60), now: now) == "18m")
        #expect(UsageFormatting.resetCountdown(until: now.addingTimeInterval(4 * 3600 + 12 * 60), now: now) == "4h 12m")
        #expect(UsageFormatting.resetCountdown(until: now.addingTimeInterval(2 * 86400 + 3 * 3600), now: now) == "2d 3h")
    }

    @Test("lastUpdatedText formats recency")
    func lastUpdated() {
        #expect(UsageFormatting.lastUpdatedText(since: now, now: now) == "just now")
        #expect(UsageFormatting.lastUpdatedText(since: now, now: now.addingTimeInterval(30)) == "30s ago")
        #expect(UsageFormatting.lastUpdatedText(since: now, now: now.addingTimeInterval(120)) == "2m ago")
    }
}

import Testing
import Foundation

@Suite("UsageComparison.leaders")
struct UsageComparisonLeadersTests {

    @Test("Flags the single highest account")
    func singleLeader() {
        #expect(UsageComparison.leaders([1, 100]) == [false, true])
        #expect(UsageComparison.leaders([64, 50]) == [true, false])
        #expect(UsageComparison.leaders([30, 30, 90]) == [false, false, true])
    }

    @Test("Flags every account tied at the top")
    func tiedLeaders() {
        #expect(UsageComparison.leaders([90, 90, 10]) == [true, true, false])
    }

    @Test("No leader when there's nothing to compare")
    func noLeader() {
        // A single present value.
        #expect(UsageComparison.leaders([nil, 100]) == [false, false])
        // All equal — no meaningful peak.
        #expect(UsageComparison.leaders([50, 50]) == [false, false])
        // All zero.
        #expect(UsageComparison.leaders([0, 0]) == [false, false])
        // Nothing present.
        #expect(UsageComparison.leaders([nil, nil]) == [false, false])
    }

    @Test("A missing metric is never the leader")
    func nilNeverLeads() {
        #expect(UsageComparison.leaders([nil, 40, 80]) == [false, false, true])
    }
}

@Suite("UsageComparison.modelRowNames")
struct UsageComparisonModelRowTests {

    private func limit(_ name: String) -> ModelLimit {
        ModelLimit(modelName: name, percent: 0, resetsAt: nil, severity: nil)
    }

    @Test("Unions model names across accounts in first-seen order, de-duplicated")
    func union() {
        let a = [limit("Fable"), limit("Opus")]
        let b = [limit("Fable"), limit("Sonnet")]
        #expect(UsageComparison.modelRowNames([a, b]) == ["Fable", "Opus", "Sonnet"])
    }

    @Test("No models yields no rows")
    func empty() {
        #expect(UsageComparison.modelRowNames([[], []]) == [])
    }
}

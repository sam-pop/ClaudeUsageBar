import Testing
import Foundation

@Suite("UsageSnapshot model limits")
struct ModelLimitTests {

    /// The `limits` array shape captured live from the real endpoint.
    private let payload = """
    {
      "five_hour": {"utilization": 2.0, "resets_at": "2026-07-20T05:00:00Z"},
      "seven_day": {"utilization": 49.0, "resets_at": "2026-07-26T03:00:00Z"},
      "limits": [
        {"kind": "session", "percent": 3, "severity": "normal", "resets_at": "2026-07-20T09:59:59Z", "scope": null, "is_active": false},
        {"kind": "weekly_all", "percent": 60, "severity": "normal", "resets_at": "2026-07-26T02:59:59Z", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "percent": 97, "severity": "critical", "resets_at": "2026-07-26T02:59:59Z", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
      ]
    }
    """

    @Test("Extracts model-scoped limits (Fable) and ignores unscoped ones")
    func extractsFable() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(payload.utf8))
        let snapshot = UsageSnapshot(from: response)

        let limits = try #require(snapshot.modelLimits)
        #expect(limits.count == 1)   // only the model-scoped entry
        let fable = try #require(limits.first)
        #expect(fable.modelName == "Fable")
        #expect(fable.percent == 97)
        #expect(fable.severity == "critical")
        #expect(fable.resetsAt != nil)
    }

    @Test("Nil when the response has no limits array (older API)")
    func noLimits() {
        let response = UsageResponse(
            fiveHour: UsagePeriod(utilization: 10, resetsAt: "2026-07-20T05:00:00Z"),
            sevenDay: UsagePeriod(utilization: 20, resetsAt: "2026-07-26T03:00:00Z")
        )
        #expect(UsageSnapshot(from: response).modelLimits == nil)
    }

    @Test("Snapshot with model limits round-trips through JSON persistence")
    func roundTrips() throws {
        let original = UsageSnapshot(
            fiveHourPercent: 2, sevenDayPercent: 49,
            fiveHourResetsAt: nil, sevenDayResetsAt: nil, fetchedAt: Date(),
            modelLimits: [ModelLimit(modelName: "Fable", percent: 97, resetsAt: nil, severity: "critical")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.modelLimits?.first?.modelName == "Fable")
        #expect(decoded.modelLimits?.first?.percent == 97)
    }

    @Test("Old persisted snapshot without the field still decodes (nil)")
    func backwardCompatible() throws {
        let legacy = #"{"fiveHourPercent":2,"sevenDayPercent":49,"fetchedAt":770000000}"#
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.modelLimits == nil)
        #expect(decoded.fiveHourPercent == 2)
    }
}

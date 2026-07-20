import Foundation

// MARK: - API Response (Codable)

struct UsageResponse: Codable {
    let fiveHour: UsagePeriod
    let sevenDay: UsagePeriod
    /// Newer, richer limit list. Model-scoped entries (e.g. Fable) live here; absent on
    /// older API responses, so optional.
    let limits: [UsageLimitDTO]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    init(fiveHour: UsagePeriod, sevenDay: UsagePeriod, limits: [UsageLimitDTO]? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
    }
}

struct UsagePeriod: Codable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// One entry of the API's `limits` array. Only model-scoped entries interest us here;
/// `scope.model.display_name` names the model (e.g. "Fable").
struct UsageLimitDTO: Codable {
    let percent: Double?
    let severity: String?
    let resetsAt: String?
    let scope: Scope?

    struct Scope: Codable {
        let model: Model?
        struct Model: Codable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
    }

    enum CodingKeys: String, CodingKey {
        case percent, severity, scope
        case resetsAt = "resets_at"
    }
}

/// View-ready per-model usage limit (e.g. Fable at 97%).
struct ModelLimit: Codable, Equatable, Identifiable {
    let modelName: String
    let percent: Int
    let resetsAt: Date?
    let severity: String?
    var id: String { modelName }
}

// MARK: - View-ready model

struct UsageSnapshot: Codable {
    let fiveHourPercent: Int
    let sevenDayPercent: Int
    let fiveHourResetsAt: Date?
    let sevenDayResetsAt: Date?
    let fetchedAt: Date
    /// Per-model limits (e.g. Fable). Optional so snapshots persisted before this field
    /// existed still decode.
    let modelLimits: [ModelLimit]?

    var higherPercent: Int {
        max(fiveHourPercent, sevenDayPercent)
    }

    init(fiveHourPercent: Int, sevenDayPercent: Int, fiveHourResetsAt: Date?, sevenDayResetsAt: Date?, fetchedAt: Date, modelLimits: [ModelLimit]? = nil) {
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
        self.fetchedAt = fetchedAt
        self.modelLimits = modelLimits
    }

    init(from response: UsageResponse) {
        self.init(
            fiveHourPercent: Int(response.fiveHour.utilization.rounded()),
            sevenDayPercent: Int(response.sevenDay.utilization.rounded()),
            fiveHourResetsAt: Self.parseISO8601(response.fiveHour.resetsAt),
            sevenDayResetsAt: Self.parseISO8601(response.sevenDay.resetsAt),
            fetchedAt: Date(),
            modelLimits: Self.extractModelLimits(from: response.limits)
        )
    }

    /// Pulls model-scoped entries (those with a `scope.model.display_name`) out of the raw
    /// `limits` array into view-ready `ModelLimit`s. Returns nil when there are none.
    static func extractModelLimits(from limits: [UsageLimitDTO]?) -> [ModelLimit]? {
        guard let limits else { return nil }
        let modelLimits: [ModelLimit] = limits.compactMap { dto in
            guard let name = dto.scope?.model?.displayName else { return nil }
            return ModelLimit(
                modelName: name,
                percent: Int((dto.percent ?? 0).rounded()),
                resetsAt: dto.resetsAt.flatMap(Self.parseISO8601),
                severity: dto.severity
            )
        }
        return modelLimits.isEmpty ? nil : modelLimits
    }

    /// Parses an ISO8601 timestamp, tolerating both fractional-seconds
    /// (`…:00.000Z`) and plain (`…:00Z`) forms the API may return.
    private static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    func persist() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "lastSnapshot")
        }
    }

    static func loadCached() -> UsageSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: "lastSnapshot") else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }
}

// MARK: - Menu bar display mode

enum MenuBarDisplayMode: String, Codable, CaseIterable {
    case auto = "auto"
    case fiveHour = "5h"
    case sevenDay = "7d"

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        }
    }
}

// MARK: - History data point

struct UsageDataPoint: Codable {
    let timestamp: Date
    let fiveHourPercent: Int
    let sevenDayPercent: Int
}

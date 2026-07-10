import Foundation

// MARK: - API Response (Codable)

struct UsageResponse: Codable {
    let fiveHour: UsagePeriod
    let sevenDay: UsagePeriod

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
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

// MARK: - View-ready model

struct UsageSnapshot: Codable {
    let fiveHourPercent: Int
    let sevenDayPercent: Int
    let fiveHourResetsAt: Date?
    let sevenDayResetsAt: Date?
    let fetchedAt: Date

    var higherPercent: Int {
        max(fiveHourPercent, sevenDayPercent)
    }

    init(fiveHourPercent: Int, sevenDayPercent: Int, fiveHourResetsAt: Date?, sevenDayResetsAt: Date?, fetchedAt: Date) {
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
        self.fetchedAt = fetchedAt
    }

    init(from response: UsageResponse) {
        self.init(
            fiveHourPercent: Int(response.fiveHour.utilization.rounded()),
            sevenDayPercent: Int(response.sevenDay.utilization.rounded()),
            fiveHourResetsAt: Self.parseISO8601(response.fiveHour.resetsAt),
            sevenDayResetsAt: Self.parseISO8601(response.sevenDay.resetsAt),
            fetchedAt: Date()
        )
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

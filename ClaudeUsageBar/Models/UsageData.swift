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

struct UsageSnapshot {
    let fiveHourPercent: Int
    let sevenDayPercent: Int
    let fiveHourResetsAt: Date?
    let sevenDayResetsAt: Date?
    let fetchedAt: Date

    var higherPercent: Int {
        max(fiveHourPercent, sevenDayPercent)
    }

    init(from response: UsageResponse) {
        self.fiveHourPercent = Int(response.fiveHour.utilization.rounded())
        self.sevenDayPercent = Int(response.sevenDay.utilization.rounded())

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        self.fiveHourResetsAt = formatter.date(from: response.fiveHour.resetsAt)
        self.sevenDayResetsAt = formatter.date(from: response.sevenDay.resetsAt)
        self.fetchedAt = Date()
    }
}

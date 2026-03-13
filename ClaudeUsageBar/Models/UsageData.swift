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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        self.init(
            fiveHourPercent: Int(response.fiveHour.utilization.rounded()),
            sevenDayPercent: Int(response.sevenDay.utilization.rounded()),
            fiveHourResetsAt: formatter.date(from: response.fiveHour.resetsAt),
            sevenDayResetsAt: formatter.date(from: response.sevenDay.resetsAt),
            fetchedAt: Date()
        )
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

// MARK: - History data point

struct UsageDataPoint: Codable {
    let timestamp: Date
    let fiveHourPercent: Int
    let sevenDayPercent: Int
}

import Foundation

/// Per-account persistence of the last snapshot and usage history, namespaced by account
/// id so two accounts never collide on the old flat `"lastSnapshot"` / `"usageHistory"`
/// keys. `UserDefaults` is injected so tests use an ephemeral suite instead of the shared
/// `.standard` domain.
struct AccountPersistence {
    let defaults: UserDefaults
    let accountID: UUID

    private var snapshotKey: String { "lastSnapshot-\(accountID.uuidString)" }
    private var historyKey: String { "usageHistory-\(accountID.uuidString)" }

    init(defaults: UserDefaults = .standard, accountID: UUID) {
        self.defaults = defaults
        self.accountID = accountID
    }

    func saveSnapshot(_ snapshot: UsageSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    func loadSnapshot() -> UsageSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func saveHistory(_ history: [UsageDataPoint]) {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    func loadHistory() -> [UsageDataPoint] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([UsageDataPoint].self, from: data)) ?? []
    }
}

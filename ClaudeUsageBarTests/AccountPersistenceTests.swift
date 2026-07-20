import Testing
import Foundation

@Suite("AccountPersistence")
struct AccountPersistenceTests {

    /// A fresh, isolated defaults domain per test so nothing touches `.standard`.
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "AccountPersistenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func snapshot(five: Int, seven: Int) -> UsageSnapshot {
        UsageSnapshot(fiveHourPercent: five, sevenDayPercent: seven,
                      fiveHourResetsAt: nil, sevenDayResetsAt: nil, fetchedAt: Date())
    }

    @Test("Snapshot round-trips for one account")
    func snapshotRoundTrips() {
        let defaults = ephemeralDefaults()
        let store = AccountPersistence(defaults: defaults, accountID: UUID())

        store.saveSnapshot(snapshot(five: 42, seven: 17))
        let loaded = store.loadSnapshot()

        #expect(loaded?.fiveHourPercent == 42)
        #expect(loaded?.sevenDayPercent == 17)
    }

    @Test("Snapshots are namespaced — one account's data is invisible to another")
    func snapshotNamespaced() {
        let defaults = ephemeralDefaults()
        let a = AccountPersistence(defaults: defaults, accountID: UUID())
        let b = AccountPersistence(defaults: defaults, accountID: UUID())

        a.saveSnapshot(snapshot(five: 90, seven: 90))

        #expect(a.loadSnapshot()?.fiveHourPercent == 90)
        #expect(b.loadSnapshot() == nil)
    }

    @Test("History round-trips and defaults to empty")
    func historyRoundTrips() {
        let defaults = ephemeralDefaults()
        let store = AccountPersistence(defaults: defaults, accountID: UUID())

        #expect(store.loadHistory().isEmpty)

        let points = [
            UsageDataPoint(timestamp: Date(), fiveHourPercent: 10, sevenDayPercent: 20),
            UsageDataPoint(timestamp: Date(), fiveHourPercent: 30, sevenDayPercent: 40),
        ]
        store.saveHistory(points)

        let loaded = store.loadHistory()
        #expect(loaded.count == 2)
        #expect(loaded.last?.fiveHourPercent == 30)
    }

    @Test("History is namespaced per account")
    func historyNamespaced() {
        let defaults = ephemeralDefaults()
        let a = AccountPersistence(defaults: defaults, accountID: UUID())
        let b = AccountPersistence(defaults: defaults, accountID: UUID())

        a.saveHistory([UsageDataPoint(timestamp: Date(), fiveHourPercent: 5, sevenDayPercent: 6)])

        #expect(a.loadHistory().count == 1)
        #expect(b.loadHistory().isEmpty)
    }
}

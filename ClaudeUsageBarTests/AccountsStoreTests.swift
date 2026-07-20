import Testing
import Foundation

@Suite("AccountsStore")
struct AccountsStoreTests {

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "AccountsStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("Empty store has no accounts and loads an empty list")
    func emptyByDefault() {
        let store = AccountsStore(defaults: ephemeralDefaults())
        #expect(!store.hasAccounts)
        #expect(store.load().isEmpty)
    }

    @Test("Saved accounts round-trip in order and mark the store populated")
    func roundTrips() {
        let store = AccountsStore(defaults: ephemeralDefaults())
        let accounts = [
            Account(label: "Personal", accountUUID: "uuid-a", email: "a@example.com"),
            Account(label: "Work", accountUUID: "uuid-b"),
        ]
        store.save(accounts)

        #expect(store.hasAccounts)
        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded[0].label == "Personal")
        #expect(loaded[0].accountUUID == "uuid-a")
        #expect(loaded[0].email == "a@example.com")
        #expect(loaded[1].label == "Work")
        #expect(loaded[1].email == nil)
    }

    @Test("Saving an empty list still marks the store populated (distinguishes 'migrated to zero' from 'never migrated')")
    func emptyListIsPopulated() {
        let store = AccountsStore(defaults: ephemeralDefaults())
        store.save([])
        #expect(store.hasAccounts)
        #expect(store.load().isEmpty)
    }
}

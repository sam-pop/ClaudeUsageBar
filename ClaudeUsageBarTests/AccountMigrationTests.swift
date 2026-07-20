import Testing
import Foundation

@Suite("AccountMigration")
struct AccountMigrationTests {

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "AccountMigrationTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func legacyCreds() -> CachedCredentials {
        CachedCredentials(accessToken: "sk-ant-oat01-legacy", refreshToken: "r", expiresAt: nil)
    }

    /// Builds a migration with injectable seams; tracks whether legacy cleanup ran.
    private func makeMigration(
        defaults: UserDefaults,
        credentialStore: AccountCredentialStoring,
        legacyCreds: CachedCredentials?,
        onDelete: @escaping () -> Void = {}
    ) -> AccountMigration {
        AccountMigration(
            accountsStore: AccountsStore(defaults: defaults),
            credentialStore: credentialStore,
            defaults: defaults,
            resolveLegacyCredentials: { legacyCreds },
            deleteLegacyArtifacts: onDelete
        )
    }

    @Test("Fresh migration: legacy creds become Account 1 with namespaced state, legacy deleted")
    func freshMigration() throws {
        let defaults = ephemeralDefaults()
        let credStore = InMemoryAccountCredentialStore()
        // Seed legacy flat snapshot/history under the old keys.
        let snap = UsageSnapshot(fiveHourPercent: 55, sevenDayPercent: 66,
                                 fiveHourResetsAt: nil, sevenDayResetsAt: nil, fetchedAt: Date())
        defaults.set(try JSONEncoder().encode(snap), forKey: "lastSnapshot")
        defaults.set(try JSONEncoder().encode([UsageDataPoint(timestamp: Date(), fiveHourPercent: 1, sevenDayPercent: 2)]),
                     forKey: "usageHistory")

        var deleted = false
        let migration = makeMigration(defaults: defaults, credentialStore: credStore,
                                      legacyCreds: legacyCreds(), onDelete: { deleted = true })

        let accounts = migration.run()

        #expect(accounts.count == 1)
        let account = try #require(accounts.first)
        #expect(account.label == "Account 1")
        #expect(account.accountUUID == nil)   // identity backfilled later
        // Credentials moved into the account's slot in the map.
        #expect(try credStore.loadAll()[account.id]?.accessToken == "sk-ant-oat01-legacy")
        // Legacy flat snapshot/history copied to namespaced keys.
        let ns = AccountPersistence(defaults: defaults, accountID: account.id)
        #expect(ns.loadSnapshot()?.fiveHourPercent == 55)
        #expect(ns.loadHistory().count == 1)
        #expect(deleted)   // legacy artifacts cleaned up
    }

    @Test("Idempotent: a second run does not re-migrate or duplicate")
    func idempotent() throws {
        let defaults = ephemeralDefaults()
        let credStore = InMemoryAccountCredentialStore()
        let migration = makeMigration(defaults: defaults, credentialStore: credStore, legacyCreds: legacyCreds())

        let first = migration.run()
        let firstID = try #require(first.first?.id)

        // Second run: even if a "new" legacy cred appears, nothing changes.
        let migration2 = makeMigration(defaults: defaults, credentialStore: credStore,
                                       legacyCreds: CachedCredentials(accessToken: "sk-ant-oat01-other", refreshToken: "r2", expiresAt: nil))
        let second = migration2.run()

        #expect(second.count == 1)
        #expect(second.first?.id == firstID)          // same account, not re-minted
        #expect(try credStore.loadAll().count == 1)   // no duplicate credential slot
    }

    @Test("Rebuild-from-keychain: accounts list lost but credential map intact → rebuild, don't overwrite")
    func rebuildFromKeychain() throws {
        let defaults = ephemeralDefaults()   // no accounts.v1 key (defaults were reset)
        let existingA = UUID(), existingB = UUID()
        let credStore = InMemoryAccountCredentialStore([
            existingA: legacyCreds(),
            existingB: CachedCredentials(accessToken: "sk-ant-oat01-b", refreshToken: "rb", expiresAt: nil),
        ])
        var deleted = false
        let migration = makeMigration(defaults: defaults, credentialStore: credStore,
                                      legacyCreds: legacyCreds(), onDelete: { deleted = true })

        let accounts = migration.run()

        #expect(accounts.count == 2)                       // rebuilt from the 2 existing slots
        #expect(Set(accounts.map(\.id)) == Set([existingA, existingB]))
        #expect(try credStore.loadAll().count == 2)        // map untouched
        #expect(!deleted)                                  // not a legacy-cleanup path
    }

    @Test("Save failure: legacy artifacts are NOT deleted and migration is not marked done")
    func saveFailureKeepsLegacy() {
        let defaults = ephemeralDefaults()
        let credStore = NonPersistingAccountCredentialStore()   // save() drops the write
        var deleted = false
        let migration = makeMigration(defaults: defaults, credentialStore: credStore,
                                      legacyCreds: legacyCreds(), onDelete: { deleted = true })

        let accounts = migration.run()

        #expect(accounts.isEmpty)                                   // migration bailed
        #expect(!deleted)                                           // legacy creds preserved
        #expect(!AccountsStore(defaults: defaults).hasAccounts)     // will retry next launch
    }

    @Test("Fresh install: no legacy creds → empty populated list, no crash")
    func freshInstall() throws {
        let defaults = ephemeralDefaults()
        let credStore = InMemoryAccountCredentialStore()
        let migration = makeMigration(defaults: defaults, credentialStore: credStore, legacyCreds: nil)

        let accounts = migration.run()

        #expect(accounts.isEmpty)
        #expect(AccountsStore(defaults: defaults).hasAccounts)   // marked migrated (won't retry every launch)
    }
}

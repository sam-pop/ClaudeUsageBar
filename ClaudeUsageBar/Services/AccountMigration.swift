import Foundation

/// One-time migration from the single-account (≤1.2) layout to the multi-account
/// `accounts.v1` layout. Safe to run on every launch: it no-ops once an accounts list
/// exists, and never overwrites a populated credential map. All side-effecting inputs
/// (legacy credential read, legacy-artifact deletion) are injected so the decision logic
/// is testable without touching the keychain or filesystem.
struct AccountMigration {
    let accountsStore: AccountsStore
    let credentialStore: AccountCredentialStoring
    let defaults: UserDefaults
    /// Reads the legacy single-account credentials (app item → legacy plaintext file).
    let resolveLegacyCredentials: () -> CachedCredentials?
    /// Deletes the legacy plaintext file and the legacy single `oauth-credentials` item.
    let deleteLegacyArtifacts: () -> Void

    private let legacySnapshotKey = "lastSnapshot"
    private let legacyHistoryKey = "usageHistory"

    /// Runs the migration if it hasn't already. Returns the account list now in effect.
    @discardableResult
    func run() -> [Account] {
        // Idempotent: once a list exists, this is a no-op on every subsequent launch.
        if accountsStore.hasAccounts {
            return accountsStore.load()
        }

        // Defaults were reset but the credential map survived in the keychain — rebuild the
        // list from its slots rather than overwriting real accounts with a fresh single one.
        if let existing = try? credentialStore.loadAll(), !existing.isEmpty {
            let accounts = existing.keys.enumerated().map { index, id in
                Account(id: id, label: "Account \(index + 1)")
            }
            accountsStore.save(accounts)
            return accounts
        }

        // Fresh migration from the legacy single account, if any credentials exist.
        guard let creds = resolveLegacyCredentials() else {
            // Fresh install: mark migrated with an empty list so we don't retry every launch.
            accountsStore.save([])
            return []
        }

        let account = Account(label: "Account 1")

        // Persist the credentials and VERIFY the round-trip before doing anything
        // destructive. If the new copy didn't land, bail without marking migration done and
        // without deleting the legacy artifacts — the only surviving copy — so the next
        // launch retries.
        do {
            try credentialStore.save([account.id: creds])
            guard try credentialStore.loadAll()[account.id] != nil else { return [] }
        } catch {
            return []
        }

        migrateLegacyState(to: account.id)
        accountsStore.save([account])
        deleteLegacyArtifacts()
        return [account]
    }

    /// Copies the legacy flat `lastSnapshot` / `usageHistory` values into the account's
    /// namespaced keys. Best-effort — a decode failure just leaves that piece empty.
    private func migrateLegacyState(to id: UUID) {
        let namespaced = AccountPersistence(defaults: defaults, accountID: id)
        if let data = defaults.data(forKey: legacySnapshotKey),
           let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            namespaced.saveSnapshot(snapshot)
        }
        if let data = defaults.data(forKey: legacyHistoryKey),
           let history = try? JSONDecoder().decode([UsageDataPoint].self, from: data) {
            namespaced.saveHistory(history)
        }
    }
}

import Foundation

/// One tracked Claude account. `id` is the app's own stable handle and the key into
/// the credential map; `accountUUID`/`email` come from the OAuth profile endpoint at
/// capture time and drive labeling, dedupe, and the re-read identity guard.
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    /// Stable Claude account identity from the OAuth profile endpoint. `nil` until it has
    /// been fetched — the case for a legacy-migrated account (identity unknown at migration
    /// time, backfilled on the first successful profile fetch). Dedupe and the re-read
    /// identity guard only apply once this is populated.
    var accountUUID: String?
    var email: String?
    /// Optional user-chosen menu-bar prefix (e.g. "🏠" or "Me"). When set, it overrides the
    /// prefix auto-derived from `label`. `nil`/empty means "derive from the label".
    var shortCode: String?

    init(id: UUID = UUID(), label: String, accountUUID: String? = nil,
         email: String? = nil, shortCode: String? = nil) {
        self.id = id
        self.label = label
        self.accountUUID = accountUUID
        self.email = email
        self.shortCode = shortCode
    }
}

/// Persists the ordered account list under a single, versioned `UserDefaults` key.
/// `UserDefaults` is injected so tests use an ephemeral suite.
struct AccountsStore {
    static let key = "accounts.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a list has ever been written — the migration's idempotency guard.
    var hasAccounts: Bool {
        defaults.object(forKey: Self.key) != nil
    }

    func load() -> [Account] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    func save(_ accounts: [Account]) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

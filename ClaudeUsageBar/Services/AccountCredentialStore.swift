import Foundation
import Security

/// Errors from the multi-account credential store. `authFailed` means the keychain
/// item exists but couldn't be read (ACL broken by a code-signature change, or the
/// keychain is locked) — the caller MUST NOT overwrite on this, or it would destroy
/// every account's credentials. A genuinely-absent item is reported as an empty map,
/// never as an error.
enum AccountCredentialStoreError: Error, Equatable {
    case authFailed
    case saveFailed(OSStatus)
}

/// Persists the whole `[account.id: credentials]` map behind one keychain item. One
/// item = one ACL and no orphaned per-account items. The unit-test seam.
protocol AccountCredentialStoring: Sendable {
    func loadAll() throws -> [UUID: CachedCredentials]
    func save(_ map: [UUID: CachedCredentials]) throws
}

/// Owns per-account credential reads/writes with the read-modify-write discipline the
/// multi-account design requires: every mutation re-loads the full map fresh, changes
/// exactly one slot, and writes back — so two accounts' concurrent refreshes can't clobber
/// each other, and a load that fails with `authFailed` propagates BEFORE any save runs
/// (never overwriting the surviving accounts). `@MainActor` so the load→mutate→save runs
/// as one uninterrupted section.
@MainActor
final class AccountCredentialManager {
    private let store: AccountCredentialStoring

    init(store: AccountCredentialStoring) {
        self.store = store
    }

    func credentials(for id: UUID) throws -> CachedCredentials? {
        try store.loadAll()[id]
    }

    func update(id: UUID, credentials: CachedCredentials) throws {
        var map = try store.loadAll()   // throws authFailed → propagates before any save
        map[id] = credentials
        try store.save(map)
    }

    func remove(id: UUID) throws {
        var map = try store.loadAll()
        map[id] = nil
        try store.save(map)
    }
}

/// Pure interpretation of a `SecItemCopyMatching` result. The load path MUST distinguish
/// "item genuinely absent" (safe → empty map) from "item present but unreadable"
/// (ACL broken / keychain locked → `authFailed`, must never be overwritten). Anything
/// that isn't an unambiguous success-with-data or a clean not-found is treated as
/// `authFailed` — failing closed protects the surviving accounts from a destructive save.
enum KeychainLoadOutcome: Equatable {
    case found(Data)
    case notFound
    case authFailed

    static func classify(status: OSStatus, data: Data?) -> KeychainLoadOutcome {
        switch status {
        case errSecSuccess:
            // Success without data is anomalous; fail closed rather than risk an overwrite.
            if let data { return .found(data) }
            return .authFailed
        case errSecItemNotFound:
            return .notFound
        default:
            // errSecAuthFailed / errSecInteractionNotAllowed / anything else → don't overwrite.
            return .authFailed
        }
    }
}

/// Real single-item Keychain store: the whole `[account.id: credentials]` map lives in
/// ONE app-owned generic-password item, so there is one ACL to break and no per-account
/// orphans. Writes use `SecItemUpdate` (add-on-not-found) — never delete-then-add — so a
/// crash mid-write can't wipe every account. A present-but-unreadable item (ACL broken by
/// a code-signature change, or a locked/corrupt keychain) throws `authFailed`; the caller
/// must NOT overwrite on that.
///
/// Not unit-tested: its `SecItem*` calls hit the login keychain, which would prompt and
/// pollute the developer's keychain during `make test`. `AccountCredentialStoring` is the
/// seam; the load-classification and RMW logic are tested via the pure helpers above.
struct KeychainAccountCredentialStore: AccountCredentialStoring {
    private let service = "com.sam.ClaudeUsageBar"
    private let account = "accounts-credentials-v1"

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func loadAll() throws -> [UUID: CachedCredentials] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch KeychainLoadOutcome.classify(status: status, data: result as? Data) {
        case .notFound:
            return [:]
        case .authFailed:
            throw AccountCredentialStoreError.authFailed
        case .found(let data):
            // A present-but-undecodable payload is treated as authFailed, NEVER notFound —
            // returning empty here would greenlight a save that erases every account.
            do {
                return try AccountCredentialCodec.decode(data)
            } catch {
                throw AccountCredentialStoreError.authFailed
            }
        }
    }

    func save(_ map: [UUID: CachedCredentials]) throws {
        let data = try AccountCredentialCodec.encode(map)

        // Update in place when the item exists (no delete window); add on first write.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AccountCredentialStoreError.saveFailed(updateStatus)
        }

        var addAttributes = baseQuery()
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AccountCredentialStoreError.saveFailed(addStatus)
        }
    }
}

/// Bridges the credential map to/from the single keychain payload. `JSONEncoder`
/// serializes a `[UUID: _]` dictionary as a flat array (UUID isn't a string key), so
/// we round-trip through `[String: _]` keyed by `uuidString` to get a stable object.
enum AccountCredentialCodec {
    static func encode(_ map: [UUID: CachedCredentials]) throws -> Data {
        let stringKeyed = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        return try JSONEncoder().encode(stringKeyed)
    }

    static func decode(_ data: Data) throws -> [UUID: CachedCredentials] {
        if data.isEmpty { return [:] }
        let stringKeyed = try JSONDecoder().decode([String: CachedCredentials].self, from: data)
        return Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }
}

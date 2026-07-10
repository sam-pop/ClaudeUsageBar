import Foundation
import Security

/// Abstraction over where the app persists its own copy of the OAuth credentials.
/// The protocol is the unit-test seam — tests inject an in-memory store so they never
/// touch the real login keychain.
protocol CredentialStoring: Sendable {
    func load() -> CachedCredentials?
    func save(_ credentials: CachedCredentials)
    func delete()
}

/// Stores credentials in an app-owned generic-password Keychain item (encrypted at
/// rest, no-prompt reads for this app). Replaces the former plaintext file cache.
///
/// Not unit-tested: its SecItem* calls hit the login keychain, which would prompt and
/// pollute the developer's keychain during `make test`. `CredentialStoring` is the seam.
struct KeychainCredentialStore: CredentialStoring {
    private let service = "com.sam.ClaudeUsageBar"
    private let account = "oauth-credentials"

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func load() -> CachedCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let creds = try? JSONDecoder().decode(CachedCredentials.self, from: data),
                  !creds.accessToken.isEmpty else {
                return nil
            }
            return creds
        case errSecItemNotFound:
            // Nothing stored yet — a plain miss, no self-heal needed.
            return nil
        default:
            // Authorization-type failures (errSecAuthFailed / errSecInteractionNotAllowed /
            // user-denied) mean our own item's ACL no longer matches this build's code
            // signature — the ad-hoc-signing CDHash churned across rebuilds. Deleting needs
            // no ACL approval, so we drop the stale item and let the caller fall through the
            // migration chain to re-create it. Self-heals silently on the next launch.
            delete()
            return nil
        }
    }

    func save(_ credentials: CachedCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

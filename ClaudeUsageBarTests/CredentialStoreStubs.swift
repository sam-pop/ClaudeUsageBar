import Foundation

// Test doubles for the `CredentialStoring` seam. The real `KeychainCredentialStore`
// is deliberately never exercised in tests: its SecItem* calls hit the login
// keychain, which would prompt and pollute the developer's keychain during
// `make test`. These in-memory stand-ins are the test boundary.

/// In-memory `CredentialStoring` for tests. Single-threaded test use only.
final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var stored: CachedCredentials?
    func load() -> CachedCredentials? { stored }
    func save(_ credentials: CachedCredentials) { stored = credentials }
    func delete() { stored = nil }
}

/// A store whose `save` never persists and whose `load` always returns nil. Used to
/// prove the legacy plaintext file is retained when the round-trip verification fails.
final class FailingCredentialStore: CredentialStoring, @unchecked Sendable {
    func load() -> CachedCredentials? { nil }
    func save(_ credentials: CachedCredentials) {}
    func delete() {}
}

// MARK: - Multi-account credential store doubles

/// In-memory `AccountCredentialStoring` for tests. Single-threaded test use only.
final class InMemoryAccountCredentialStore: AccountCredentialStoring, @unchecked Sendable {
    private var map: [UUID: CachedCredentials]
    private(set) var saveCount = 0

    init(_ initial: [UUID: CachedCredentials] = [:]) { self.map = initial }

    func loadAll() throws -> [UUID: CachedCredentials] { map }
    func save(_ map: [UUID: CachedCredentials]) throws {
        self.map = map
        saveCount += 1
    }
}

/// A store whose `save` silently fails to persist (loadAll stays empty). Proves the
/// migration won't delete the legacy credentials when the new copy didn't actually land.
final class NonPersistingAccountCredentialStore: AccountCredentialStoring, @unchecked Sendable {
    func loadAll() throws -> [UUID: CachedCredentials] { [:] }
    func save(_ map: [UUID: CachedCredentials]) throws { /* drops the write */ }
}

/// A store whose `loadAll` always throws `authFailed` (ACL broken / keychain locked).
/// `save` records whether it was ever reached — the invariant under test is that it is
/// NOT, so a login-less mutation can never wipe the surviving accounts.
final class AuthFailedAccountCredentialStore: AccountCredentialStoring, @unchecked Sendable {
    private(set) var saveWasCalled = false
    func loadAll() throws -> [UUID: CachedCredentials] { throw AccountCredentialStoreError.authFailed }
    func save(_ map: [UUID: CachedCredentials]) throws { saveWasCalled = true }
}

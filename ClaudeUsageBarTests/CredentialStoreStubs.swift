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

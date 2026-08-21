import Testing
import Foundation

// MARK: - CachedCredentials refresh expiry

@Suite("CachedCredentials refresh expiry")
struct CachedCredentialsExpiry {
    @Test("Legacy payload without refreshTokenExpiresAt decodes with nil")
    func legacyDecodes() throws {
        let legacy = #"{"accessToken":"a","refreshToken":"r"}"#
        let creds = try JSONDecoder().decode(CachedCredentials.self, from: Data(legacy.utf8))
        #expect(creds.refreshTokenExpiresAt == nil)
        #expect(creds.accessToken == "a")
    }

    @Test("Round-trips a set refreshTokenExpiresAt")
    func roundTrips() throws {
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        let creds = CachedCredentials(accessToken: "a", refreshToken: "r", expiresAt: nil, refreshTokenExpiresAt: when)
        let data = try JSONEncoder().encode(creds)
        let back = try JSONDecoder().decode(CachedCredentials.self, from: data)
        #expect(back.refreshTokenExpiresAt == when)
    }
}

// MARK: - CachedCredentials Codable

@Suite("CachedCredentials Codable")
struct CachedCredentialsCodableTests {

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        let original = CachedCredentials(
            accessToken: "sk-ant-oat01-round",
            refreshToken: "sk-ant-ort01-trip",
            expiresAt: Date(timeIntervalSince1970: 1_783_002_600)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedCredentials.self, from: data)
        #expect(decoded.accessToken == original.accessToken)
        #expect(decoded.refreshToken == original.refreshToken)
        let expiresAt = try #require(decoded.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince1970 - 1_783_002_600) < 0.001)
    }

    @Test("Round-trips with nil optionals")
    func roundTripNil() throws {
        let original = CachedCredentials(accessToken: "t", refreshToken: nil, expiresAt: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedCredentials.self, from: data)
        #expect(decoded.accessToken == "t")
        #expect(decoded.refreshToken == nil)
        #expect(decoded.expiresAt == nil)
    }
}

// MARK: - KeychainService credential migration
//
// These exercise the migration chain through the `CredentialStoring` seam only. The
// real `KeychainCredentialStore` (SecItem* calls) is never touched — it would prompt
// and pollute the login keychain during `make test`. `.serialized` because the tests
// mutate the shared `KeychainService.store` global.

@Suite("KeychainService credential migration", .serialized)
struct KeychainMigrationTests {

    private func tempLegacyURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageBarTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".credentials.json")
    }

    @Test("Store hit returns stored creds without reading the legacy file")
    func storeHit() throws {
        let store = InMemoryCredentialStore()
        store.save(CachedCredentials(accessToken: "sk-ant-oat01-stored", refreshToken: "r", expiresAt: nil))
        KeychainService.store = store

        // Point the legacy URL at a file that would parse to *different* creds; it must be ignored.
        let legacyURL = tempLegacyURL()
        let other = CachedCredentials(accessToken: "sk-ant-oat01-legacy", refreshToken: nil, expiresAt: nil)
        try JSONEncoder().encode(other).write(to: legacyURL)

        let result = try #require(KeychainService.getCredentials(legacyFileURL: legacyURL))
        #expect(result.accessToken == "sk-ant-oat01-stored")
        #expect(FileManager.default.fileExists(atPath: legacyURL.path)) // legacy file untouched
    }

    @Test("Legacy JSON file migrates to the store and is deleted after verified round-trip")
    func legacyJSONMigrates() throws {
        let store = InMemoryCredentialStore()
        KeychainService.store = store
        let legacyURL = tempLegacyURL()
        let legacy = CachedCredentials(
            accessToken: "sk-ant-oat01-legacy",
            refreshToken: "sk-ant-ort01-r",
            expiresAt: Date(timeIntervalSince1970: 1_783_002_600)
        )
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let result = try #require(KeychainService.getCredentials(legacyFileURL: legacyURL))
        #expect(result.accessToken == "sk-ant-oat01-legacy")
        #expect(store.load()?.accessToken == "sk-ant-oat01-legacy") // persisted into the store
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path)) // plaintext file removed
    }

    @Test("Legacy bare-token file migrates with nil refresh/expiry")
    func legacyBareTokenMigrates() throws {
        let store = InMemoryCredentialStore()
        KeychainService.store = store
        let legacyURL = tempLegacyURL()
        try "sk-ant-oat01-baretoken".write(to: legacyURL, atomically: true, encoding: .utf8)

        let result = try #require(KeychainService.getCredentials(legacyFileURL: legacyURL))
        #expect(result.accessToken == "sk-ant-oat01-baretoken")
        #expect(result.refreshToken == nil)
        #expect(result.expiresAt == nil)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("Legacy file is NOT deleted when the store fails to persist")
    func legacyFileKeptWhenStoreFails() throws {
        KeychainService.store = FailingCredentialStore()
        let legacyURL = tempLegacyURL()
        let legacy = CachedCredentials(accessToken: "sk-ant-oat01-legacy", refreshToken: nil, expiresAt: nil)
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let result = try #require(KeychainService.getCredentials(legacyFileURL: legacyURL))
        #expect(result.accessToken == "sk-ant-oat01-legacy")
        // Round-trip verification failed, so the only surviving copy (the file) must remain.
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }
}

// MARK: - CachedCredentials.needsRefresh

@Suite("CachedCredentials.needsRefresh")
struct CachedCredentialsNeedsRefreshTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Expiring within the leeway window returns true")
    func expiringSoon() {
        let creds = CachedCredentials(accessToken: "t", refreshToken: "r",
                                      expiresAt: now.addingTimeInterval(120)) // 2 min out
        #expect(creds.needsRefresh(now: now, leeway: 300))
    }

    @Test("Far-future expiry returns false")
    func farFuture() {
        let creds = CachedCredentials(accessToken: "t", refreshToken: "r",
                                      expiresAt: now.addingTimeInterval(3600)) // 1 hour out
        #expect(!creds.needsRefresh(now: now, leeway: 300))
    }

    @Test("Nil expiresAt returns false")
    func nilExpiry() {
        let creds = CachedCredentials(accessToken: "t", refreshToken: "r", expiresAt: nil)
        #expect(!creds.needsRefresh(now: now, leeway: 300))
    }

    @Test("Already-expired token returns true")
    func alreadyExpired() {
        let creds = CachedCredentials(accessToken: "t", refreshToken: "r",
                                      expiresAt: now.addingTimeInterval(-60)) // expired 1 min ago
        #expect(creds.needsRefresh(now: now, leeway: 300))
    }
}

// MARK: - UsageAPIError classification

@Suite("UsageAPIError classification")
struct UsageAPIErrorTests {

    @Test("Auth, transient, and keychain-refresh flags are correct")
    func classification() {
        // 401/403 are auth errors, not transient.
        #expect(UsageAPIError.invalidResponse(401).isAuthError)
        #expect(UsageAPIError.invalidResponse(403).isAuthError)
        #expect(!UsageAPIError.invalidResponse(401).isTransient)

        // 5xx is transient, not auth.
        #expect(UsageAPIError.invalidResponse(500).isTransient)
        #expect(!UsageAPIError.invalidResponse(500).isAuthError)

        // 404 is neither.
        #expect(!UsageAPIError.invalidResponse(404).isAuthError)
        #expect(!UsageAPIError.invalidResponse(404).isTransient)

        // Network failures are transient.
        #expect(UsageAPIError.requestFailed(URLError(.timedOut)).isTransient)

        // noToken / tokenExpired need a keychain refresh.
        #expect(UsageAPIError.noToken.needsKeychainRefresh)
        #expect(UsageAPIError.tokenExpired.needsKeychainRefresh)
        #expect(!UsageAPIError.invalidResponse(500).needsKeychainRefresh)
    }
}

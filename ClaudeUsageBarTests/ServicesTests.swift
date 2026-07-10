import Testing
import Foundation

// MARK: - KeychainService.parseCredentials / hexDecode

@Suite("KeychainService credential parsing")
struct KeychainServiceParseTests {

    @Test("Parses Claude Code OAuth JSON blob including millisecond expiresAt")
    func parsesJSONBlob() throws {
        let expiresMs: Double = 1_783_002_600_000 // 2026-07-09T18:30:00Z in ms
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc123","refreshToken":"sk-ant-ort01-xyz789","expiresAt":\(Int(expiresMs))}}
        """
        let creds = try #require(KeychainService.parseCredentials(from: Data(json.utf8)))
        #expect(creds.accessToken == "sk-ant-oat01-abc123")
        #expect(creds.refreshToken == "sk-ant-ort01-xyz789")
        let expiresAt = try #require(creds.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince1970 - expiresMs / 1000) < 0.001)
    }

    @Test("Hex-wrapped JSON blob decodes then parses")
    func parsesHexWrappedBlob() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-hex","refreshToken":"r"}}"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        let decoded = try #require(KeychainService.hexDecode(hex))
        let creds = try #require(KeychainService.parseCredentials(from: decoded))
        #expect(creds.accessToken == "sk-ant-oat01-hex")
        #expect(creds.refreshToken == "r")
        #expect(creds.expiresAt == nil)
    }

    @Test("Regex fallback extracts token from non-JSON text")
    func regexFallback() throws {
        let text = "garbage prefix sk-ant-oat01-Token_ABC-123 trailing junk"
        let creds = try #require(KeychainService.parseCredentials(from: Data(text.utf8)))
        #expect(creds.accessToken == "sk-ant-oat01-Token_ABC-123")
        #expect(creds.refreshToken == nil)
        #expect(creds.expiresAt == nil)
    }

    @Test("hexDecode rejects odd-length input")
    func hexDecodeRejectsOddLength() {
        #expect(KeychainService.hexDecode("abc") == nil)
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

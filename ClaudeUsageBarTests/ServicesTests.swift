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

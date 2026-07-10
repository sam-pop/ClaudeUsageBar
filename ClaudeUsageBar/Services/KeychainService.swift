import Foundation
import Security

struct CachedCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

enum KeychainServiceError: Error {
    case refreshFailed(status: Int, body: String)
    case noRefreshToken
}

enum KeychainService {
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let oauthTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// Where the app persists its own copy of the credentials. Injectable seam for tests.
    /// `nonisolated(unsafe)`: the value is Sendable and only tests mutate it, from a single
    /// thread — production code assigns it once at process start.
    nonisolated(unsafe) static var store: CredentialStoring = KeychainCredentialStore()

    /// Legacy plaintext cache written by pre-1.2 builds. Read once during migration, then
    /// deleted. Overridable in tests so the migration path never touches the real path.
    static var defaultLegacyCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsageBar", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    /// Returns credentials from the app-owned store; otherwise migrates from the legacy
    /// plaintext file or, failing that, reads Claude Code's keychain item (one-time prompt).
    static func getCredentials(legacyFileURL: URL = defaultLegacyCacheURL) -> CachedCredentials? {
        // 1. App-owned store hit.
        if let creds = store.load() {
            return creds
        }
        // 2. Migrate a legacy plaintext file, if one exists.
        if let legacy = readLegacyCacheFile(at: legacyFileURL) {
            store.save(legacy)
            // Only delete the plaintext file once the store has verifiably persisted an
            // equivalent copy — otherwise a failing store would destroy the sole copy.
            if let roundTrip = store.load(), roundTrip == legacy {
                try? FileManager.default.removeItem(at: legacyFileURL)
                removeLegacyDirectoryIfEmpty(legacyFileURL)
            }
            return legacy
        }
        // 3. Fall through to Claude Code's keychain item (may prompt).
        guard let creds = readKeychainCredentials() else { return nil }
        store.save(creds)
        return creds
    }

    /// Force re-read from Claude Code's keychain item. Triggers a password prompt.
    /// Should only be called from a user-initiated action (e.g., a Refresh button).
    static func refreshFromKeychain() -> CachedCredentials? {
        store.delete()
        guard let creds = readKeychainCredentials() else { return nil }
        store.save(creds)
        return creds
    }

    // MARK: - OAuth refresh

    /// Exchange a refresh token for a new access token via Anthropic's OAuth endpoint.
    /// Does not touch Claude Code's keychain item. On success, persists the new credentials
    /// to the app-owned store. On failure throws — caller should fall back to the
    /// user-controlled refresh path.
    static func refreshAccessToken(using refreshToken: String) async throws -> CachedCredentials {
        var request = URLRequest(url: oauthTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("ClaudeUsageBar/1.0", forHTTPHeaderField: "user-agent")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw KeychainServiceError.refreshFailed(status: status, body: snippet)
        }

        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)

        let newCreds = CachedCredentials(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? refreshToken,
            expiresAt: decoded.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        store.save(newCreds)
        return newCreds
    }

    // MARK: - Legacy plaintext-file migration (one-shot, read-only)

    /// Reads and parses the legacy plaintext credential file. Kept only to migrate old
    /// installs into the app-owned store; never written to. Preserves the historical
    /// bare-token backward-compat branch.
    private static func readLegacyCacheFile(at url: URL) -> CachedCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let decoded = try? JSONDecoder().decode(CachedCredentials.self, from: data) {
            return decoded.accessToken.isEmpty ? nil : decoded
        }
        // Backwards compat: previous versions wrote the bare access token string.
        if let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty, token.hasPrefix("sk-ant-") {
            return CachedCredentials(accessToken: token, refreshToken: nil, expiresAt: nil)
        }
        return nil
    }

    /// Removes the legacy `ClaudeUsageBar` support directory if the migration emptied it.
    private static func removeLegacyDirectoryIfEmpty(_ fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Claude Code keychain item (triggers password prompt)

    private static func readKeychainCredentials() -> CachedCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        if let creds = parseCredentials(from: data) {
            return creds
        }

        // Hex-decode fallbacks for stores that wrap the JSON in hex bytes.
        let hexString = data.map { String(format: "%02x", $0) }.joined()
        if let hexData = hexDecode(hexString), let creds = parseCredentials(from: hexData) {
            return creds
        }
        if let hexData = hexDecode(String(data: data, encoding: .ascii) ?? ""),
           let creds = parseCredentials(from: hexData) {
            return creds
        }

        return nil
    }

    static func parseCredentials(from data: Data) -> CachedCredentials? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        // Preferred path: parse the JSON blob Claude Code stores.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            let refresh = oauth["refreshToken"] as? String
            let expiresAtMs = oauth["expiresAt"] as? Double
            let expiresAt = expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000.0) }
            return CachedCredentials(accessToken: token, refreshToken: refresh, expiresAt: expiresAt)
        }

        // Fallback: regex-extract access token from any text representation.
        if let range = str.range(of: #"sk-ant-oat01-[A-Za-z0-9_-]+"#, options: .regularExpression) {
            return CachedCredentials(accessToken: String(str[range]), refreshToken: nil, expiresAt: nil)
        }
        return nil
    }

    static func hexDecode(_ hex: String) -> Data? {
        let cleaned = hex.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}

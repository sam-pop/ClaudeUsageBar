import Foundation

struct CachedCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// Expiry of the refresh token itself (Anthropic's refresh tokens carry a rolling
    /// ~28-day expiry). Optional so previously-persisted payloads without this field still
    /// decode.
    var refreshTokenExpiresAt: Date?

    /// Whether the access token has expired or will within `leeway`. Tokens without a
    /// known expiry (`expiresAt == nil`) never report as needing a proactive refresh —
    /// the reactive 401/403 path remains the safety net for those.
    func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }
}

enum KeychainServiceError: Error {
    case refreshFailed(status: Int, body: String)
    case noRefreshToken
}

enum KeychainService {
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
    /// plaintext file. Returns `nil` if neither has anything — the caller's job is then to
    /// start a fresh browser login.
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
        return nil
    }

    // MARK: - OAuth refresh

    /// The bare OAuth refresh-token exchange: POSTs to the token endpoint and returns the
    /// new credentials WITHOUT persisting them. The multi-account path uses this and lets
    /// the per-account store own persistence.
    static func performOAuthRefresh(refreshToken: String) async throws -> CachedCredentials {
        var request = URLRequest(url: OAuthEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "user-agent")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthEndpoints.clientID
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw KeychainServiceError.refreshFailed(status: status, body: snippet)
        }

        return try refreshCredentials(from: data, fallbackRefreshToken: refreshToken)
    }

    /// Pure decode of a 2xx OAuth refresh-token response into `CachedCredentials`. Kept
    /// separate from the networking wrapper above so this mapping is unit-testable without
    /// a live HTTP round trip. `fallbackRefreshToken` is used when the response omits
    /// `refresh_token`. `now` is injectable for deterministic tests; defaults to `Date()`
    /// so the one production call site above doesn't need to pass it.
    static func refreshCredentials(
        from data: Data, fallbackRefreshToken: String, now: Date = Date()
    ) throws -> CachedCredentials {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
            let refresh_token_expires_in: Int?
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)

        return CachedCredentials(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
            expiresAt: decoded.expires_in.map { now.addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: decoded.refresh_token_expires_in.map { now.addingTimeInterval(TimeInterval($0)) }
        )
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
}

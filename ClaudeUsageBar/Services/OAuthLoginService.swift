import Foundation

/// Outcome of a fresh-login code exchange (`OAuthLoginService.exchange`), distinct from
/// `KeychainServiceError`/`OAuthRefreshOutcome` which classify the refresh-token path.
/// `.exchangeRejected` means the code itself is dead (e.g. 400 `invalid_grant`) and the
/// user must restart the login; `.transient` (429/5xx) is worth retrying.
enum OAuthLoginError: Error, Equatable { case exchangeRejected, transient, malformedResponse }

/// Pure decode + status classification for the authorization-code exchange response.
/// Kept separate from the networking wrapper below so this logic is unit-testable
/// without a live HTTP round trip.
enum OAuthExchange {
    private struct Grant: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let refresh_token_expires_in: Int?
    }

    /// Classifies an exchange response by status and, for a 2xx, decodes it into
    /// `CachedCredentials`. Status ranges are spike-verified: 429/5xx are transient
    /// (worth a retry), everything else outside 2xx (400 `invalid_grant`, 401, 403…)
    /// is a terminal rejection of the code.
    static func credentials(fromStatus status: Int, body: Data) throws -> CachedCredentials {
        switch status {
        case 200...299:
            guard let grant = try? JSONDecoder().decode(Grant.self, from: body) else {
                throw OAuthLoginError.malformedResponse
            }
            return CachedCredentials(
                accessToken: grant.access_token,
                refreshToken: grant.refresh_token,
                expiresAt: grant.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
                refreshTokenExpiresAt: grant.refresh_token_expires_in.map { Date().addingTimeInterval(TimeInterval($0)) })
        case 429, 500...599:
            throw OAuthLoginError.transient
        default:
            throw OAuthLoginError.exchangeRejected
        }
    }
}

/// Exchanges a browser-login authorization code for real credentials. Thin networking
/// wrapper around `OAuthExchange`, which owns all decode/classify logic and is what the
/// tests drive.
struct OAuthLoginService {
    func exchange(code: String, pending: PendingLogin) async throws -> CachedCredentials {
        var request = URLRequest(url: URL(string: OAuthEndpoints.token)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // REQUIRED: the token endpoint is Cloudflare-fronted and returned 429
        // rate_limit_error to every request without a User-Agent during the Phase-0
        // spike, and 200 to the identical request with one (spike S1).
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "user-agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": pending.pkce.state,
            "client_id": OAuthEndpoints.clientID,
            "redirect_uri": pending.redirectURI,
            "code_verifier": pending.pkce.verifier,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return try OAuthExchange.credentials(fromStatus: status, body: data)
    }
}

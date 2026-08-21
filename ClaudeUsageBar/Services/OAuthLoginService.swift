import Foundation

/// Outcome of a fresh-login code exchange (`OAuthLoginService.exchange`), distinct from
/// `KeychainServiceError`/`OAuthRefreshOutcome` which classify the refresh-token path.
/// `.exchangeRejected` means the code itself is dead (e.g. 400 `invalid_grant`) and the
/// user must restart the login; `.transient` is worth retrying.
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
    /// `CachedCredentials`. Only 429 (rate_limit_error) and 400 `invalid_grant` were
    /// directly observed in the design spike. 401/403 are treated as terminal by
    /// deliberate choice, not observation, to match `OAuthRefreshOutcome`'s existing set
    /// for the sibling refresh path — note that a 403 from these Cloudflare-fronted hosts
    /// has separately been seen to be a bot challenge rather than a dead grant, so this
    /// default is a judgment call, not a guarantee. Everything else (including any
    /// unrecognized status) fails open to `.transient`, so a single unexpected response
    /// never strands the user — same policy `OAuthRefreshOutcome` documents for refresh.
    static func credentials(fromStatus status: Int, body: Data, now: Date = Date()) throws -> CachedCredentials {
        switch status {
        case 200...299:
            guard let grant = try? JSONDecoder().decode(Grant.self, from: body) else {
                throw OAuthLoginError.malformedResponse
            }
            return CachedCredentials(
                accessToken: grant.access_token,
                refreshToken: grant.refresh_token,
                expiresAt: grant.expires_in.map { now.addingTimeInterval(TimeInterval($0)) },
                refreshTokenExpiresAt: grant.refresh_token_expires_in.map { now.addingTimeInterval(TimeInterval($0)) })
        case 400, 401, 403:
            throw OAuthLoginError.exchangeRejected
        default:
            throw OAuthLoginError.transient
        }
    }
}

/// Exchanges a browser-login authorization code for real credentials. Thin networking
/// wrapper around `OAuthExchange`, which owns all decode/classify logic and is what the
/// tests drive.
struct OAuthLoginService {
    func exchange(code: String, pending: PendingLogin) async throws -> CachedCredentials {
        var request = URLRequest(url: OAuthEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
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

        // `URLSession.data(for:)` throws for transport-level failures (offline, timeout,
        // DNS, TLS, a dropped Wi-Fi/VPN mid-flight) — none of which say anything about
        // whether the code itself is good, so they're transient, not a rejection. The
        // one exception is cancellation: a user-initiated cancel must not be retried or
        // reported as a transient server condition.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if Task.isCancelled { throw error }
            throw OAuthLoginError.transient
        }
        guard let http = response as? HTTPURLResponse else { throw OAuthLoginError.transient }
        return try OAuthExchange.credentials(fromStatus: http.statusCode, body: data)
    }
}

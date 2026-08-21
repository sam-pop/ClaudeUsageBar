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
    /// for the sibling refresh path. Cloudflare fronts these hosts and has returned 403 to
    /// spike probes of routes this client doesn't have (S10), so a 403 here is not
    /// necessarily a dead grant — treating it as terminal is a judgment call for
    /// consistency with `OAuthRefreshOutcome`, not a guarantee. Everything else (including
    /// any unrecognized status) fails open to `.transient`, so a single unexpected
    /// response never strands the user — same policy `OAuthRefreshOutcome` documents for
    /// refresh.
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
        // one exception is cancellation: a cancelled task must not be retried or reported
        // as a transient server condition.
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

extension OAuthLoginService {
    /// How long the loopback listener waits for the browser's redirect before giving up and
    /// resuming its wait with `nil`. A caller does not choose this later — see `begin` below
    /// for why the wait is already running by the time it gets a value back.
    static let loopbackTimeout: TimeInterval = 600

    /// Starts a browser OAuth login: generates fresh PKCE and decides loopback-vs-paste mode
    /// BEFORE any browser opens. `redirectURI` is bound here and replayed byte-identically at
    /// token exchange, so the mode is fixed for the life of this login — a later timeout does
    /// not switch modes, it restarts as a brand-new login (a fresh call to this method).
    ///
    /// `forcePaste: true` always selects paste mode: no server, `redirectURI =
    /// OAuthEndpoints.pasteRedirect`. Otherwise a `LoopbackServer` is started; on success the
    /// mode is `.loopback(port:)` with the `127.0.0.1` (not `localhost`) redirect — `LoopbackServer`
    /// binds IPv4 loopback only, and pinning the literal avoids a `localhost` resolution to
    /// `::1` hitting connection-refused. A `StartError.bindFailed` falls back to paste mode
    /// instead of throwing: a fresh login always produces *some* usable mode. Any other error
    /// from `start()` (none is currently possible, per its own contract) propagates instead of
    /// being silently treated as a fallback.
    ///
    /// Ordering hazard this exists to prevent: `LoopbackServer.waitForCallback` must be armed
    /// before the browser can deliver its redirect, or the arriving callback is answered 404
    /// like any stray request, silently burning the single-use code. Rather than leave that
    /// sequencing to the caller, this method itself starts the wait — as a concurrent `Task` —
    /// before returning, so it is already armed by the time the caller has anything in hand to
    /// open a browser with. For loopback mode, the caller's only remaining job is to open
    /// `authorizeURL` and then `await` the returned `callback` for the resulting code (`nil` on
    /// timeout or `server.stop()`). Do **not** call `server.waitForCallback` again yourself —
    /// `LoopbackServer` allows exactly one waiter per login, so a second call returns `nil`
    /// immediately, indistinguishable from an instant timeout.
    ///
    /// `authorizeURL` is built with `loginHintEmail: nil`: this method only receives an account
    /// id, not an email. A caller that knows the account's email and wants it preselected
    /// should build its own URL via `pending.authorizeURL(loginHintEmail:)` instead of using
    /// the one returned here.
    ///
    /// Never log or print `authorizeURL` — it carries the PKCE code challenge (and, for a
    /// caller-built URL with a hint, a real email address).
    func begin(
        accountID: UUID?,
        forcePaste: Bool,
        now: () -> Date = Date.init,
        makeServer: () -> LoopbackServer = { LoopbackServer() }
    ) async throws -> (
        pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?
    ) {
        let pkce = OAuthPKCE.generate()

        func paste() -> (pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?) {
            let pending = PendingLogin(
                accountID: accountID, mode: .paste, pkce: pkce,
                redirectURI: OAuthEndpoints.pasteRedirect, startedAt: now())
            return (pending, pending.authorizeURL(loginHintEmail: nil), nil, nil)
        }

        guard !forcePaste else { return paste() }

        let server = makeServer()
        let port: UInt16
        do {
            port = try await server.start()
        } catch LoopbackServer.StartError.bindFailed {
            return paste()
        }

        let pending = PendingLogin(
            accountID: accountID, mode: .loopback(port: port), pkce: pkce,
            redirectURI: "http://127.0.0.1:\(port)/callback", startedAt: now())
        let expectedState = pkce.state
        let callback = Task { await server.waitForCallback(expectedState: expectedState, timeout: Self.loopbackTimeout) }
        return (pending, pending.authorizeURL(loginHintEmail: nil), server, callback)
    }
}

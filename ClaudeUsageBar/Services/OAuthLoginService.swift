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
    /// Bounds how long the loopback listener waits for a callback to be *accepted*, not how
    /// long the wait itself may take — matches `LoopbackServer.waitForCallback`'s own contract:
    /// a callback accepted right at this boundary is still delivered.
    static let loopbackTimeout: TimeInterval = 600

    /// Starts a browser OAuth login: generates fresh PKCE and decides loopback-vs-paste mode
    /// BEFORE any browser opens. `redirectURI` is bound here and replayed byte-identically at
    /// token exchange, so the mode is fixed for the life of this login — a later timeout does
    /// not switch modes, it restarts as a brand-new login (a fresh call to this method).
    ///
    /// `forcePaste: true` always selects paste mode: no server, `redirectURI =
    /// OAuthEndpoints.pasteRedirect`. Otherwise a `LoopbackServer` is started; on success the
    /// mode is `.loopback(port:)` with a **`localhost`** redirect. This is not a style choice:
    /// the authorization server rejects `http://127.0.0.1:<port>/callback` for this client with
    /// "Redirect URI … is not supported by client", observed live. `localhost` is the form the
    /// Phase-0 spike proved returns HTTP 200. Note `LoopbackServer` binds IPv4 loopback only,
    /// so a browser that resolved `localhost` to `::1` first would hit connection-refused;
    /// that has not been observed, and the server leaves no alternative.
    /// A `StartError.bindFailed` falls back to paste mode
    /// instead of throwing: a fresh login always produces *some* usable mode. Any other error
    /// from `start()` (none is currently possible, per its own contract) propagates instead of
    /// being silently treated as a fallback.
    ///
    /// `loginHintEmail` is forwarded to `pending.authorizeURL(loginHintEmail:)` when building
    /// `authorizeURL` — supply it when re-authing a known account, to preselect it (the main
    /// assist for the wrong-account recovery path); omit it for a fresh "Add account" login.
    ///
    /// Ordering hazard this exists to prevent: `LoopbackServer.waitForCallback` must be armed
    /// before the browser can deliver its redirect, or the arriving callback is answered 404
    /// like any stray request, silently burning the single-use code. Rather than leave that
    /// sequencing to the caller, this method itself enqueues the wait — as a concurrent `Task`
    /// — before returning. That does NOT guarantee the wait has actually armed by the time this
    /// method returns: the executor still has to pick the `Task` up and cross into the actor,
    /// and `engine.arm` then hops onto the engine's own queue before the phase actually flips to
    /// `.awaiting`. What it does remove entirely is the realistic failure mode — a caller
    /// sequencing `openURL` and then `waitForCallback` fully serially — since the wait is
    /// already handed back as a `Task`, so the serial form is no longer the natural way to write
    /// the caller. The method stays callable — hence the warning below. The residual scheduling
    /// window is microseconds, raced against a browser launch plus a TLS handshake plus user
    /// interaction.
    ///
    /// For loopback mode, the caller opens `authorizeURL` and then `await`s the returned
    /// `callback` for the resulting code. A delivered code stops the listener automatically
    /// (see the implementation); a `nil` from timeout does not, so `LoopbackServer`'s own
    /// grace-period "expired" page keeps serving. The caller still owns `server.stop()` for the
    /// cancel/abandon paths (e.g. the user dismisses the login before either happens).
    /// **`callback.cancel()` does nothing** — `waitForCallback` suspends in a plain
    /// `CheckedContinuation`, not a cancellation handler, so cancelling this `Task` never
    /// unblocks it; `server.stop()` is the only way to abort the wait. Do **not** call
    /// `server.waitForCallback` again yourself either — `LoopbackServer` allows exactly one
    /// waiter per login, so a second call returns `nil` immediately, indistinguishable from an
    /// instant timeout.
    ///
    /// Never log or print `authorizeURL` — it carries the PKCE code challenge and, when a hint
    /// is supplied, a real email address.
    func begin(
        accountID: UUID?,
        forcePaste: Bool,
        loginHintEmail: String? = nil,
        now: @Sendable () -> Date = Date.init,
        makeServer: @Sendable () -> LoopbackServer = { LoopbackServer() }
    ) async throws -> (
        pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?
    ) {
        let pkce = OAuthPKCE.generate()

        func paste() -> (pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?) {
            let pending = PendingLogin(
                accountID: accountID, mode: .paste, pkce: pkce,
                redirectURI: OAuthEndpoints.pasteRedirect, startedAt: now())
            return (pending, pending.authorizeURL(loginHintEmail: loginHintEmail), nil, nil)
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
            redirectURI: "http://localhost:\(port)/callback", startedAt: now())
        let expectedState = pkce.state
        let callback = Task<String?, Never> {
            let code = await server.waitForCallback(expectedState: expectedState, timeout: Self.loopbackTimeout)
            // The code is handed over only after the success-page send has been processed — or
            // after the connection was already gone — so stopping here cannot cut the browser
            // off mid-load. Success only: a timeout must leave the listener up so
            // LoopbackServer's own grace-period "expired" page keeps serving.
            if code != nil { await server.stop() }
            return code
        }
        return (pending, pending.authorizeURL(loginHintEmail: loginHintEmail), server, callback)
    }
}

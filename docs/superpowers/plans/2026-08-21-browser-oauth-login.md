# Browser OAuth Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace "capture credentials from Claude Code's keychain" with an app-owned browser OAuth login (authorization code + PKCE), so each account has an independent, renewable credential and re-auth is a browser round-trip.

**Architecture:** A pure OAuth core (PKCE, authorize-URL builder, `code#state` parser, exchange decoder) with no I/O, wrapped by `OAuthLoginService` (opens the browser, runs a `LoopbackServer` or paste flow, POSTs the exchange). `AccountsViewModel` gains a `Dependencies` seam and a single `beginLogin(accountID:)` path with an explicit error taxonomy, replacing `addCurrentAccount`/`rereadFromClaudeCode`. All pending-login state lives on the view model (the MenuBarExtra popover closes when the browser takes focus); terminal outcomes are announced via the existing notification plumbing. The Claude-Code-keychain capture code is deleted.

**Tech Stack:** Swift 6, SwiftUI/AppKit, `Network`/`NWListener` for the loopback server, Swift Testing, XcodeGen, ad-hoc signed macOS 13+ menu-bar app.

**Spec:** `docs/superpowers/specs/2026-08-21-browser-oauth-login-design.md` (Phase-0 spike PASSED 2026-08-21 — this plan is unblocked).

## Global Constraints

- **User-Agent on every HTTPS request** (`AppInfo.userAgent`) — exchange, identity fetch, refresh. A missing UA gets a Cloudflare 429. (Spike S1.)
- **Requested scope is exactly `user:profile user:inference`** — never `org:create_api_key`. (Spike S4.)
- **Endpoints:** authorize `https://claude.ai/oauth/authorize`; token `https://console.anthropic.com/v1/oauth/token`; loopback redirect `http://localhost:<port>/callback`; paste redirect `https://console.anthropic.com/oauth/code/callback`. `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e`.
- **`state` and `code_verifier` from `SecRandomCopyBytes`** (≥32 bytes, base64url unpadded). `code_challenge_method=S256` sent explicitly.
- **Never log or render** tokens, codes, verifiers, the authorize URL (contains `login_hint` email), or raw HTTP response bodies.
- **No `try?` on credential saves** — save failure is a surfaced terminal state.
- **Revocation is unavailable** (spike S10) — dropped/removed grants age out (~28 days); do not add revoke calls.
- **TDD, frequent commits, unsigned commits** in agents: `git -c commit.gpgsign=false commit`. Note unsigned commits in reports.
- **`make test`** (runs `xcodegen generate` first) is the test arbiter; ignore SourceKit false-positives for new files. Keep non-`Sendable` framework types out of `@MainActor`-crossing returns (local-Xcode-26 vs CI-Xcode-16 drift).

---

### Task 1: `CachedCredentials.refreshTokenExpiresAt`

**Files:**
- Modify: `ClaudeUsageBar/Services/KeychainService.swift:4-16` (struct + add field), `:118-129` (populate from refresh)
- Test: `ClaudeUsageBarTests/ServicesTests.swift` (new suite `CachedCredentialsExpiry`)

**Interfaces:**
- Produces: `CachedCredentials.refreshTokenExpiresAt: Date?`; `performOAuthRefresh` preserves the prior value when the response omits `refresh_token_expires_in`.

- [ ] **Step 1: Write the failing test** — additive field decodes as nil against an old payload, and is set from a fresh value.

```swift
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
```

- [ ] **Step 2: Run to verify it fails** — `make test` (or `-only-testing:ClaudeUsageBarTests/CachedCredentialsExpiry`). Expected: FAIL (extra argument `refreshTokenExpiresAt`).

- [ ] **Step 3: Add the field** in `KeychainService.swift`:

```swift
struct CachedCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var refreshTokenExpiresAt: Date?
    // ...needsRefresh(now:leeway:) unchanged...
}
```

Give it a default so existing call sites keep compiling: add `refreshTokenExpiresAt: Date? = nil` to the memberwise usage sites that construct it positionally, OR rely on the synthesized memberwise init by updating those sites. Then populate it in `performOAuthRefresh` (`:118-129`):

```swift
struct RefreshResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let refresh_token_expires_in: Int?
}
let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
return CachedCredentials(
    accessToken: decoded.access_token,
    refreshToken: decoded.refresh_token ?? refreshToken,
    expiresAt: decoded.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
    refreshTokenExpiresAt: decoded.refresh_token_expires_in.map { Date().addingTimeInterval(TimeInterval($0)) }
)
```

Note: when the refresh response omits `refresh_token_expires_in`, this sets nil. The design says "keep the prior value" — since `performOAuthRefresh` is a pure exchange without the old creds in scope, the *caller* (`AccountRuntime.tryTokenRefresh`) preserves it. Add to Task 10's scope: after a refresh, if the new `refreshTokenExpiresAt == nil`, carry forward the old one.

- [ ] **Step 4: Fix construction sites** — grep `CachedCredentials(` and update any positional constructor. Run `make test`. Expected: PASS, all prior tests green.

- [ ] **Step 5: Commit** — `git -c commit.gpgsign=false commit -am "feat: add refreshTokenExpiresAt to CachedCredentials"`

---

### Task 2: PKCE + secure random (`OAuthPKCE`)

**Files:**
- Create: `ClaudeUsageBar/Services/OAuthPKCE.swift`
- Test: `ClaudeUsageBarTests/OAuthPKCETests.swift`

**Interfaces:**
- Produces: `struct OAuthPKCE { let verifier: String; let challenge: String; let state: String }`, `static func generate() -> OAuthPKCE`, and `static func challenge(for verifier: String) -> String` (pure, testable against RFC 7636).

- [ ] **Step 1: Write the failing test** — RFC 7636 Appendix B vector + format checks.

```swift
import Testing
import Foundation

@Suite("OAuthPKCE")
struct OAuthPKCETests {
    @Test("S256 challenge matches the RFC 7636 test vector")
    func rfcVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(OAuthPKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("generate() yields base64url-unpadded verifier and state of adequate length")
    func generateFormat() {
        let p = OAuthPKCE.generate()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for s in [p.verifier, p.state] {
            #expect(s.count >= 43)
            #expect(s.unicodeScalars.allSatisfy { allowed.contains($0) })
        }
        #expect(p.challenge == OAuthPKCE.challenge(for: p.verifier))
        #expect(OAuthPKCE.generate().verifier != p.verifier)   // random
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL (no such type `OAuthPKCE`).

- [ ] **Step 3: Implement** `OAuthPKCE.swift`:

```swift
import Foundation
import CryptoKit
import Security

struct OAuthPKCE: Equatable {
    let verifier: String
    let challenge: String
    let state: String

    static func generate() -> OAuthPKCE {
        let verifier = base64URL(randomBytes(32))
        return OAuthPKCE(verifier: verifier, challenge: challenge(for: verifier), state: base64URL(randomBytes(32)))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: add OAuthPKCE (S256 + SecRandom)`

---

### Task 3: Authorize-URL builder + `PendingLogin` model

**Files:**
- Create: `ClaudeUsageBar/Services/OAuthLoginModels.swift`
- Test: `ClaudeUsageBarTests/OAuthAuthorizeURLTests.swift`

**Interfaces:**
- Consumes: `OAuthPKCE` (Task 2).
- Produces:
  ```swift
  enum OAuthLoginMode: Equatable { case loopback(port: UInt16), paste }
  struct PendingLogin: Equatable {
      let accountID: UUID?
      let mode: OAuthLoginMode
      let pkce: OAuthPKCE
      let redirectURI: String
      let startedAt: Date
  }
  enum OAuthEndpoints {
      static let authorize = "https://claude.ai/oauth/authorize"
      static let token = "https://console.anthropic.com/v1/oauth/token"
      static let pasteRedirect = "https://console.anthropic.com/oauth/code/callback"
      static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
      static let scope = "user:profile user:inference"
  }
  extension PendingLogin { func authorizeURL(loginHintEmail: String?) -> URL }
  ```

- [ ] **Step 1: Write the failing test** — required params present, scope minimal, login_hint conditional, redirect matches mode.

```swift
import Testing
import Foundation

@Suite("PendingLogin.authorizeURL")
struct OAuthAuthorizeURLTests {
    private func params(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("Loopback authorize URL carries PKCE, S256, minimal scope, loopback redirect")
    func loopback() {
        let pkce = OAuthPKCE.generate()
        let p = PendingLogin(accountID: nil, mode: .loopback(port: 51000), pkce: pkce,
                             redirectURI: "http://localhost:51000/callback", startedAt: .init())
        let q = params(p.authorizeURL(loginHintEmail: nil))
        #expect(q["client_id"] == OAuthEndpoints.clientID)
        #expect(q["response_type"] == "code")
        #expect(q["code_challenge"] == pkce.challenge)
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == pkce.state)
        #expect(q["scope"] == "user:profile user:inference")
        #expect(q["redirect_uri"] == "http://localhost:51000/callback")
        #expect(q["login_hint"] == nil)
    }

    @Test("login_hint added when re-authing a known account; paste mode uses the console redirect")
    func hintAndPaste() {
        let p = PendingLogin(accountID: UUID(), mode: .paste, pkce: .generate(),
                             redirectURI: OAuthEndpoints.pasteRedirect, startedAt: .init())
        let q = params(p.authorizeURL(loginHintEmail: "sam@example.com"))
        #expect(q["login_hint"] == "sam@example.com")
        #expect(q["redirect_uri"] == OAuthEndpoints.pasteRedirect)
    }
}
```

- [ ] **Step 2: Run** — Expected: FAIL (no such types).
- [ ] **Step 3: Implement** `OAuthLoginModels.swift` with the interface block above and:

```swift
extension PendingLogin {
    func authorizeURL(loginHintEmail: String?) -> URL {
        var comps = URLComponents(string: OAuthEndpoints.authorize)!
        var items = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: OAuthEndpoints.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: OAuthEndpoints.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        if let loginHintEmail { items.append(URLQueryItem(name: "login_hint", value: loginHintEmail)) }
        comps.queryItems = items
        return comps.url!
    }
}
```

(Include `code=true` — the spike's authorize params carried it. Verify no double-encoding of `redirect_uri`.)

- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: add PendingLogin + authorize-URL builder`

---

### Task 4: `code#state` paste parser

**Files:**
- Modify: `ClaudeUsageBar/Services/OAuthLoginModels.swift`
- Test: `ClaudeUsageBarTests/OAuthPasteParseTests.swift`

**Interfaces:**
- Produces: `enum OAuthPaste { static func parse(_ raw: String) -> (code: String, state: String)? }` — splits on the FIRST `#`, trims surrounding whitespace, rejects empty halves and over-long input (cap 8192).
- **Amended after the Task 4 review:** also rejects input where either half contains internal whitespace. Without this, a clipboard-wrapped newline yields a corrupted code that only fails later at the token endpoint, surfacing as "Login expired or was already used" — a misleading error, the exact failure class this feature exists to eliminate. Deliberately NOT full base64url charset validation: we have one real sample of Anthropic's code format, and rejecting an unexpected-but-legitimate character would break logins outright, which is worse than a late error. Whitespace is unambiguously a paste artifact.

- [ ] **Step 1: Write the failing test:**

```swift
import Testing

@Suite("OAuthPaste.parse")
struct OAuthPasteParseTests {
    @Test("Splits code#state and trims surrounding whitespace")
    func splits() {
        let out = OAuthPaste.parse("  abc123#xyz789\n")
        #expect(out?.code == "abc123")
        #expect(out?.state == "xyz789")
    }
    @Test("Rejects input with no separator, empty halves, or absurd length")
    func rejects() {
        #expect(OAuthPaste.parse("abc123") == nil)
        #expect(OAuthPaste.parse("#xyz") == nil)
        #expect(OAuthPaste.parse("abc#") == nil)
        #expect(OAuthPaste.parse(String(repeating: "a", count: 9000) + "#s") == nil)
    }
}
```

- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement:**

```swift
enum OAuthPaste {
    static func parse(_ raw: String) -> (code: String, state: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8192, let hash = trimmed.firstIndex(of: "#") else { return nil }
        let code = String(trimmed[..<hash])
        let state = String(trimmed[trimmed.index(after: hash)...])
        guard !code.isEmpty, !state.isEmpty else { return nil }
        return (code, state)
    }
}
```

- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: add code#state paste parser`

---

### Task 5: Token exchange decode + `OAuthLoginService.exchange`

**Files:**
- Create: `ClaudeUsageBar/Services/OAuthLoginService.swift`
- Test: `ClaudeUsageBarTests/OAuthExchangeDecodeTests.swift`

**Interfaces:**
- Consumes: `PendingLogin`, `OAuthEndpoints`, `CachedCredentials`, `AppInfo.userAgent`.
- Produces:
  ```swift
  enum OAuthLoginError: Error, Equatable { case exchangeRejected, transient, malformedResponse }
  enum OAuthExchange {   // pure decode + error classification, unit-tested
      static func credentials(fromStatus status: Int, body: Data) throws -> CachedCredentials
  }
  ```
  `OAuthLoginService.exchange(code:pending:) async throws -> CachedCredentials` performs the POST then calls `OAuthExchange.credentials`.

- [ ] **Step 1: Write the failing test** — decode 200; classify 400 `invalid_grant` as `.exchangeRejected`; 429/5xx as `.transient`.

```swift
import Testing
import Foundation

@Suite("OAuthExchange.credentials")
struct OAuthExchangeDecodeTests {
    @Test("Decodes a 200 grant into credentials with both expiries")
    func decodes200() throws {
        let body = #"{"access_token":"at","refresh_token":"rt","expires_in":28800,"refresh_token_expires_in":2383011,"scope":"user:inference user:profile","token_type":"Bearer"}"#
        let creds = try OAuthExchange.credentials(fromStatus: 200, body: Data(body.utf8))
        #expect(creds.accessToken == "at")
        #expect(creds.refreshToken == "rt")
        #expect(creds.expiresAt != nil)
        #expect(creds.refreshTokenExpiresAt != nil)
    }
    @Test("400 invalid_grant is a terminal rejection; 429 and 503 are transient")
    func classifies() {
        #expect(throws: OAuthLoginError.exchangeRejected) {
            try OAuthExchange.credentials(fromStatus: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        #expect(throws: OAuthLoginError.transient) {
            try OAuthExchange.credentials(fromStatus: 429, body: Data("{}".utf8))
        }
        #expect(throws: OAuthLoginError.transient) {
            try OAuthExchange.credentials(fromStatus: 503, body: Data("{}".utf8))
        }
    }
}
```

- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement** the pure decoder + the networking wrapper:

```swift
import Foundation

enum OAuthLoginError: Error, Equatable { case exchangeRejected, transient, malformedResponse }

enum OAuthExchange {
    private struct Grant: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let refresh_token_expires_in: Int?
    }
    static func credentials(fromStatus status: Int, body: Data) throws -> CachedCredentials {
        switch status {
        case 200...299:
            guard let g = try? JSONDecoder().decode(Grant.self, from: body) else { throw OAuthLoginError.malformedResponse }
            return CachedCredentials(
                accessToken: g.access_token,
                refreshToken: g.refresh_token,
                expiresAt: g.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
                refreshTokenExpiresAt: g.refresh_token_expires_in.map { Date().addingTimeInterval(TimeInterval($0)) })
        case 429, 500...599:
            throw OAuthLoginError.transient
        default:
            throw OAuthLoginError.exchangeRejected   // 400 invalid_grant, 401, 403…
        }
    }
}

struct OAuthLoginService {
    func exchange(code: String, pending: PendingLogin) async throws -> CachedCredentials {
        var req = URLRequest(url: URL(string: OAuthEndpoints.token)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")   // REQUIRED (spike S1)
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": pending.pkce.state,
            "client_id": OAuthEndpoints.clientID,
            "redirect_uri": pending.redirectURI,
            "code_verifier": pending.pkce.verifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return try OAuthExchange.credentials(fromStatus: status, body: data)
    }
}
```

- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: OAuth code exchange + decode/classify`

---

### Task 6: `LoopbackServer`

**Files:**
- Create: `ClaudeUsageBar/Services/LoopbackServer.swift`
- Test: `ClaudeUsageBarTests/LoopbackServerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  actor LoopbackServer {
      enum StartError: Error { case bindFailed }
      init()
      /// Binds an ephemeral loopback port; throws bindFailed if none available.
      func start() throws -> UInt16
      /// Waits for GET /callback?code=&state= with state == expectedState, or nil on timeout.
      func waitForCallback(expectedState: String, timeout: TimeInterval) async -> String?
      func stop()
  }
  ```

- [ ] **Step 1: Write the failing test** — a round-trip: start, fire a real GET at the port, receive the code; and non-`/callback` requests don't complete it.

```swift
import Testing
import Foundation

@Suite("LoopbackServer", .serialized)
struct LoopbackServerTests {
    @Test("Delivers the code from GET /callback with matching state")
    func roundTrip() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st8", timeout: 5)

        // favicon + preconnect noise first — must NOT complete the flow
        _ = try? await get(port: port, path: "/favicon.ico")
        _ = try? await get(port: port, path: "/callback?code=x&state=WRONG")
        _ = try? await get(port: port, path: "/callback?code=good-code&state=st8")

        let code = await captured
        #expect(code == "good-code")
        await server.stop()
    }

    private func get(port: UInt16, path: String) async throws -> Int {
        let (_, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        return (resp as? HTTPURLResponse)?.statusCode ?? -1
    }
}
```

- [ ] **Step 2: Run** — Expected: FAIL (no such type).
- [ ] **Step 3: Implement** with `Network.NWListener` bound to loopback, port 0. Loop accepting connections; parse the request line; for `GET /callback` with a non-empty `code` and `state == expectedState`, respond `200` static HTML (`Cache-Control: no-store`, `Connection: close`, body has no request content) and resolve the waiter; everything else → `404` and keep listening. `waitForCallback` races the accept loop against a `Task.sleep(timeout)`; on timeout, keep serving a static "login expired" page for a grace period, then `stop()`. Use `NWListener.newConnectionHandler`, read with `connection.receive`. Bind `.hostAny` on `NWEndpoint.Host("127.0.0.1")` via `NWParameters.tcp` with `requiredLocalEndpoint` loopback. **Guard: `start()` throws `.bindFailed` if the listener enters `.failed`** (drives Task 7's paste fallback).

  (Full `Network` wiring is the implementer's; the test above is the contract. Keep all parsing tolerant of partial reads — accumulate until `\r\n\r\n`.)

- [ ] **Step 4: Run** — Expected: PASS. Also run twice to confirm no port leak.
- [ ] **Step 5: Commit** — `feat: loopback OAuth callback server`

---

### Task 7: `OAuthLoginService.begin` (mode selection + browser open)

**Files:**
- Modify: `ClaudeUsageBar/Services/OAuthLoginService.swift`
- Test: `ClaudeUsageBarTests/OAuthLoginServiceTests.swift`

**Interfaces:**
- Consumes: `LoopbackServer`, `PendingLogin`, `OAuthPKCE`.
- Produces:
  ```swift
  extension OAuthLoginService {
      /// Chooses mode BEFORE opening the browser: binds a listener → .loopback; bind failure → .paste.
      func begin(accountID: UUID?, forcePaste: Bool) throws -> (PendingLogin, authorizeURL: URL, server: LoopbackServer?)
  }
  ```
  Injected `now: () -> Date` and the `LoopbackServer` factory so tests avoid real sockets where possible. Mode is fixed at `begin`; the timeout path in Task 9 calls `begin(forcePaste: true)` to *restart*.

- [ ] **Step 1: Write the failing test** — `forcePaste` yields `.paste` + console redirect + nil server; loopback path yields a `http://localhost:<port>/callback` redirect.

```swift
@Suite("OAuthLoginService.begin")
struct OAuthLoginServiceTests {
    @Test("forcePaste selects paste mode with the console redirect and no server")
    func paste() throws {
        let (pending, url, server) = try OAuthLoginService().begin(accountID: nil, forcePaste: true)
        #expect(pending.mode == .paste)
        #expect(pending.redirectURI == OAuthEndpoints.pasteRedirect)
        #expect(server == nil)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirect = items.first { $0.name == "redirect_uri" }?.value
        #expect(redirect == OAuthEndpoints.pasteRedirect)
    }
}
```

(If a loopback round-trip in a unit test is undesirable on CI, keep the loopback branch covered by Task 6's server test + a Task 9 flow test with an injected fake, and unit-test only the paste branch here.)

- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement** `begin`: generate `OAuthPKCE`; if `forcePaste`, build a `.paste` PendingLogin with `redirectURI = OAuthEndpoints.pasteRedirect`, server nil; else construct a `LoopbackServer`, `try start()` → on success `.loopback(port:)` with **`redirectURI = "http://127.0.0.1:\(port)/callback"`**, on `StartError.bindFailed` fall back to paste.
  - **Use the `127.0.0.1` literal, NOT `localhost`** (changed after the Task 6 review). The listener binds IPv4 loopback only — confirmed with `lsof` — so if a browser resolved `localhost` to `::1` first it would hit connection-refused and the login would die with a dead tab. The IP literal removes the ambiguity. This is safe: spike S3 confirmed `http://127.0.0.1/callback` is a registered redirect URI for this client (the client metadata lists both `http://localhost/callback` and `http://127.0.0.1/callback`, port-agnostic), and §4 of the design spec already stated this preference.
  - **Ordering the API cannot enforce:** `waitForCallback` must be armed BEFORE the browser is opened. Until the wait arms the listener, a callback is answered `404` like any stray request, burning a single-use code. Structure `beginLogin` so the wait is started first, then `openURL`. Return the pending, `pending.authorizeURL(loginHintEmail:)` is called by the caller (which knows the account email), and the server. **Do not open the browser here** — the view model opens via injected `openURL` (testability). Adjust the tuple/signature accordingly if cleaner.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: OAuth login mode selection`

---

### Task 8: `AccountsViewModel.Dependencies` seam + login state types

**Files:**
- Modify: `ClaudeUsageBar/ViewModels/AccountsViewModel.swift`
- Test: `ClaudeUsageBarTests/AccountsViewModelLoginTests.swift` (new)

**Interfaces:**
- Produces on `AccountsViewModel`:
  ```swift
  struct Dependencies {
      // UPDATED to the real Task 7 API — the earlier 3-tuple/non-async shape is stale.
      // `callback` is an ALREADY-ARMED wait: Task 7 starts waitForCallback before returning,
      // which is what makes the arm-before-browser hazard structurally impossible. Task 9
      // must `await result.callback?.value` and must NEVER call waitForCallback itself.
      var beginLogin: (_ accountID: UUID?, _ forcePaste: Bool, _ loginHintEmail: String?) async throws
          -> (pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?)
      var exchange: (_ code: String, _ pending: PendingLogin) async throws -> CachedCredentials
      var fetchIdentity: (_ token: String) async throws -> AccountIdentity
      var openURL: (URL) -> Void
      var now: () -> Date
  }
  enum LoginState: Equatable { case idle, waitingForBrowser(since: Date), awaitingPaste, failed(String) }
  @Published private(set) var loginState: [UUID: LoginState]
  @Published private(set) var pendingLogin: PendingLogin?          // exactly one at a time
  @Published var addLoginState: LoginState                          // for the accountID==nil flow
  ```
  A new `init(..., deps: Dependencies = .live)` overload; `.live` wires `OAuthLoginService`/`ProfileService`/`NSWorkspace.shared.open`.

- [ ] **Step 1: Write the failing test** — the seam exists and defaults are injectable; a fake deps double drives later tests.

```swift
@MainActor
@Suite("AccountsViewModel login seam")
struct AccountsViewModelLoginTests {
    @Test("Injected Dependencies are usable; no real network on init")
    func seamInjectable() {
        let deps = AccountsViewModel.Dependencies(
            beginLogin: { _, _ in throw OAuthLoginError.transient },
            exchange: { _, _ in throw OAuthLoginError.transient },
            fetchIdentity: { _ in AccountIdentity(uuid: "u", email: "e", displayName: "d") },
            openURL: { _ in },
            now: { Date(timeIntervalSince1970: 0) })
        let vm = AccountsViewModel(
            accountsStore: AccountsStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!),
            credentialStore: InMemoryAccountCredentialStore(),
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
            startTimer: false, deps: deps)
        #expect(vm.pendingLogin == nil)
    }
}
```

(Confirm `AccountsStore` and `AccountsViewModel` init signatures; adjust the fake to match. `InMemoryAccountCredentialStore` already exists in `CredentialStoreStubs.swift`.)

- [ ] **Step 2: Run** — Expected: FAIL (no `Dependencies` / `deps:` param).
- [ ] **Step 3: Implement** the types + a `deps` stored property + `.live` factory; thread `deps` through `init`. Leave `beginLogin(_:)` itself for Task 9.
- [ ] **Step 4: Run** — Expected: PASS (and all existing view-model construction sites updated to the defaulted init).
- [ ] **Step 5: Commit** — `feat: AccountsViewModel login dependency seam + state types`

---

### Task 9: `beginLogin` flow + error taxonomy (replaces capture paths)

**Files:**
- Modify: `ClaudeUsageBar/ViewModels/AccountsViewModel.swift` (add `beginLogin`, `submitPaste`, `cancelLogin`; delete `addCurrentAccount`, `rereadFromClaudeCode`)
- Test: `ClaudeUsageBarTests/AccountsViewModelLoginTests.swift`

**Interfaces:**
- Consumes: Task 8 seam, `AccountCredentialManager.update` (throws), `AccountIdentityResolver`, `AccountRuntime.credentialsReplaced()` (Task 10).
- Produces: `func beginLogin(_ accountID: UUID?) async`, `func submitPaste(_ raw: String) async`, `func cancelLogin()`. One pending login enforced.

- [ ] **Step 1: Write failing tests** covering the taxonomy (Spec §4):

```swift
// (inside the @MainActor suite; helpers build a vm with a configurable fake deps)

@Test("Successful re-auth: exchange → identity match → save → clears needsReAuth")
func success() async { /* fake exchange returns creds, fetchIdentity returns the account's uuid;
    expect loginState[id]==.idle, needsReAuth[id]==false, credentials stored */ }

@Test("identityFetchFailed keeps the pending grant and does NOT report a mismatch")
func identityFailure() async { /* fetchIdentity throws URLError; expect loginState==.failed with a
    'couldn't verify' message, NOT 'different account', and a retry re-runs only identity */ }

@Test("identityMismatch reports the actual email and drops the grant")
func mismatch() async { /* account.accountUUID = A; fetchIdentity returns B+email;
    expect .failed contains the B email; credentials NOT stored */ }

@Test("credentialSaveFailed surfaces a distinct terminal state (no silent try?)")
func saveFails() async { /* AuthFailedAccountCredentialStore; expect .failed mentions keychain,
    needsReAuth stays true, message != mismatch */ }

@Test("A second beginLogin while one is pending is refused")
func serial() async { /* start one (fake begin returns loopback but never completes), call again;
    expect the second sets addLoginState/.failed 'finish the login in progress' and pendingLogin unchanged */ }
```

- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement** `beginLogin`:
  - Refuse if `pendingLogin != nil` (set a "finish the login in progress" failure on the target's state).
  - `let result = try await deps.beginLogin(accountID, false, emailFor(accountID))` → set `pendingLogin`, `loginState[id] = .waitingForBrowser(since: now)`, then `deps.openURL(result.authorizeURL)`.
    - **Pass the account's email as `loginHintEmail`** so claude.ai preselects the right account on re-auth (spike S9 confirmed the parameter is accepted). Pass `nil` for the add-account flow, where no account is known yet. Task 7's `begin` builds the URL, so the hint must be handed to it — do not rebuild the URL here.
    - **Do NOT call `waitForCallback`.** `begin` already armed it before returning; that ordering is what stops an arriving callback from being 404'd and the single-use code burned. Use the returned task.
  - Loopback: `await result.callback?.value`. nil → restart as paste: `try await deps.beginLogin(accountID, true, emailFor(accountID))`, set `.awaitingPaste`, open the new URL. Non-nil → `finishLogin(code:)`.
    - Note a deliberate contract quirk from Task 6: a successful return can legitimately arrive *after* the timeout when a code was accepted right at the boundary — the timeout bounds acceptance, not total call duration. Treat a non-nil late result as success, not as a timeout.
  - `finishLogin(code:)`: `try deps.exchange(...)`. **`OAuthLoginError` has THREE cases — handle all three, or the third is dead at its only call site** (found in the Task 5 review): `.transient` → retry once (this now also covers transport failures: offline, timeout, DNS, and any unexpected status, since Task 5 fails open); `.exchangeRejected` (400/401/403) → `.failed("Login expired or was already used — try again.")`; `.malformedResponse` → `.failed("Got an unreadable response from the login server — try again.")` (realistically a captive portal or a Cloudflare challenge page returned with a 200). Then identity (required):
    - throws → `.failed("Logged in, but couldn't verify the account — Retry.")`, **keep** `pendingLogin` + the in-memory creds for a `retryIdentity()`.
    - mismatch vs `account.accountUUID` → `.failed("That browser is signed into \(identity.email) — expected \(label).")`, **drop** creds, clear pending.
    - match (or `accountUUID == nil` → backfill via `AccountIdentityResolver`, dedupe-merge): `do { try credentials.update(id:, credentials:) } catch { .failed("Logged in, but couldn't store it — keychain unreadable.") ; return }` — **no `try?`**. Then `runtimes[id]?.credentialsReplaced()`, clear `needsReAuth[id]`, clear pending, `.idle`, post a success notification.
  - `accountID == nil` path (Add account): after identity, dedupe against existing `accountUUID`; existing → refresh in place; else append a new `Account` and `attachRuntime`.
  - `submitPaste(_ raw:)`: guard `pendingLogin?.mode == .paste`; `OAuthPaste.parse` → guard state matches `pending.pkce.state` (else `.failed("That code doesn't match this login.")`) → `finishLogin(code:)`.
  - `cancelLogin()`: `server.stop()`, clear `pendingLogin`, reset the owning state to `.idle`.
  - **Cancellation must have its own catch (found in the Task 5 re-review).** `exchange` deliberately rethrows the raw error (not an `OAuthLoginError`) when `Task.isCancelled`, so it matches none of the three `OAuthLoginError` branches. Catch `is CancellationError` / `URLError.cancelled` — or simply check `Task.isCancelled` — and return to `.idle` silently, showing NO error: the user cancelled on purpose. Without this branch a cancelled login surfaces an unhandled error, which is the same defect class the Task 5 Critical fixed.
- [ ] **Step 4: Delete** `addCurrentAccount()` and `rereadFromClaudeCode(_:)`. Run `make test` — expect compile breaks at their call sites (fixed in Task 11) and the deleted-code test suite (fixed in Task 12); for now run `-only-testing:ClaudeUsageBarTests/AccountsViewModelLoginTests`. Expected: PASS.
- [ ] **Step 5: Commit** — `feat: beginLogin flow with explicit error taxonomy; remove keychain capture`

---

### Task 10: `AccountRuntime.credentialsReplaced()` + carry-forward expiry

**Files:**
- Modify: `ClaudeUsageBar/ViewModels/AccountRuntime.swift`
- Test: `ClaudeUsageBarTests/AccountRuntimeTests.swift`

**Interfaces:**
- Produces: `func credentialsReplaced() async` — resets the breaker, clears `needsReAuth`, triggers `refresh()`. Also: in `tryTokenRefresh`, carry forward `refreshTokenExpiresAt` when the refresh response omits it.
- Also produces (folded in from the Task 1 review): `KeychainService.refreshCredentials(from data: Data, fallbackRefreshToken: String) throws -> CachedCredentials` — the pure decode+map lifted out of `performOAuthRefresh`, so the refresh path's JSON key mapping is unit-tested. **Why:** `performOAuthRefresh` currently maps `refresh_token_expires_in` inline with no test; a typo in that key would ship green and silently yield `nil` forever. Task 5 covers the *exchange* path's decode; nothing covered the *refresh* path's.
- **Note:** Task 1's brief carried a contradiction — its Interfaces line claimed `performOAuthRefresh` "preserves the prior value" while its Step 3 deferred that here. This task is where preservation actually happens; `performOAuthRefresh` itself stays a pure exchange.

- [ ] **Step 0: Extract + test the refresh decode** (folded in from the Task 1 review). Lift the `RefreshResponse` decode and mapping out of `KeychainService.performOAuthRefresh` into `static func refreshCredentials(from data: Data, fallbackRefreshToken: String) throws -> CachedCredentials`, and have `performOAuthRefresh` call it. Test it first, against the spike's real response shape:

```swift
@Suite("KeychainService.refreshCredentials")
struct RefreshDecodeTests {
    @Test("Maps the real refresh response, including refresh_token_expires_in")
    func mapsRealShape() throws {
        let body = #"{"access_token":"at","refresh_token":"rt","expires_in":28800,"refresh_token_expires_in":2383011,"token_type":"Bearer"}"#
        let creds = try KeychainService.refreshCredentials(from: Data(body.utf8), fallbackRefreshToken: "old")
        #expect(creds.accessToken == "at")
        #expect(creds.refreshToken == "rt")
        #expect(creds.refreshTokenExpiresAt != nil)
        #expect(creds.expiresAt != nil)
    }

    @Test("Falls back to the prior refresh token when the response omits one")
    func fallsBack() throws {
        let body = #"{"access_token":"at","expires_in":10}"#
        let creds = try KeychainService.refreshCredentials(from: Data(body.utf8), fallbackRefreshToken: "old")
        #expect(creds.refreshToken == "old")
        #expect(creds.refreshTokenExpiresAt == nil)   // caller carries the old value forward (Step 3)
    }
}
```

- [ ] **Step 1: Write the failing test** — after a tripped breaker, `credentialsReplaced()` clears `needsReAuth` and re-fetches.

```swift
@Test("credentialsReplaced clears needsReAuth and refreshes")
func replaced() async {
    // build a runtime whose fetchUsage first 401s (sets needsReAuth), then succeeds
    // call refresh() → needsReAuth true; swap fetch to success; call credentialsReplaced()
    // #expect(runtime.needsReAuth == false) and a snapshot present
}
```

- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement:**

```swift
func credentialsReplaced() async {
    breaker = RefreshCircuitBreaker()   // fresh, un-tripped
    needsReAuth = false
    await refresh()
}
```

And in `tryTokenRefresh`, before `credentials.update`, if `refreshed.refreshTokenExpiresAt == nil` set it from the old `creds.refreshTokenExpiresAt` (preserve the rolling window across a response that omits it).

- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: AccountRuntime.credentialsReplaced + expiry carry-forward`

---

### Task 11: UI — shared login pill, paste field, both layouts, notifications

**Files:**
- Create: `ClaudeUsageBar/Views/LoginPill.swift`
- Modify: `ClaudeUsageBar/Views/UsageMatrixView.swift:98-127` (freshness), `ClaudeUsageBar/Views/AccountRowView.swift:21-32,145-156`, `ClaudeUsageBar/Views/UsagePopoverView.swift` (empty state + "Add account…"), `ClaudeUsageBar/ViewModels/AccountsViewModel.swift` (success/failure notification)
- Test: manual QA (SwiftUI views); a `MenuBarPresentation`-style pure helper if any logic is extractable.

**Interfaces:**
- Consumes: `viewModel.needsReAuth`, `viewModel.loginState`, `viewModel.pendingLogin`, `beginLogin`, `submitPaste`, `cancelLogin`.

- [ ] **Step 1:** Build `LoginPill(viewModel:accountID:)`: renders from `loginState[accountID]` —
  - needs-login/idle → button "Log in again" → `Task { await viewModel.beginLogin(accountID) }`
  - `.waitingForBrowser` → "Waiting for browser…" + Cancel + "Copy link" (writes `pending.authorizeURL` to `NSPasteboard`) + "Use a code instead" (→ `cancelLogin` then `beginLogin` restart forcing paste — expose a `beginLogin(accountID, forcePaste:)` or a `switchToPaste()`)
  - `.awaitingPaste` → a `TextField` + Submit → `Task { await viewModel.submitPaste($0) }`
  - `.failed(msg)` → red inline text + "Try again"
- [ ] **Step 2:** Render `LoginPill` in `UsageMatrixView.freshness` (replacing the `needsReAuth` branch at `:100-106`) **and** in `AccountRowView` — hoisted above the `snapshot == nil` check so a stale snapshot still shows it (Spec §1.4). Add a `needsReAuth`-driven banner in `AccountRowView` independent of `.error`.
- [ ] **Step 3:** `UsagePopoverView`: "Add current account" → "Add account…" → `Task { await viewModel.beginLogin(nil) }`; empty-state copy no longer mentions Claude Code (Task 12).
- [ ] **Step 4:** Notifications: in `beginLogin` success/failure, post via the existing `UNUserNotificationCenter` path (mirror `sendNotification`) — "\(label) login refreshed ✓" / a short failure reason — so the outcome is visible after the popover has closed.
- [ ] **Step 5:** Manual QA build: `make install`; real loopback login for the personal account, watch the pill go idle + notification. Commit — `feat: browser-login UI (pill, paste, both layouts, notifications)`

---

### Task 12: Deletions, copy edits, README

**Files:**
- Modify: `ClaudeUsageBar/Services/KeychainService.swift` (delete `captureFromClaudeCode`, `readKeychainCredentials`, `parseCredentials`, `hexDecode`, `refreshFromKeychain`, `getCredentials` step 3), `ClaudeUsageBar/Services/UsageAPIService.swift:12-15`, `ClaudeUsageBar/Views/UsagePopoverView.swift`, `ClaudeUsageBar/Views/UsageMatrixView.swift:106`
- Modify/Delete tests: `ClaudeUsageBarTests/ServicesTests.swift` (remove the parse/hex suite), add a migration "no Claude-Code fallback" case to `AccountMigrationTests.swift`
- Modify: `README.md` (lines ~14, 32, 45, 51-57, 90, 114, 129, 170, 205-208)

- [ ] **Step 1:** Delete the listed `KeychainService` members. Keep `store`, `defaultLegacyCacheURL`, `readLegacyCacheFile`, `removeLegacyDirectoryIfEmpty`, `performOAuthRefresh`, and `getCredentials` **steps 1–2 only** (app store + legacy plaintext file); delete step 3 (Claude-Code keychain fallback). Verify `refreshAccessToken` is still referenced; delete if caller-less.
- [ ] **Step 2:** Remove `ServicesTests` parse/hex suite. Update `UsageAPIError.errorDescription` `.noToken`/`.tokenExpired` to not mention Claude Code ("Not signed in — click Log in" / "Login expired — click Log in again").
- [ ] **Step 3:** Add a migration test: legacy defaults empty + `resolveLegacyCredentials` returns nil ⇒ empty account list (no crash), asserting the removed fallback path.
- [ ] **Step 4:** Rewrite the README sections: drop the "Claude Code must be logged in" requirement (headline), rewrite troubleshooting around login expiry + the browser flow.
- [ ] **Step 5:** `make test` — full suite green. Commit — `refactor: remove Claude Code keychain capture; update copy + README`

---

### Task 13: Expiry surfacing

**Files:**
- Create/Modify: a pure helper `ClaudeUsageBar/Logic/LoginExpiry.swift` + render in `UsageMatrixView.freshness` / `AccountRowView`
- Test: `ClaudeUsageBarTests/LoginExpiryTests.swift`

**Interfaces:**
- Produces: `enum LoginExpiry { static func warning(refreshTokenExpiresAt: Date?, now: Date) -> String? }` → "Login expires in 3d" when `< 7d`, nil otherwise; and a threshold notifier at 3d/1d.

- [ ] **Step 1: Write the failing test:**

```swift
@Suite("LoginExpiry.warning")
struct LoginExpiryTests {
    @Test("Warns within 7 days, silent beyond, nil when unknown")
    func warns() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: now.addingTimeInterval(3*86400), now: now) == "Login expires in 3d")
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: now.addingTimeInterval(20*86400), now: now) == nil)
        #expect(LoginExpiry.warning(refreshTokenExpiresAt: nil, now: now) == nil)
    }
}
```

- [ ] **Step 2–4:** Implement the pure function, render it in the freshness line, wire a 3d/1d notification alongside the threshold notifier. Run — PASS.
- [ ] **Step 5: Commit** — `feat: surface login expiry countdown + pre-expiry notification`

---

## Self-Review

- **Spec coverage:** §3 spike ✓ (done, Task 0 n/a). §4 OAuthLoginService/LoopbackServer/PendingLogin → Tasks 2–7; VM wiring/error taxonomy → Tasks 8–9; `credentialsReplaced` → Task 10; UI/pending-state/notifications → Task 11; data model `refreshTokenExpiresAt` → Task 1; expiry surfacing → Task 13. §5 endpoints → Global Constraints + Task 3. §6 deletions → Task 12. §7 security → Global Constraints + Tasks 2/5/6/9. §8 testing → per-task tests + Task 11 manual QA. §9 phasing → task order.
- **Placeholder scan:** LoopbackServer's `Network` internals and some SwiftUI bodies are described rather than fully coded — acceptable because each has a contract test (Task 6) or is manual-QA UI (Task 11); all pure logic has full code.
- **Type consistency:** `PendingLogin`, `OAuthLoginMode`, `OAuthEndpoints`, `OAuthPKCE`, `OAuthLoginError`, `LoginState`, `Dependencies` names are consistent across Tasks 2–13. `credentialsReplaced()` matches Task 9 caller and Task 10 definition.
- **Known follow-up:** Task 7's loopback branch is thin on unit coverage by design (real sockets live in Task 6); Task 9 flow tests use injected fakes. Task 11 "Use a code instead" needs `beginLogin` to accept a `forcePaste`/`switchToPaste` entry — fold into Task 9's public surface when implementing.

# Browser OAuth Login — Design (v2, post-audit)

**Date:** 2026-08-21 · **Status:** approved design, spike pending
**Replaces:** the "capture from Claude Code's keychain" credential acquisition path, entirely.
**Audit trail:** v1 hardened by two independent audits (Opus + Fable) + lead security pass; 3 blockers and ~14 majors folded in below.

## 1. Context and motivation

### Confirmed root cause of recurring "Refresh login" (2026-08-21)

- Anthropic OAuth refresh tokens carry a hard **~28-day expiry** (`refreshTokenExpiresAt` observed live in Claude Code's credential blob: login 2026-08-21 → expires 2026-09-18).
- Both tracked accounts were captured 2026-07-20; both died 2026-08-17 (~28 days later, per last-successful-fetch timestamps). Simultaneous death was the expiry birthday, not token-family collision (v1 hypothesis, **rejected**) and not keychain-ACL breakage (audit hypothesis, **rejected** — the store demonstrably wrote on 2026-08-18 with the same binary).
- Therefore: **re-login every ≤4 weeks is inevitable.** The goal is not "never re-auth" but "re-auth is a painless 10-second browser round-trip, with the expiry visible before it lands."

### UX defects this design also fixes (diagnosed same day)

1. "Refresh login" only re-read Claude Code's keychain; users expect it to open a login. Browser (claude.ai) logins were invisible to the app.
2. Identity-fetch failure was collapsed by `try?` into "logged into a different account" (misleading), and several failure paths were fully silent (`try? credentials.update`).
3. Re-authing account B required switching Claude Code's own login — disruptive and confusing.
4. Single-account layout (`AccountRowView`) shows **no re-auth affordance at all** when a stale snapshot exists (body renders usage whenever `snapshot != nil`; the login button lives in the error banner, reachable only when `snapshot == nil`).

## 2. Goal / non-goals

**Goal:** The app owns its credentials end-to-end. Adding an account or re-authing = the app opens a browser OAuth flow (authorization code + PKCE, Claude Code's public `client_id`), captures its own access+refresh tokens, and never touches Claude Code's keychain again. Login expiry is surfaced before it bites.

**Non-goals:** revoking previously captured tokens (age out naturally); org selection; API-key auth; programmatically reopening the MenuBarExtra window (no macOS 13 API); menu-bar-icon login indicators.

## 3. Phase-0 spike (hard gate — no app code before this passes)

Scripted (curl/python), against live endpoints, findings appended to this spec. Authorize-endpoint details below are **inference** from Claude Code's binary strings until the spike proves them.

| # | Experiment | Decides |
|---|-----------|---------|
| S1 | Authorize → loopback redirect → code exchange. Record **exact** request/response fields, both endpoints. | Exchange body (field-by-field) that goes in §5. |
| S2 | Paste-mode variant (`code#state` shown on the callback page) end-to-end. | Paste flow viability + parse format. |
| S3 | ≥3 distinct random loopback ports; `127.0.0.1` literal vs `localhost`; path `/callback`. | Redirect-URI allowlist shape. If only a fixed port is allowed: port-in-use handling becomes mandatory and §6 concurrency stays serialized for a second reason. |
| S4 | Scope ladder: `user:profile` alone → `user:profile user:inference` → Claude Code's full set. | Smallest scope set on which usage + profile endpoints return 200. `org:create_api_key` is **not** requested unless the endpoint forces it. |
| S5 | New token against `GET /oauth/usage` and `GET /api/oauth/profile`. | Feature works at all. |
| S6 | Log in twice for the same account; then use grant #1's refresh token. | Eviction policy. If #1 dies: every login must revoke-then-replace and §9 revocation scope expands. |
| S7 | Refresh the spike grant; compare `refresh_token_expires_in` before/after. | Whether rotation renews the 28-day clock (decides notification cadence copy). |
| S8 | Record final hosts after redirects (CLI v2.1.238 carries `platform.claude.com` URLs; our proven token host is `console.anthropic.com`). Verify the token POST directly on the pinned host — never trust a cross-host 302 to preserve a POST body. | Which hosts get pinned as constants. |
| S9 | `login_hint=<email>` on authorize. | Whether re-auth can preselect the account. |
| S10 | `POST /revoke` with a spike refresh token. | §9 revoke-on-removal viability. |
| S11 | Durability checkpoint: re-refresh the spike grant at T+72h, **before merge**. | No short-window illusion. |

Any S1/S2/S5 failure kills the feature; S3/S4/S6–S10 failures reshape it (documented here, then re-approved).

## 4. Architecture

New files in `ClaudeUsageBar/Services/` and one state type in the view model. All network/browser/clock effects injected.

### `OAuthLoginService`

One entry point per flow start; owns PKCE + authorize URL + exchange.

```swift
struct PendingLogin {                 // value type, owned by AccountsViewModel
    let accountID: UUID?              // nil = "Add account…"
    let mode: Mode                    // .loopback(port:) | .paste
    let state: String                 // 32B SecRandomCopyBytes, base64url unpadded
    let verifier: String              // 43–128 chars, same RNG
    let redirectURI: String           // EXACT string sent at authorize; replayed at exchange
    let startedAt: Date
}
enum Mode { case loopback(port: UInt16), paste }
```

- `begin(accountID:preferredMode:) -> (PendingLogin, authorizeURL: URL)` — pure given injected RNG; caller opens the URL via injected `openURL`.
- `exchange(code:pending:) async throws -> TokenGrant` — POST to the token endpoint with the S1-recorded body (`grant_type=authorization_code`, `code`, `client_id`, `code_verifier`, `redirect_uri`, `state` — final list from S1). Returns access token, refresh token, `expires_in`, `refresh_token_expires_in`.
- Mode is chosen **before** the browser opens: try to bind the listener; bind failure → `.paste` mode. A timeout **restarts** as a fresh `.paste` login (new state+verifier, prior pending invalidated). There is no mid-flight fallback — `redirect_uri` is fixed at authorize time.

### `LoopbackServer`

- Binds the loopback interface only; port 0 (OS-assigned) unless S3 forces otherwise; redirect URI uses the `127.0.0.1` literal if allowlisted (kills `localhost`→`::1` resolution flakes), else `localhost` + bind both stacks.
- **Serves until satisfied or timeout (10 min):** accepts connections in a loop; only `GET /callback` with non-empty `code` AND `state` equal to the pending login's completes the flow. Everything else (favicon, preconnect, port scans) → `404`, keep listening. Completion → static 200 page ("Logged in — you can close this tab"), then shutdown. At timeout the listener stops accepting completions but keeps serving a static "login expired — try again from the app" page for a 10-minute grace period before shutting down (a late browser redirect must not land on connection-refused).
- Response: `Cache-Control: no-store`, `Connection: close`, body contains **no** request-derived content.

### `AccountsViewModel` wiring

- New seam mirroring `AccountRuntime.Dependencies`:
  `AccountsViewModel.Dependencies { loginService, fetchIdentity, openURL, now }` — required because current static call sites (`ProfileService`/`KeychainService`) make the flows untestable (they have zero coverage today).
- `beginLogin(_ accountID: UUID?)` replaces both `addCurrentAccount()` and `rereadFromClaudeCode(_:)`. Pipeline: exchange → `fetchIdentity` (required) → guard → **save (no `try?`)** → `runtime.credentialsReplaced()` → refresh.
- **Exactly one pending login** (`pendingLogin: PendingLogin?`): a second `beginLogin` while pending is refused ("Finish the login in progress first"); other login affordances disabled. Rationale: one browser session yields one account — parallel logins capture duplicates and produce unattributable errors.
- Per-account UI state: `loginState: [UUID: LoginState]` (`idle / waitingForBrowser / awaitingPaste / failed(String)`) + `addAccountLoginState` for the account-less flow. The shared `addAccountError` string is no longer used for login flows.
- All pending state lives here (`@Published`), never in view `@State` — the popover **provably closes** when the browser takes focus; on reopen it re-renders waiting/paste/failed from the VM. Terminal outcomes also fire a user notification via the existing `UNUserNotificationCenter` plumbing ("Work login refreshed ✓" / failure reason).
- `AccountRuntime` gains `credentialsReplaced()`: resets the circuit breaker, clears `needsReAuth`, triggers a refresh. (Today a fresh login would leave a tripped breaker tripped for up to 600 s.)

### Error taxonomy (replaces the `try?` collapses)

| Case | User sees | Recovery |
|---|---|---|
| `exchangeRejected` (bad/expired/reused code) | "Login expired or was already used — try again." | Restart flow. |
| `identityFetchFailed` (network/5xx; token is seconds old, so never auth) | "Logged in, but couldn't verify the account — Retry." | Pending grant kept **in memory**; Retry re-runs only the identity step. |
| `identityMismatch(actualEmail)` | "That browser is signed into *actual* — expected *label*." + "Copy login link" (paste into the right profile) | Mismatched grant is **dropped, never persisted** (known cost: it stays live server-side; revocation out of scope). |
| `credentialSaveFailed` (keychain `authFailed`/OSStatus) | "Logged in, but couldn't store it — keychain item unreadable." + **Reset stored logins** (deletes the app's keychain item, marks every account needs-login) | The one path where re-login genuinely can't help; must never be silent. |
| Identity-less migrated account (`accountUUID == nil`) | Backfill runs the existing `AccountIdentityResolver` dedupe; a duplicate merges credentials into the existing slot (models `addCurrentAccount`'s current dedupe) instead of converting the column into a copy. |

### UI

- Shared `LoginPill` component driven by `needsReAuth[id]` + `loginState[id]`, rendered in **both** `UsageMatrixView.freshness` and `AccountRowView` — and in `AccountRowView` it renders regardless of snapshot presence (fixes §1.4). Label: "Log in again" (opens browser immediately) → "Waiting for browser… · Cancel · Copy link · Use a code instead" → paste field (mode `.paste`) → inline failure text in the owning column.
- "Add current account" → "Add account…", same flow with `accountID == nil`; dedupe: an already-tracked identity refreshes that account's credentials in place (existing behavior, kept).
- Expiry surfacing: freshness line shows "Login expires in *N* d" once `refreshTokenExpiresAt − now < 7 d`; pre-expiry notification at 3 d and 1 d (cadence copy adjusted by S7).

### Data model

`CachedCredentials` gains `refreshTokenExpiresAt: Date?` (additive optional — existing keychain payloads decode unchanged). Populated from exchange and refresh responses; `performOAuthRefresh` keeps the prior value when the response omits it.

## 5. OAuth endpoints (pinned after S1/S8)

- Authorize: `https://claude.ai/oauth/authorize` *(or S8 host)* — `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e`, `response_type=code`, `code_challenge` (S256), `state`, `redirect_uri`, scopes per S4, `login_hint` per S9.
- Token: `https://console.anthropic.com/v1/oauth/token` *(proven today; re-pinned per S8)* — exchange body verbatim from S1.
- Paste-mode redirect: the manual-callback URL recorded in S2.

## 6. Deletions and edits (complete inventory, audit-verified)

**Delete:** `KeychainService.captureFromClaudeCode`, `readKeychainCredentials`, `parseCredentials`, `hexDecode`, `refreshFromKeychain` (already caller-less); `getCredentials` step 3 (Claude-Code-keychain fallback); `AccountsViewModel.addCurrentAccount` + `rereadFromClaudeCode`; `AccountRowView`'s "Re-read from Claude Code" button; the `ServicesTests.swift` parse/hex suite (4 tests).
**Keep:** `CredentialStoring`, `KeychainCredentialStore`, `KeychainService.store`, `defaultLegacyCacheURL`, `readLegacyCacheFile`, `removeLegacyDirectoryIfEmpty`, `performOAuthRefresh` (+ `refreshAccessToken` only if still referenced; delete if caller-less at implementation time).
**Stated behavior change (tested):** a pre-1.2 upgrader whose only credential copy is Claude Code's keychain now lands in the empty state and logs in via browser, instead of silently auto-migrating.
**Copy edits:** `UsageAPIError.errorDescription` (noToken/tokenExpired no longer mention Claude Code), `UsagePopoverView` empty state/button/help/tip, `UsageMatrixView` pill help, ~9 README locations (headline: the "Claude Code must be logged in" requirement disappears; troubleshooting table rewritten around login expiry).

## 7. Security requirements (lead-owned, non-negotiable)

- `state` and `code_verifier` from `SecRandomCopyBytes` (≥32 bytes, base64url, unpadded); never `UUID()`/`Int.random`. `code_challenge_method=S256` explicit.
- Pending login is single-use: cleared on success, cancel, timeout, and supersession; late loopback hits and stale pastes are rejected by state comparison.
- Listener: loopback bind only; validates method+path+state before completing; static responses; no request material ever reflected.
- Never logged/rendered: tokens, codes, verifiers, the authorize URL (contains `login_hint` email), or raw HTTP response bodies. `KeychainServiceError.refreshFailed(status:body:)` must never gain a `LocalizedError` conformance that surfaces `body` (today `state = .error(...)` renders error text in the popover).
- Wrong-account grants are dropped, never persisted. Account **removal** revokes that account's refresh token (best-effort, S10) — otherwise every removal leaks a live grant.
- Tokens persist only via the existing single-item keychain map store; save failures surface (§4 taxonomy), never `try?`.

## 8. Testing

- **Pure units:** PKCE (RFC 7636 test vector), authorize-URL builder, `code#state` parser (trim/length-cap/malformed), state match incl. cross-login rejection, exchange decode incl. `refresh_token_expires_in`, expiry-countdown formatting.
- **LoopbackServer integration:** round-trip; survives favicon + empty-preconnect before the real callback; bind-failure → paste mode; timeout; post-timeout hit gets "expired" page. (CI note: loopback works on the `macos-15` runner; keep non-`Sendable` framework types out of actor-crossing returns — known local-Xcode-26 vs CI-Xcode drift.)
- **ViewModel flows** (via `Dependencies`, injected `openURL` so `make test` never launches a browser): success clears `needsReAuth` + resets breaker; `identityFetchFailed` retry reuses in-memory grant; mismatch; save-failure surfaced (existing `AuthFailedAccountCredentialStore` stub — currently unused at VM layer); second `beginLogin` refused; pending state survives view teardown; add-account dedupe merge; nil-UUID backfill dedupe.
- **Migration:** no-Claude-Code-fallback case added to the existing suite.
- **Manual QA (lead, real accounts):** loopback + paste logins for both accounts; wrong-account mismatch; the motivating scenario (upgrade with dead captured creds → both pills → both recovered); single-account layout shows the pill with a stale snapshot.

## 9. Phasing

P0 spike (gate) → P1 `OAuthLoginService` + `LoopbackServer` + models, TDD, no UI → P2 VM wiring + UI + deletions + copy → P3 lead QA against the full app, README, ship. Detailed task breakdown lives in the implementation plan (next doc).

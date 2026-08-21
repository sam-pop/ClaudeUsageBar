import Foundation

/// Classifies why an OAuth token refresh failed, so the per-account circuit breaker only
/// trips on failures that mean the refresh token itself is dead — not on failures that a
/// later retry will clear.
///
/// This is the M2/M6 audit fix: the old breaker counted *any* error (offline, timeout,
/// 429) toward its limit, so with the Claude Code keychain fallback removed a single
/// plane-mode blip would permanently strand an account. Only hard rejections count now.
enum OAuthRefreshOutcome: Equatable {
    /// The token endpoint rejected the refresh token (invalid_grant-shaped: 400/401/403).
    /// Counts toward the breaker; enough of these → stop and surface re-login.
    case rejected
    /// Offline/timeout, 429 rate-limit, or 5xx server error. The refresh token is probably
    /// still valid — do NOT count toward the breaker; retry later.
    case transient

    var countsTowardBreaker: Bool { self == .rejected }

    static func classify(_ error: Error) -> OAuthRefreshOutcome {
        switch error {
        case KeychainServiceError.noRefreshToken:
            return .rejected
        case KeychainServiceError.refreshFailed(let status, _):
            // Only invalid_grant-shaped rejections mean the token is dead. 429 and 5xx are
            // temporary; any other status fails open to transient so we never strand.
            return [400, 401, 403].contains(status) ? .rejected : .transient
        default:
            // Network errors, decoding failures, cancellation — all retryable.
            return .transient
        }
    }
}

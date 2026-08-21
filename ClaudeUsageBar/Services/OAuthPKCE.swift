import Foundation
import CryptoKit
import Security

/// RFC 7636 PKCE (Proof Key for Public Clients) material for the browser OAuth login.
/// `verifier` is the cryptographic secret that proves our token exchange belongs to the
/// client that started the login. `state` binds the callback to this specific request
/// (anti-CSRF). `challenge` is S256(verifier) — the server will verify we know the
/// verifier without us sending it in the request.
struct OAuthPKCE: Equatable {
    let verifier: String
    let challenge: String
    let state: String

    static func generate() -> OAuthPKCE {
        let verifier = base64URL(randomBytes(32))
        return OAuthPKCE(verifier: verifier, challenge: challenge(for: verifier), state: base64URL(randomBytes(32)))
    }

    /// Computes the RFC 7636 S256 challenge: base64url(SHA256(verifier)).
    /// UTF-8 encoding of the base64url verifier is identical to its ASCII bytes,
    /// since base64url alphabet is ASCII-only — this implements the RFC's ASCII(code_verifier).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Generates cryptographically secure random bytes using SecRandomCopyBytes.
    /// We use exactly 32 bytes to match OAuth 2.0 recommended entropy (256 bits minimum).
    /// Failure is a precondition crash, not a silent fallback — there is no safe degraded
    /// path for security-token generation; continuing with weak randomness is worse than
    /// crashing during development and testing.
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

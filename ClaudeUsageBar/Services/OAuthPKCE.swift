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

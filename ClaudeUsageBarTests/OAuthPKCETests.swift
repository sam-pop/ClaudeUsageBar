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

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
        let url = p.authorizeURL(loginHintEmail: nil)
        let q = params(url)
        #expect(q["client_id"] == OAuthEndpoints.clientID)
        #expect(q["response_type"] == "code")
        #expect(q["code"] == "true")
        #expect(q["code_challenge"] == pkce.challenge)
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == pkce.state)
        #expect(q["scope"] == "user:profile user:inference")
        #expect(q["redirect_uri"] == "http://localhost:51000/callback")
        #expect(q["login_hint"] == nil)
        #expect(url.absoluteString.hasPrefix("https://claude.ai/oauth/authorize?"))
    }

    @Test("login_hint added when re-authing a known account; paste mode uses the console redirect")
    func hintAndPaste() {
        let p = PendingLogin(accountID: UUID(), mode: .paste, pkce: .generate(),
                             redirectURI: OAuthEndpoints.pasteRedirect, startedAt: .init())
        let q = params(p.authorizeURL(loginHintEmail: "sam@example.com"))
        #expect(q["login_hint"] == "sam@example.com")
        #expect(q["redirect_uri"] == OAuthEndpoints.pasteRedirect)
    }

    @Test("A plus-addressed login_hint is not corrupted into a space")
    func plusAddressedHint() {
        let p = PendingLogin(accountID: UUID(), mode: .paste, pkce: .generate(),
                             redirectURI: OAuthEndpoints.pasteRedirect, startedAt: .init())
        let url = p.authorizeURL(loginHintEmail: "sam+claude@example.com")
        // decoded queryItems must round-trip the original, and the raw query must not contain a bare '+'
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(q?.queryItems?.first { $0.name == "login_hint" }?.value == "sam+claude@example.com")
        #expect(q?.percentEncodedQuery?.contains("sam+claude") == false)
    }

    @Test("OAuthEndpoints constants match the spike-confirmed values")
    func constants() {
        #expect(OAuthEndpoints.clientID == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(OAuthEndpoints.token == "https://console.anthropic.com/v1/oauth/token")
        #expect(OAuthEndpoints.pasteRedirect == "https://console.anthropic.com/oauth/code/callback")
    }
}

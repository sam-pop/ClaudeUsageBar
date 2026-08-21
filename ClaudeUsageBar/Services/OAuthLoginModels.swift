import Foundation

/// How the browser OAuth login receives its authorization code back from Anthropic.
/// `loopback` runs a local HTTP server on an ephemeral port and captures the redirect
/// directly; `paste` sends the browser to Anthropic's own callback page, which renders
/// a `code#state` string for the user to copy back into the app.
enum OAuthLoginMode: Equatable {
    case loopback(port: UInt16)
    case paste
}

/// A browser OAuth login that has been started but not yet completed. `pkce` is the
/// verifier/challenge/state generated for this attempt; `redirectURI` is the exact
/// redirect_uri string sent with the authorize request, replayed verbatim at the
/// token exchange. `accountID` is set when this login is re-authenticating an
/// existing account, so its identity can be checked against the account returned
/// by the token exchange.
struct PendingLogin: Equatable {
    let accountID: UUID?
    let mode: OAuthLoginMode
    let pkce: OAuthPKCE
    let redirectURI: String
    let startedAt: Date
}

/// Anthropic's OAuth endpoints and client parameters for the browser login flow,
/// confirmed live against the real servers during the design spike for this feature.
enum OAuthEndpoints {
    static let authorize = "https://claude.ai/oauth/authorize"
    static let token = "https://console.anthropic.com/v1/oauth/token"
    /// Anthropic's own callback page for paste mode: it renders a `code#state` string
    /// for the user to copy back into the app, instead of redirecting to a local port.
    static let pasteRedirect = "https://console.anthropic.com/oauth/code/callback"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Deliberately excludes `org:create_api_key`. Spike S4 requested it and the
    /// server granted back only `user:inference user:profile` for this client;
    /// requesting the minimum keeps api-key-minting privilege off every stored
    /// token regardless of what the server would grant.
    static let scope = "user:profile user:inference"
}

extension PendingLogin {
    /// Builds the authorize URL for this login attempt. `loginHintEmail` should be
    /// supplied only when re-authing a known account, to preselect it; otherwise omit
    /// it so the user picks an account themselves.
    ///
    /// Never log or print the returned URL: it carries `login_hint` (a real email
    /// address) and the PKCE code challenge.
    func authorizeURL(loginHintEmail: String?) -> URL {
        var comps = URLComponents(string: OAuthEndpoints.authorize)!
        var items = [
            // Included because Claude Code's own login sends it, and our spike's
            // authorize request carried it too.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: OAuthEndpoints.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: OAuthEndpoints.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        if let loginHintEmail {
            items.append(URLQueryItem(name: "login_hint", value: loginHintEmail))
        }
        // `URLQueryItem`/`URLComponents.queryItems` leaves characters that are legal
        // in a query component (like `:`, `/`, and `+`) un-escaped. The server
        // form-decodes `+` as a space, so a plus-addressed email in `login_hint`
        // would arrive corrupted. Encode every value to unreserved characters only,
        // matching the fully percent-encoded form our spike proved the server
        // accepts.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        comps.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
        }
        return comps.url!
    }
}

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

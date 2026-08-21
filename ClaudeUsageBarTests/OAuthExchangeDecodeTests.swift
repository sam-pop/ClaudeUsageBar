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

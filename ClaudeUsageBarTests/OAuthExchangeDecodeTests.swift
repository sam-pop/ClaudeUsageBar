import Testing
import Foundation

@Suite("OAuthExchange.credentials")
struct OAuthExchangeDecodeTests {
    @Test("Decodes a 200 grant, mapping expires_in and refresh_token_expires_in to the correct fields")
    func decodes200() throws {
        let body = #"{"access_token":"at","refresh_token":"rt","expires_in":28800,"refresh_token_expires_in":2383011,"scope":"user:inference user:profile","token_type":"Bearer"}"#
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let creds = try OAuthExchange.credentials(fromStatus: 200, body: Data(body.utf8), now: fixedNow)
        #expect(creds.accessToken == "at")
        #expect(creds.refreshToken == "rt")
        // Pinned to the exact seconds, not just "some future date" — expires_in and
        // refresh_token_expires_in differ by ~83x, so a field swap in the decoder would
        // fail these but pass a bare `!= nil` check.
        #expect(abs(creds.expiresAt!.timeIntervalSince(fixedNow) - 28800) < 1)
        #expect(abs(creds.refreshTokenExpiresAt!.timeIntervalSince(fixedNow) - 2_383_011) < 1)
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
    @Test("A 2xx with an undecodable body is malformedResponse, not a crash")
    func malformedBody() {
        #expect(throws: OAuthLoginError.malformedResponse) {
            try OAuthExchange.credentials(fromStatus: 200, body: Data("{}".utf8))
        }
        #expect(throws: OAuthLoginError.malformedResponse) {
            try OAuthExchange.credentials(fromStatus: 200, body: Data("<html>challenge</html>".utf8))
        }
    }
    @Test("401 and 403 are terminal rejections, matching OAuthRefreshOutcome's set")
    func terminalStatuses() {
        #expect(throws: OAuthLoginError.exchangeRejected) {
            try OAuthExchange.credentials(fromStatus: 401, body: Data("{}".utf8))
        }
        #expect(throws: OAuthLoginError.exchangeRejected) {
            try OAuthExchange.credentials(fromStatus: 403, body: Data("{}".utf8))
        }
    }
    @Test("Any other unexpected status fails open to transient, never stranding the user")
    func failsOpen() {
        #expect(throws: OAuthLoginError.transient) {
            try OAuthExchange.credentials(fromStatus: 500, body: Data("{}".utf8))
        }
        #expect(throws: OAuthLoginError.transient) {
            try OAuthExchange.credentials(fromStatus: 418, body: Data("{}".utf8))
        }
    }
}

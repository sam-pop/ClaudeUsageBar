import Testing
import Foundation

@Suite("KeychainService.refreshCredentials")
struct KeychainRefreshDecodeTests {
    @Test("Decodes a refresh response, mapping expires_in and refresh_token_expires_in to the correct fields")
    func decodesRefreshResponse() throws {
        let body = #"{"access_token":"at2","refresh_token":"rt2","expires_in":28800,"refresh_token_expires_in":2383011}"#
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let creds = try KeychainService.refreshCredentials(
            from: Data(body.utf8), fallbackRefreshToken: "unused", now: fixedNow)
        #expect(creds.accessToken == "at2")
        #expect(creds.refreshToken == "rt2")
        // Pinned to the exact seconds, not just "some future date" — expires_in and
        // refresh_token_expires_in differ by ~83x, so a field swap in the decoder would
        // fail these but pass a bare `!= nil` check.
        let expiresAt = try #require(creds.expiresAt)
        let refreshTokenExpiresAt = try #require(creds.refreshTokenExpiresAt)
        #expect(abs(expiresAt.timeIntervalSince(fixedNow) - 28800) < 1)
        #expect(abs(refreshTokenExpiresAt.timeIntervalSince(fixedNow) - 2_383_011) < 1)
    }

    @Test("A response omitting refresh_token falls back to the token that was sent")
    func fallsBackToSentRefreshToken() throws {
        let body = #"{"access_token":"at3","expires_in":3600}"#
        let creds = try KeychainService.refreshCredentials(
            from: Data(body.utf8), fallbackRefreshToken: "r-sent")
        #expect(creds.accessToken == "at3")
        #expect(creds.refreshToken == "r-sent")
        #expect(creds.refreshTokenExpiresAt == nil)
    }
}

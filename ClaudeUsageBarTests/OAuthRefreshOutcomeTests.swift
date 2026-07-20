import Testing
import Foundation

@Suite("OAuthRefreshOutcome.classify")
struct OAuthRefreshOutcomeTests {

    @Test("Hard token rejections (400/401/403) count toward the breaker")
    func hardRejections() {
        for status in [400, 401, 403] {
            let error = KeychainServiceError.refreshFailed(status: status, body: "invalid_grant")
            #expect(OAuthRefreshOutcome.classify(error) == .rejected)
            #expect(OAuthRefreshOutcome.classify(error).countsTowardBreaker)
        }
    }

    @Test("Rate-limit (429) is transient — must not strand the account")
    func rateLimited() {
        let error = KeychainServiceError.refreshFailed(status: 429, body: "slow down")
        #expect(OAuthRefreshOutcome.classify(error) == .transient)
        #expect(!OAuthRefreshOutcome.classify(error).countsTowardBreaker)
    }

    @Test("Server errors (5xx) are transient")
    func serverErrors() {
        for status in [500, 502, 503] {
            let error = KeychainServiceError.refreshFailed(status: status, body: "")
            #expect(OAuthRefreshOutcome.classify(error) == .transient)
        }
    }

    @Test("Network failures (offline/timeout) are transient")
    func networkFailures() {
        #expect(OAuthRefreshOutcome.classify(URLError(.notConnectedToInternet)) == .transient)
        #expect(OAuthRefreshOutcome.classify(URLError(.timedOut)) == .transient)
    }

    @Test("noRefreshToken is a hard rejection")
    func noRefreshToken() {
        #expect(OAuthRefreshOutcome.classify(KeychainServiceError.noRefreshToken) == .rejected)
    }
}

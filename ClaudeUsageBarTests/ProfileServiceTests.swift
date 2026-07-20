import Testing
import Foundation

@Suite("ProfileService.decodeIdentity")
struct ProfileServiceTests {

    /// Shape captured live from the real endpoint during Phase 0 (values are examples).
    private let realPayload = """
    {"account":{"uuid":"2d9b2827-106a-49ce-ab38-8a334813c284","full_name":"Sam P","display_name":"Sam","email":"person@example.com","has_claude_max":true,"has_claude_pro":false,"created_at":"2025-08-27T13:47:29.082977Z"},"organization":{"uuid":"d7647837-3851-4f19-816f-0054bc09d7f2","name":"person@example.com's Organization","organization_type":"claude_max"}}
    """

    @Test("Extracts uuid, email, and display name from the real profile shape")
    func decodesRealPayload() throws {
        let identity = try ProfileService.decodeIdentity(from: Data(realPayload.utf8))
        #expect(identity.uuid == "2d9b2827-106a-49ce-ab38-8a334813c284")
        #expect(identity.email == "person@example.com")
        #expect(identity.displayName == "Sam")
    }

    @Test("Tolerates a missing display_name / email")
    func decodesMinimal() throws {
        let json = #"{"account":{"uuid":"abc-123"}}"#
        let identity = try ProfileService.decodeIdentity(from: Data(json.utf8))
        #expect(identity.uuid == "abc-123")
        #expect(identity.email == nil)
        #expect(identity.displayName == nil)
    }

    @Test("Throws on a payload without an account.uuid")
    func throwsOnMissingUUID() {
        let json = #"{"organization":{"uuid":"x"}}"#
        #expect(throws: (any Error).self) {
            try ProfileService.decodeIdentity(from: Data(json.utf8))
        }
    }
}

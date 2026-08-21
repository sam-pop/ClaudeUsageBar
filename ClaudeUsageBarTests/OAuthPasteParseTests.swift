import Testing

@Suite("OAuthPaste.parse")
struct OAuthPasteParseTests {
    @Test("Splits code#state and trims surrounding whitespace")
    func splits() {
        let out = OAuthPaste.parse("  abc123#xyz789\n")
        #expect(out?.code == "abc123")
        #expect(out?.state == "xyz789")
    }
    @Test("Rejects input with no separator, empty halves, or absurd length")
    func rejects() {
        #expect(OAuthPaste.parse("abc123") == nil)
        #expect(OAuthPaste.parse("#xyz") == nil)
        #expect(OAuthPaste.parse("abc#") == nil)
        #expect(OAuthPaste.parse(String(repeating: "a", count: 9000) + "#s") == nil)
    }
    @Test("Rejects empty string and whitespace-only input")
    func rejectsEmpty() {
        #expect(OAuthPaste.parse("") == nil)
        #expect(OAuthPaste.parse("   \n  ") == nil)
    }
    @Test("Rejects internal whitespace in code or state")
    func rejectsInternalWhitespace() {
        #expect(OAuthPaste.parse("abc\n123#state") == nil)
    }
    @Test("Handles multiple # by treating everything after first # as state")
    func handlesMultipleHashes() {
        #expect(OAuthPaste.parse("abc#xyz#extra")?.state == "xyz#extra")
        #expect(OAuthPaste.parse("abc#xyz#extra")?.code == "abc")
    }
}

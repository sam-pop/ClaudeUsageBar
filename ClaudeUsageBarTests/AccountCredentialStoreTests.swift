import Testing
import Foundation

@Suite("AccountCredentialCodec")
struct AccountCredentialCodecTests {

    @Test("Round-trips a multi-account map keyed by UUID")
    func roundTripsMultiAccountMap() throws {
        let a = UUID()
        let b = UUID()
        let map: [UUID: CachedCredentials] = [
            a: CachedCredentials(accessToken: "sk-ant-oat01-a", refreshToken: "r-a", expiresAt: nil),
            b: CachedCredentials(accessToken: "sk-ant-oat01-b", refreshToken: "r-b",
                                 expiresAt: Date(timeIntervalSince1970: 1_783_002_600)),
        ]

        let data = try AccountCredentialCodec.encode(map)
        let decoded = try AccountCredentialCodec.decode(data)

        #expect(decoded.count == 2)
        #expect(decoded[a]?.accessToken == "sk-ant-oat01-a")
        #expect(decoded[a]?.refreshToken == "r-a")
        #expect(decoded[b]?.accessToken == "sk-ant-oat01-b")
        let expiresAt = try #require(decoded[b]?.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince1970 - 1_783_002_600) < 0.001)
    }

    @Test("Decodes an empty payload to an empty map")
    func decodesEmpty() throws {
        let data = try AccountCredentialCodec.encode([:])
        #expect(try AccountCredentialCodec.decode(data).isEmpty)
    }
}

@Suite("KeychainLoadOutcome.classify")
struct KeychainLoadOutcomeTests {

    @Test("Success with data is .found")
    func successWithData() {
        let data = Data("payload".utf8)
        #expect(KeychainLoadOutcome.classify(status: errSecSuccess, data: data) == .found(data))
    }

    @Test("Item-not-found is .notFound (safe to treat as empty)")
    func itemNotFound() {
        #expect(KeychainLoadOutcome.classify(status: errSecItemNotFound, data: nil) == .notFound)
    }

    @Test("Auth/interaction failures are .authFailed, never .notFound")
    func authErrors() {
        #expect(KeychainLoadOutcome.classify(status: errSecAuthFailed, data: nil) == .authFailed)
        #expect(KeychainLoadOutcome.classify(status: errSecInteractionNotAllowed, data: nil) == .authFailed)
    }

    @Test("Success with no data is anomalous → .authFailed (never overwrite)")
    func successNoData() {
        #expect(KeychainLoadOutcome.classify(status: errSecSuccess, data: nil) == .authFailed)
    }

    @Test("Any other unexpected status fails closed to .authFailed")
    func otherStatus() {
        #expect(KeychainLoadOutcome.classify(status: errSecParam, data: nil) == .authFailed)
    }
}

@Suite("AccountCredentialManager")
@MainActor
struct AccountCredentialManagerTests {

    private func creds(_ token: String) -> CachedCredentials {
        CachedCredentials(accessToken: token, refreshToken: "r-\(token)", expiresAt: nil)
    }

    @Test("update writes exactly one slot, leaving other accounts untouched")
    func updatesOneSlot() throws {
        let a = UUID(), b = UUID()
        let store = InMemoryAccountCredentialStore([a: creds("a")])
        let manager = AccountCredentialManager(store: store)

        try manager.update(id: b, credentials: creds("b"))

        #expect(try store.loadAll().count == 2)
        #expect(try manager.credentials(for: a)?.accessToken == "a")
        #expect(try manager.credentials(for: b)?.accessToken == "b")
    }

    @Test("remove deletes one slot, leaving other accounts untouched")
    func removesOneSlot() throws {
        let a = UUID(), b = UUID()
        let store = InMemoryAccountCredentialStore([a: creds("a"), b: creds("b")])
        let manager = AccountCredentialManager(store: store)

        try manager.remove(id: a)

        #expect(try store.loadAll().count == 1)
        #expect(try manager.credentials(for: a) == nil)
        #expect(try manager.credentials(for: b)?.accessToken == "b")
    }

    @Test("update on an authFailed store throws and never overwrites (H1 invariant)")
    func authFailedBlocksOverwrite() throws {
        let store = AuthFailedAccountCredentialStore()
        let manager = AccountCredentialManager(store: store)

        #expect(throws: AccountCredentialStoreError.authFailed) {
            try manager.update(id: UUID(), credentials: creds("x"))
        }
        #expect(store.saveWasCalled == false)
    }
}

import Testing
import Foundation

/// The loopback cases briefly bind a real ephemeral port to observe what `begin` itself
/// decides (mode, redirect, whether a server/callback come back) — request-handling
/// behavior (favicon noise, partial reads, timeouts, …) is already covered by
/// `LoopbackServerTests`. Serialized like that suite since both touch real sockets.
@Suite("OAuthLoginService.begin", .serialized)
struct OAuthLoginServiceTests {
    @Test("forcePaste selects paste mode with the console redirect and no server")
    func forcePasteSelectsPaste() async throws {
        let result = try await OAuthLoginService().begin(accountID: nil, forcePaste: true)
        #expect(result.pending.mode == .paste)
        #expect(result.pending.redirectURI == OAuthEndpoints.pasteRedirect)
        #expect(result.server == nil)
        #expect(result.callback == nil)

        let items = URLComponents(url: result.authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "redirect_uri" }?.value == OAuthEndpoints.pasteRedirect)
    }

    @Test("forcePaste carries the given accountID and the injected clock")
    func forcePasteCarriesAccountIDAndClock() async throws {
        let id = UUID()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try await OAuthLoginService().begin(accountID: id, forcePaste: true, now: { fixedNow })
        #expect(result.pending.accountID == id)
        #expect(result.pending.startedAt == fixedNow)
    }

    @Test("A successful bind selects loopback mode with a 127.0.0.1 redirect on the bound port")
    func loopbackSuccessSelectsLoopback() async throws {
        let result = try await OAuthLoginService().begin(accountID: nil, forcePaste: false)
        guard case .loopback(let port) = result.pending.mode else {
            Issue.record("expected .loopback mode, got \(String(describing: result.pending.mode))")
            await result.server?.stop()
            return
        }
        #expect(result.pending.redirectURI == "http://127.0.0.1:\(port)/callback")
        #expect(result.server != nil)
        #expect(result.callback != nil)

        let items = URLComponents(url: result.authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "redirect_uri" }?.value == "http://127.0.0.1:\(port)/callback")

        // Tear down: resumes the already-armed `callback` wait with nil instead of leaving a
        // live listener (and its timeout Task) running for the rest of the suite.
        await result.server?.stop()
        _ = await result.callback?.value
    }

    @Test("A bind failure (port already taken) falls back to paste mode")
    func bindFailureFallsBackToPaste() async throws {
        let hog = LoopbackServer()
        let takenPort = try await hog.start()

        let result = try await OAuthLoginService().begin(
            accountID: nil, forcePaste: false,
            makeServer: { LoopbackServer(requestedPort: takenPort) })

        await hog.stop()

        #expect(result.pending.mode == .paste)
        #expect(result.pending.redirectURI == OAuthEndpoints.pasteRedirect)
        #expect(result.server == nil)
        #expect(result.callback == nil)
    }

    @Test("The armed callback wait resolves to the code delivered on the bound port")
    func armedCallbackDeliversCode() async throws {
        let result = try await OAuthLoginService().begin(accountID: nil, forcePaste: false)
        guard case .loopback(let port) = result.pending.mode, let callback = result.callback else {
            Issue.record("expected loopback mode with an armed callback")
            return
        }
        let state = result.pending.pkce.state
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/callback?code=abc123&state=\(state)")!)
        request.timeoutInterval = 5
        _ = try await URLSession.shared.data(for: request)
        #expect(await callback.value == "abc123")
        await result.server?.stop()
    }
}

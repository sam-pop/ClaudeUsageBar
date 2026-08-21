import Testing
import Foundation

/// The loopback cases briefly bind a real ephemeral port to observe what `begin` itself
/// decides (mode, redirect, whether a server/callback come back, whether the server is
/// stopped after a delivered code) — request-handling behavior (favicon noise, partial
/// reads, timeouts, …) is already covered by `LoopbackServerTests`. `.serialized` only
/// keeps this suite's own tests from running concurrently with each other (Swift Testing
/// still parallelizes across suites) — real socket/timer state is easier to reason about
/// one test at a time.
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

    @Test("loginHintEmail is included in authorizeURL when supplied, absent otherwise")
    func loginHintPassThrough() async throws {
        let hinted = try await OAuthLoginService().begin(
            accountID: nil, forcePaste: true, loginHintEmail: "sam@example.com")
        let hintedItems = URLComponents(url: hinted.authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(hintedItems.first { $0.name == "login_hint" }?.value == "sam@example.com")

        let plain = try await OAuthLoginService().begin(accountID: nil, forcePaste: true)
        let plainItems = URLComponents(url: plain.authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(plainItems.first { $0.name == "login_hint" } == nil)
    }

    @Test("A successful bind selects loopback mode with a localhost redirect on the bound port")
    func loopbackSuccessSelectsLoopback() async throws {
        let id = UUID()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try await OAuthLoginService().begin(
            accountID: id, forcePaste: false, loginHintEmail: "sam@example.com", now: { fixedNow })
        guard case .loopback(let port) = result.pending.mode else {
            Issue.record("expected .loopback mode, got \(String(describing: result.pending.mode))")
            await result.server?.stop()
            return
        }
        #expect(result.pending.redirectURI == "http://localhost:\(port)/callback")
        #expect(result.pending.accountID == id)
        #expect(result.pending.startedAt == fixedNow)
        #expect(result.server != nil)
        #expect(result.callback != nil)

        let items = URLComponents(url: result.authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "redirect_uri" }?.value == "http://localhost:\(port)/callback")
        #expect(items.first { $0.name == "login_hint" }?.value == "sam@example.com")

        // Tear down: resumes the already-enqueued `callback` wait with nil instead of leaving a
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
        // Defensive cleanup: if this ever regresses to a bound server, don't leak a live
        // listener and its 600s wait into the rest of the suite instead of failing cleanly.
        await result.server?.stop()
        _ = await result.callback?.value

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
    }

    @Test("A delivered code stops the listener automatically")
    func deliveredCodeStopsListener() async throws {
        let result = try await OAuthLoginService().begin(accountID: nil, forcePaste: false)
        guard case .loopback(let port) = result.pending.mode, let callback = result.callback,
              let server = result.server else {
            Issue.record("expected loopback mode with an armed callback and server")
            return
        }
        let state = result.pending.pkce.state
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/callback?code=xyz789&state=\(state)")!)
        request.timeoutInterval = 5
        _ = try await URLSession.shared.data(for: request)
        #expect(await callback.value == "xyz789")

        // `start()` throws bindFailed only once the server has been stopped (LoopbackServerTests
        // "start() after stop() fails instead of handing back a dead port") — the delivered code
        // above must already have triggered that, without an explicit stop() from this test.
        await #expect(throws: LoopbackServer.StartError.self) {
            _ = try await server.start()
        }
    }
}

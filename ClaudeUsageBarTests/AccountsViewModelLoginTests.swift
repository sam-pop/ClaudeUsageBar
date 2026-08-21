import Testing
import Foundation
import UserNotifications

/// `beginLogin` matches `OAuthLoginService.begin(accountID:forcePaste:loginHintEmail:...)`,
/// which takes 3 required parameters — the fake below matches that arity.
///
/// `.timeLimit` guards against a reintroduced blocking call wedging the suite, but only if
/// the hang is asynchronous (an awaited prompt or network wait) — Swift Testing enforces
/// the limit via cooperative cancellation, which cannot interrupt a synchronous call
/// blocked on the main thread with no suspension point (the original keychain hang was
/// exactly that kind of call).
@Suite("AccountsViewModel login seam", .timeLimit(.minutes(1)))
@MainActor
struct AccountsViewModelLoginTests {

    /// A generic stub error for the runtime-facing closures (`fetchUsage`/`refreshToken`)
    /// that most of these tests never expect to succeed or be retried.
    private struct StubError: Error {}

    /// Counts how many times this seam's real-I/O closures fire, so a test can prove
    /// `AccountsViewModel` actually routes through `deps` instead of a hardcoded call.
    private final class Calls: @unchecked Sendable {
        var resolve = 0
        var delete = 0
        var fetchUsage = 0
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "AccountsViewModelLoginTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeDeps(calls: Calls, legacyCredentials: CachedCredentials?) -> AccountsViewModel.Dependencies {
        AccountsViewModel.Dependencies(
            beginLogin: { _, _, _ in throw OAuthLoginError.transient },
            exchange: { _, _ in throw OAuthLoginError.transient },
            fetchIdentity: { _ in AccountIdentity(uuid: "u", email: "e", displayName: "d") },
            openURL: { _ in },
            now: { Date(timeIntervalSince1970: 0) },
            resolveLegacyCredentials: {
                calls.resolve += 1
                return legacyCredentials
            },
            deleteLegacyArtifacts: { calls.delete += 1 },
            requestNotificationAuthorization: { nil },
            addNotification: { _ in },
            fetchUsage: { _ in throw StubError() },
            refreshToken: { _ in throw StubError() })
    }

    @Test("No legacy credentials: init routes through the seam, deletes nothing, attaches no accounts")
    func nilLegacyPathRoutesThroughSeam() {
        let calls = Calls()
        // Production shares one UserDefaults instance between the accounts list and app
        // state; matching that here rather than using two unrelated suites.
        let sharedDefaults = ephemeralDefaults()
        let vm = AccountsViewModel(
            accountsStore: AccountsStore(defaults: sharedDefaults),
            credentialStore: InMemoryAccountCredentialStore(),
            defaults: sharedDefaults,
            startTimer: false,
            deps: makeDeps(calls: calls, legacyCredentials: nil))
        #expect(vm.pendingLogin == nil)
        #expect(calls.resolve == 1)   // init routed through the seam
        #expect(calls.delete == 0)    // nothing destructive on the nil path
        #expect(vm.accounts.isEmpty)  // no runtimes attached → no refresh I/O
    }

    @Test("Legacy credentials present: migration runs through the seam and deletes the legacy artifacts")
    func migratesThroughSeam() {
        let calls = Calls()
        let sharedDefaults = ephemeralDefaults()
        let legacy = CachedCredentials(accessToken: "sk-ant-oat01-legacy", refreshToken: "r", expiresAt: nil)
        let vm = AccountsViewModel(
            accountsStore: AccountsStore(defaults: sharedDefaults),
            credentialStore: InMemoryAccountCredentialStore(),
            defaults: sharedDefaults,
            startTimer: false,
            deps: makeDeps(calls: calls, legacyCredentials: legacy))
        #expect(calls.resolve == 1)
        #expect(calls.delete == 1)      // legacy artifacts cleaned up through the seam
        #expect(vm.accounts.count == 1) // migration produced exactly the one legacy account
        // Honest limitation, accepted rather than fixed: if `deleteLegacyArtifacts`'s
        // wiring were ever reverted to the hardcoded keychain/filesystem calls, this test
        // would destroy real credential artifacts before failing. Inherent to a counting
        // double on a destructive seam — still far better than no coverage at all.
    }

    @Test("An existing account's usage refresh goes through the seam, not a hardcoded network call")
    func existingAccountRefreshesThroughSeam() async {
        let calls = Calls()
        let sharedDefaults = ephemeralDefaults()
        // accountUUID is nil, matching a legacy-migrated account — a successful fetch
        // below also exercises the fetchIdentity backfill path through the seam.
        let account = Account(label: "Test Account")
        let accountsStore = AccountsStore(defaults: sharedDefaults)
        accountsStore.save([account])   // hasAccounts becomes true: migration short-circuits

        let credentialStore = InMemoryAccountCredentialStore([
            account.id: CachedCredentials(accessToken: "sk-ant-oat01-tok", refreshToken: "r", expiresAt: nil)
        ])

        var deps = makeDeps(calls: calls, legacyCredentials: nil)
        deps.fetchUsage = { _ in
            calls.fetchUsage += 1
            return UsageResponse(
                fiveHour: UsagePeriod(utilization: 10, resetsAt: "2026-07-09T18:30:00Z"),
                sevenDay: UsagePeriod(utilization: 10, resetsAt: "2026-07-16T00:00:00Z"))
        }

        let vm = AccountsViewModel(
            accountsStore: accountsStore,
            credentialStore: credentialStore,
            defaults: sharedDefaults,
            startTimer: false,
            deps: deps)

        await vm.refreshAll()

        #expect(calls.fetchUsage >= 1)
        #expect(vm.snapshots[account.id] != nil)
    }
}

/// The browser-login flow: its error taxonomy, the one-pending-login rule, and the paths
/// that must never persist a grant. Every system touch is scripted through
/// `AccountsViewModel.Dependencies`, so no browser opens and no real login runs.
@Suite("AccountsViewModel browser login", .timeLimit(.minutes(1)))
@MainActor
struct AccountsViewModelBrowserLoginTests {

    private struct StubError: Error {}

    /// What the injected seam should do for one view model, plus a record of what it was
    /// actually asked. `@unchecked Sendable` because the seam's closures are non-isolated
    /// while each test drives them from one logical flow at a time.
    private final class Script: @unchecked Sendable {
        /// The PKCE the fake `beginLogin` hands out, so a test can paste a matching state.
        let pkce = OAuthPKCE.generate()
        /// Start in paste mode even when the caller didn't ask for it — what a bind failure
        /// produces in production.
        var beginPaste = false
        var beginError: Error?
        /// What the loopback callback task yields: a code, or `nil` for a timeout.
        var callbackCode: String?
        var callbackDelay: Duration = .zero
        /// Hand a callback back for paste mode too — which the real `begin` never does. Only
        /// for proving the restart is bounded by the caller rather than by that contract.
        var pasteYieldsCallback = false
        /// Scripted results, consumed front to back; the last entry repeats.
        var exchangeResults: [Result<CachedCredentials, Error>] = []
        var identityResults: [Result<AccountIdentity, Error>] = []
        var usageResult: Result<UsageResponse, Error> = .failure(UsageAPIError.tokenExpired)

        var beginCalls: [(accountID: UUID?, forcePaste: Bool, hint: String?)] = []
        var exchangeCount = 0
        var identityCount = 0
        var openedCount = 0
        var usageTokens: [String] = []
        var notifications: [UNNotificationRequest] = []

        func nextExchange() throws -> CachedCredentials {
            exchangeCount += 1
            return try Self.pop(&exchangeResults)
        }

        func nextIdentity() throws -> AccountIdentity {
            identityCount += 1
            return try Self.pop(&identityResults)
        }

        private static func pop<T>(_ queue: inout [Result<T, Error>]) throws -> T {
            guard let first = queue.first else { throw StubError() }
            if queue.count > 1 { queue.removeFirst() }
            return try first.get()
        }
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "AccountsViewModelBrowserLoginTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeDeps(_ script: Script) -> AccountsViewModel.Dependencies {
        AccountsViewModel.Dependencies(
            beginLogin: { accountID, forcePaste, hint in
                script.beginCalls.append((accountID, forcePaste, hint))
                if let error = script.beginError { throw error }
                let paste = forcePaste || script.beginPaste
                let pending = PendingLogin(
                    accountID: accountID,
                    mode: paste ? .paste : .loopback(port: 49152),
                    pkce: script.pkce,
                    redirectURI: paste ? OAuthEndpoints.pasteRedirect : "http://127.0.0.1:49152/callback",
                    startedAt: Date(timeIntervalSince1970: 0))
                // Stand-in for the authorize URL; the real one is built by `OAuthLoginService`.
                let url = URL(string: "https://claude.ai/oauth/authorize")!
                guard !paste || script.pasteYieldsCallback else { return (pending, url, nil, nil) }
                let code = script.callbackCode
                let delay = script.callbackDelay
                let callback = Task<String?, Never> {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    return code
                }
                return (pending, url, nil, callback)
            },
            exchange: { _, _ in try script.nextExchange() },
            fetchIdentity: { _ in try script.nextIdentity() },
            openURL: { _ in script.openedCount += 1 },
            now: { Date(timeIntervalSince1970: 0) },
            resolveLegacyCredentials: { nil },
            deleteLegacyArtifacts: {},
            requestNotificationAuthorization: { nil },
            addNotification: { script.notifications.append($0) },
            fetchUsage: { token in
                script.usageTokens.append(token)
                return try script.usageResult.get()
            },
            refreshToken: { _ in throw StubError() })
    }

    private func makeVM(
        _ script: Script,
        accounts: [Account],
        store: AccountCredentialStoring
    ) -> AccountsViewModel {
        let defaults = ephemeralDefaults()
        let accountsStore = AccountsStore(defaults: defaults)
        accountsStore.save(accounts)    // an existing list short-circuits the migration
        return AccountsViewModel(
            accountsStore: accountsStore,
            credentialStore: store,
            defaults: defaults,
            startTimer: false,
            deps: makeDeps(script))
    }

    private static let oldCredentials = CachedCredentials(
        accessToken: "old-token", refreshToken: "old-refresh", expiresAt: nil)
    private static let freshCredentials = CachedCredentials(
        accessToken: "fresh-token", refreshToken: "fresh-refresh", expiresAt: nil)

    private func usageResponse() -> UsageResponse {
        UsageResponse(
            fiveHour: UsagePeriod(utilization: 10, resetsAt: "2026-07-09T18:30:00Z"),
            sevenDay: UsagePeriod(utilization: 20, resetsAt: "2026-07-16T00:00:00Z"))
    }

    private func identity(_ uuid: String, email: String?, name: String? = nil) -> AccountIdentity {
        AccountIdentity(uuid: uuid, email: email, displayName: name)
    }

    private func failureMessage(_ state: AccountsViewModel.LoginState?, _ comment: Comment) -> String {
        guard case .failed(let message)? = state else {
            Issue.record("expected a .failed state, got \(String(describing: state)) — \(comment)")
            return ""
        }
        return message
    }

    private func noticeMessage(_ state: AccountsViewModel.LoginState?, _ comment: Comment) -> String {
        guard case .notice(let message)? = state else {
            Issue.record("expected a .notice state, got \(String(describing: state)) — \(comment)")
            return ""
        }
        return message
    }

    // MARK: - Success

    @Test("Success: exchange → matching identity → stored, needsReAuth cleared, runtime refreshed")
    func successStoresAndRevives() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com", name: "A"))]

        let account = Account(label: "Work", accountUUID: "acct-A", email: "a@example.com")
        let store = InMemoryAccountCredentialStore([account.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.refreshAll()
        #expect(vm.needsReAuth[account.id] == true)   // the dead-login state this flow recovers from

        script.usageResult = .success(usageResponse())
        await vm.beginLogin(account.id)

        #expect(vm.loginState[account.id] == .idle)
        #expect(vm.pendingLogin == nil)
        #expect(try store.loadAll()[account.id]?.accessToken == "fresh-token")
        #expect(vm.needsReAuth[account.id] == false)
        // credentialsReplaced() ran: the account re-fetched against the NEW token.
        #expect(script.usageTokens.contains("fresh-token"))
        #expect(vm.snapshots[account.id] != nil)
        #expect(script.notifications.count == 1)
        #expect(script.openedCount == 1)
        // login_hint carries the account's email so claude.ai preselects it.
        #expect(script.beginCalls.first?.hint == "a@example.com")
    }

    @Test("An empty stored email is sent as no login_hint at all")
    func blankEmailSendsNoHint() async {
        let script = Script()
        script.beginPaste = true
        let account = Account(label: "Work", accountUUID: "acct-A", email: "   ")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)

        #expect(script.beginCalls.first?.hint == nil)
    }

    @Test("A callback that arrives after a pause is a success, not a timeout")
    func lateCallbackIsSuccess() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.callbackDelay = .milliseconds(50)
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com"))]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let store = InMemoryAccountCredentialStore([account.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.beginLogin(account.id)

        #expect(script.beginCalls.count == 1)   // no paste-mode restart
        #expect(vm.loginState[account.id] == .idle)
        #expect(try store.loadAll()[account.id]?.accessToken == "fresh-token")
    }

    // MARK: - Timeout, cancel, serialization

    @Test("A loopback timeout restarts the login in paste mode")
    func timeoutRestartsAsPaste() async {
        let script = Script()
        script.callbackCode = nil   // the callback task yields nil: timeout

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)

        #expect(script.beginCalls.count == 2)
        #expect(script.beginCalls.last?.forcePaste == true)
        #expect(vm.loginState[account.id] == .awaitingPaste)
        #expect(vm.pendingLogin?.mode == .paste)
        #expect(script.exchangeCount == 0)
        // Ten minutes have passed with the popover shut: without a notification the app has
        // silently opened a new page and started expecting a pasted code.
        #expect(script.notifications.count == 1)
        #expect(script.notifications.first?.content.body.contains("paste the code") == true)
    }

    @Test("A restart that fails to start reports the failure, not a request to paste a code")
    func failedRestartDoesNotAskForAPaste() async {
        let script = Script()
        script.callbackCode = nil   // the loopback wait times out, so a paste restart follows

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        // The restart itself can't start: there is no login left to paste into.
        script.beginError = OAuthLoginError.transient
        await vm.beginLogin(account.id)

        #expect(vm.pendingLogin == nil)
        #expect(script.notifications.count == 1)
        #expect(script.notifications.first?.content.title.contains("didn't finish") == true)
    }

    @Test("Removing an account mid-login releases the slot — its Cancel button went with the row")
    func removingAnAccountCancelsItsLogin() async {
        let script = Script()
        script.beginPaste = true   // parks in .awaitingPaste holding the one pending slot

        let work = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [work], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(work.id)
        #expect(vm.pendingLogin != nil)

        await vm.remove(work.id)

        #expect(vm.pendingLogin == nil)
        #expect(vm.loginState[work.id] == nil)     // no orphaned entries for a gone account
        #expect(vm.needsReAuth[work.id] == nil)

        // The slot is really free: the next login starts instead of being refused with
        // "Finish the login in progress first." while no login is on screen to finish.
        script.identityResults = [.success(identity("acct-B", email: "b@example.com", name: "Bee"))]
        await vm.beginLogin(nil)

        #expect(script.beginCalls.count == 2)
        #expect(vm.addLoginState == .awaitingPaste)
    }

    @Test("The paste-mode restart never restarts again, even if it is handed a listener")
    func restartHappensAtMostOnce() async {
        let script = Script()
        script.callbackCode = nil            // every callback in this test times out
        script.pasteYieldsCallback = true    // …including the paste-mode restart's

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)

        // One loopback login plus exactly one paste restart. Without the caller's own bound
        // this recurses for as long as the seam keeps timing out.
        #expect(script.beginCalls.count == 2)
        #expect(script.beginCalls.last?.forcePaste == true)
        #expect(vm.pendingLogin == nil)
        #expect(vm.loginState[account.id] == .idle)
    }

    @Test("Cancelling a loopback login stops its listener and shows no error")
    func cancelStopsTheListener() async throws {
        let script = Script()
        let server = LoopbackServer()
        let port = try await server.start()
        #expect(port > 0)

        // Wire the real listener into the flow exactly as `OAuthLoginService.begin` does:
        // the wait is already armed as a Task before `beginLogin` ever sees it.
        var deps = makeDeps(script)
        let pkce = script.pkce
        deps.beginLogin = { accountID, _, _ in
            script.beginCalls.append((accountID, false, nil))
            let pending = PendingLogin(
                accountID: accountID, mode: .loopback(port: port), pkce: pkce,
                redirectURI: "http://127.0.0.1:\(port)/callback",
                startedAt: Date(timeIntervalSince1970: 0))
            let callback = Task<String?, Never> {
                await server.waitForCallback(expectedState: pkce.state, timeout: 600)
            }
            return (pending, URL(string: "https://claude.ai/oauth/authorize")!, server, callback)
        }

        let account = Account(label: "Work", accountUUID: "acct-A")
        let defaults = ephemeralDefaults()
        let accountsStore = AccountsStore(defaults: defaults)
        accountsStore.save([account])
        let vm = AccountsViewModel(
            accountsStore: accountsStore, credentialStore: InMemoryAccountCredentialStore(),
            defaults: defaults, startTimer: false, deps: deps)

        let login = Task { await vm.beginLogin(account.id) }
        while vm.pendingLogin == nil { await Task.yield() }

        await vm.cancelLogin()
        await login.value

        #expect(vm.pendingLogin == nil)
        #expect(vm.loginState[account.id] == .idle)   // cancelling is not a failure
        #expect(script.beginCalls.count == 1)         // and must not restart as paste
        // A stopped server refuses to start again — proof the listener was torn down and
        // its port isn't left bound for the life of the app.
        await #expect(throws: LoopbackServer.StartError.self) { try await server.start() }
    }

    @Test("A second login while one is pending is refused")
    func secondLoginRefused() async {
        let script = Script()
        script.beginPaste = true   // parks in .awaitingPaste with a live pending login

        let work = Account(label: "Work", accountUUID: "acct-A")
        let personal = Account(label: "Personal", accountUUID: "acct-B")
        let vm = makeVM(script, accounts: [work, personal], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(work.id)
        #expect(vm.loginState[work.id] == .awaitingPaste)
        let pending = vm.pendingLogin

        await vm.beginLogin(personal.id)

        let message = failureMessage(vm.loginState[personal.id], "second login")
        #expect(message.contains("Finish the login in progress"))
        #expect(vm.pendingLogin == pending)               // the first login is untouched
        #expect(vm.loginState[work.id] == .awaitingPaste)
        #expect(script.beginCalls.count == 1)

        // A repeat request from the flow that is already running is refused too, but must not
        // replace that flow's own state with a failure — the login is still live.
        await vm.beginLogin(work.id)
        #expect(vm.loginState[work.id] == .awaitingPaste)
        #expect(script.beginCalls.count == 1)
    }

    @Test("The “finish the login in progress” refusal clears when that login ends")
    func busyNoticeClearsWhenThePendingLoginEnds() async {
        let script = Script()
        script.beginPaste = true   // parks in .awaitingPaste with a live pending login

        let work = Account(label: "Work", accountUUID: "acct-A")
        let personal = Account(label: "Personal", accountUUID: "acct-B")
        let vm = makeVM(script, accounts: [work, personal], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(work.id)
        await vm.beginLogin(personal.id)
        #expect(failureMessage(vm.loginState[personal.id], "refusal").contains("Finish the login"))

        await vm.cancelLogin()

        // The refusal is written onto whichever account was clicked second, so nothing that
        // account does clears it: left in place it sits there as that account's own failure.
        #expect(vm.loginState[personal.id] == .idle)
        #expect(vm.loginAffordance(for: personal.id) == LoginAffordance.none)
        #expect(vm.loginState[work.id] == .idle)
    }

    @Test("The authorize URL is exposed while a login is pending, for Copy link, and dropped after")
    func authorizeURLIsExposedForCopying() async {
        let script = Script()
        script.beginPaste = true

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)
        // Exactly the URL handed to the browser — the point is opening the same login
        // somewhere else, not rebuilding a new one.
        #expect(vm.pendingAuthorizeURL == URL(string: "https://claude.ai/oauth/authorize"))

        await vm.cancelLogin()
        #expect(vm.pendingAuthorizeURL == nil)
    }

    @Test("Use a code instead: the loopback listener is torn down and the login restarts in paste mode")
    func switchToPasteRestartsTheLogin() async throws {
        let script = Script()
        let server = LoopbackServer()
        let port = try await server.start()

        // A real listener, so the switch can be shown to actually release the port — a
        // restart that leaves the old server bound is the bug this path invites.
        var deps = makeDeps(script)
        let pkce = script.pkce
        let url = URL(string: "https://claude.ai/oauth/authorize")!
        deps.beginLogin = { accountID, forcePaste, _ in
            script.beginCalls.append((accountID, forcePaste, nil))
            guard !forcePaste else {
                let pending = PendingLogin(
                    accountID: accountID, mode: .paste, pkce: pkce,
                    redirectURI: OAuthEndpoints.pasteRedirect, startedAt: Date(timeIntervalSince1970: 0))
                return (pending, url, nil, nil)
            }
            let pending = PendingLogin(
                accountID: accountID, mode: .loopback(port: port), pkce: pkce,
                redirectURI: "http://127.0.0.1:\(port)/callback", startedAt: Date(timeIntervalSince1970: 0))
            let callback = Task<String?, Never> {
                await server.waitForCallback(expectedState: pkce.state, timeout: 600)
            }
            return (pending, url, server, callback)
        }

        let account = Account(label: "Work", accountUUID: "acct-A")
        let defaults = ephemeralDefaults()
        let accountsStore = AccountsStore(defaults: defaults)
        accountsStore.save([account])
        let vm = AccountsViewModel(
            accountsStore: accountsStore, credentialStore: InMemoryAccountCredentialStore(),
            defaults: defaults, startTimer: false, deps: deps)

        let login = Task { await vm.beginLogin(account.id) }
        while vm.pendingLogin == nil { await Task.yield() }
        #expect(vm.loginAffordance(for: account.id) == .waitingForBrowser)

        await vm.switchToPaste()
        await login.value

        #expect(script.beginCalls.count == 2)
        #expect(script.beginCalls.last?.forcePaste == true)
        #expect(vm.pendingLogin?.mode == .paste)
        #expect(vm.loginState[account.id] == .awaitingPaste)
        // The abandoned listener is really gone: a stopped server refuses to start again.
        await #expect(throws: LoopbackServer.StartError.self) { try await server.start() }
    }

    // MARK: - Exchange taxonomy

    @Test("A rejected exchange says the code is spent — not that the account is wrong")
    func exchangeRejectedIsItsOwnMessage() async {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.failure(OAuthLoginError.exchangeRejected)]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)

        let message = failureMessage(vm.loginState[account.id], "exchangeRejected")
        #expect(message.contains("already used"))
        #expect(!message.contains("signed into"))
        #expect(script.exchangeCount == 1)   // a rejected code is never retried
        #expect(vm.pendingLogin == nil)
        #expect(script.identityCount == 0)
    }

    @Test("An unreadable exchange response gets its own message")
    func malformedResponseIsItsOwnMessage() async {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.failure(OAuthLoginError.malformedResponse)]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)

        let message = failureMessage(vm.loginState[account.id], "malformedResponse")
        #expect(message.contains("unreadable"))
        #expect(script.exchangeCount == 1)
    }

    @Test("A transient exchange failure is retried once, then succeeds")
    func transientExchangeIsRetriedOnce() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.failure(OAuthLoginError.transient), .success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com"))]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let store = InMemoryAccountCredentialStore([account.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.beginLogin(account.id)

        #expect(script.exchangeCount == 2)
        #expect(vm.loginState[account.id] == .idle)
        #expect(try store.loadAll()[account.id]?.accessToken == "fresh-token")
    }

    @Test("A cancelled exchange returns to idle showing no error")
    func cancellationShowsNoError() async {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.failure(CancellationError())]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)

        #expect(vm.loginState[account.id] == .idle)
        #expect(vm.pendingLogin == nil)
        #expect(script.notifications.isEmpty)
    }

    // MARK: - Identity taxonomy

    @Test("identityFetchFailed keeps the grant for a retry and never reports a mismatch")
    func identityFailureKeepsTheGrant() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [
            .failure(URLError(.timedOut)),
            .success(identity("acct-A", email: "a@example.com")),
        ]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let store = InMemoryAccountCredentialStore([account.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.beginLogin(account.id)

        let message = failureMessage(vm.loginState[account.id], "identity fetch failure")
        #expect(message.contains("couldn't verify"))
        #expect(!message.contains("signed into"))       // never a mismatch claim
        #expect(!message.contains("different account"))
        #expect(vm.pendingLogin != nil)                 // the grant is still recoverable
        #expect(try store.loadAll()[account.id]?.accessToken == "old-token")

        script.usageResult = .success(usageResponse())
        await vm.retryIdentity()

        #expect(script.exchangeCount == 1)   // only the identity step re-ran
        #expect(script.identityCount == 2)
        #expect(vm.loginState[account.id] == .idle)
        #expect(try store.loadAll()[account.id]?.accessToken == "fresh-token")
    }

    @Test("identityMismatch reports the actual email and stores nothing")
    func mismatchDropsTheGrant() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-B", email: "b@example.com", name: "B"))]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let store = InMemoryAccountCredentialStore([account.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.beginLogin(account.id)

        let message = failureMessage(vm.loginState[account.id], "identity mismatch")
        #expect(message.contains("b@example.com"))
        #expect(message.contains("Work"))
        #expect(try store.loadAll()[account.id]?.accessToken == "old-token")   // grant dropped
        #expect(vm.pendingLogin == nil)
        // The popover is shut while the browser has focus, so the rejection is only visible
        // as a notification — and it must not be mistaken for a success.
        #expect(script.notifications.count == 1)
        #expect(script.notifications.first?.content.body.contains("b@example.com") == true)
        #expect(script.notifications.first?.content.title.contains("didn't finish") == true)
    }

    @Test("A credential save failure is a distinct terminal state, not a silent success")
    func saveFailureSurfaces() async {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com"))]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let store = AuthFailedAccountCredentialStore()
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.refreshAll()
        #expect(vm.needsReAuth[account.id] == true)

        await vm.beginLogin(account.id)

        let message = failureMessage(vm.loginState[account.id], "credential save failure")
        #expect(message.contains("keychain"))
        // The same error covers a failed write, so it must not diagnose the item as unreadable.
        #expect(message.hasPrefix("Couldn't store the login"))
        #expect(!message.contains("unreadable"))
        #expect(!message.contains("signed into"))
        #expect(vm.needsReAuth[account.id] == true)   // nothing landed, so nothing is fixed
        #expect(store.saveWasCalled == false)
        // Reported as a failure, never as the success it isn't.
        #expect(script.notifications.count == 1)
        #expect(script.notifications.first?.content.title.contains("didn't finish") == true)
        #expect(vm.pendingLogin == nil)
    }

    @Test("A later outcome replaces the earlier notification rather than stacking beside it")
    func outcomeNotificationsShareOneIdentifier() async {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.failure(OAuthLoginError.exchangeRejected),
                                  .success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com"))]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let store = InMemoryAccountCredentialStore([account.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.beginLogin(account.id)   // fails
        await vm.beginLogin(account.id)   // then succeeds

        #expect(script.notifications.count == 2)
        // One identifier per flow, so Notification Center replaces the first: "login didn't
        // finish" must not sit next to the "logged in" that followed it.
        #expect(Set(script.notifications.map(\.identifier)).count == 1)
    }

    @Test("An identity failure notifies too: it parks the login where nothing else can be started")
    func identityFailureNotifies() async {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.failure(URLError(.timedOut))]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)

        #expect(script.notifications.count == 1)
        #expect(script.notifications.first?.content.body.contains("couldn't verify") == true)
        // And the UI has both ways out of it, rather than a pill that refuses every click.
        #expect(vm.canRetryIdentity(for: account.id))
        #expect(vm.loginAffordance(for: account.id).actions == [.retryIdentity, .cancel])
    }

    @Test("A login that fails to start is reported, and only a real failure is")
    func startFailureNotifiesButCancellationDoesNot() async {
        let script = Script()
        script.beginError = OAuthLoginError.transient

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)
        #expect(script.notifications.count == 1)

        script.beginError = CancellationError()
        await vm.beginLogin(account.id)
        #expect(vm.loginState[account.id] == .idle)
        #expect(script.notifications.count == 1)   // cancelling is the user's own doing
    }

    // MARK: - Add account

    @Test("Add account: an already-tracked identity refreshes it in place instead of duplicating")
    func addAccountDedupes() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com", name: "A"))]

        let account = Account(label: "Work", accountUUID: "acct-A", email: "a@example.com")
        let store = InMemoryAccountCredentialStore([account.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.beginLogin(nil)

        #expect(vm.accounts.count == 1)
        #expect(try store.loadAll()[account.id]?.accessToken == "fresh-token")
        // A notice, not a failure: the credentials landed. Rendering this as an error styles a
        // success in red and contradicts the success notification this same flow posts.
        #expect(noticeMessage(vm.addLoginState, "add-account dedupe").contains("already tracked"))
        #expect(vm.loginAffordance(for: nil).actions == [.dismiss])
        #expect(!vm.loginAffordance(for: nil).actions.contains(.tryAgain))
        #expect(vm.pendingLogin == nil)
        #expect(script.beginCalls.first?.hint == nil)   // no hint for an unknown account
    }

    @Test("Add account: a new identity appends an account and starts tracking it")
    func addAccountAppends() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-B", email: "b@example.com", name: "Bee"))]
        script.usageResult = .success(usageResponse())

        let store = InMemoryAccountCredentialStore()
        let vm = makeVM(script, accounts: [], store: store)

        await vm.beginLogin(nil)

        #expect(vm.accounts.count == 1)
        let added = try #require(vm.accounts.first)
        #expect(added.label == "Bee")
        #expect(added.accountUUID == "acct-B")
        #expect(try store.loadAll()[added.id]?.accessToken == "fresh-token")
        #expect(vm.addLoginState == .idle)
        #expect(vm.snapshots[added.id] != nil)   // the new runtime was attached and refreshed
    }

    @Test("An identity-less account whose login turns out to be another account merges, never duplicates")
    func migratedAccountMergesIntoItsDuplicate() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com"))]

        // `migrated` has no identity yet; `known` already holds the identity this login returns.
        let migrated = Account(label: "Account 1")
        let known = Account(label: "Work", accountUUID: "acct-A", email: "a@example.com")
        let store = InMemoryAccountCredentialStore([
            migrated.id: Self.oldCredentials, known.id: Self.oldCredentials,
        ])
        let vm = makeVM(script, accounts: [migrated, known], store: store)

        await vm.beginLogin(migrated.id)

        #expect(vm.accounts.count == 2)
        // The credentials belong to the account that already owns this identity.
        #expect(try store.loadAll()[known.id]?.accessToken == "fresh-token")
        #expect(try store.loadAll()[migrated.id]?.accessToken == "old-token")
        // …and the identity is NOT backfilled onto the migrated slot: two accounts claiming
        // one identity is exactly what the dedupe exists to prevent.
        #expect(vm.accounts.first(where: { $0.id == migrated.id })?.accountUUID == nil)
        let message = noticeMessage(vm.loginState[migrated.id], "duplicate merge")
        #expect(message.contains("already tracked"))
        #expect(vm.loginAffordance(for: migrated.id).actions == [.dismiss])
    }

    @Test("An identity-less account with no duplicate is backfilled and stored")
    func migratedAccountIsBackfilled() async throws {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-C", email: "c@example.com"))]

        let migrated = Account(label: "Account 1")
        let store = InMemoryAccountCredentialStore([migrated.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [migrated], store: store)

        await vm.beginLogin(migrated.id)

        #expect(vm.accounts.first?.accountUUID == "acct-C")
        #expect(vm.accounts.first?.email == "c@example.com")
        #expect(try store.loadAll()[migrated.id]?.accessToken == "fresh-token")
        #expect(vm.loginState[migrated.id] == .idle)
    }

    // MARK: - Paste mode

    @Test("A pasted code whose state doesn't match this login is rejected")
    func pasteWithMismatchedStateRejected() async throws {
        let script = Script()
        script.beginPaste = true
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com"))]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let store = InMemoryAccountCredentialStore([account.id: Self.oldCredentials])
        let vm = makeVM(script, accounts: [account], store: store)

        await vm.beginLogin(account.id)
        #expect(vm.loginState[account.id] == .awaitingPaste)

        await vm.submitPaste("auth-code#not-this-logins-state")

        let message = failureMessage(vm.loginState[account.id], "state mismatch")
        #expect(message.contains("doesn't match"))
        #expect(script.exchangeCount == 0)   // a foreign code is never exchanged
        #expect(vm.pendingLogin != nil)      // the login survives, so a correct paste still works
        // …so the field stays on screen with the rejection, rather than the state reading as a
        // terminal failure whose "try again" the pending login would silently refuse.
        #expect(vm.loginAffordance(for: account.id) == .awaitingPaste(message: message))
        // And that message can't be dismissed out from under a login that is still live.
        vm.dismissLoginMessage(for: account.id)
        #expect(vm.loginAffordance(for: account.id) == .awaitingPaste(message: message))

        await vm.submitPaste("auth-code#\(script.pkce.state)")

        #expect(script.exchangeCount == 1)
        #expect(vm.loginState[account.id] == .idle)
        #expect(try store.loadAll()[account.id]?.accessToken == "fresh-token")
    }

    @Test("A finished login's message can be dismissed, so it doesn't sit in the popover forever")
    func terminalMessageIsDismissible() async {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.failure(OAuthLoginError.exchangeRejected)]

        let account = Account(label: "Work", accountUUID: "acct-A")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(account.id)
        #expect(vm.loginAffordance(for: account.id).actions == [.tryAgain, .dismiss])

        vm.dismissLoginMessage(for: account.id)

        // Nothing else clears the message: this flow's state isn't written again until it
        // logs in. Dismissing drops back to the plain offer of a login — the account's token
        // is still dead, so the way back in has to stay on screen.
        #expect(vm.loginState[account.id] == .idle)
        #expect(vm.needsReAuth[account.id] == true)
        #expect(vm.loginAffordance(for: account.id) == .start)
    }

    @Test("The add flow's notice is dismissible, so it can't squat where the Add button goes")
    func addFlowNoticeIsDismissible() async {
        let script = Script()
        script.callbackCode = "auth-code"
        script.exchangeResults = [.success(Self.freshCredentials)]
        script.identityResults = [.success(identity("acct-A", email: "a@example.com"))]

        let account = Account(label: "Work", accountUUID: "acct-A", email: "a@example.com")
        let vm = makeVM(script, accounts: [account], store: InMemoryAccountCredentialStore())

        await vm.beginLogin(nil)   // an already-tracked identity produces the dedupe notice

        #expect(vm.loginAffordance(for: nil).message?.contains("already tracked") == true)

        vm.dismissLoginMessage(for: nil)

        #expect(vm.addLoginState == .idle)
        #expect(vm.loginAffordance(for: nil) == LoginAffordance.none)
    }
}

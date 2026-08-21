import SwiftUI
import ServiceManagement
import UserNotifications

/// The app's single source of truth. Owns the account list and one `AccountRuntime` per
/// account, plus app-global concerns (display mode, launch-at-login, notification auth).
/// Runtimes are plain objects; each is given an `onChange` that republishes this object's
/// `@Published` state, so a runtime's async refresh re-renders the menu bar without the
/// nested-`ObservableObject` freeze.
@MainActor
final class AccountsViewModel: ObservableObject {

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var snapshots: [UUID: UsageSnapshot] = [:]
    @Published private(set) var runtimeStates: [UUID: AccountRuntime.LoadingState] = [:]
    @Published private(set) var needsReAuth: [UUID: Bool] = [:]
    @Published var addAccountError: String?
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginError: String?
    @Published var notificationsAuthorized: Bool?
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode") }
    }

    /// Where a browser login currently stands for one account. Keyed by account id for a
    /// re-auth login; the accountID==nil "add account" flow instead uses `addLoginState`.
    enum LoginState: Equatable {
        case idle
        case waitingForBrowser(since: Date)
        case awaitingPaste
        case failed(String)
    }

    @Published private(set) var loginState: [UUID: LoginState] = [:]
    /// The login this view model is currently driving, if any. The browser-login flow
    /// (added on top of this seam) is intended to keep at most one login in flight at a
    /// time, whether it's re-auth for an existing account or the accountID==nil
    /// add-account path.
    @Published private(set) var pendingLogin: PendingLogin?
    /// The URL handed to the browser for `pendingLogin`, kept so the popover can offer it as
    /// "Copy link" — the recovery when the browser that opened is signed into the wrong
    /// profile. Never log it: it carries the PKCE challenge and, on re-auth, a real email.
    @Published private(set) var pendingAuthorizeURL: URL?
    /// Login state for the accountID==nil "add account" flow, mirroring `loginState`'s
    /// per-account entries.
    @Published var addLoginState: LoginState = .idle

    /// The single injection point for every system-touching operation this coordinator
    /// performs, or hands down to the `AccountRuntime`s it owns: the browser OAuth flow,
    /// identity lookups, usage fetch and token refresh, notification authorization and
    /// posting, the legacy migration's keychain/filesystem calls, and the clock.
    struct Dependencies: Sendable {
        var beginLogin: @Sendable (_ accountID: UUID?, _ forcePaste: Bool, _ loginHintEmail: String?) async throws
            -> (pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?)
        var exchange: @Sendable (_ code: String, _ pending: PendingLogin) async throws -> CachedCredentials
        var fetchIdentity: @Sendable (_ token: String) async throws -> AccountIdentity
        var openURL: @Sendable (URL) -> Void
        var now: @Sendable () -> Date
        /// Reads the legacy single-account credentials for the one-time `AccountMigration`
        /// run at init. A test double must not perform real keychain I/O — return `nil`,
        /// or canned credentials to exercise the migration branch.
        var resolveLegacyCredentials: @Sendable () -> CachedCredentials?
        /// Deletes the legacy plaintext cache file and the legacy single-account keychain
        /// item, once migration has verified the new copy landed. A test double must not
        /// touch the real keychain or filesystem; recording the call is the point.
        var deleteLegacyArtifacts: @Sendable () -> Void
        /// Requests notification authorization and reports whether it's granted. A test
        /// double must not touch the real `UNUserNotificationCenter`; return `nil`,
        /// `true`, or `false` to drive whatever `notificationsAuthorized` state the test
        /// needs.
        var requestNotificationAuthorization: @Sendable () async -> Bool?
        /// Posts one already-built notification request. A test double must not touch
        /// the real `UNUserNotificationCenter` — recording the call (or doing nothing) is
        /// the point.
        var addNotification: @Sendable (UNNotificationRequest) -> Void
        /// Fetches usage for one account's access token. Threaded into every attached
        /// `AccountRuntime.Dependencies` so a test controls it instead of hitting the
        /// real API.
        var fetchUsage: @Sendable (_ token: String) async throws -> UsageResponse
        /// Refreshes one account's OAuth token. Threaded into every attached
        /// `AccountRuntime.Dependencies` so a test controls it instead of hitting the
        /// real API.
        var refreshToken: @Sendable (_ credentials: CachedCredentials) async throws -> CachedCredentials

        /// Wires the real `OAuthLoginService`, `ProfileService`, `NSWorkspace` browser
        /// opener, `UsageAPIService`/`KeychainService` usage-refresh calls, notification
        /// authorization and posting, and the legacy-migration keychain/filesystem calls
        /// this view model used to hardcode. Builds closures only — none of them run
        /// until the view model calls one, so constructing `.live` performs no I/O.
        static var live: Dependencies {
            Dependencies(
                beginLogin: { accountID, forcePaste, loginHintEmail in
                    try await OAuthLoginService().begin(
                        accountID: accountID, forcePaste: forcePaste, loginHintEmail: loginHintEmail)
                },
                exchange: { code, pending in
                    try await OAuthLoginService().exchange(code: code, pending: pending)
                },
                fetchIdentity: { token in
                    try await ProfileService.fetchIdentity(token: token)
                },
                openURL: { url in
                    NSWorkspace.shared.open(url)
                },
                now: Date.init,
                resolveLegacyCredentials: { KeychainService.getCredentials() },
                deleteLegacyArtifacts: {
                    KeychainCredentialStore().delete()
                    try? FileManager.default.removeItem(at: KeychainService.defaultLegacyCacheURL)
                },
                requestNotificationAuthorization: {
                    let center = UNUserNotificationCenter.current()
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                    let settings = await center.notificationSettings()
                    return settings.authorizationStatus == .authorized
                },
                addNotification: { UNUserNotificationCenter.current().add($0) },
                fetchUsage: { try await UsageAPIService.fetch(token: $0) },
                refreshToken: { creds in
                    guard let refreshToken = creds.refreshToken else {
                        throw KeychainServiceError.noRefreshToken
                    }
                    return try await KeychainService.performOAuthRefresh(refreshToken: refreshToken)
                }
            )
        }
    }

    private var runtimes: [UUID: AccountRuntime] = [:]
    private var identityBackfillInFlight: Set<UUID> = []
    private let accountsStore: AccountsStore
    private let credentialStore: AccountCredentialStoring
    private let credentials: AccountCredentialManager
    private let defaults: UserDefaults
    private let deps: Dependencies
    private var timer: Timer?

    // MARK: - Init

    init(
        accountsStore: AccountsStore = AccountsStore(),
        credentialStore: AccountCredentialStoring = KeychainAccountCredentialStore(),
        defaults: UserDefaults = .standard,
        startTimer: Bool = true,
        deps: Dependencies = .live
    ) {
        self.accountsStore = accountsStore
        self.credentialStore = credentialStore
        self.credentials = AccountCredentialManager(store: credentialStore)
        self.defaults = defaults
        self.deps = deps

        let raw = defaults.string(forKey: "menuBarDisplayMode") ?? "auto"
        self.menuBarDisplayMode = MenuBarDisplayMode(rawValue: raw) ?? .auto

        // One-time migration from the single-account layout.
        let migration = AccountMigration(
            accountsStore: accountsStore,
            credentialStore: credentialStore,
            defaults: defaults,
            resolveLegacyCredentials: deps.resolveLegacyCredentials,
            deleteLegacyArtifacts: deps.deleteLegacyArtifacts
        )
        self.accounts = migration.run()

        for account in accounts { attachRuntime(for: account) }

        Task { [weak self] in await self?.requestNotificationAuthorization() }
        Task { [weak self] in await self?.refreshAll() }
        if startTimer { scheduleTimer() }
    }

    // MARK: - Menu bar

    var menuBarText: String {
        MenuBarPresentation.compute(accounts: accounts, snapshots: snapshots, mode: menuBarDisplayMode).text
    }

    var menuBarWorstPercent: Int? {
        MenuBarPresentation.compute(accounts: accounts, snapshots: snapshots, mode: menuBarDisplayMode).worstPercent
    }

    var isSingleAccount: Bool { accounts.count == 1 }

    /// A per-account view of everything the popover renders.
    struct AccountView: Identifiable {
        let account: Account
        var id: UUID { account.id }
        let snapshot: UsageSnapshot?
        let state: AccountRuntime.LoadingState
        let history: [UsageDataPoint]
    }

    var accountViews: [AccountView] {
        accounts.map { account in
            AccountView(
                account: account,
                snapshot: snapshots[account.id],
                state: runtimeStates[account.id] ?? .idle,
                history: runtimes[account.id]?.history ?? []
            )
        }
    }

    // MARK: - Refresh

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for runtime in runtimes.values {
                group.addTask { await runtime.refresh() }
            }
        }
    }

    func refresh(_ id: UUID) async {
        await runtimes[id]?.refresh()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    // MARK: - Runtime wiring

    private func attachRuntime(for account: Account) {
        let id = account.id
        let runtimeDeps = AccountRuntime.Dependencies(
            fetchUsage: deps.fetchUsage,
            refreshToken: deps.refreshToken,
            now: deps.now,
            onThresholdCrossing: { [weak self] crossing in
                self?.sendNotification(account: account, crossing: crossing)
            }
        )
        let runtime = AccountRuntime(
            id: id,
            credentials: credentials,
            persistence: AccountPersistence(defaults: defaults, accountID: id),
            deps: runtimeDeps,
            onChange: { [weak self] in self?.syncFromRuntime(id) }
        )
        runtimes[id] = runtime
        syncFromRuntime(id)
    }

    /// Pulls a runtime's latest state into this object's `@Published` maps, triggering a
    /// SwiftUI update. This is the explicit republish path.
    private func syncFromRuntime(_ id: UUID) {
        guard let runtime = runtimes[id] else { return }
        snapshots[id] = runtime.snapshot
        runtimeStates[id] = runtime.state
        needsReAuth[id] = runtime.needsReAuth

        // A migrated account starts with no identity (migration is offline). Backfill it
        // from the profile endpoint on its first successful refresh — the token is known
        // good then — so it can be deduped against accounts added later.
        if runtime.snapshot != nil,
           let account = accounts.first(where: { $0.id == id }),
           account.accountUUID == nil,
           !identityBackfillInFlight.contains(id) {
            identityBackfillInFlight.insert(id)
            Task { [weak self] in await self?.backfillIdentity(id) }
        }
    }

    private func backfillIdentity(_ id: UUID) async {
        defer { identityBackfillInFlight.remove(id) }
        guard let token = try? credentials.credentials(for: id)?.accessToken,
              let identity = try? await deps.fetchIdentity(token) else { return }

        let result = AccountIdentityResolver.backfill(accounts, id: id,
                                                      uuid: identity.uuid, email: identity.email)
        accounts = result.accounts
        accountsStore.save(accounts)
        if let dupLabel = result.duplicateOfLabel,
           let account = accounts.first(where: { $0.id == id }) {
            addAccountError = "“\(account.label)” looks like the same account as “\(dupLabel)”. You can remove one."
        }
    }

    // MARK: - Browser login

    /// The loopback listener belonging to `pendingLogin`, when it has one.
    private var loginServer: LoopbackServer?
    /// Credentials from a login whose code has been exchanged but whose identity check
    /// hasn't finished. Held in memory — never persisted — so `retryIdentity()` can re-run
    /// just that step: the authorization code behind them is single-use and already spent.
    private var unverifiedGrant: CachedCredentials?
    /// Bumped whenever a login starts or ends. Each step captures it before an await and
    /// rechecks after, so a login that was cancelled or restarted mid-flight can't write
    /// state on top of the one that replaced it.
    private var loginEpoch = 0
    /// True between `deps.beginLogin` being called and `pendingLogin` being assigned — the
    /// window in which `pendingLogin` alone would let a second login start.
    private var isStartingLogin = false

    /// Starts a browser OAuth login: `accountID` re-authenticates that account, `nil` adds a
    /// new one. Returns once the login has reached a terminal state — or, in paste mode, once
    /// the browser is open and `submitPaste(_:)` owns the rest.
    ///
    /// `forcePaste` starts in paste mode directly; a loopback timeout restarts this way on
    /// its own.
    func beginLogin(_ accountID: UUID?, forcePaste: Bool = false) async {
        guard pendingLogin == nil, !isStartingLogin else {
            // One browser session yields one account, so parallel logins would capture
            // duplicates and produce errors that can't be attributed to either flow. A repeat
            // request from the flow that is already running gets no message: its own state
            // (waiting, or awaiting a paste) already says what is happening, and replacing
            // that with a failure would strand a login that is still live.
            if pendingLogin?.accountID != accountID {
                setLoginState(.failed(Self.busyMessage), for: accountID)
            }
            return
        }
        await runLogin(accountID, forcePaste: forcePaste)
    }

    /// Abandons the browser wait and restarts the same login in paste mode — the "use a code
    /// instead" recovery for a redirect that never comes back (a browser that blocks loopback
    /// requests, or a tab the user closed). The redirect URI is fixed for the life of a login,
    /// so switching modes has to be a brand-new login, not a change to this one.
    func switchToPaste() async {
        guard let pending = pendingLogin, pending.mode != .paste else { return }
        let owner = pending.accountID
        await cancelLogin()
        await beginLogin(owner, forcePaste: true)
    }

    /// Finishes a paste-mode login from the `code#state` string Anthropic's callback page
    /// renders.
    func submitPaste(_ raw: String) async {
        guard let pending = pendingLogin, pending.mode == .paste else { return }
        guard let parsed = OAuthPaste.parse(raw) else {
            setLoginState(.failed("That doesn't look like a login code — copy the whole line."),
                          for: pending.accountID)
            return
        }
        // The state binds the code to this login (anti-CSRF). The pending login is kept on
        // rejection so a corrected paste can still finish it.
        guard parsed.state == pending.pkce.state else {
            setLoginState(.failed("That code doesn't match this login."), for: pending.accountID)
            return
        }
        await finishLogin(code: parsed.code)
    }

    /// Abandons the pending login. `async` so its listener is stopped before this returns,
    /// rather than at some later scheduling point.
    func cancelLogin() async {
        guard let pending = pendingLogin else { return }
        await endLogin(.idle, for: pending.accountID)
    }

    /// Re-runs the identity check for a login whose grant is already in hand — the recovery
    /// behind "couldn't verify the account". Re-running the exchange is not an option: that
    /// code is spent.
    func retryIdentity() async {
        guard let pending = pendingLogin, let grant = unverifiedGrant else { return }
        await verifyAndStore(grant, pending: pending)
    }

    /// Whether `retryIdentity()` would do anything for this flow: its identity step failed
    /// with the grant still in hand. The popover needs this to tell that state apart from a
    /// terminal failure — they share the `.failed` case but not their way out.
    func canRetryIdentity(for accountID: UUID?) -> Bool {
        guard let pending = pendingLogin, unverifiedGrant != nil else { return false }
        return pending.accountID == accountID
    }

    /// What the login control should offer for one flow (`nil` = the add-account flow).
    func loginAffordance(for accountID: UUID?) -> LoginAffordance {
        LoginAffordance.resolve(
            state: currentLoginState(for: accountID),
            needsReAuth: accountID.map { needsReAuth[$0] == true } ?? false,
            canRetryIdentity: canRetryIdentity(for: accountID),
            hasLivePasteLogin: pendingLogin.map { $0.accountID == accountID && $0.mode == .paste } ?? false)
    }

    /// Clears a finished login's message once it has been read. Nothing else does: a flow's
    /// state isn't touched again until it starts another login, so a terminal failure would
    /// otherwise sit in the popover for the life of the app — and for the add-account flow it
    /// sits where the "Add account…" button belongs.
    func dismissLoginMessage(for accountID: UUID?) {
        // A live login owns its flow's state, including a message about a paste it is still
        // willing to accept.
        if let pending = pendingLogin, pending.accountID == accountID { return }
        guard case .failed = currentLoginState(for: accountID) else { return }
        setLoginState(.idle, for: accountID)
    }

    private func currentLoginState(for accountID: UUID?) -> LoginState {
        accountID.map { loginState[$0] ?? .idle } ?? addLoginState
    }

    private func runLogin(_ accountID: UUID?, forcePaste: Bool) async {
        isStartingLogin = true
        let started: (pending: PendingLogin, authorizeURL: URL,
                      server: LoopbackServer?, callback: Task<String?, Never>?)
        do {
            started = try await deps.beginLogin(accountID, forcePaste, loginHintEmail(for: accountID))
            isStartingLogin = false
        } catch {
            isStartingLogin = false
            if isCancellation(error) {
                setLoginState(.idle, for: accountID)
            } else {
                let message = "Couldn't start the login — try again."
                setLoginState(.failed(message), for: accountID)
                notifyLoginProblem(accountID: accountID, message: message)
            }
            // No login started, so nothing holds the pending slot any more.
            clearBusyNotices(except: accountID)
            return
        }

        loginEpoch += 1
        let epoch = loginEpoch
        pendingLogin = started.pending
        pendingAuthorizeURL = started.authorizeURL
        loginServer = started.server
        setLoginState(started.pending.mode == .paste ? .awaitingPaste : .waitingForBrowser(since: deps.now()),
                      for: accountID)
        // Never log this URL: it carries the PKCE challenge and, on re-auth, a real email.
        deps.openURL(started.authorizeURL)

        // Paste mode has no listener to wait on — `submitPaste` finishes the login.
        guard let callback = started.callback else { return }

        let code = await callback.value
        // Cancelled or restarted while waiting: whatever replaced this login owns the state.
        guard epoch == loginEpoch else { return }
        guard let code else {
            // The wait timed out. `waitForCallback` bounds how long a callback may be
            // *accepted*, not the total call duration, so a code accepted at the boundary
            // still arrives non-nil above and is handled as the success it is; only nil gets
            // here, and the fixed redirect URI means the retry has to be a brand-new login.
            await endLogin(.idle, for: accountID)
            // At most one restart: paste mode has no listener, so it cannot time out in turn.
            // Guarding on the flag rather than on `begin` returning no callback keeps that
            // true even if the seam ever hands a forced-paste login a listener anyway. The
            // pending-login checks are re-run because `endLogin` above suspends, and a login
            // started in that window has already claimed the one pending slot — restarting on
            // top of it would strand its listener.
            if !forcePaste, pendingLogin == nil, !isStartingLogin {
                await runLogin(accountID, forcePaste: true)
            }
            return
        }
        await finishLogin(code: code)
    }

    /// Second half of a login: turn the authorization code into credentials, then verify and
    /// store them. Each failure is reported distinctly — collapsing them is what let a
    /// network blip tell the user to go switch accounts.
    private func finishLogin(code: String) async {
        guard let pending = pendingLogin else { return }
        // Captured before the release below, which suspends: a `cancelLogin()` landing in
        // that window bumps the epoch, and reading it afterwards would capture the
        // post-cancel value and let every later guard pass.
        let epoch = loginEpoch
        // The code is in hand, so the listener has no further role: on the loopback path
        // `begin`'s callback task has already stopped it, and this drops the reference.
        await releaseLoginServer()
        guard epoch == loginEpoch else { return }

        let grant: CachedCredentials
        do {
            grant = try await exchangeRetryingTransient(code: code, pending: pending)
        } catch {
            guard epoch == loginEpoch else { return }
            guard !isCancellation(error) else {
                // The user cancelled on purpose: there is nothing to report.
                await endLogin(.idle, for: pending.accountID)
                return
            }
            let message: String
            switch error {
            case OAuthLoginError.exchangeRejected:
                message = "Login expired or was already used — try again."
            case OAuthLoginError.malformedResponse:
                // A 200 that doesn't decode is realistically a captive portal or a challenge
                // page rather than the token endpoint.
                message = "Got an unreadable response from the login server — try again."
            default:
                // `.transient` with its retry already spent, plus anything the seam raises
                // from outside the taxonomy.
                message = "Couldn't reach the login server — try again."
            }
            await endLogin(.failed(message), for: pending.accountID)
            return
        }
        guard epoch == loginEpoch else { return }

        unverifiedGrant = grant
        await verifyAndStore(grant, pending: pending)
    }

    /// One retry on `.transient`, which covers transport failures (offline, timeout, DNS)
    /// and any unexpected status, since the exchange classifier fails open to it.
    private func exchangeRetryingTransient(code: String, pending: PendingLogin) async throws -> CachedCredentials {
        do {
            return try await deps.exchange(code, pending)
        } catch OAuthLoginError.transient {
            return try await deps.exchange(code, pending)
        }
    }

    /// Identity is required: it is what stops one account's slot being overwritten with
    /// another's login. Its two failure modes stay distinct — a fetch that failed says
    /// nothing about which account the browser is signed into.
    private func verifyAndStore(_ grant: CachedCredentials, pending: PendingLogin) async {
        let epoch = loginEpoch
        let identity: AccountIdentity
        do {
            identity = try await deps.fetchIdentity(grant.accessToken)
        } catch {
            guard epoch == loginEpoch else { return }
            guard !isCancellation(error) else {
                await endLogin(.idle, for: pending.accountID)
                return
            }
            // The grant and the pending login stay in memory so `retryIdentity()` can re-run
            // only this step.
            let message = "Logged in, but couldn't verify the account — Retry."
            setLoginState(.failed(message), for: pending.accountID)
            // Not terminal, but it is where the login stops without the user being told: this
            // state holds the pending login, so every later click is refused until they come
            // back and press Retry or Cancel.
            notifyLoginProblem(accountID: pending.accountID, message: message)
            return
        }
        guard epoch == loginEpoch else { return }

        if let accountID = pending.accountID {
            await completeReAuth(grant, accountID: accountID, identity: identity)
        } else {
            await completeAddAccount(grant, identity: identity)
        }
    }

    private func completeReAuth(_ grant: CachedCredentials, accountID: UUID, identity: AccountIdentity) async {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            // No such account any more — removed while the browser was open — so there is no
            // slot for this grant.
            await endLogin(.idle, for: accountID)
            return
        }

        if let expected = account.accountUUID {
            guard identity.uuid == expected else {
                let actual = identity.email ?? "a different account"
                await endLogin(.failed("That browser is signed into \(actual) — expected “\(account.label)”."),
                               for: accountID)
                return
            }
            await storeAndFinish(grant, for: accountID, owner: accountID, notice: nil)
            return
        }

        // A migrated account has no identity until a login supplies one. If that identity
        // already belongs to another account, the credentials belong in that slot: applying
        // the backfill here would leave two accounts claiming one identity.
        let resolved = AccountIdentityResolver.backfill(accounts, id: accountID,
                                                        uuid: identity.uuid, email: identity.email)
        if resolved.duplicateOfLabel != nil,
           let duplicate = accounts.first(where: { $0.id != accountID && $0.accountUUID == identity.uuid }) {
            await storeAndFinish(
                grant, for: duplicate.id, owner: accountID,
                notice: "That login is already tracked as “\(duplicate.label)” — its login was refreshed instead.")
            return
        }
        accounts = resolved.accounts
        accountsStore.save(accounts)
        await storeAndFinish(grant, for: accountID, owner: accountID, notice: nil)
    }

    private func completeAddAccount(_ grant: CachedCredentials, identity: AccountIdentity) async {
        // Dedupe on the stable account uuid: logging into an account that is already tracked
        // refreshes it instead of creating a second copy.
        if let existing = accounts.first(where: { $0.accountUUID == identity.uuid }) {
            await storeAndFinish(grant, for: existing.id, owner: nil,
                                 notice: "“\(existing.label)” is already tracked — its login was refreshed.")
            return
        }

        let label = identity.displayName ?? identity.email ?? "Account \(accounts.count + 1)"
        let account = Account(label: label, accountUUID: identity.uuid, email: identity.email)
        guard await storeGrant(grant, for: account.id, owner: nil) else { return }
        accounts.append(account)
        accountsStore.save(accounts)
        attachRuntime(for: account)
        await endLogin(.idle, for: nil)
        notifyLoginSucceeded(accountID: account.id)
        await runtimes[account.id]?.credentialsReplaced()
    }

    /// The shared tail of a login that landed on an existing account.
    /// - Parameters:
    ///   - owner: the flow this login was started from (`nil` = the add-account flow), which
    ///     differs from `accountID` when a login turns out to belong to another account.
    ///   - notice: what to tell the user when the login didn't do what they asked — it rides
    ///     on `.failed` because that is the only state carrying a message.
    private func storeAndFinish(_ grant: CachedCredentials, for accountID: UUID,
                                owner: UUID?, notice: String?) async {
        guard await storeGrant(grant, for: accountID, owner: owner) else { return }
        needsReAuth[accountID] = false
        // `notifyFailure: false`: a notice rides on `.failed` but the login itself succeeded,
        // and `notifyLoginSucceeded` below already reports it.
        await endLogin(notice.map(LoginState.failed) ?? .idle, for: owner, notifyFailure: false)
        notifyLoginSucceeded(accountID: accountID)
        await runtimes[accountID]?.credentialsReplaced()
    }

    /// Stores a verified grant, or surfaces the one terminal failure a repeat login cannot
    /// fix. Never `try?`: a save that silently didn't land leaves the account looking logged
    /// out forever with nothing to explain it.
    /// - Returns: whether the credentials actually landed.
    private func storeGrant(_ grant: CachedCredentials, for accountID: UUID, owner: UUID?) async -> Bool {
        do {
            try credentials.update(id: accountID, credentials: grant)
            return true
        } catch {
            // "Couldn't store" first: this fires for a failed *write* as well as an unreadable
            // item, so leading with the read diagnosis names the wrong problem.
            await endLogin(.failed("Couldn't store the login — the keychain refused it."), for: owner)
            return false
        }
    }

    /// Ends the pending login and parks the owning flow in `state`. The epoch bump is what
    /// turns a step of the finished login that is still awaiting into a no-op, so it happens
    /// before the listener is stopped — `stop()` resumes a waiting callback with `nil`, and
    /// that resumption must not be read as a timeout.
    ///
    /// `notifyFailure` is false only where a `.failed` state carries a notice about a login
    /// that actually landed.
    private func endLogin(_ state: LoginState, for owner: UUID?, notifyFailure: Bool = true) async {
        pendingLogin = nil
        pendingAuthorizeURL = nil
        unverifiedGrant = nil
        loginEpoch += 1
        setLoginState(state, for: owner)
        clearBusyNotices(except: owner)
        if notifyFailure, case .failed(let message) = state {
            notifyLoginProblem(accountID: owner, message: message)
        }
        await releaseLoginServer()
    }

    /// What a login request is told when another login already owns the one pending slot.
    private static let busyMessage = "Finish the login in progress first."

    /// Clears that refusal from every flow except `owner`, whose state the caller has just
    /// set. The message is written onto whichever account was clicked *second*, so nothing
    /// that flow does clears it — without this sweep it sits there looking like that
    /// account's own failure until it starts a login of its own.
    private func clearBusyNotices(except owner: UUID?) {
        for (id, state) in loginState where id != owner && state == .failed(Self.busyMessage) {
            loginState[id] = .idle
        }
        if owner != nil, addLoginState == .failed(Self.busyMessage) { addLoginState = .idle }
    }

    /// Stops this login's loopback listener, if it had one. `begin`'s callback task stops the
    /// server on success only; every other terminal outcome — timeout restart, cancel, or a
    /// failure that abandons the login — has to stop it here, or the listener stays bound.
    /// `stop()` is idempotent, so calling it after a success costs nothing and keeps this the
    /// single release point.
    private func releaseLoginServer() async {
        guard let server = loginServer else { return }
        loginServer = nil
        await server.stop()
    }

    private func setLoginState(_ state: LoginState, for accountID: UUID?) {
        if let accountID { loginState[accountID] = state } else { addLoginState = state }
    }

    /// The email claude.ai should preselect, when this login re-auths an account whose
    /// address we know. A blank stored email is normalized to `nil` so the authorize URL
    /// never carries an empty `login_hint`.
    private func loginHintEmail(for accountID: UUID?) -> String? {
        guard let accountID,
              let email = accounts.first(where: { $0.id == accountID })?.email else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether an error out of the login seam means "the user cancelled", not "the login
    /// failed". `OAuthLoginService.exchange` rethrows the raw error when its task is
    /// cancelled, so cancellation arrives as `CancellationError` or `URLError.cancelled`
    /// rather than as one of `OAuthLoginError`'s cases.
    private func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        // `ProfileService` wraps every transport error, cancellation included, so the
        // `URLError` has to be unwrapped for the identity step to reach this branch at all.
        if case .requestFailed(let underlying) = error as? UsageAPIError {
            return (underlying as? URLError)?.code == .cancelled
        }
        return (error as? URLError)?.code == .cancelled
    }

    /// The popover closes as soon as the browser takes focus, so a notification is the only
    /// way the user learns a login landed.
    private func notifyLoginSucceeded(accountID: UUID) {
        let label = accounts.first(where: { $0.id == accountID })?.label ?? "Account"
        let content = UNMutableNotificationContent()
        content.title = "\(label): logged in"
        content.body = "Usage tracking is active for this account."
        deps.addNotification(UNNotificationRequest(
            identifier: "login-\(accountID.uuidString)", content: content, trigger: nil))
    }

    /// The same reason for a login that didn't land. Without this the user is left staring at
    /// a browser tab that looks finished, with the app's rejection visible only if they happen
    /// to reopen the popover. Deliberately silent on cancellation: they stopped it themselves.
    private func notifyLoginProblem(accountID: UUID?, message: String) {
        let label = accountID.flatMap { id in accounts.first(where: { $0.id == id })?.label }
            ?? "Claude Usage"
        let content = UNMutableNotificationContent()
        content.title = "\(label): login didn't finish"
        content.body = message
        deps.addNotification(UNNotificationRequest(
            identifier: "login-failed-\(accountID?.uuidString ?? "add")", content: content, trigger: nil))
    }

    // MARK: - Account operations

    func remove(_ id: UUID) {
        // Stop first so an in-flight refresh can't re-create the slot after deletion.
        runtimes[id]?.stop()
        runtimes[id] = nil
        snapshots[id] = nil
        runtimeStates[id] = nil
        try? credentials.remove(id: id)
        accounts.removeAll { $0.id == id }
        accountsStore.save(accounts)
    }

    func relabel(_ id: UUID, to label: String) {
        updateAccount(id) { $0.label = label }
    }

    func setShortCode(_ id: UUID, to shortCode: String?) {
        let trimmed = shortCode?.trimmingCharacters(in: .whitespaces)
        updateAccount(id) { $0.shortCode = (trimmed?.isEmpty == true) ? nil : trimmed }
    }

    private func updateAccount(_ id: UUID, _ mutate: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        mutate(&accounts[index])
        accountsStore.save(accounts)
    }

    // MARK: - Launch at login

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't change launch-at-login: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() async {
        notificationsAuthorized = await deps.requestNotificationAuthorization()
    }

    private nonisolated func sendNotification(account: Account, crossing: ThresholdTracker.Crossing) {
        let (windowName, windowKey) = crossing.window == .fiveHour
            ? ("5-hour", "fiveHour")
            : ("7-day", "sevenDay")

        let content = UNMutableNotificationContent()
        content.title = "\(account.label): Claude Usage Warning"
        content.body = crossing.threshold >= 90
            ? "\(windowName) window at \(crossing.percent)% — approaching limit!"
            : "\(windowName) window at \(crossing.percent)%"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-\(account.id.uuidString)-\(windowKey)-\(crossing.threshold)",
            content: content,
            trigger: nil
        )
        deps.addNotification(request)
    }
}

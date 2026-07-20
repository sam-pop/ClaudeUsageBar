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
        didSet { UserDefaults.standard.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode") }
    }

    private var runtimes: [UUID: AccountRuntime] = [:]
    private let accountsStore: AccountsStore
    private let credentialStore: AccountCredentialStoring
    private let credentials: AccountCredentialManager
    private let defaults: UserDefaults
    private var timer: Timer?

    // MARK: - Init

    init(
        accountsStore: AccountsStore = AccountsStore(),
        credentialStore: AccountCredentialStoring = KeychainAccountCredentialStore(),
        defaults: UserDefaults = .standard,
        startTimer: Bool = true
    ) {
        self.accountsStore = accountsStore
        self.credentialStore = credentialStore
        self.credentials = AccountCredentialManager(store: credentialStore)
        self.defaults = defaults

        let raw = defaults.string(forKey: "menuBarDisplayMode") ?? "auto"
        self.menuBarDisplayMode = MenuBarDisplayMode(rawValue: raw) ?? .auto

        // One-time migration from the single-account layout.
        let migration = AccountMigration(
            accountsStore: accountsStore,
            credentialStore: credentialStore,
            defaults: defaults,
            resolveLegacyCredentials: { KeychainService.getCredentials() },
            deleteLegacyArtifacts: {
                KeychainCredentialStore().delete()
                try? FileManager.default.removeItem(at: KeychainService.defaultLegacyCacheURL)
            }
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
        let deps = AccountRuntime.Dependencies(
            fetchUsage: { try await UsageAPIService.fetch(token: $0) },
            refreshToken: { creds in
                guard let refreshToken = creds.refreshToken else {
                    throw KeychainServiceError.noRefreshToken
                }
                return try await KeychainService.performOAuthRefresh(refreshToken: refreshToken)
            },
            now: { Date() },
            onThresholdCrossing: { [weak self] crossing in
                self?.sendNotification(account: account, crossing: crossing)
            }
        )
        let runtime = AccountRuntime(
            id: id,
            credentials: credentials,
            persistence: AccountPersistence(defaults: defaults, accountID: id),
            deps: deps,
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
    }

    // MARK: - Account operations

    /// Captures whichever account Claude Code is currently logged into and adds it.
    func addCurrentAccount() async {
        addAccountError = nil
        guard let creds = KeychainService.captureFromClaudeCode() else {
            addAccountError = "Couldn't read Claude Code's login. Open Claude Code and sign in, then try again."
            return
        }
        guard creds.refreshToken != nil else {
            addAccountError = "That login has no refresh token, so it can't be tracked. Re-login in Claude Code and retry."
            return
        }

        // Identity is required for dedupe + labeling.
        let identity = try? await ProfileService.fetchIdentity(token: creds.accessToken)

        // Dedupe on the stable account uuid.
        if let uuid = identity?.uuid, let existing = accounts.first(where: { $0.accountUUID == uuid }) {
            // Refresh the existing account's credentials rather than duplicating it.
            try? credentials.update(id: existing.id, credentials: creds)
            addAccountError = "“\(existing.label)” is already tracked — its login was refreshed."
            await refresh(existing.id)
            return
        }

        let label = identity?.displayName ?? identity?.email ?? "Account \(accounts.count + 1)"
        let account = Account(label: label, accountUUID: identity?.uuid, email: identity?.email)
        do {
            try credentials.update(id: account.id, credentials: creds)
        } catch {
            addAccountError = "Couldn't save the account's credentials: \(error.localizedDescription)"
            return
        }
        accounts.append(account)
        accountsStore.save(accounts)
        attachRuntime(for: account)
        await refresh(account.id)
    }

    /// Re-captures an account's credentials from Claude Code — the recovery path when its
    /// refresh token has died. Identity-guarded: refuses if Claude Code is logged into a
    /// different account, so account A can never be silently overwritten with B's login.
    func rereadFromClaudeCode(_ id: UUID) async {
        addAccountError = nil
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        guard let creds = KeychainService.captureFromClaudeCode(), creds.refreshToken != nil else {
            addAccountError = "Couldn't read a usable login from Claude Code. Sign in there and retry."
            return
        }

        let identity = try? await ProfileService.fetchIdentity(token: creds.accessToken)
        if let expected = account.accountUUID {
            guard identity?.uuid == expected else {
                addAccountError = "Claude Code is logged into a different account. Switch to “\(account.label)” first."
                return
            }
        }

        try? credentials.update(id: id, credentials: creds)
        // Backfill identity for a legacy-migrated account that never had it.
        if account.accountUUID == nil, let identity {
            updateAccount(id) { $0.accountUUID = identity.uuid; $0.email = identity.email }
        }
        await refresh(id)
    }

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
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        notificationsAuthorized = await Self.isNotificationAuthorized()
    }

    private nonisolated static func isNotificationAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
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
        UNUserNotificationCenter.current().add(request)
    }
}

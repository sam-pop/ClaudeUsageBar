import Testing
import Foundation

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

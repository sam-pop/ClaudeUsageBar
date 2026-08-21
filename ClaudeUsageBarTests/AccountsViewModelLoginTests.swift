import Testing
import Foundation

/// `beginLogin` matches `OAuthLoginService.begin(accountID:forcePaste:loginHintEmail:...)`,
/// which takes 3 required parameters — the fake below matches that arity.
///
/// `.timeLimit` guards against a reintroduced blocking system call (keychain or
/// notification prompt) wedging the whole suite instead of failing a single test.
@Suite("AccountsViewModel login seam", .timeLimit(.minutes(1)))
@MainActor
struct AccountsViewModelLoginTests {

    /// A generic stub error for the runtime-facing closures (`fetchUsage`/`refreshToken`)
    /// that these tests never expect to succeed or be retried.
    private struct StubError: Error {}

    /// Counts how many times the migration seam's two real-I/O closures fire, so a test
    /// can prove `AccountsViewModel.init` actually routes through `deps` instead of a
    /// hardcoded keychain/filesystem call.
    private final class Calls: @unchecked Sendable {
        var resolve = 0
        var delete = 0
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
            fetchUsage: { _ in throw StubError() },
            refreshToken: { _ in throw StubError() })
    }

    @Test("No legacy credentials: init routes through the seam, deletes nothing, attaches no accounts")
    func nilLegacyPathRoutesThroughSeam() {
        let calls = Calls()
        let vm = AccountsViewModel(
            accountsStore: AccountsStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!),
            credentialStore: InMemoryAccountCredentialStore(),
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
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
        let legacy = CachedCredentials(accessToken: "sk-ant-oat01-legacy", refreshToken: "r", expiresAt: nil)
        let vm = AccountsViewModel(
            accountsStore: AccountsStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!),
            credentialStore: InMemoryAccountCredentialStore(),
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
            startTimer: false,
            deps: makeDeps(calls: calls, legacyCredentials: legacy))
        #expect(calls.resolve == 1)
        #expect(calls.delete == 1)      // legacy artifacts cleaned up through the seam
        #expect(vm.accounts.count == 1) // migration produced exactly the one legacy account
    }
}

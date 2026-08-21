import Testing
import Foundation

/// `beginLogin` matches `OAuthLoginService.begin(accountID:forcePaste:loginHintEmail:...)`,
/// which takes 3 parameters — the fake below matches that arity.
@MainActor
@Suite("AccountsViewModel login seam")
struct AccountsViewModelLoginTests {
    @Test("Injected Dependencies are usable; no real network on init")
    func seamInjectable() {
        let deps = AccountsViewModel.Dependencies(
            beginLogin: { _, _, _ in throw OAuthLoginError.transient },
            exchange: { _, _ in throw OAuthLoginError.transient },
            fetchIdentity: { _ in AccountIdentity(uuid: "u", email: "e", displayName: "d") },
            openURL: { _ in },
            now: { Date(timeIntervalSince1970: 0) },
            resolveLegacyCredentials: { nil },
            deleteLegacyArtifacts: { })
        let vm = AccountsViewModel(
            accountsStore: AccountsStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!),
            credentialStore: InMemoryAccountCredentialStore(),
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
            startTimer: false, deps: deps)
        #expect(vm.pendingLogin == nil)
    }
}

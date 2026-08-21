import Testing
import Foundation

/// The login-state → control mapping the popover renders. Pinned here because SwiftUI views
/// aren't unit-testable in this project, and the popover this drives is closed at exactly the
/// moment these states are entered.
@Suite("Login affordance")
struct LoginAffordanceTests {

    private func resolve(
        _ state: AccountsViewModel.LoginState,
        needsReAuth: Bool = false,
        canRetryIdentity: Bool = false,
        hasLivePasteLogin: Bool = false
    ) -> LoginAffordance {
        LoginAffordance.resolve(
            state: state, needsReAuth: needsReAuth,
            canRetryIdentity: canRetryIdentity, hasLivePasteLogin: hasLivePasteLogin)
    }

    @Test("A healthy idle account offers nothing at all")
    func healthyAccountShowsNothing() {
        #expect(resolve(.idle) == LoginAffordance.none)
        #expect(resolve(.idle).actions.isEmpty)
    }

    @Test("A dead token offers a login")
    func deadTokenOffersLogin() {
        let affordance = resolve(.idle, needsReAuth: true)
        #expect(affordance == .start)
        #expect(affordance.actions == [.logIn])
    }

    @Test("An in-flight login outranks needsReAuth: what the login is doing is what's shown")
    func inFlightLoginOutranksNeedsReAuth() {
        #expect(resolve(.waitingForBrowser(since: Date()), needsReAuth: true) == .waitingForBrowser)
        #expect(resolve(.awaitingPaste, needsReAuth: true) == .awaitingPaste(message: nil))
    }

    @Test("Waiting for the browser offers cancel, the copyable link, and the paste fallback")
    func waitingOffersTheEscapeHatches() {
        let affordance = resolve(.waitingForBrowser(since: Date()))
        // Copy link is the recovery when the browser that opened is signed into the wrong
        // profile; the paste code is the recovery when the loopback redirect never lands.
        #expect(affordance.actions == [.cancel, .copyLink, .usePasteCode])
        #expect(affordance.message == nil)
    }

    @Test("Awaiting a paste offers the field and a way out of it")
    func pasteOffersFieldAndCancel() {
        #expect(resolve(.awaitingPaste).actions == [.submitPaste, .cancel])
    }

    @Test("A rejected paste keeps the field, because that login is still willing to accept one")
    func rejectedPasteKeepsTheField() {
        let affordance = resolve(.failed("That doesn't look like a login code — copy the whole line."),
                                 needsReAuth: true, hasLivePasteLogin: true)
        // Rendering this as a terminal failure would drop the field and offer a fresh login
        // that the one-login-at-a-time rule refuses without a word — a dead end.
        #expect(affordance.actions == [.submitPaste, .cancel])
        #expect(affordance.message == "That doesn't look like a login code — copy the whole line.")
    }

    @Test("An identity failure outranks the live-paste-login rule")
    func identityFailureOutranksLivePasteLogin() {
        // Both flags can be true at once: a paste-mode login whose identity step then failed.
        // Only the identity step can be re-run there — the code behind the grant is spent.
        let affordance = resolve(.failed("Logged in, but couldn't verify the account — Retry."),
                                 canRetryIdentity: true, hasLivePasteLogin: true)
        #expect(affordance.actions == [.retryIdentity, .cancel])
    }

    @Test("The identity-failed state offers BOTH retry and cancel — the soft-lock guard")
    func identityFailureIsNeverASoftLock() {
        let affordance = resolve(.failed("Logged in, but couldn't verify the account — Retry."),
                                 needsReAuth: true, canRetryIdentity: true)
        #expect(affordance == .identityFailed(message: "Logged in, but couldn't verify the account — Retry."))
        // This state holds the one pending login, so a plain "Try again" would be silently
        // refused by the one-login-at-a-time rule. Retry re-runs just the identity step;
        // Cancel releases the pending login so a fresh login can start.
        #expect(affordance.actions.contains(.retryIdentity))
        #expect(affordance.actions.contains(.cancel))
        #expect(!affordance.actions.contains(.logIn))
        #expect(!affordance.actions.contains(.tryAgain))
    }

    @Test("A failure with no recoverable grant is terminal, and offers a fresh attempt")
    func terminalFailureOffersAFreshLogin() {
        let affordance = resolve(.failed("Login expired or was already used — try again."),
                                 needsReAuth: true)
        #expect(affordance == .failed(message: "Login expired or was already used — try again."))
        // Dismiss too: nothing else clears the message, so it would sit in the popover — and
        // in the add-account flow it sits where the "Add account…" button belongs.
        #expect(affordance.actions == [.tryAgain, .dismiss])
        // No retry offered: the authorization code behind that grant is spent.
        #expect(!affordance.actions.contains(.retryIdentity))
    }

    @Test("Every state that carries a message surfaces it, and no other state does")
    func onlyFailuresCarryMessages() {
        #expect(resolve(.failed("boom")).message == "boom")
        #expect(resolve(.failed("boom"), canRetryIdentity: true).message == "boom")
        #expect(resolve(.failed("boom"), hasLivePasteLogin: true).message == "boom")
        #expect(resolve(.idle).message == nil)
        #expect(resolve(.idle, needsReAuth: true).message == nil)
        #expect(resolve(.awaitingPaste).message == nil)
        #expect(resolve(.waitingForBrowser(since: Date())).message == nil)
    }
}

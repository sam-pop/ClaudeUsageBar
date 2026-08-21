import Foundation

/// What the login control offers for one login flow — an account's re-auth, or the
/// add-account flow — derived from that flow's `LoginState`.
///
/// Kept SwiftUI-free so the state → control mapping is pinned by tests instead of by
/// eyeballing a popover that closes the moment the browser takes focus.
enum LoginAffordance: Equatable {
    /// Nothing to offer: this account's login works and no login of its own is running.
    case none
    /// The stored login is dead; a new one can be started.
    case start
    /// The browser is open and the app is waiting for the callback.
    case waitingForBrowser
    /// The browser was sent to Anthropic's callback page; the app wants the `code#state`
    /// string it renders. `message` is set when a paste was rejected and the login is still
    /// waiting for a corrected one.
    case awaitingPaste(message: String?)
    /// The grant is in hand but the identity check failed. Distinct from `.failed` because
    /// this flow still holds the pending login: only `retryIdentity()` or `cancelLogin()`
    /// move it, and a fresh `beginLogin` for this account is refused by the
    /// one-login-at-a-time rule.
    case identityFailed(message: String)
    /// The login ended without credentials; the only way forward is a new one.
    case failed(message: String)

    /// - Parameters:
    ///   - state: this flow's entry in `loginState`, or `addLoginState` for the add flow.
    ///   - needsReAuth: whether the account's stored token is dead. Ignored while a login is
    ///     running — what that login is doing is the more useful thing to say.
    ///   - canRetryIdentity: whether *this* flow holds a grant whose identity step can be
    ///     re-run (`AccountsViewModel.canRetryIdentity(for:)`).
    ///   - hasLivePasteLogin: whether this flow still owns a paste-mode login that
    ///     `submitPaste(_:)` would accept.
    static func resolve(
        state: AccountsViewModel.LoginState,
        needsReAuth: Bool,
        canRetryIdentity: Bool,
        hasLivePasteLogin: Bool
    ) -> LoginAffordance {
        switch state {
        case .waitingForBrowser:
            return .waitingForBrowser
        case .awaitingPaste:
            return .awaitingPaste(message: nil)
        case .failed(let message):
            if canRetryIdentity { return .identityFailed(message: message) }
            // A rejected paste — unreadable, or a state that belongs to another login — keeps
            // its login alive so a corrected paste can still finish it. The field has to stay
            // with the message: a fresh login would be refused while that one holds the slot.
            if hasLivePasteLogin { return .awaitingPaste(message: message) }
            return .failed(message: message)
        case .idle:
            return needsReAuth ? .start : .none
        }
    }

    /// The text shown alongside the controls, when the state carries one.
    var message: String? {
        switch self {
        case .identityFailed(let message), .failed(let message): return message
        case .awaitingPaste(let message): return message
        case .none, .start, .waitingForBrowser: return nil
        }
    }

    /// The controls this state offers, in display order.
    var actions: [LoginAction] {
        switch self {
        case .none:
            return []
        case .start:
            return [.logIn]
        case .waitingForBrowser:
            return [.cancel, .copyLink, .usePasteCode]
        case .awaitingPaste:
            return [.submitPaste, .cancel]
        case .identityFailed:
            // Both, always. Retry alone parks the pending login forever when the identity
            // endpoint stays unreachable — and because that login holds the one pending slot,
            // every later click on this account is refused with nothing to explain it.
            // Cancel alone throws away a grant that is still good.
            return [.retryIdentity, .cancel]
        case .failed:
            // This flow has no live login of its own left to cancel or retry. Dismiss exists
            // because nothing else clears the message — a flow's state is not written again
            // until it logs in, so it would otherwise sit in the popover indefinitely.
            return [.tryAgain, .dismiss]
        }
    }
}

/// One control the login affordance can offer. `submitPaste` stands for the text field and
/// its Submit button, which the view renders instead of a plain button.
enum LoginAction: Hashable {
    case logIn
    case cancel
    case copyLink
    case usePasteCode
    case submitPaste
    case retryIdentity
    case tryAgain
    case dismiss
}

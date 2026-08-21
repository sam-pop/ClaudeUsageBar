import SwiftUI

/// The login control for one flow — an account's re-auth (`accountID`), or the add-account
/// flow (`accountID == nil`) — rendered from `AccountsViewModel`'s published login state and
/// the pure `LoginAffordance` mapping. Renders nothing when there is nothing to offer.
///
/// Every control here drives the view model, never local state. `MenuBarExtra`'s window style
/// dismisses the popover the moment the browser takes focus, so this view is torn down in the
/// middle of every login and rebuilt from scratch when the user next opens the menu bar item:
/// anything it remembered itself would be gone by then.
struct LoginPill: View {
    @ObservedObject var viewModel: AccountsViewModel
    let accountID: UUID?
    /// `compact` fits the matrix's 172-pt account column; `standard` fits the 320-pt
    /// single-account row and the add-account footer.
    var layout: Layout = .standard

    enum Layout { case compact, standard }

    /// The `code#state` being typed. Deliberately view state: it is a half-typed field, not
    /// login state, and the login it belongs to lives on the view model.
    @State private var pasteDraft = ""
    /// Confirms a "Copy link" press for as long as this popover stays open — which is exactly
    /// how long the confirmation is worth showing.
    @State private var didCopy = false

    var body: some View {
        let affordance = viewModel.loginAffordance(for: accountID)
        if affordance != .none {
            chrome(tint(for: affordance)) {
                if layout == .compact, affordance == .start {
                    // Keep the matrix column's one-line pill rather than a full banner.
                    compactStartPill
                } else {
                    VStack(alignment: .leading, spacing: layout == .compact ? 4 : 6) {
                        statusLine(affordance)
                        // The field stands in for `.submitPaste`, so that action is dropped
                        // from the button row below.
                        if case .awaitingPaste = affordance { pasteField }
                        buttonRow(affordance.actions.filter { $0 != .submitPaste })
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func statusLine(_ affordance: LoginAffordance) -> some View {
        switch affordance {
        case .none:
            EmptyView()
        case .start:
            line("Login expired — usage can't refresh.", icon: "key.slash.fill", tint: .red)
        case .waitingForBrowser:
            line("Waiting for browser…", icon: "safari", tint: .blue)
        case .awaitingPaste(let rejection):
            if let rejection {
                line(rejection, icon: "exclamationmark.triangle.fill", tint: .red)
            } else {
                line("Paste the code the browser page shows.", icon: "doc.on.clipboard", tint: .blue)
            }
        case .identityFailed(let message), .failed(let message):
            line(message, icon: "exclamationmark.triangle.fill", tint: .red)
        case .notice(let message):
            // Neutral on purpose: the login this describes worked.
            line(message, icon: "info.circle", tint: .secondary)
        }
    }

    private func line(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: layout == .compact ? 8 : 10)).foregroundStyle(tint)
            Text(text)
                .font(layout == .compact ? .system(size: 9) : .caption2)
                .foregroundStyle(tint == .red ? Color.red : Color.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var compactStartPill: some View {
        Button {
            Task { await viewModel.beginLogin(accountID) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "key.slash.fill").font(.system(size: 8))
                Text("Log in again").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.14)))
            .overlay(Capsule().stroke(Color.red.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain).help(help(for: .logIn))
    }

    @ViewBuilder
    private var pasteField: some View {
        let field = TextField("code#state", text: $pasteDraft)
            .textFieldStyle(.roundedBorder).controlSize(.small)
            .font(layout == .compact ? .system(size: 9) : nil)
            .onSubmit { submitPaste() }
        let submit = Button("Submit") { submitPaste() }
            .controlSize(.mini).buttonStyle(.borderedProminent)
            .disabled(pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if layout == .compact {
            VStack(alignment: .leading, spacing: 3) { field; submit }
        } else {
            HStack(spacing: 6) { field; submit }
        }
    }

    @ViewBuilder
    private func buttonRow(_ actions: [LoginAction]) -> some View {
        if !actions.isEmpty {
            if layout == .compact {
                // Three controls don't fit across a 172-pt column, so they stack.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(actions, id: \.self) { button($0) }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(actions, id: \.self) { button($0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ action: LoginAction) -> some View {
        let label = Text(title(for: action))
            .font(layout == .compact ? .system(size: 9, weight: .medium) : .caption2)
        if isPrimary(action) {
            Button { perform(action) } label: { label }
                .controlSize(.mini).buttonStyle(.borderedProminent).help(help(for: action))
        } else {
            Button { perform(action) } label: { label }
                .buttonStyle(.link).help(help(for: action))
        }
    }

    /// `standard` wraps its content in a tinted banner; `compact` sits inline in the matrix's
    /// header cell, which has its own padding.
    @ViewBuilder
    private func chrome<Content: View>(_ tint: Color, @ViewBuilder content: () -> Content) -> some View {
        if layout == .compact {
            content()
        } else {
            content()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.08)))
        }
    }

    // MARK: - Actions

    private func perform(_ action: LoginAction) {
        switch action {
        case .logIn, .tryAgain: Task { await viewModel.beginLogin(accountID) }
        case .cancel: Task { await viewModel.cancelLogin() }
        case .retryIdentity: Task { await viewModel.retryIdentity() }
        case .usePasteCode: Task { await viewModel.switchToPaste() }
        case .copyLink: copyAuthorizeLink()
        case .submitPaste: submitPaste()
        case .dismiss: viewModel.dismissLoginMessage(for: accountID)
        }
    }

    /// Puts the sign-in link on the pasteboard so it can be opened in a browser signed into
    /// the right account. At the user's explicit request, and only there: this URL carries the
    /// PKCE challenge and, on re-auth, a real email address, so it is never logged.
    private func copyAuthorizeLink() {
        guard let url = viewModel.pendingAuthorizeURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        didCopy = true
    }

    private func submitPaste() {
        let raw = pasteDraft
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pasteDraft = ""
        Task { await viewModel.submitPaste(raw) }
    }

    // MARK: - Copy

    private func isPrimary(_ action: LoginAction) -> Bool {
        switch action {
        case .logIn, .tryAgain, .retryIdentity, .submitPaste: return true
        case .cancel, .copyLink, .usePasteCode, .dismiss: return false
        }
    }

    private func title(for action: LoginAction) -> String {
        switch action {
        case .logIn: return "Log in again"
        case .cancel: return "Cancel"
        case .copyLink: return didCopy ? "Copied" : "Copy link"
        case .usePasteCode: return "Use a code instead"
        case .retryIdentity: return "Retry"
        case .tryAgain: return "Try again"
        case .submitPaste: return "Submit"
        case .dismiss: return "Dismiss"
        }
    }

    private func help(for action: LoginAction) -> String {
        switch action {
        case .logIn, .tryAgain: return "Opens claude.ai in your browser to sign in"
        case .cancel: return "Stop waiting and leave this account as it is"
        case .copyLink: return "Copy the sign-in link, to open in a browser signed into this account"
        case .usePasteCode: return "Finish by pasting the code from the browser instead"
        case .retryIdentity: return "Check which account signed in — without signing in again"
        case .submitPaste: return "Finish the login with the pasted code"
        case .dismiss: return "Clear this message"
        }
    }

    private func tint(for affordance: LoginAffordance) -> Color {
        switch affordance {
        case .waitingForBrowser: return .blue
        case .awaitingPaste(let rejection): return rejection == nil ? .blue : .red
        case .notice: return .secondary
        case .none, .start, .identityFailed, .failed: return .red
        }
    }
}

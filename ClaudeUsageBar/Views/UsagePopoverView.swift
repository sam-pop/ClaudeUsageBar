import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if viewModel.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(viewModel.accountViews) { view in
                            AccountRowView(viewModel: viewModel, accountView: view)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 460)
            }

            addAccountControls
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "sparkle").foregroundStyle(.orange)
            Text("Claude Usage").font(.system(.headline, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.title2).foregroundStyle(.secondary)
            Text("No accounts yet").font(.callout).fontWeight(.medium)
            Text("Log into Claude Code, then add the current account below.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 16)
    }

    private var addAccountControls: some View {
        VStack(spacing: 4) {
            Button {
                Task { await viewModel.addCurrentAccount() }
            } label: {
                Label("Add current account", systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Captures whichever account Claude Code is currently logged into")

            if let error = viewModel.addAccountError {
                Text(error).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
            } else {
                Text("Tip: switch Claude Code's login first to add a different account.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Text("Bar:").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $viewModel.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Toggle("Launch at login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { _ in viewModel.toggleLaunchAtLogin() }
                ))
                .toggleStyle(.switch).controlSize(.mini).font(.caption2)
            }

            if viewModel.notificationsAuthorized == false {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.slash")
                        Text("Notifications off — enable in System Settings").lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless).help("Refresh all now")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

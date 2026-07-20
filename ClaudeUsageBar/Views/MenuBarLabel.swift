import SwiftUI
import AppKit

/// The menu-bar status item. For a single account it reproduces the historical rendering
/// exactly (5h/7d badge + percent + reset countdown, color via the badge). For two or more
/// accounts it draws a compact composed image — a colored dot per account plus the
/// `P 45% · W 82%` text — since `Text`/SF Symbols render monochrome in a `MenuBarExtra`.
struct MenuBarLabel: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        if viewModel.accounts.isEmpty {
            Image(systemName: "sparkle")
        } else if viewModel.isSingleAccount {
            singleAccountLabel
        } else {
            Image(nsImage: MenuBarImage.multiAccount(
                accounts: viewModel.accounts,
                snapshots: viewModel.snapshots,
                mode: viewModel.menuBarDisplayMode
            ))
        }
    }

    // MARK: - Single account (unchanged rendering)

    @ViewBuilder
    private var singleAccountLabel: some View {
        let account = viewModel.accounts[0]
        let snapshot = viewModel.snapshots[account.id]
        let active = MenuBarSelection.active(mode: viewModel.menuBarDisplayMode, snapshot: snapshot)
        let needsRefresh = viewModel.needsReAuth[account.id] ?? false

        HStack(spacing: 4) {
            if needsRefresh {
                Image(systemName: "key.slash.fill").foregroundStyle(.red)
                Text("Refresh")
            } else {
                Image(nsImage: MenuBarImage.badge(
                    window: active?.window ?? (viewModel.menuBarDisplayMode == .auto ? .fiveHour : viewModel.menuBarDisplayMode),
                    isAuto: viewModel.menuBarDisplayMode == .auto,
                    percent: active?.percent ?? 0
                ))
                Text(viewModel.menuBarText).monospacedDigit()
            }
        }
    }
}

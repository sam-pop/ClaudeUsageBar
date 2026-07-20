import SwiftUI
import AppKit

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var viewModel: AccountsViewModel

    init() {
        // Single-instance guard: if an older copy is already running (e.g. left alive by
        // `make install`), terminate this launch so two processes can't refresh-race the
        // shared credential map.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sam.ClaudeUsageBar"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            NSApp?.terminate(nil)
        }
        _viewModel = StateObject(wrappedValue: AccountsViewModel())
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

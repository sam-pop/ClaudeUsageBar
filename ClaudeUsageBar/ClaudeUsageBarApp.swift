import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var viewModel = UsageViewModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
        } label: {
            MenuBarLabel(text: viewModel.menuBarText, color: viewModel.menuBarColor)
        }
        .menuBarExtraStyle(.window)
    }
}

import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkle")
                    .foregroundStyle(.orange)
                Text("Claude Usage")
                    .font(.system(.headline, weight: .semibold))
                Spacer()
                if case .loading = viewModel.state {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Content
            Group {
                switch viewModel.state {
                case .idle:
                    loadingPlaceholder
                case .loading:
                    if let s = viewModel.snapshot {
                        usageSections(s)
                    } else {
                        loadingPlaceholder
                    }
                case .loaded(let snapshot):
                    usageSections(snapshot)
                case .error(let message):
                    errorView(message)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Footer
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 280)
    }

    // MARK: - Subviews

    private func usageSections(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: 16) {
            UsageSectionView(
                title: "5-Hour Window",
                percent: snapshot.fiveHourPercent,
                resetsAt: snapshot.fiveHourResetsAt
            )
            UsageSectionView(
                title: "7-Day Window",
                percent: snapshot.sevenDayPercent,
                resetsAt: snapshot.sevenDayResetsAt
            )

            if let fetchedAt = viewModel.snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Updated \(UsageViewModel.lastUpdatedText(since: fetchedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading usage data...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Refresh now")

            Spacer()

            Toggle("Launch at Login", isOn: Binding(
                get: { viewModel.launchAtLogin },
                set: { _ in viewModel.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}

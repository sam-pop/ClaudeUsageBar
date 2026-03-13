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
                    if let s = viewModel.snapshot {
                        usageSections(s)
                        errorBanner(message)
                    } else {
                        errorView(message)
                    }
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
        .frame(width: 300)
    }

    // MARK: - Subviews

    private func usageSections(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: 12) {
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

            // Sparkline
            if viewModel.usageHistory.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Label("5hr", systemImage: "circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                        Label("7day", systemImage: "circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("Trend")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    SparklineView(dataPoints: viewModel.usageHistory)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            if let fetchedAt = viewModel.snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    HStack(spacing: 4) {
                        Text("Updated \(UsageViewModel.lastUpdatedText(since: fetchedAt))")
                        if viewModel.isStaleData {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                        }
                    }
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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
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

import SwiftUI

struct UsageSectionView: View {
    let title: String
    let percent: Int
    let resetsAt: Date?

    private var color: Color {
        UsageViewModel.color(for: percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(percent)%")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }

            ProgressBarView(percent: percent, color: color)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("Resets in")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(UsageViewModel.liveCountdown(until: resetsAt))
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

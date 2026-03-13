import SwiftUI

struct UsageSectionView: View {
    let title: String
    let percent: Int
    let resetsAt: Date?

    private var color: Color {
        UsageViewModel.color(for: percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(percent)%")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }

            ProgressBarView(percent: percent, color: color)

            HStack {
                Text("Resets in")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(UsageViewModel.resetCountdown(until: resetsAt))
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

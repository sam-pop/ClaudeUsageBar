import SwiftUI

struct UsageSectionView: View {
    let title: String
    let percent: Int
    let resetsAt: Date?

    var body: some View {
        // The whole section ticks every second so that, the instant `resetsAt` passes, the
        // window's percent/color/bar roll over to a fresh 0% instead of sticking at the last
        // value — matching the "Resets in now" countdown below it.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let shown = UsageSnapshot.effectivePercent(percent, resetsAt: resetsAt, now: context.date)
            let color = UsageColor.level(shown)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(shown)%")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                }

                ProgressBarView(percent: shown, color: color)

                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("Resets in")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(UsageFormatting.liveCountdown(until: resetsAt, now: context.date))
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

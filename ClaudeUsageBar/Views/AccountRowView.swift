import SwiftUI

/// One account's block in the popover: an editable header (label + menu-bar short code,
/// remove) plus its 5-hour / 7-day usage, sparkline, and last-updated line.
struct AccountRowView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let accountView: AccountsViewModel.AccountView

    @State private var isEditing = false
    @State private var draftLabel = ""
    @State private var draftShortCode = ""

    private var account: Account { accountView.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            if isEditing { editor }

            // Above the snapshot check on purpose: a dead login usually leaves the last
            // snapshot in place, so gating this on `snapshot == nil` hid the only way back in
            // behind an "Updated 3h ago" line that looked healthy.
            LoginPill(viewModel: viewModel, accountID: account.id)

            if let snapshot = accountView.snapshot {
                usageSections(snapshot)
                if let limits = snapshot.modelLimits, !limits.isEmpty {
                    modelLimitsSection(limits)
                }
                if accountView.history.count >= 2 { sparkline }
                updatedLine(snapshot.fetchedAt)
            } else if case .error(let message) = accountView.state {
                errorBanner(message)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(account.label).font(.system(.subheadline, weight: .semibold)).lineLimit(1)
            if let email = account.email, email != account.label {
                Text(email).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button {
                draftLabel = account.label
                draftShortCode = account.shortCode ?? ""
                isEditing.toggle()
            } label: { Image(systemName: "pencil").font(.system(size: 10)) }
                .buttonStyle(.borderless).help("Rename / set menu-bar code")
            Button(role: .destructive) {
                viewModel.remove(account.id)
            } label: { Image(systemName: "trash").font(.system(size: 10)) }
                .buttonStyle(.borderless).help("Remove this account")
        }
    }

    private var editor: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Label", text: $draftLabel)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                TextField("Bar", text: $draftShortCode)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 44)
                    .help("Menu-bar prefix (e.g. P, W, 🏠). Blank = auto from the label.")
            }
            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }.controlSize(.mini)
                Button("Save") {
                    let trimmed = draftLabel.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { viewModel.relabel(account.id, to: trimmed) }
                    viewModel.setShortCode(account.id, to: draftShortCode)
                    isEditing = false
                }
                .controlSize(.mini).buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Usage

    private func usageSections(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: 10) {
            UsageSectionView(title: "5-Hour Window", percent: snapshot.fiveHourPercent,
                             resetsAt: snapshot.fiveHourResetsAt)
            UsageSectionView(title: "7-Day Window", percent: snapshot.sevenDayPercent,
                             resetsAt: snapshot.sevenDayResetsAt)
        }
    }

    private func modelLimitsSection(_ limits: [ModelLimit]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-model (weekly)")
                .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            ForEach(limits) { limit in
                // Once a limit's reset has passed the window has rolled over to 0%, so drop
                // the stale percent (and its "critical" red) rather than showing a stuck value.
                let shown = UsageSnapshot.effectivePercent(limit.percent, resetsAt: limit.resetsAt)
                let color: Color = (limit.severity == "critical" && shown > 0) ? .red : UsageColor.level(shown)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(limit.modelName)
                            .font(.system(.subheadline, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text("\(shown)%")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(color)
                    }
                    ProgressBarView(percent: shown, color: color)
                    if let resetsAt = limit.resetsAt {
                        Text("Resets in \(UsageFormatting.resetCountdown(until: resetsAt))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var sparkline: some View {
        SparklineView(dataPoints: accountView.history)
            .frame(height: 32)
    }

    private func updatedLine(_ fetchedAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text("Updated \(UsageFormatting.lastUpdatedText(since: fetchedAt))")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The refresh error only. Anything to do with logging back in is `LoginPill`'s, hoisted
    /// out of this banner so it shows whether or not there's a snapshot.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(.orange)
            Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 4)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }
}

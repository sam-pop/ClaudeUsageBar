import SwiftUI

/// Multi-account comparison layout: usage windows are rows, accounts are columns, so the
/// same stat lines up horizontally and the highest account in each row is flagged "peak".
/// Used for 2+ accounts; a single account keeps the taller `AccountRowView` layout.
struct UsageMatrixView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let columns: [AccountsViewModel.AccountView]

    static let labelWidth: CGFloat = 74
    static let columnWidth: CGFloat = 172

    @State private var editingID: UUID?
    @State private var draftLabel = ""
    @State private var draftShortCode = ""

    /// One row of the metric per account: effective percent + reset, or nil when the account
    /// has no snapshot / doesn't report that metric.
    private struct CellData {
        let percent: Int
        let resetsAt: Date?
        let critical: Bool
    }

    private var modelNames: [String] {
        UsageComparison.modelRowNames(columns.map { $0.snapshot?.modelLimits ?? [] })
    }

    var body: some View {
        // One tick keeps every window's effective percent (and the leader flags) rolling over
        // the instant a reset passes, matching the popover sections.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(spacing: 0) {
                headerRow(now: now)
                metricRow(title: "5-Hour", subtitle: "session") { snap in
                    CellData(percent: snap.fiveHourEffectivePercent(now: now),
                             resetsAt: snap.fiveHourResetsAt, critical: false)
                }
                metricRow(title: "7-Day", subtitle: "weekly") { snap in
                    CellData(percent: snap.sevenDayEffectivePercent(now: now),
                             resetsAt: snap.sevenDayResetsAt, critical: false)
                }
                ForEach(modelNames, id: \.self) { name in
                    modelRow(name: name, now: now)
                }
                trendRow
            }
        }
    }

    // MARK: - Header row

    private func headerRow(now: Date) -> some View {
        row {
            cornerCell
            ForEach(columns.indices, id: \.self) { index in
                columnDivider(index)
                headerCell(columns[index], index: index, now: now)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var cornerCell: some View {
        Color.clear.frame(width: Self.labelWidth, height: 1)
    }

    private func headerCell(_ column: AccountsViewModel.AccountView, index: Int, now: Date) -> some View {
        let account = column.account
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(AccountColor.color(forIndex: index)).frame(width: 7, height: 7)
                Text(account.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Button {
                    draftLabel = account.label
                    draftShortCode = account.shortCode ?? ""
                    editingID = account.id
                } label: { Image(systemName: "pencil").font(.system(size: 9)) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Rename / set menu-bar code")
                Button(role: .destructive) {
                    Task { await viewModel.remove(account.id) }
                } label: { Image(systemName: "trash").font(.system(size: 9)) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Remove this account")
            }
            if let email = account.email, email != account.label {
                Text(email).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
            freshness(column, now: now)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(width: Self.columnWidth, alignment: .leading)
        .popover(isPresented: editBinding(for: account.id), arrowEdge: .bottom) { editForm(account) }
    }

    @ViewBuilder
    private func freshness(_ column: AccountsViewModel.AccountView, now: Date) -> some View {
        // A login that needs starting — or one already running — replaces the freshness line:
        // how stale the numbers are matters less than the fact that they've stopped updating.
        if viewModel.loginAffordance(for: column.account.id) != .none {
            LoginPill(viewModel: viewModel, accountID: column.account.id, layout: .compact)
        } else if let warning = LoginExpiry.warning(refreshTokenExpiresAt: column.refreshTokenExpiresAt, now: now) {
            HStack(spacing: 3) {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 8))
                Text(warning).font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.orange)
        } else if let snapshot = column.snapshot {
            let stale = now.timeIntervalSince(snapshot.fetchedAt) > 300
            let ago = UsageFormatting.lastUpdatedText(since: snapshot.fetchedAt, now: now)
            if stale {
                Button {
                    Task { await viewModel.refresh(column.account.id) }
                } label: {
                    pill(text: "Stale · \(ago)", systemImage: "arrow.clockwise", tint: .orange)
                }
                .buttonStyle(.plain).help("Refresh this account now")
            } else {
                Label("Updated \(ago)", systemImage: "circle.fill")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .labelStyle(DotLabelStyle())
            }
        } else if case .error = column.state {
            Text("Couldn't load").font(.system(size: 9)).foregroundStyle(.orange)
        } else {
            Text("Loading…").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Metric rows

    private func metricRow(title: String, subtitle: String,
                           value: @escaping (UsageSnapshot) -> CellData) -> some View {
        let data: [CellData?] = columns.map { $0.snapshot.map(value) }
        let flags = UsageComparison.leaders(data.map { $0?.percent })
        return row {
            labelCell(title, subtitle)
            ForEach(columns.indices, id: \.self) { index in
                columnDivider(index)
                metricCell(data[index], leader: flags[index])
            }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func modelRow(name: String, now: Date) -> some View {
        let data: [CellData?] = columns.map { column in
            guard let limit = column.snapshot?.modelLimits?.first(where: { $0.modelName == name }) else { return nil }
            let percent = UsageSnapshot.effectivePercent(limit.percent, resetsAt: limit.resetsAt, now: now)
            return CellData(percent: percent, resetsAt: limit.resetsAt,
                            critical: limit.severity == "critical")
        }
        let flags = UsageComparison.leaders(data.map { $0?.percent })
        return row {
            labelCell(name, "model · wk")
            ForEach(columns.indices, id: \.self) { index in
                columnDivider(index)
                metricCell(data[index], leader: flags[index])
            }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    @ViewBuilder
    private func metricCell(_ data: CellData?, leader: Bool) -> some View {
        Group {
            if let data {
                let color: Color = (data.critical && data.percent > 0) ? .red : UsageColor.level(data.percent)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(data.percent)%")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .monospacedDigit().foregroundStyle(color)
                        Spacer(minLength: 2)
                        if leader {
                            Text("PEAK").font(.system(size: 8, weight: .heavy))
                                .tracking(0.5).foregroundStyle(.orange)
                        }
                    }
                    ProgressBarView(percent: data.percent, color: color)
                    Text("resets \(UsageFormatting.resetCountdown(until: data.resetsAt))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
            } else {
                Text("—").font(.system(size: 15)).foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(width: Self.columnWidth, alignment: .leading)
        .overlay(alignment: .leading) {
            if leader {
                Capsule().fill(Color.orange).frame(width: 2.5).padding(.vertical, 8)
            }
        }
    }

    // MARK: - Trend row

    private var trendRow: some View {
        row {
            labelCell("Trend", "recent")
            ForEach(columns.indices, id: \.self) { index in
                let column = columns[index]
                columnDivider(index)
                Group {
                    if column.history.count >= 2 {
                        SparklineView(dataPoints: column.history)
                    } else {
                        Text("—").font(.system(size: 15)).foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(width: Self.columnWidth, alignment: .leading)
            }
        }
    }

    // MARK: - Shared cell scaffolding

    private func labelCell(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(.leading, 4).padding(.trailing, 6).padding(.top, 11)
        .frame(width: Self.labelWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) { content() }
    }

    @ViewBuilder
    private func columnDivider(_ index: Int) -> some View {
        if index > 0 {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
        }
    }

    // MARK: - Editing

    private func editBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { editingID == id }, set: { if !$0 { editingID = nil } })
    }

    private func editForm(_ account: Account) -> some View {
        VStack(spacing: 8) {
            TextField("Label", text: $draftLabel).textFieldStyle(.roundedBorder)
            TextField("Menu-bar code", text: $draftShortCode).textFieldStyle(.roundedBorder)
                .help("Menu-bar prefix (e.g. P, W, 🏠). Blank = auto from the label.")
            HStack {
                Spacer()
                Button("Cancel") { editingID = nil }
                Button("Save") {
                    let trimmed = draftLabel.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { viewModel.relabel(account.id, to: trimmed) }
                    viewModel.setShortCode(account.id, to: draftShortCode)
                    editingID = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12).frame(width: 240)
    }

    // MARK: - Bits

    private func pill(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 8))
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
    }
}

/// A tiny leading status dot for the "Updated Ns ago" line, tinted by the label's foreground.
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.green)
            configuration.title
        }
    }
}

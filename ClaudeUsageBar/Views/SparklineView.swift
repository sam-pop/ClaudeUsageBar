import SwiftUI

struct SparklineView: View {
    let dataPoints: [UsageDataPoint]

    var body: some View {
        if dataPoints.count >= 2 {
            VStack(spacing: 2) {
                GeometryReader { geo in
                    ZStack {
                        gridLines(height: geo.size.height, width: geo.size.width)
                        sparklinePath(geo: geo, values: dataPoints.map(\.sevenDayPercent), color: .orange)
                        sparklinePath(geo: geo, values: dataPoints.map(\.fiveHourPercent), color: .blue)
                    }
                }
                .frame(height: 40)

                timeAxis
            }
        }
    }

    // MARK: - Grid

    private func gridLines(height: CGFloat, width: CGFloat) -> some View {
        ForEach([25, 50, 75], id: \.self) { level in
            Path { path in
                let y = height * (1 - CGFloat(level) / 100)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
            .stroke(Color.primary.opacity(0.06), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        }
    }

    // MARK: - Sparkline

    private func sparklinePath(geo: GeometryProxy, values: [Int], color: Color) -> some View {
        Path { path in
            let count = values.count
            guard count >= 2 else { return }
            let step = geo.size.width / CGFloat(count - 1)
            let height = geo.size.height

            for (i, val) in values.enumerated() {
                let x = step * CGFloat(i)
                let y = height * (1 - CGFloat(min(max(val, 0), 100)) / 100)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        .stroke(color.gradient, lineWidth: 1.5)
    }

    // MARK: - Time Axis

    private var timeAxis: some View {
        HStack {
            Text(agoLabel(for: dataPoints.first?.timestamp))
            Spacer()
            if dataPoints.count > 4 {
                Text(agoLabel(for: dataPoints[dataPoints.count / 2].timestamp))
                Spacer()
            }
            Text("now")
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(.quaternary)
    }

    private func agoLabel(for date: Date?) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h ago" }
        if minutes > 0 { return "\(minutes)m ago" }
        return "now"
    }
}

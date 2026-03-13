import SwiftUI

struct SparklineView: View {
    let dataPoints: [UsageDataPoint]

    var body: some View {
        if dataPoints.count >= 2 {
            GeometryReader { geo in
                ZStack {
                    sparklinePath(geo: geo, values: dataPoints.map(\.fiveHourPercent), color: .blue)
                    sparklinePath(geo: geo, values: dataPoints.map(\.sevenDayPercent), color: .orange)
                }
            }
            .frame(height: 32)
            .padding(.vertical, 4)
        }
    }

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
}

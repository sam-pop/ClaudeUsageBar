import SwiftUI

struct ProgressBarView: View {
    let percent: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))

                RoundedRectangle(cornerRadius: 4)
                    .fill(color.gradient)
                    .frame(width: geo.size.width * clampedFraction)
                    .animation(.easeInOut(duration: 0.4), value: percent)
            }
        }
        .frame(height: 8)
    }

    private var clampedFraction: CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100.0
    }
}

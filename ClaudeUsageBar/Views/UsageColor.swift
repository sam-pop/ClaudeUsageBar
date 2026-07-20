import SwiftUI

/// SwiftUI level color for a usage percent (green < 50 ≤ yellow < 75 ≤ red). Shared by the
/// popover sections and the single-account menu bar; mirrors `MenuBarImage.levelColor`.
enum UsageColor {
    static func level(_ percent: Int) -> Color {
        switch percent {
        case ..<50: return .green
        case ..<75: return .yellow
        default:    return .red
        }
    }
}

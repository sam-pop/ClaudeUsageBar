import SwiftUI

/// Stable per-account identity color, keyed by the account's position in the (stable) list.
/// Distinguishes columns in the comparison matrix and tints each account's sparkline.
/// This is an *identity* hue — distinct from `UsageColor`, which encodes severity.
enum AccountColor {
    private static let palette: [Color] = [.blue, .purple, .teal, .pink, .orange, .indigo]

    static func color(forIndex index: Int) -> Color {
        palette[((index % palette.count) + palette.count) % palette.count]
    }
}

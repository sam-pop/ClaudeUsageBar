import SwiftUI
import AppKit

struct MenuBarLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: coloredSparkle)
            Text(text)
                .monospacedDigit()
        }
    }

    private var coloredSparkle: NSImage {
        let base = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)!
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [NSColor(color)]))
        let colored = base.withSymbolConfiguration(config)!
        colored.isTemplate = false
        return colored
    }
}

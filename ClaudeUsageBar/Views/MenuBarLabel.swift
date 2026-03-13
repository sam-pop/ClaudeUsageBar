import SwiftUI
import AppKit

struct MenuBarLabel: View {
    let text: String
    let color: Color
    let displayMode: MenuBarDisplayMode
    let activeWindow: MenuBarDisplayMode

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: modeBadge)
            Text(text)
                .monospacedDigit()
        }
    }

    private var modeBadge: NSImage {
        let badgeText = activeWindow == .fiveHour ? "5h" : "7d"
        let isAuto = displayMode == .auto
        let bgColor = isAuto ? NSColor.systemBlue : NSColor(color)

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            bgColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()

            let font = NSFont.systemFont(ofSize: 8, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let str = NSAttributedString(string: badgeText, attributes: attrs)
            let strSize = str.size()
            let strRect = NSRect(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2,
                width: strSize.width,
                height: strSize.height
            )
            str.draw(in: strRect)
            return true
        }
        image.isTemplate = false
        return image
    }
}

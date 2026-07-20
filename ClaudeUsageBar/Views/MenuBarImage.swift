import AppKit

/// AppKit drawing for the menu-bar status item. Color must be baked into an `NSImage`
/// because `Text`/SF Symbols render monochrome in a `MenuBarExtra` label.
enum MenuBarImage {

    /// Level color for a percent, matching `UsageViewModel.color(for:)`.
    static func levelColor(_ percent: Int) -> NSColor {
        switch percent {
        case ..<50: return .systemGreen
        case ..<75: return .systemYellow
        default:    return .systemRed
        }
    }

    /// The single-account 5h/7d badge (blue in auto mode, else the level color).
    static func badge(window: MenuBarDisplayMode, isAuto: Bool, percent: Int) -> NSImage {
        let badgeText = window == .fiveHour ? "5h" : "7d"
        let bgColor = isAuto ? NSColor.systemBlue : levelColor(percent)
        let size = NSSize(width: 18, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            bgColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let str = NSAttributedString(string: badgeText, attributes: attrs)
            let strSize = str.size()
            str.draw(in: NSRect(x: (rect.width - strSize.width) / 2,
                                y: (rect.height - strSize.height) / 2,
                                width: strSize.width, height: strSize.height))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The multi-account compact image: a colored dot + `X 45%` segment per account,
    /// separated by a middot. Text uses the dynamic label color so it adapts to light/dark.
    static func multiAccount(
        accounts: [Account],
        snapshots: [UUID: UsageSnapshot],
        mode: MenuBarDisplayMode
    ) -> NSImage {
        let prefixes = MultiAccountMenuBar.shortPrefixes(
            for: accounts.map(\.label),
            overrides: accounts.map(\.shortCode)
        )
        struct Segment { let dotColor: NSColor?; let text: String; let tag: String? }
        let segments: [Segment] = zip(prefixes, accounts).map { prefix, account in
            if let snapshot = snapshots[account.id],
               let active = MenuBarSelection.active(mode: mode, snapshot: snapshot) {
                let tag = MultiAccountMenuBar.windowTag(mode: mode, window: active.window)
                return Segment(dotColor: levelColor(active.percent), text: "\(prefix) \(active.percent)%", tag: tag)
            }
            return Segment(dotColor: nil, text: "\(prefix) --%", tag: nil)
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let tagFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let tagAttrs: [NSAttributedString.Key: Any] = [.font: tagFont, .foregroundColor: NSColor.secondaryLabelColor]
        let sepAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let tagGap: CGFloat = 2

        let dotDiameter: CGFloat = 7
        let dotGap: CGFloat = 3
        let segGap: CGFloat = 5
        let height: CGFloat = 18

        // Measure total width.
        var width: CGFloat = 0
        let sep = NSAttributedString(string: "·", attributes: sepAttrs)
        for (index, segment) in segments.enumerated() {
            if index > 0 { width += sep.size().width + segGap * 2 }
            if segment.dotColor != nil { width += dotDiameter + dotGap }
            width += NSAttributedString(string: segment.text, attributes: textAttrs).size().width
            if let tag = segment.tag {
                width += tagGap + NSAttributedString(string: tag, attributes: tagAttrs).size().width
            }
        }
        width = ceil(width) + 2

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 1
            for (index, segment) in segments.enumerated() {
                if index > 0 {
                    x += segGap
                    let sepSize = sep.size()
                    sep.draw(at: NSPoint(x: x, y: (height - sepSize.height) / 2))
                    x += sepSize.width + segGap
                }
                if let dot = segment.dotColor {
                    dot.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: (height - dotDiameter) / 2,
                                                width: dotDiameter, height: dotDiameter)).fill()
                    x += dotDiameter + dotGap
                }
                let str = NSAttributedString(string: segment.text, attributes: textAttrs)
                let strSize = str.size()
                str.draw(at: NSPoint(x: x, y: (height - strSize.height) / 2))
                x += strSize.width
                // Auto-mode window tag ("5h"/"7d"), drawn slightly raised and smaller.
                if let tag = segment.tag {
                    x += tagGap
                    let tagStr = NSAttributedString(string: tag, attributes: tagAttrs)
                    let tagSize = tagStr.size()
                    tagStr.draw(at: NSPoint(x: x, y: (height - tagSize.height) / 2 + 3))
                    x += tagSize.width
                }
            }
            return true
        }
        // Not a template: the colored dots must keep their color.
        image.isTemplate = false
        return image
    }
}

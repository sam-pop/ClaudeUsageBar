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

    /// The "Bars" mode image: one cluster per account, each a stacked pair of mini progress
    /// bars — 5h on top, 7d below — with its short prefix and the percent beside each bar.
    /// Bars use the *effective* percent, so a window past its reset shows empty, not stale.
    static func twoStat(accounts: [Account], snapshots: [UUID: UsageSnapshot], now: Date = Date()) -> NSImage {
        let prefixes = MultiAccountMenuBar.shortPrefixes(
            for: accounts.map(\.label), overrides: accounts.map(\.shortCode)
        )

        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]
        let rowLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        struct Cluster { let prefix: String; let p5: Int?; let p7: Int?; let num5: String; let num7: String }
        let clusters: [Cluster] = zip(prefixes, accounts).map { prefix, account in
            guard let s = snapshots[account.id] else {
                return Cluster(prefix: prefix, p5: nil, p7: nil, num5: "--", num7: "--")
            }
            let p5 = UsageSnapshot.effectivePercent(s.fiveHourPercent, resetsAt: s.fiveHourResetsAt, now: now)
            let p7 = UsageSnapshot.effectivePercent(s.sevenDayPercent, resetsAt: s.sevenDayResetsAt, now: now)
            return Cluster(prefix: prefix, p5: p5, p7: p7, num5: "\(p5)%", num7: "\(p7)%")
        }

        let barW: CGFloat = 26, barH: CGFloat = 4.5
        let gap: CGFloat = 3, prefixGap: CGFloat = 4, clusterGap: CGFloat = 7
        let height: CGFloat = 20
        let rowCenterTop = height - 6, rowCenterBot: CGFloat = 6

        func width(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGFloat {
            NSAttributedString(string: s, attributes: a).size().width
        }
        let labelW = max(width("5h", rowLabelAttrs), width("7d", rowLabelAttrs))
        func numW(_ c: Cluster) -> CGFloat { max(width(c.num5, numAttrs), width(c.num7, numAttrs)) }
        func prefixW(_ c: Cluster) -> CGFloat { width(c.prefix, prefixAttrs) }
        func clusterW(_ c: Cluster) -> CGFloat { prefixW(c) + prefixGap + labelW + gap + barW + gap + numW(c) }

        var total: CGFloat = 0
        for (i, c) in clusters.enumerated() {
            if i > 0 { total += clusterGap + 0.5 + clusterGap }
            total += clusterW(c)
        }
        total = ceil(total) + 2

        let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 1
            for (i, c) in clusters.enumerated() {
                if i > 0 {
                    x += clusterGap
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.4).setFill()
                    NSBezierPath(rect: NSRect(x: x, y: 3, width: 0.5, height: height - 6)).fill()
                    x += 0.5 + clusterGap
                }
                let pfx = NSAttributedString(string: c.prefix, attributes: prefixAttrs)
                pfx.draw(at: NSPoint(x: x, y: (height - pfx.size().height) / 2))
                x += pfx.size().width + prefixGap

                let clusterX = x
                func drawRow(_ label: String, pct: Int?, num: String, cy: CGFloat) {
                    var rx = clusterX
                    let lbl = NSAttributedString(string: label, attributes: rowLabelAttrs)
                    lbl.draw(at: NSPoint(x: rx, y: cy - lbl.size().height / 2))
                    rx += labelW + gap

                    let track = NSRect(x: rx, y: cy - barH / 2, width: barW, height: barH)
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
                    NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
                    if let pct, pct > 0 {
                        let w = max(barW * CGFloat(min(pct, 100)) / 100, barH)
                        levelColor(pct).setFill()
                        NSBezierPath(roundedRect: NSRect(x: rx, y: cy - barH / 2, width: w, height: barH),
                                     xRadius: barH / 2, yRadius: barH / 2).fill()
                    }
                    rx += barW + gap
                    let numStr = NSAttributedString(string: num, attributes: numAttrs)
                    numStr.draw(at: NSPoint(x: rx, y: cy - numStr.size().height / 2))
                }
                drawRow("5h", pct: c.p5, num: c.num5, cy: rowCenterTop)
                drawRow("7d", pct: c.p7, num: c.num7, cy: rowCenterBot)
                x = clusterX + labelW + gap + barW + gap + numW(c)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

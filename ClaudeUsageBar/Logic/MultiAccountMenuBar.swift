import Foundation

/// Pure composition of the multi-account (N≥2) menu-bar string and its worst-case level.
/// Kept free of SwiftUI so it is fully testable; the view maps `worstPercent` to a color
/// via the existing `UsageViewModel.color(for:)`.
enum MultiAccountMenuBar {

    /// Resolves each account's menu-bar prefix, preserving input order. A non-empty
    /// `override` (the user's `shortCode`) is used verbatim; otherwise a prefix is derived
    /// from the label — the first character uppercased, lengthened when it would collide
    /// with an already-assigned prefix (including user overrides), falling back to a numeric
    /// suffix when the label can't disambiguate.
    static func shortPrefixes(for labels: [String], overrides: [String?]) -> [String] {
        var assigned: [String] = []
        var used = Set<String>()

        for (index, label) in labels.enumerated() {
            // A non-blank user override wins verbatim.
            let override = (index < overrides.count ? overrides[index] : nil)?
                .trimmingCharacters(in: .whitespaces)
            if let override, !override.isEmpty {
                assigned.append(override)
                used.insert(override)
                continue
            }

            // Derive from the label, growing the prefix until it's unique.
            let cleaned = label.trimmingCharacters(in: .whitespaces)
            var candidate: String?
            var prefix = ""
            for ch in cleaned {
                prefix.append(ch)
                let c = capitalizingFirst(prefix)
                if !used.contains(c) { candidate = c; break }
            }
            // The whole label collided (e.g. a duplicate) — append a numeric suffix.
            if candidate == nil {
                let base = cleaned.isEmpty ? "?" : capitalizingFirst(String(cleaned.prefix(1)))
                var n = 2
                while used.contains("\(base)\(n)") { n += 1 }
                candidate = "\(base)\(n)"
            }
            assigned.append(candidate!)
            used.insert(candidate!)
        }
        return assigned
    }

    private static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Convenience for the all-auto-derived case (no user overrides).
    static func shortPrefixes(for labels: [String]) -> [String] {
        shortPrefixes(for: labels, overrides: labels.map { _ in nil })
    }

    /// Composes the compact bar string, e.g. `["P","W"]` + `[45,82]` → `"P 45% · W 82%"`.
    static func compose(prefixes: [String], percents: [Int]) -> String {
        zip(prefixes, percents).map { "\($0) \($1)%" }.joined(separator: " · ")
    }

    /// The highest percent across accounts (drives the worst-case color); nil if empty.
    static func worstPercent(_ percents: [Int]) -> Int? {
        percents.max()
    }
}

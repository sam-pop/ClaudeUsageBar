import Foundation

/// Pure comparison helpers for the multi-account matrix popover, where each usage window is
/// a row and each account a column. Kept SwiftUI-free so the "who's highest" and
/// "which model rows exist" decisions are unit-testable.
enum UsageComparison {

    /// Flags the cell(s) holding the highest value in a metric row, for "peak" highlighting.
    /// Returns all-false unless the row is worth flagging: at least two present (non-nil)
    /// values, a positive maximum, and some variation (an all-equal row has no meaningful
    /// leader). `nil` entries (an account missing that metric) are never leaders.
    static func leaders(_ percents: [Int?]) -> [Bool] {
        let present = percents.compactMap { $0 }
        guard present.count >= 2,
              let maxVal = present.max(),
              let minVal = present.min(),
              maxVal > 0, maxVal != minVal
        else {
            return Array(repeating: false, count: percents.count)
        }
        return percents.map { $0 == maxVal }
    }

    /// Ordered, de-duplicated union of model names across accounts (first-seen order), so
    /// each distinct model (e.g. "Fable") gets exactly one row even when only some accounts
    /// report it.
    static func modelRowNames(_ perAccount: [[ModelLimit]]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for models in perAccount {
            for model in models where seen.insert(model.modelName).inserted {
                names.append(model.modelName)
            }
        }
        return names
    }
}

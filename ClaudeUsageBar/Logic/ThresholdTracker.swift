import Foundation

/// Tracks usage-threshold crossings independently per window (5-hour / 7-day), with
/// hysteresis so a notification fires once per crossing and re-arms only after the
/// window drops back below the lowest threshold.
///
/// Designed per-window now so Phase 5's per-window notifications sit directly on top.
struct ThresholdTracker {
    enum Window: Hashable {
        case fiveHour
        case sevenDay
    }

    struct Crossing: Equatable {
        let window: Window
        let threshold: Int
        let percent: Int
    }

    private let thresholds: [Int]
    private let clearBelow: Int
    private var fired: [Window: Set<Int>] = [.fiveHour: [], .sevenDay: []]

    init(thresholds: [Int] = [80, 90]) {
        self.thresholds = thresholds.sorted()
        self.clearBelow = thresholds.min() ?? 0
    }

    /// Parses a raw UserDefaults value (`notificationThresholds`) into a valid, sorted,
    /// deduped threshold list clamped to 1...100. Non-numeric entries are dropped;
    /// `nil` or an all-junk/empty result falls back to `defaults`.
    ///
    /// Takes `[Any]?` because `UserDefaults.array(forKey:)` returns bridged values and
    /// `defaults write … -array 80 90` stores the numbers as strings.
    static func sanitizedThresholds(from raw: [Any]?, default defaults: [Int] = [80, 90]) -> [Int] {
        guard let raw else { return defaults }
        let ints: [Int] = raw.compactMap { value in
            switch value {
            case let i as Int: return i
            case let d as Double: return Int(d)
            case let s as String: return Int(s)
            default: return nil
            }
        }
        let cleaned = Set(ints.map { min(100, max(1, $0)) }).sorted()
        return cleaned.isEmpty ? defaults : cleaned
    }

    /// Records the latest percentages for both windows and returns any thresholds newly
    /// crossed this call. A window that has dropped below the lowest threshold is re-armed.
    mutating func record(fiveHour: Int, sevenDay: Int) -> [Crossing] {
        record(window: .fiveHour, percent: fiveHour) + record(window: .sevenDay, percent: sevenDay)
    }

    private mutating func record(window: Window, percent: Int) -> [Crossing] {
        if percent < clearBelow {
            fired[window] = []
            return []
        }

        var crossings: [Crossing] = []
        for threshold in thresholds where percent >= threshold {
            if fired[window, default: []].insert(threshold).inserted {
                crossings.append(Crossing(window: window, threshold: threshold, percent: percent))
            }
        }
        return crossings
    }
}

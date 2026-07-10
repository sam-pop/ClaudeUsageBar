import Foundation

/// Pure append-with-sampling logic for the usage history sparkline. Samples no more
/// often than `minInterval` and caps the buffer at `maxPoints` (dropping oldest first).
enum HistoryBuffer {
    /// Returns the history with `point` appended, or the input unchanged when the last
    /// sample is newer than `minInterval` ago. Trims to `maxPoints`, oldest dropped.
    static func appending(
        _ point: UsageDataPoint,
        to history: [UsageDataPoint],
        maxPoints: Int,
        minInterval: TimeInterval
    ) -> [UsageDataPoint] {
        if let last = history.last,
           point.timestamp.timeIntervalSince(last.timestamp) < minInterval {
            return history
        }

        var updated = history
        updated.append(point)
        if updated.count > maxPoints {
            updated.removeFirst(updated.count - maxPoints)
        }
        return updated
    }
}

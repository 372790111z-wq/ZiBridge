import Foundation

// Timing metadata only. Constant-space O(1) replacement; never stores audio.
// Values are the most recent window, not an estimate of the whole session p95.
struct RecentTimingSamples {
    static let capacity = 2048
    private(set) var values: [Double] = []
    private var next = 0
    private(set) var total = 0
    mutating func append(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        if values.count < Self.capacity { values.append(value) }
        else { values[next] = value; next = (next + 1) % Self.capacity }
        total += 1
    }
}

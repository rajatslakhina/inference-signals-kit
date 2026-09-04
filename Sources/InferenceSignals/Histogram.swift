import Foundation

/// A fixed-bucket histogram. Memory is `bounds.count + 1` counters no matter
/// how many samples arrive, which is the property a fleet aggregate needs:
/// a long-running session must not accumulate one `Double` per inference.
///
/// Quantiles are estimated by linear interpolation inside the bucket that
/// contains the target rank, so the estimate is bounded by the bucket edges
/// on either side — the tests assert exactly that, not an exact value.
public struct BoundedHistogram: Hashable, Sendable, Codable {
    /// Upper bounds of each finite bucket, strictly increasing. The last
    /// bucket is implicit and catches everything above `bounds.last`.
    public let bounds: [Double]
    public private(set) var counts: [Int]
    public private(set) var total: Int
    public private(set) var minimum: Double?
    public private(set) var maximum: Double?

    public enum ConfigurationError: Error, Equatable, Sendable {
        case noBounds
        case boundsNotStrictlyIncreasing(at: Int)
        case nonFiniteBound(at: Int)
    }

    public init(bounds: [Double]) throws {
        guard !bounds.isEmpty else { throw ConfigurationError.noBounds }
        for (index, bound) in bounds.enumerated() {
            guard bound.isFinite else { throw ConfigurationError.nonFiniteBound(at: index) }
            if index > 0, bound <= bounds[index - 1] {
                throw ConfigurationError.boundsNotStrictlyIncreasing(at: index)
            }
        }
        self.bounds = bounds
        self.counts = Array(repeating: 0, count: bounds.count + 1)
        self.total = 0
    }

    /// Log-spaced latency buckets from 1 ms to ~65 s (17 finite buckets),
    /// plus the overflow bucket.
    public static func latencyMilliseconds() -> BoundedHistogram {
        var bounds: [Double] = []
        var edge = 1.0
        for _ in 0..<17 {
            bounds.append(edge)
            edge *= 2
        }
        // The bounds above are strictly increasing and finite by
        // construction, so this cannot throw; a failure would be a bug in
        // the loop, and falling back to a single bucket keeps it visible
        // without trapping.
        return (try? BoundedHistogram(bounds: bounds))
            ?? (try? BoundedHistogram(bounds: [1]))
            ?? BoundedHistogram(uncheckedBounds: [1])
    }

    /// Linear tokens-per-second buckets, 5 t/s wide up to 200 t/s.
    public static func tokensPerSecond() -> BoundedHistogram {
        let bounds = stride(from: 5.0, through: 200.0, by: 5.0).map { $0 }
        return (try? BoundedHistogram(bounds: bounds))
            ?? BoundedHistogram(uncheckedBounds: [5])
    }

    private init(uncheckedBounds: [Double]) {
        bounds = uncheckedBounds
        counts = Array(repeating: 0, count: uncheckedBounds.count + 1)
        total = 0
    }

    /// Records one observation. NaN is ignored (it is not a measurement);
    /// infinities land in the overflow bucket.
    public mutating func record(_ value: Double) {
        if value.isNaN { return }
        let index = bucketIndex(for: value)
        // `bucketIndex` always returns a value in `0..<counts.count`, and
        // counts has `bounds.count + 1` entries, so this subscript is
        // in range; the guard is belt-and-braces against a future edit.
        guard counts.indices.contains(index) else { return }
        Saturating.increment(&counts[index])
        Saturating.increment(&total)
        minimum = min(minimum ?? value, value)
        maximum = max(maximum ?? value, value)
    }

    /// Index of the first bucket whose upper bound is ≥ `value`, or the
    /// overflow bucket. Binary search; `bounds` is sorted by construction.
    public func bucketIndex(for value: Double) -> Int {
        var low = 0
        var high = bounds.count
        while low < high {
            let mid = low + (high - low) / 2
            if bounds[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// The lower and upper edge of a bucket. The first bucket's lower edge
    /// is zero (latencies and rates are non-negative); the overflow bucket's
    /// upper edge is `+infinity`.
    public func edges(of index: Int) -> (lower: Double, upper: Double)? {
        guard counts.indices.contains(index) else { return nil }
        let lower = index == 0 ? 0 : bounds[index - 1]
        let upper = index < bounds.count ? bounds[index] : Double.infinity
        return (lower, upper)
    }

    /// Estimated value at quantile `q` in [0, 1]. Returns `nil` when empty.
    /// Values outside [0, 1] are clamped. In the overflow bucket the estimate
    /// is the bucket's lower edge (there is no upper edge to interpolate to)
    /// unless the observed maximum is known, in which case that is used.
    public func quantile(_ q: Double) -> Double? {
        guard total > 0 else { return nil }
        let clamped = q.isNaN ? 0 : min(1, max(0, q))
        // Rank is 1-based: the smallest sample is rank 1.
        let targetRank = max(1, Saturating.int(clamping: (clamped * Double(total)).rounded(.up)))
        var cumulative = 0
        for (index, count) in counts.enumerated() {
            let previous = cumulative
            cumulative = Saturating.add(cumulative, count)
            guard cumulative >= targetRank, count > 0 else { continue }
            guard let edge = edges(of: index) else { return nil }
            if !edge.upper.isFinite {
                return maximum ?? edge.lower
            }
            // Position of the target rank inside this bucket, in (0, 1].
            let fraction = Double(targetRank - previous) / Double(count)
            return edge.lower + (edge.upper - edge.lower) * fraction
        }
        return maximum
    }

    public var p50: Double? { quantile(0.50) }
    public var p95: Double? { quantile(0.95) }
    public var p99: Double? { quantile(0.99) }
}

import XCTest
@testable import InferenceSignals

final class HistogramTests: XCTestCase {

    func testConfigurationIsValidated() {
        XCTAssertThrowsSpecific(try BoundedHistogram(bounds: []), BoundedHistogram.ConfigurationError.noBounds)
        XCTAssertThrowsSpecific(try BoundedHistogram(bounds: [1, 1]),
                                BoundedHistogram.ConfigurationError.boundsNotStrictlyIncreasing(at: 1))
        XCTAssertThrowsSpecific(try BoundedHistogram(bounds: [2, 1]),
                                BoundedHistogram.ConfigurationError.boundsNotStrictlyIncreasing(at: 1))
        XCTAssertThrowsSpecific(try BoundedHistogram(bounds: [1, .infinity]),
                                BoundedHistogram.ConfigurationError.nonFiniteBound(at: 1))
    }

    func testBucketIndexIsFirstBoundAtOrAboveValue() throws {
        let histogram = try BoundedHistogram(bounds: [1, 2, 4, 8])
        XCTAssertEqual(histogram.bucketIndex(for: 0), 0)
        XCTAssertEqual(histogram.bucketIndex(for: 1), 0)
        XCTAssertEqual(histogram.bucketIndex(for: 1.5), 1)
        XCTAssertEqual(histogram.bucketIndex(for: 4), 2)
        XCTAssertEqual(histogram.bucketIndex(for: 8), 3)
        XCTAssertEqual(histogram.bucketIndex(for: 9), 4)
        XCTAssertEqual(histogram.bucketIndex(for: .infinity), 4)
        XCTAssertEqual(histogram.counts.count, 5)
    }

    func testEmptyReportsNilAndNaNIsIgnored() throws {
        var histogram = try BoundedHistogram(bounds: [1, 2])
        XCTAssertNil(histogram.p50)
        histogram.record(.nan)
        XCTAssertEqual(histogram.total, 0)
        XCTAssertNil(histogram.quantile(0.5))
    }

    func testMemoryIsBoundedRegardlessOfSampleCount() throws {
        var histogram = try BoundedHistogram(bounds: [1, 2, 4])
        for i in 0..<10_000 { histogram.record(Double(i % 7)) }
        XCTAssertEqual(histogram.total, 10_000)
        XCTAssertEqual(histogram.counts.count, 4)
        XCTAssertEqual(histogram.counts.reduce(0, +), 10_000)
    }

    func testQuantileEstimateStaysInsideTheContainingBucket() throws {
        var histogram = BoundedHistogram.latencyMilliseconds()
        // 1000 samples uniform in [0, 1000) ms — the true p50 is 500 ms,
        // which lives in the (256, 512] bucket; p95 ≈ 950 in (512, 1024].
        for i in 0..<1_000 { histogram.record(Double(i)) }
        let p50 = try XCTUnwrap(histogram.p50)
        let p95 = try XCTUnwrap(histogram.p95)
        XCTAssertGreaterThan(p50, 256)
        XCTAssertLessThanOrEqual(p50, 512)
        XCTAssertGreaterThan(p95, 512)
        XCTAssertLessThanOrEqual(p95, 1_024)
        XCTAssertLessThanOrEqual(p50, p95)
        // A histogram that put everything in one bucket would report
        // p50 == p95 == that bucket's interpolation; the ordering above is
        // strict, so it cannot pass.
        XCTAssertLessThan(p50, p95)
    }

    func testQuantileInterpolatesWithinBucket() throws {
        var histogram = try BoundedHistogram(bounds: [10, 20])
        // Four samples all in (10, 20]. Ranks 1..4 map to 12.5, 15, 17.5, 20.
        for value in [11.0, 12, 13, 14] { histogram.record(value) }
        XCTAssertEqual(try XCTUnwrap(histogram.quantile(0.25)), 12.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(histogram.quantile(0.5)), 15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(histogram.quantile(1.0)), 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(histogram.quantile(0)), 12.5, accuracy: 1e-9)
        // Out-of-range quantiles clamp instead of trapping.
        XCTAssertEqual(try XCTUnwrap(histogram.quantile(7)), 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(histogram.quantile(-3)), 12.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(histogram.quantile(.nan)), 12.5, accuracy: 1e-9)
    }

    func testOverflowBucketReportsObservedMaximum() throws {
        var histogram = try BoundedHistogram(bounds: [1, 2])
        histogram.record(50)
        histogram.record(.infinity)
        XCTAssertEqual(histogram.counts[2], 2)
        XCTAssertEqual(histogram.quantile(0.5), .infinity) // maximum observed
        var finite = try BoundedHistogram(bounds: [1, 2])
        finite.record(50)
        XCTAssertEqual(finite.p99, 50)
        XCTAssertEqual(finite.edges(of: 2)?.upper, .infinity)
        XCTAssertNil(finite.edges(of: 3))
        XCTAssertNil(finite.edges(of: -1))
    }

    func testStandardHistogramsHaveExpectedShape() {
        let latency = BoundedHistogram.latencyMilliseconds()
        XCTAssertEqual(latency.bounds.first, 1)
        XCTAssertEqual(latency.bounds.count, 17)
        XCTAssertEqual(latency.bounds.last, 65_536)
        let tps = BoundedHistogram.tokensPerSecond()
        XCTAssertEqual(tps.bounds.first, 5)
        XCTAssertEqual(tps.bounds.last, 200)
        XCTAssertEqual(tps.bounds.count, 40)
    }

    func testRunningMeanIgnoresNonFinite() {
        var mean = RunningMean()
        XCTAssertNil(mean.mean)
        mean.record(1)
        mean.record(.nan)
        mean.record(.infinity)
        mean.record(3)
        XCTAssertEqual(mean.count, 2)
        XCTAssertEqual(mean.mean, 2)
    }
}

import XCTest
@testable import InferenceSignals

final class CollectorTests: XCTestCase {

    private func makeCollector(sink: any SignalSink,
                               capacity: Int = 100,
                               sampling: SamplingPolicy = .standard,
                               maximumProfiles: Int = 32) throws -> SignalCollector {
        try SignalCollector(sink: sink,
                            buffer: try PriorityRingBuffer(capacity: capacity),
                            samplingPolicy: sampling,
                            tailPolicy: TailPolicy(defaultBudget: .seconds(2)),
                            maximumProfiles: maximumProfiles)
    }

    func testConfigurationRejectsNonPositiveProfileCap() {
        XCTAssertThrowsSpecific(try makeCollector(sink: InMemorySink(), maximumProfiles: 0),
                                SignalCollector.ConfigurationError.nonPositiveMaximumProfiles(0))
    }

    // MARK: Aggregation happens before sampling

    func testCountsAreUnaffectedBySampling() throws {
        let collector = try makeCollector(sink: InMemorySink())
        for i in 0..<400 {
            collector.ingest(Fixtures.record(request: "n\(i)", thermal: .critical, at: Int64(i)))
        }
        for i in 0..<40 {
            collector.ingest(Fixtures.record(request: "e\(i)", recordClass: .error, thermal: .critical, at: Int64(1_000 + i)))
        }
        let snapshot = collector.snapshot()
        let planner = try XCTUnwrap(snapshot.profiles[Fixtures.planner])
        XCTAssertEqual(planner.completions, 400, "every completion counts, sampled out or not")
        XCTAssertEqual(planner.failures[.guardrailRefusal], 40)
        XCTAssertEqual(snapshot.recordsIngested, 440)
        XCTAssertGreaterThan(snapshot.recordsSampledOut, 300, "2% keep rate at critical")
        // Every error is still in the buffer; the sampled-out records are not.
        let buffered = collector.peekBuffer()
        XCTAssertEqual(buffered.filter { $0.recordClass == .error }.count, 40)
        XCTAssertEqual(buffered.count + snapshot.recordsSampledOut, 440)
    }

    func testErrorRateIsFailuresOverStartedRequests() throws {
        let collector = try makeCollector(sink: InMemorySink())
        for _ in 0..<10 { collector.noteRequestStarted(profile: Fixtures.planner) }
        collector.ingest(Fixtures.record(recordClass: .error))
        collector.ingest(Fixtures.record(recordClass: .error, payload: .inferenceFailed(.deadlineExceeded, Fixtures.shape(), elapsed: .zero)))
        let planner = try XCTUnwrap(collector.snapshot().profiles[Fixtures.planner])
        XCTAssertEqual(planner.requestsStarted, 10)
        XCTAssertEqual(planner.failureCount, 2)
        XCTAssertEqual(try XCTUnwrap(planner.errorRate), 0.2, accuracy: 1e-9)
        XCTAssertNil(ProfileSignals(profile: Fixtures.executor).errorRate)
    }

    func testSaturationGaugesAndPressureCounter() throws {
        let collector = try makeCollector(sink: InMemorySink(), sampling: .keepEverything)
        let sample = LatencySample(queueWait: .zero, timeToFirstToken: .milliseconds(1), total: .milliseconds(2), outputTokens: 1)
        collector.ingest(Fixtures.record(thermal: .serious,
                                         payload: .inferenceCompleted(sample, Fixtures.shape(prompt: 1_024, window: 4_096, reused: 512))))
        collector.ingest(Fixtures.record(thermal: .nominal,
                                         payload: .inferenceCompleted(sample, Fixtures.shape(prompt: 4_096, window: 4_096, reused: 0))))
        let planner = try XCTUnwrap(collector.snapshot().profiles[Fixtures.planner])
        XCTAssertEqual(try XCTUnwrap(planner.contextHeadroom.mean), 0.375, accuracy: 1e-9)   // (0.75 + 0) / 2
        XCTAssertEqual(try XCTUnwrap(planner.prefixReuseRate.mean), 0.25, accuracy: 1e-9)    // (0.5 + 0) / 2
        XCTAssertEqual(planner.completionsUnderPressure, 1)
    }

    func testPromptShapeGuardsAgainstDegenerateInputs() {
        let zeroWindow = PromptShape(promptTokens: 10, instructionTokens: 0, contextWindowTokens: 0, toolSetDigest: Digest(string: ""))
        XCTAssertEqual(zeroWindow.contextHeadroom, 0)
        let negative = PromptShape(promptTokens: -5, instructionTokens: -1, reusedPrefixTokens: -2,
                                   contextWindowTokens: -9, attachmentCount: -1, toolSetDigest: Digest(string: ""))
        XCTAssertEqual(negative.promptTokens, 0)
        XCTAssertEqual(negative.contextHeadroom, 0)
        XCTAssertEqual(negative.prefixReuseRate, 0)
        let overfull = PromptShape(promptTokens: 8_000, instructionTokens: 0, reusedPrefixTokens: 9_000,
                                   contextWindowTokens: 4_096, toolSetDigest: Digest(string: ""))
        XCTAssertEqual(overfull.contextHeadroom, 0)
        XCTAssertEqual(overfull.prefixReuseRate, 1)
    }

    func testProfileMapIsBounded() throws {
        let collector = try makeCollector(sink: InMemorySink(), sampling: .keepEverything, maximumProfiles: 3)
        for i in 0..<50 {
            collector.ingest(Fixtures.record(profile: ProfileID(.literal("p\(i)")), at: Int64(i)))
        }
        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.profiles.count, 4, "3 real profiles + the overflow bucket")
        XCTAssertEqual(snapshot.profiles[SignalsSnapshot.overflowProfile]?.completions, 47)
        // A known profile keeps attributing after the cap is hit.
        collector.ingest(Fixtures.record(profile: ProfileID(.literal("p0")), at: 99))
        XCTAssertEqual(collector.snapshot().profiles[ProfileID(.literal("p0"))]?.completions, 2)
    }

    // MARK: Flush

    func testFlushDeliversAndClearsTheBuffer() async throws {
        let sink = InMemorySink()
        let collector = try makeCollector(sink: sink, sampling: .keepEverything)
        for i in 0..<10 { collector.ingest(Fixtures.record(request: "r\(i)", at: Int64(i))) }
        let flushed = await collector.flush()
        XCTAssertEqual(flushed, 10)
        let deliveredCount = await sink.delivered.count
        XCTAssertEqual(deliveredCount, 10)
        XCTAssertEqual(collector.snapshot().bufferOccupancy, 0)
        XCTAssertEqual(collector.snapshot().recordsDelivered, 10)
        let emptyFlush = await collector.flush()
        XCTAssertEqual(emptyFlush, 0, "an empty flush does not call the sink")
        let batches = await sink.batches
        XCTAssertEqual(batches, 1)
    }

    func testFlushBatchReturnsExactlyWhatWasDelivered() async throws {
        let sink = InMemorySink()
        let collector = try makeCollector(sink: sink, sampling: .keepEverything)
        for i in 0..<5 { collector.ingest(Fixtures.record(request: "a\(i)", at: Int64(i))) }
        let first = await collector.flushBatch()
        XCTAssertEqual(first.map { $0.requestID?.rawValue }, ["a0", "a1", "a2", "a3", "a4"])
        for i in 0..<2 { collector.ingest(Fixtures.record(request: "b\(i)", at: Int64(10 + i))) }
        let second = await collector.flushBatch()
        XCTAssertEqual(second.map { $0.requestID?.rawValue }, ["b0", "b1"], "the second batch, not the cumulative log")
        let empty = await collector.flushBatch()
        XCTAssertEqual(empty, [])
        let total = await sink.delivered.count
        XCTAssertEqual(total, 7)
    }

    func testConcurrentFlushesDeliverEveryRecordExactlyOnce() async throws {
        let sink = GatedSink(gated: true)
        let collector = try makeCollector(sink: sink, capacity: 10_000, sampling: .keepEverything)
        for i in 0..<500 { collector.ingest(Fixtures.record(request: "r\(i)", at: Int64(i))) }

        // First flush drains and parks inside the sink.
        let first = Task { await collector.flush() }
        while await sink.waiting < 1 { await Task.yield() }
        XCTAssertEqual(collector.inFlightFlushes, 1)

        // Records ingested while the first delivery is suspended, then eight
        // concurrent flushes racing each other and the parked one.
        for i in 500..<800 { collector.ingest(Fixtures.record(request: "r\(i)", at: Int64(i))) }
        let racers = (0..<8).map { _ in Task { await collector.flush() } }
        while await sink.waiting < 2 { await Task.yield() }
        await sink.release()
        // Any racer that found the buffer empty returned 0 without touching
        // the sink; release again for any that parked after the first release.
        try await Task.sleep(for: .milliseconds(20))
        await sink.release()

        let firstCount = await first.value
        var racerTotal = 0
        for racer in racers { racerTotal += await racer.value }

        let delivered = await sink.delivered
        XCTAssertEqual(firstCount, 500)
        XCTAssertEqual(racerTotal, 300)
        XCTAssertEqual(delivered.count, 800)
        XCTAssertEqual(Set(delivered.compactMap { $0.requestID?.rawValue }).count, 800, "no duplicates")
        XCTAssertEqual(collector.inFlightFlushes, 0)
        XCTAssertEqual(collector.snapshot().recordsDelivered, 800)
    }

    func testFailedDeliveryReoffersThroughTheBoundedBuffer() async throws {
        let sink = GatedSink()
        await sink.setFailing(true)
        let collector = try makeCollector(sink: sink, capacity: 20, sampling: .keepEverything)
        for i in 0..<20 { collector.ingest(Fixtures.record(request: "r\(i)", at: Int64(i))) }
        let firstAttempt = await collector.flush()
        XCTAssertEqual(firstAttempt, 0)
        var snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.deliveryFailures, 1)
        XCTAssertEqual(snapshot.bufferOccupancy, 20, "the batch went back")
        XCTAssertEqual(snapshot.recordsDelivered, 0)

        // More records than the buffer holds arrive during the outage: the
        // buffer's eviction policy, not the collector, decides what survives,
        // and occupancy never exceeds capacity.
        for i in 20..<50 { collector.ingest(Fixtures.record(request: "r\(i)", at: Int64(i))) }
        collector.ingest(Fixtures.record(request: "err", recordClass: .error, at: 50))
        let secondAttempt = await collector.flush()
        XCTAssertEqual(secondAttempt, 0)
        snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.bufferOccupancy, 20)
        XCTAssertEqual(snapshot.deliveryFailures, 2)

        await sink.setFailing(false)
        let recovered = await collector.flush()
        XCTAssertEqual(recovered, 20)
        let delivered = await sink.delivered
        XCTAssertTrue(delivered.contains { $0.requestID?.rawValue == "err" }, "the error survived the outage")
        XCTAssertEqual(collector.snapshot().bufferOccupancy, 0)
    }

    func testSnapshotReportsPolicyAndDevice() throws {
        let collector = try makeCollector(sink: InMemorySink(), capacity: 7)
        collector.updateDevice(DeviceEnvelope(thermal: .serious, energy: .lowPowerMode))
        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.bufferCapacity, 7)
        XCTAssertEqual(snapshot.device.thermal, .serious)
        XCTAssertEqual(snapshot.samplingRateNominal, 0.05, accuracy: 1e-12)
    }
}

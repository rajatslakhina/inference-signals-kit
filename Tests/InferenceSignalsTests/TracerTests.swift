import XCTest
@testable import InferenceSignals

final class TracerTests: XCTestCase {

    private struct Harness {
        let clock = ManualClock()
        let environment = StaticEnvelopeProvider()
        let sink = InMemorySink()
        let collector: SignalCollector
        let tracer: SessionTracer

        init(tailBudget: Nanoseconds = .seconds(2), sampling: SamplingPolicy = .keepEverything) throws {
            collector = try SignalCollector(sink: sink,
                                            buffer: try PriorityRingBuffer(capacity: 1_000),
                                            samplingPolicy: sampling,
                                            tailPolicy: TailPolicy(defaultBudget: tailBudget))
            tracer = SessionTracer(sessionID: Fixtures.session,
                                   initialProfile: Fixtures.planner,
                                   tier: .onDevice,
                                   clock: clock,
                                   environment: environment,
                                   collector: collector,
                                   tailPolicy: TailPolicy(defaultBudget: tailBudget))
        }

        func buffered() -> [SignalRecord] { collector.peekBuffer() }
    }

    func testLatencyQuartetIsMeasuredFromTheClock() throws {
        let h = try Harness()
        h.tracer.start()
        let handle = try h.tracer.enqueue(requestID: .literal("r1"), shape: Fixtures.shape())
        h.clock.advance(.milliseconds(30))            // queue wait
        try h.tracer.markRunning(handle)
        h.clock.advance(.milliseconds(120))           // TTFT
        try h.tracer.markFirstToken(handle)
        h.clock.advance(.milliseconds(500))           // generation
        try h.tracer.complete(handle, outputTokens: 100)

        let completion = try XCTUnwrap(h.buffered().last)
        guard case .inferenceCompleted(let sample, _) = completion.payload else {
            return XCTFail("expected completion, got \(completion.payload)")
        }
        XCTAssertEqual(sample.queueWait, .milliseconds(30))
        XCTAssertEqual(sample.timeToFirstToken, .milliseconds(120))
        XCTAssertEqual(sample.total, .milliseconds(620))
        XCTAssertEqual(try XCTUnwrap(sample.tokensPerSecond), 200, accuracy: 1e-9)
        XCTAssertEqual(completion.recordClass, .nominal)
        XCTAssertEqual(h.tracer.openRequests, 0)
    }

    func testTokensPerSecondIsNilWhenGenerationIsInstantOrEmpty() {
        let instant = LatencySample(queueWait: .zero, timeToFirstToken: .milliseconds(5), total: .milliseconds(5), outputTokens: 10)
        XCTAssertNil(instant.tokensPerSecond)
        let empty = LatencySample(queueWait: .zero, timeToFirstToken: .zero, total: .milliseconds(5), outputTokens: 0)
        XCTAssertNil(empty.tokensPerSecond)
        XCTAssertEqual(LatencySample(queueWait: .zero, timeToFirstToken: .zero, total: .zero, outputTokens: -4).outputTokens, 0)
    }

    func testCompletionWithoutIntermediateMarksStillProducesSaneNumbers() throws {
        let h = try Harness()
        h.tracer.start()
        let handle = try h.tracer.enqueue(requestID: .literal("r1"), shape: Fixtures.shape())
        h.clock.advance(.milliseconds(80))
        try h.tracer.complete(handle, outputTokens: 5)
        guard case .inferenceCompleted(let sample, _) = try XCTUnwrap(h.buffered().last).payload else {
            return XCTFail("expected completion")
        }
        XCTAssertEqual(sample.queueWait, .zero)
        XCTAssertEqual(sample.timeToFirstToken, .milliseconds(80))
        XCTAssertEqual(sample.total, .milliseconds(80))
    }

    func testTailClassificationUsesTheProfileBudget() throws {
        let h = try Harness(tailBudget: .milliseconds(500))
        h.tracer.start()
        let handle = try h.tracer.enqueue(requestID: .literal("slow"), shape: Fixtures.shape())
        try h.tracer.markRunning(handle)
        h.clock.advance(.milliseconds(501))
        try h.tracer.complete(handle, outputTokens: 1)
        XCTAssertEqual(h.buffered().last?.recordClass, .tail)

        let fast = try h.tracer.enqueue(requestID: .literal("fast"), shape: Fixtures.shape())
        try h.tracer.markRunning(fast)
        h.clock.advance(.milliseconds(500))
        try h.tracer.complete(fast, outputTokens: 1)
        XCTAssertEqual(h.buffered().last?.recordClass, .nominal)
    }

    func testPerProfileBudgetOverridesDefault() {
        let policy = TailPolicy(defaultBudget: .seconds(1), budgets: [Fixtures.planner: .seconds(5)])
        XCTAssertEqual(policy.classify(total: .seconds(2), profile: Fixtures.planner), .nominal)
        XCTAssertEqual(policy.classify(total: .seconds(2), profile: Fixtures.executor), .tail)
    }

    func testAttributionIsFrozenAtEnqueue() throws {
        let h = try Harness()
        h.environment.set(DeviceEnvelope(thermal: .serious, energy: .lowPowerMode))
        h.tracer.start()
        let handle = try h.tracer.enqueue(requestID: .literal("r1"), shape: Fixtures.shape())
        // The session moves on and the device cools down before the request
        // finishes — neither may rewrite what the request is attributed to.
        h.tracer.switchProfile(to: Fixtures.executor)
        h.environment.set(.nominal)
        try h.tracer.markRunning(handle)
        try h.tracer.recordToolCall(handle, ToolCallSignature(toolName: "t", argumentsDigest: Digest(string: "a")))
        try h.tracer.complete(handle, outputTokens: 3)

        let records = h.buffered().filter { $0.requestID?.rawValue == "r1" }
        XCTAssertEqual(records.count, 2)
        for record in records {
            XCTAssertEqual(record.profile, Fixtures.planner)
            XCTAssertEqual(record.device, DeviceEnvelope(thermal: .serious, energy: .lowPowerMode))
        }
        // …while the session-level switch record carries the new profile.
        let switched = try XCTUnwrap(h.buffered().first { if case .profileSwitched = $0.payload { return true } else { return false } })
        XCTAssertEqual(switched.profile, Fixtures.executor)
        XCTAssertEqual(switched.payload, .profileSwitched(from: Fixtures.planner))
        XCTAssertEqual(h.tracer.currentProfile, Fixtures.executor)
    }

    func testFailureEmitsAnErrorRecordWithElapsedTime() throws {
        let h = try Harness()
        h.tracer.start()
        let handle = try h.tracer.enqueue(requestID: .literal("r1"), shape: Fixtures.shape())
        h.clock.advance(.milliseconds(70))
        try h.tracer.fail(handle, .guardrailRefusal)
        let record = try XCTUnwrap(h.buffered().last)
        XCTAssertEqual(record.recordClass, .error)
        XCTAssertEqual(record.payload, .inferenceFailed(.guardrailRefusal, Fixtures.shape(), elapsed: .milliseconds(70)))
        XCTAssertEqual(h.tracer.openRequests, 0)
        XCTAssertThrowsSpecific(try h.tracer.fail(handle, .cancelled), TracerError.unknownHandle)
    }

    func testToolLoopEmitsOneErrorRecordThenKeepsTheRequestOpen() throws {
        let h = try Harness()
        h.tracer.start()
        let handle = try h.tracer.enqueue(requestID: .literal("loop"), shape: Fixtures.shape())
        try h.tracer.markRunning(handle)
        let call = ToolCallSignature(toolName: "read", argumentsDigest: Digest(string: "same"))
        var verdicts: [ToolLoopVerdict] = []
        for _ in 0..<5 { verdicts.append(try h.tracer.recordToolCall(handle, call)) }
        XCTAssertEqual(verdicts[2], .cycleDetected(period: 1, repetitions: 3))
        XCTAssertTrue(verdicts[3].isNonTermination)

        let errors = h.buffered().filter { $0.recordClass == .error }
        XCTAssertEqual(errors.count, 1, "the loop is reported once, not on every subsequent call")
        XCTAssertEqual(errors.first?.payload, .inferenceFailed(.toolLoopNonTermination, Fixtures.shape(), elapsed: .zero))
        XCTAssertEqual(h.buffered().filter { if case .toolCall = $0.payload { return true } else { return false } }.count, 5)
        XCTAssertEqual(h.tracer.openRequests, 1)
        try h.tracer.complete(handle, outputTokens: 1)
        XCTAssertEqual(h.tracer.openRequests, 0)
    }

    func testEndCancelsOpenRequestsSoNoneVanish() throws {
        let h = try Harness()
        h.tracer.start()
        _ = try h.tracer.enqueue(requestID: .literal("a"), shape: Fixtures.shape())
        _ = try h.tracer.enqueue(requestID: .literal("b"), shape: Fixtures.shape())
        h.tracer.end()
        let cancelled = h.buffered().filter {
            if case .inferenceFailed(.cancelled, _, _) = $0.payload { return true } else { return false }
        }
        XCTAssertEqual(cancelled.map { $0.requestID?.rawValue }, ["a", "b"])
        XCTAssertEqual(h.buffered().last?.payload, .sessionEnded(requestCount: 2))
        XCTAssertEqual(h.tracer.openRequests, 0)
        XCTAssertThrowsSpecific(try h.tracer.enqueue(requestID: .literal("c"), shape: Fixtures.shape()),
                                TracerError.sessionAlreadyEnded)
        // `end` and `start` are idempotent.
        h.tracer.end()
        h.tracer.start()
        XCTAssertEqual(h.buffered().filter { $0.payload == .sessionStarted }.count, 1)
        XCTAssertEqual(h.buffered().filter { if case .sessionEnded = $0.payload { return true } else { return false } }.count, 1)
    }

    func testInvalidTransitionsThrowInsteadOfCorruptingTimings() throws {
        let h = try Harness()
        XCTAssertThrowsSpecific(try h.tracer.enqueue(requestID: .literal("x"), shape: Fixtures.shape()),
                                TracerError.sessionNotStarted)
        h.tracer.start()
        let handle = try h.tracer.enqueue(requestID: .literal("x"), shape: Fixtures.shape())
        XCTAssertThrowsSpecific(try h.tracer.markFirstToken(handle),
                                TracerError.invalidTransition(from: .enqueued, event: "markFirstToken"))
        try h.tracer.markRunning(handle)
        XCTAssertThrowsSpecific(try h.tracer.markRunning(handle),
                                TracerError.invalidTransition(from: .running, event: "markRunning"))
        try h.tracer.markFirstToken(handle)
        h.clock.advance(.milliseconds(10))
        try h.tracer.markFirstToken(handle) // idempotent: first timestamp wins
        try h.tracer.complete(handle, outputTokens: 2)
        XCTAssertThrowsSpecific(try h.tracer.complete(handle, outputTokens: 2), TracerError.unknownHandle)
        XCTAssertThrowsSpecific(try h.tracer.recordToolCall(handle, ToolCallSignature(toolName: "t", argumentsDigest: Digest(string: "a"))),
                                TracerError.unknownHandle)
    }

    func testOpenRequestsAreBoundedAndTheOldestIsCancelledWithARecord() throws {
        let h = try Harness()
        let tracer = SessionTracer(sessionID: Fixtures.session, initialProfile: Fixtures.planner, tier: .onDevice,
                                   clock: h.clock, environment: h.environment, collector: h.collector,
                                   tailPolicy: TailPolicy(defaultBudget: .seconds(1)), maximumOpenRequests: 3)
        tracer.start()
        var handles: [RequestHandle] = []
        for i in 0..<5 {
            handles.append(try tracer.enqueue(requestID: .literal("r\(i)"), shape: Fixtures.shape()))
        }
        XCTAssertEqual(tracer.openRequests, 3, "never more than the cap")
        let cancelled = h.buffered().filter {
            if case .inferenceFailed(.cancelled, _, _) = $0.payload { return true } else { return false }
        }
        XCTAssertEqual(cancelled.map { $0.requestID?.rawValue }, ["r0", "r1"], "oldest first, each with a record")
        // The evicted handles are dead; the survivors still work.
        XCTAssertThrowsSpecific(try tracer.markRunning(handles[0]), TracerError.unknownHandle)
        XCTAssertNoThrow(try tracer.markRunning(handles[4]))
        XCTAssertEqual(SessionTracer(sessionID: Fixtures.session, initialProfile: Fixtures.planner, tier: .onDevice,
                                     clock: h.clock, environment: h.environment, collector: h.collector,
                                     tailPolicy: TailPolicy(defaultBudget: .seconds(1)),
                                     maximumOpenRequests: 0).maximumOpenRequests, 1)
    }

    func testProfileSwitchIsIgnoredOutsideAnOpenSession() throws {
        let h = try Harness()
        h.tracer.switchProfile(to: Fixtures.executor)          // before start: no record
        XCTAssertEqual(h.buffered(), [])
        XCTAssertEqual(h.tracer.currentProfile, Fixtures.planner)
        h.tracer.start()
        h.tracer.switchProfile(to: Fixtures.executor)          // open: recorded
        XCTAssertEqual(h.tracer.currentProfile, Fixtures.executor)
        h.tracer.end()
        h.tracer.switchProfile(to: Fixtures.planner)           // after end: no record
        XCTAssertEqual(h.tracer.currentProfile, Fixtures.executor)
        let switches = h.buffered().filter { if case .profileSwitched = $0.payload { return true } else { return false } }
        XCTAssertEqual(switches.count, 1)
    }

    /// A sampler that calls back into the tracer from inside the collector.
    /// If any tracer method called the collector while holding the tracer's
    /// (non-recursive) lock, this would deadlock; the watchdog turns that
    /// into a failure instead of a hung test run.
    func testTracerNeverHoldsItsLockWhileCallingTheCollector() throws {
        final class ReentrantSampler: SamplingDeciding, @unchecked Sendable {
            let lock = NSLock()
            var tracer: SessionTracer?
            var observed = 0
            func decide(_ record: SignalRecord) -> SamplingDecision {
                lock.lock(); defer { lock.unlock() }
                if let tracer {
                    _ = tracer.currentProfile
                    _ = tracer.openRequests
                    observed += 1
                }
                return .keep(.withinRate(1))
            }
        }
        let sampler = ReentrantSampler()
        let collector = try SignalCollector(sink: InMemorySink(),
                                            buffer: try PriorityRingBuffer(capacity: 100),
                                            sampler: sampler,
                                            tailPolicy: TailPolicy(defaultBudget: .seconds(1)))
        let clock = ManualClock()
        let tracer = SessionTracer(sessionID: Fixtures.session, initialProfile: Fixtures.planner, tier: .onDevice,
                                   clock: clock, environment: StaticEnvelopeProvider(), collector: collector,
                                   tailPolicy: TailPolicy(defaultBudget: .seconds(1)), maximumOpenRequests: 2)
        sampler.lock.lock(); sampler.tracer = tracer; sampler.lock.unlock()

        let finished = DispatchSemaphore(value: 0)
        let worker = Thread {
            defer { finished.signal() }
            tracer.start()
            tracer.switchProfile(to: Fixtures.executor)
            guard let a = try? tracer.enqueue(requestID: .literal("a"), shape: Fixtures.shape()),
                  let b = try? tracer.enqueue(requestID: .literal("b"), shape: Fixtures.shape()),
                  let c = try? tracer.enqueue(requestID: .literal("c"), shape: Fixtures.shape()) // evicts a
            else { return }
            _ = a
            try? tracer.markRunning(b)
            _ = try? tracer.recordToolCall(b, ToolCallSignature(toolName: "t", argumentsDigest: Digest(string: "x")))
            try? tracer.complete(b, outputTokens: 1)
            try? tracer.fail(c, .guardrailRefusal)
            tracer.end()
        }
        worker.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "tracer deadlocked calling the collector under its own lock")
        sampler.lock.lock(); let observed = sampler.observed; sampler.lock.unlock()
        // start, switch, a-cancelled, toolCall, complete, fail, end = 7 ingests, each re-entered the tracer.
        XCTAssertEqual(observed, 7)
    }

    func testHandlesAreNotTransferableBetweenTracers() throws {
        let a = try Harness()
        let b = try Harness()
        a.tracer.start(); b.tracer.start()
        let handle = try a.tracer.enqueue(requestID: .literal("x"), shape: Fixtures.shape())
        _ = try b.tracer.enqueue(requestID: .literal("x"), shape: Fixtures.shape())
        XCTAssertThrowsSpecific(try b.tracer.markRunning(handle), TracerError.unknownHandle)
    }

    func testOutOfOrderClockNeverProducesNegativeDurations() throws {
        let h = try Harness()
        h.tracer.start()
        let handle = try h.tracer.enqueue(requestID: .literal("x"), shape: Fixtures.shape())
        h.clock.advance(.milliseconds(50))
        try h.tracer.markRunning(handle)
        // A clock that goes backwards is a bug elsewhere; the tracer must
        // clamp rather than emit a negative duration or trap.
        h.clock.rewind(to: 0)
        try h.tracer.markFirstToken(handle)
        try h.tracer.complete(handle, outputTokens: 1)
        guard case .inferenceCompleted(let sample, _) = try XCTUnwrap(h.buffered().last).payload else {
            return XCTFail("expected completion")
        }
        XCTAssertEqual(sample.queueWait, .milliseconds(50))
        XCTAssertEqual(sample.timeToFirstToken, .zero)
        XCTAssertEqual(sample.total, .zero)
        XCTAssertNil(sample.tokensPerSecond)
    }
}

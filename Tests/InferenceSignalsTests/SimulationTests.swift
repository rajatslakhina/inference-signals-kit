import XCTest
@testable import InferenceSignals

final class SimulationTests: XCTestCase {

    private struct Run {
        let sink = InMemorySink(capacity: 1_000_000)
        let clock = ManualClock()
        let environment = StaticEnvelopeProvider()
        let collector: SignalCollector
        let tracer: SessionTracer
        var executor: SimulatedExecutor

        init(seed: UInt64, sampling: SamplingPolicy = .keepEverything) throws {
            let tail = TailPolicy(defaultBudget: .seconds(3))
            collector = try SignalCollector(sink: sink,
                                            buffer: try PriorityRingBuffer(capacity: 100_000),
                                            samplingPolicy: sampling,
                                            tailPolicy: tail)
            tracer = SessionTracer(sessionID: .literal("sim"), initialProfile: SimulatedProfile.planner.id,
                                   tier: .onDevice, clock: clock, environment: environment,
                                   collector: collector, tailPolicy: tail)
            executor = SimulatedExecutor(seed: seed)
            tracer.start()
        }

        mutating func drive(requests: Int) throws -> [SimulatedOutcome] {
            var outcomes: [SimulatedOutcome] = []
            for i in 0..<requests {
                let profile = SimulatedProfile.standard[i % SimulatedProfile.standard.count]
                tracer.switchProfile(to: profile.id)
                outcomes.append(try executor.run(profile: profile, on: tracer, clock: clock))
            }
            return outcomes
        }
    }

    func testSameSeedProducesIdenticalRecords() throws {
        var a = try Run(seed: 11)
        var b = try Run(seed: 11)
        _ = try a.drive(requests: 300)
        _ = try b.drive(requests: 300)
        XCTAssertEqual(a.collector.peekBuffer(), b.collector.peekBuffer())
        var c = try Run(seed: 12)
        _ = try c.drive(requests: 300)
        XCTAssertNotEqual(a.collector.peekBuffer(), c.collector.peekBuffer())
    }

    func testEveryRecordClassAndAToolLoopAreReachable() throws {
        var run = try Run(seed: 2026)
        let outcomes = try run.drive(requests: 600)
        let records = run.collector.peekBuffer()
        let classes = Set(records.map(\.recordClass))
        XCTAssertEqual(classes, Set(RecordClass.allCases), "the demo must be able to show all three classes")
        XCTAssertTrue(outcomes.contains { if case .loopDetected = $0 { return true } else { return false } })
        XCTAssertTrue(outcomes.contains { if case .failed = $0 { return true } else { return false } })
        let loopErrors = records.filter {
            if case .inferenceFailed(.toolLoopNonTermination, _, _) = $0.payload { return true } else { return false }
        }
        XCTAssertFalse(loopErrors.isEmpty)
        XCTAssertEqual(run.tracer.openRequests, 0, "the simulator never leaves a request open")
    }

    func testAggregatesPopulateForEveryProfile() throws {
        var run = try Run(seed: 5)
        _ = try run.drive(requests: 300)
        let snapshot = run.collector.snapshot()
        for profile in SimulatedProfile.standard {
            let signals = try XCTUnwrap(snapshot.profiles[profile.id], "\(profile.id)")
            XCTAssertEqual(signals.requestsStarted, 100)
            XCTAssertGreaterThan(signals.completions, 50)
            XCTAssertNotNil(signals.timeToFirstTokenMilliseconds.p95)
            XCTAssertNotNil(signals.tokensPerSecond.p50)
            XCTAssertNotNil(signals.contextHeadroom.mean)
        }
        XCTAssertEqual(snapshot.profiles[SimulatedProfile.reviewer.id]?.toolCalls, 0)
        XCTAssertGreaterThan(snapshot.profiles[SimulatedProfile.executor.id]?.toolCalls ?? 0, 100)
    }

    func testPressureSlowsTheSimulatedExecutorDown() throws {
        var cool = try Run(seed: 1)
        _ = try cool.drive(requests: 200)
        var hot = try Run(seed: 1)
        hot.executor.pressure = DeviceEnvelope(thermal: .critical, energy: .lowPowerMode)
        _ = try hot.drive(requests: 200)
        XCTAssertGreaterThan(hot.clock.now().nanoseconds, cool.clock.now().nanoseconds * 2)
    }

    func testStandardProfilesAreWellFormed() {
        for profile in SimulatedProfile.standard {
            XCTAssertGreaterThan(profile.contextWindowTokens, 0)
            XCTAssertLessThanOrEqual(profile.promptTokens.upperBound, profile.contextWindowTokens)
            XCTAssertGreaterThan(profile.tokensPerSecond.lowerBound, 0)
            XCTAssertTrue(profile.toolCalls.upperBound == 0 || !profile.toolNames.isEmpty)
        }
        let clamped = SimulatedProfile(id: SimulatedProfile.planner.id, contextWindowTokens: 0,
                                       promptTokens: 1...2, outputTokens: 1...2, timeToFirstToken: 1...2,
                                       tokensPerSecond: 1...2, toolCalls: 0...0, toolNames: [],
                                       failureRate: 7, tailRate: -1, loopRate: .nan)
        XCTAssertEqual(clamped.contextWindowTokens, 1)
        XCTAssertEqual(clamped.failureRate, 1)
        XCTAssertEqual(clamped.tailRate, 0)
        XCTAssertEqual(clamped.loopRate, 0)
    }

    func testDegenerateProfileRunsWithoutTrapping() throws {
        // Negative ranges would make `rng.next(in: 0...promptTokens)` form an
        // invalid range and trap; the initializer lifts them to zero.
        let degenerate = SimulatedProfile(id: ProfileID(.literal("degenerate")), contextWindowTokens: -5,
                                          promptTokens: -40 ... -10, outputTokens: -3 ... -1,
                                          timeToFirstToken: -9 ... -1, tokensPerSecond: -2 ... -1,
                                          toolCalls: -4 ... -2, toolNames: ["t"],
                                          failureRate: 0, tailRate: 0, loopRate: 1)
        XCTAssertEqual(degenerate.promptTokens, 0...0)
        XCTAssertEqual(degenerate.toolCalls, 0...0)
        XCTAssertEqual(degenerate.tokensPerSecond, 0...0)
        var run = try Run(seed: 9)
        run.tracer.switchProfile(to: degenerate.id)
        for _ in 0..<50 {
            let outcome = try run.executor.run(profile: degenerate, on: run.tracer, clock: run.clock)
            if case .loopDetected = outcome { XCTFail("no tool calls can be drawn from 0...0") }
        }
        XCTAssertEqual(run.tracer.openRequests, 0)
        XCTAssertEqual(run.collector.snapshot().profiles[degenerate.id]?.completions, 50)
    }
}

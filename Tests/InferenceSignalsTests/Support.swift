import XCTest
@testable import InferenceSignals

enum Fixtures {
    static let planner = ProfileID(.literal("planner"))
    static let executor = ProfileID(.literal("executor"))
    static let session = Identifier.literal("session-1")

    static func shape(prompt: Int = 1_000, window: Int = 4_096, reused: Int = 0) -> PromptShape {
        PromptShape(promptTokens: prompt,
                    instructionTokens: 200,
                    reusedPrefixTokens: reused,
                    contextWindowTokens: window,
                    toolSetDigest: Digest(unorderedNames: ["a", "b"]))
    }

    static func record(request: String? = "r1",
                       profile: ProfileID = planner,
                       recordClass: RecordClass = .nominal,
                       thermal: ThermalState = .nominal,
                       energy: EnergyState = .unconstrained,
                       at nanos: Int64 = 0,
                       payload: SignalPayload? = nil) -> SignalRecord {
        let sample = LatencySample(queueWait: .milliseconds(5),
                                   timeToFirstToken: .milliseconds(100),
                                   total: .milliseconds(400),
                                   outputTokens: 60)
        let defaultPayload: SignalPayload
        switch recordClass {
        case .error:
            defaultPayload = .inferenceFailed(.guardrailRefusal, shape(), elapsed: .milliseconds(50))
        default:
            defaultPayload = .inferenceCompleted(sample, shape())
        }
        return SignalRecord(sessionID: session,
                            requestID: request.map(Identifier.literal),
                            profile: profile,
                            tier: .onDevice,
                            device: DeviceEnvelope(thermal: thermal, energy: energy),
                            recordedAt: Instant(nanoseconds: nanos),
                            recordClass: recordClass,
                            payload: payload ?? defaultPayload)
    }

    /// A workload with `perState` requests per thermal state, each request
    /// contributing two nominal records (a tool call and a completion), plus
    /// scattered tail and error records. Deterministic.
    static func samplingWorkload(perState: Int = 1_000) -> [SignalRecord] {
        var records: [SignalRecord] = []
        var rng = SplitMix64(seed: 7)
        var serial = 0
        for state in ThermalState.allCases {
            for _ in 0..<perState {
                serial += 1
                let id = "req-\(serial)"
                records.append(record(request: id, thermal: state, at: Int64(serial) * 10,
                                      payload: .toolCall(toolDigest: Digest(string: "t"), sequence: 1)))
                records.append(record(request: id, thermal: state, at: Int64(serial) * 10 + 1))
                let roll = rng.nextUnit()
                if roll < 0.05 {
                    records.append(record(request: id, recordClass: .error, thermal: state, at: Int64(serial) * 10 + 2))
                } else if roll < 0.10 {
                    records.append(record(request: id, recordClass: .tail, thermal: state, at: Int64(serial) * 10 + 2))
                }
            }
        }
        return records
    }
}

/// A test double for the sink that can be told to suspend until released,
/// or to fail.
actor GatedSink: SignalSink {
    private(set) var delivered: [SignalRecord] = []
    private(set) var deliveries = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var gated: Bool
    var failing = false

    init(gated: Bool = false) { self.gated = gated }

    func deliver(_ records: [SignalRecord]) async throws {
        deliveries += 1
        if gated {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        if failing { throw SinkFailure() }
        delivered.append(contentsOf: records)
    }

    func release() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func setFailing(_ value: Bool) { failing = value }
    func setGated(_ value: Bool) { gated = value }
    var waiting: Int { waiters.count }

    struct SinkFailure: Error {}
}

func XCTAssertThrowsSpecific<E: Error & Equatable>(_ expression: @autoclosure () throws -> some Any,
                                                   _ expected: E,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) {
    do {
        _ = try expression()
        XCTFail("Expected \(expected) to be thrown", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}

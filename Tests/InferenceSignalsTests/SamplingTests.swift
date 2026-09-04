import XCTest
@testable import InferenceSignals

// MARK: - Deliberately broken deciders (negative controls)

/// Drops errors under pressure — the classic "sample everything at 10%" bug.
struct FlatRateSampler: SamplingDeciding {
    let rate: Double
    func decide(_ record: SignalRecord) -> SamplingDecision {
        let unit = Sampler.unit(for: record.samplingKey)
        return unit < rate ? .keep(.withinRate(rate)) : .drop(keepProbability: rate)
    }
}

/// Keeps protected classes but decides nominal records with a per-record
/// coin, so one request's tool call and completion can disagree.
final class IncoherentSampler: SamplingDeciding, @unchecked Sendable {
    let policy: SamplingPolicy
    private let lock = NSLock()
    private var rng = SplitMix64(seed: 99)
    init(policy: SamplingPolicy) { self.policy = policy }
    func decide(_ record: SignalRecord) -> SamplingDecision {
        if record.recordClass != .nominal { return .keep(.protectedClass(record.recordClass)) }
        let probability = policy.keepProbability(for: .nominal, device: record.device)
        lock.lock(); defer { lock.unlock() }
        return rng.nextUnit() < probability ? .keep(.withinRate(probability)) : .drop(keepProbability: probability)
    }
}

/// Coherent and class-safe, but keeps half of what the policy asks for.
struct HalfRateSampler: SamplingDeciding {
    let inner: Sampler
    func decide(_ record: SignalRecord) -> SamplingDecision {
        if record.recordClass != .nominal { return .keep(.protectedClass(record.recordClass)) }
        let probability = inner.policy.keepProbability(for: .nominal, device: record.device) / 2
        let unit = Sampler.unit(for: record.samplingKey)
        return unit < probability ? .keep(.withinRate(probability)) : .drop(keepProbability: probability)
    }
}

/// The first version of `Sampler`: takes FNV-1a's top bits directly. Kept
/// as a negative control so the audit's keep-rate check is proven to catch
/// a non-uniform key mapping.
struct UnmixedSampler: SamplingDeciding {
    let policy: SamplingPolicy
    func decide(_ record: SignalRecord) -> SamplingDecision {
        if record.recordClass != .nominal { return .keep(.protectedClass(record.recordClass)) }
        let probability = policy.keepProbability(for: .nominal, device: record.device)
        if probability >= 1 { return .keep(.withinRate(1)) }
        let unit = Double(record.samplingKey.value >> 11) / Double(1 << 53)
        return unit < probability ? .keep(.withinRate(probability)) : .drop(keepProbability: probability)
    }
}

final class SamplingTests: XCTestCase {

    // MARK: Policy validation

    func testPolicyRejectsMissingStatesAndBadRates() {
        XCTAssertThrowsSpecific(try SamplingPolicy(nominalKeepRate: [.nominal: 1, .fair: 1, .serious: 1]),
                                SamplingPolicy.ConfigurationError.missingThermalState(.critical))
        XCTAssertThrowsSpecific(try SamplingPolicy(nominalKeepRate: [.nominal: 1, .fair: 1.5, .serious: 1, .critical: 1]),
                                SamplingPolicy.ConfigurationError.rateOutOfRange(.fair, 1.5))
        XCTAssertThrowsSpecific(try SamplingPolicy(nominalKeepRate: [.nominal: 1, .fair: -0.1, .serious: 1, .critical: 1]),
                                SamplingPolicy.ConfigurationError.rateOutOfRange(.fair, -0.1))
        // NaN is not equal to itself, so assert on the case rather than the value.
        XCTAssertThrowsError(try SamplingPolicy(nominalKeepRate: [.nominal: 1, .fair: .nan, .serious: 1, .critical: 1])) { error in
            guard case SamplingPolicy.ConfigurationError.rateOutOfRange(.fair, let rate)? = error as? SamplingPolicy.ConfigurationError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(rate.isNaN)
        }
        XCTAssertThrowsSpecific(try SamplingPolicy(nominalKeepRate: [.nominal: 1, .fair: 1, .serious: 1, .critical: 1],
                                                   lowPowerMultiplier: 0),
                                SamplingPolicy.ConfigurationError.multiplierOutOfRange(0))
    }

    func testPolicyRejectsRateThatIncreasesWithPressure() {
        // Keeping *more* when hotter is the bug the validation exists for.
        XCTAssertThrowsSpecific(try SamplingPolicy(nominalKeepRate: [.nominal: 0.5, .fair: 0.6, .serious: 0.1, .critical: 0.1]),
                                SamplingPolicy.ConfigurationError.rateIncreasesWithPressure(from: .nominal, to: .fair))
        XCTAssertThrowsSpecific(try SamplingPolicy(nominalKeepRate: [.nominal: 1, .fair: 0.5, .serious: 0.1, .critical: 0.2]),
                                SamplingPolicy.ConfigurationError.rateIncreasesWithPressure(from: .serious, to: .critical))
    }

    func testStandardPolicyIsWhatTheReadmeSays() {
        let policy = SamplingPolicy.standard
        XCTAssertEqual(policy.keepProbability(for: .nominal, device: .nominal), 1.0)
        XCTAssertEqual(policy.keepProbability(for: .nominal, device: DeviceEnvelope(thermal: .fair, energy: .unconstrained)), 0.5)
        XCTAssertEqual(policy.keepProbability(for: .nominal, device: DeviceEnvelope(thermal: .serious, energy: .unconstrained)), 0.1)
        XCTAssertEqual(policy.keepProbability(for: .nominal, device: DeviceEnvelope(thermal: .critical, energy: .unconstrained)), 0.02)
        XCTAssertEqual(policy.keepProbability(for: .nominal, device: DeviceEnvelope(thermal: .fair, energy: .lowPowerMode)), 0.25)
        XCTAssertEqual(policy.lowPowerMultiplier, 0.5)
    }

    func testProtectedClassesAreAlwaysOne() {
        let policy = SamplingPolicy.standard
        for thermal in ThermalState.allCases {
            for energy in EnergyState.allCases {
                let device = DeviceEnvelope(thermal: thermal, energy: energy)
                XCTAssertEqual(policy.keepProbability(for: .tail, device: device), 1)
                XCTAssertEqual(policy.keepProbability(for: .error, device: device), 1)
            }
        }
    }

    // MARK: Sampler

    func testDecisionIsDeterministicAndRequestCoherent() throws {
        // At `.fair` (50%) some requests are kept and some dropped. Find one
        // of each and prove the tool call and the completion of the *same*
        // request always agree — an assertion that `false == false` at a 2%
        // rate would not distinguish coherence from "drop everything".
        let sampler = Sampler()
        var keptRequest: String?
        var droppedRequest: String?
        for i in 0..<200 {
            let id = "req-\(i)"
            let kept = sampler.decide(Fixtures.record(request: id, thermal: .fair)).isKept
            if kept, keptRequest == nil { keptRequest = id }
            if !kept, droppedRequest == nil { droppedRequest = id }
        }
        let kept = try XCTUnwrap(keptRequest)
        let dropped = try XCTUnwrap(droppedRequest)
        for id in [kept, dropped] {
            let toolCall = Fixtures.record(request: id, thermal: .fair,
                                           payload: .toolCall(toolDigest: Digest(string: "x"), sequence: 1))
            let completion = Fixtures.record(request: id, thermal: .fair)
            XCTAssertEqual(sampler.decide(toolCall).isKept, id == kept)
            XCTAssertEqual(sampler.decide(completion).isKept, id == kept)
            XCTAssertEqual(sampler.decide(toolCall), sampler.decide(toolCall))
        }
    }

    func testSessionLifecycleRecordsShareOneDecision() throws {
        // Records with no request key on the session, so a session's
        // lifecycle rows are kept or dropped as a block. Checked at `.fair`
        // (50%) over many sessions so that both outcomes occur and the
        // assertion is coherence, not "everything was dropped".
        let sampler = Sampler()
        var keptSessions = 0
        var droppedSessions = 0
        for i in 0..<100 {
            let session = Identifier.literal("session-\(i)")
            func record(_ payload: SignalPayload) -> SignalRecord {
                SignalRecord(sessionID: session, requestID: nil, profile: Fixtures.planner, tier: .onDevice,
                             device: DeviceEnvelope(thermal: .fair, energy: .unconstrained),
                             recordedAt: Instant(nanoseconds: Int64(i)), recordClass: .nominal, payload: payload)
            }
            let rows = [record(.sessionStarted),
                        record(.profileSwitched(from: Fixtures.planner)),
                        record(.sessionEnded(requestCount: 3))]
            XCTAssertEqual(Set(rows.map(\.samplingKey)).count, 1)
            let decisions = Set(rows.map { sampler.decide($0).isKept })
            XCTAssertEqual(decisions.count, 1, "session \(i) was partially kept")
            if decisions.contains(true) { keptSessions += 1 } else { droppedSessions += 1 }
        }
        XCTAssertGreaterThan(keptSessions, 20)
        XCTAssertGreaterThan(droppedSessions, 20)
    }

    func testErrorsSurviveCriticalPressureAndNominalDoesNot() {
        let sampler = Sampler()
        var keptNominal = 0
        var keptErrors = 0
        for i in 0..<500 {
            let nominal = Fixtures.record(request: "n-\(i)", thermal: .critical, energy: .lowPowerMode)
            let error = Fixtures.record(request: "e-\(i)", recordClass: .error, thermal: .critical, energy: .lowPowerMode)
            if sampler.decide(nominal).isKept { keptNominal += 1 }
            if sampler.decide(error).isKept { keptErrors += 1 }
        }
        XCTAssertEqual(keptErrors, 500)
        // 1% keep rate: expect ~5 of 500, certainly fewer than 30.
        XCTAssertLessThan(keptNominal, 30)
        XCTAssertEqual(sampler.decide(Fixtures.record(recordClass: .error, thermal: .critical)),
                       .keep(.protectedClass(.error)))
    }

    func testZeroRateDropsEveryNominalRecordButNothingElse() throws {
        let policy = try SamplingPolicy(nominalKeepRate: [.nominal: 0, .fair: 0, .serious: 0, .critical: 0])
        let sampler = Sampler(policy: policy)
        XCTAssertEqual(sampler.decide(Fixtures.record()), .drop(keepProbability: 0))
        XCTAssertTrue(sampler.decide(Fixtures.record(recordClass: .tail)).isKept)
    }

    // MARK: Audit — positive and negative controls

    func testAuditPassesForTheShippedSampler() {
        let records = Fixtures.samplingWorkload()
        let violations = SamplingAudit.verify(Sampler(), policy: .standard, records: records)
        XCTAssertEqual(violations, [], violations.map(\.description).joined(separator: "\n"))
    }

    func testAuditCatchesASamplerThatDropsErrors() {
        let records = Fixtures.samplingWorkload()
        let violations = SamplingAudit.verify(FlatRateSampler(rate: 0.1), policy: .standard, records: records)
        XCTAssertTrue(violations.contains { if case .protectedRecordDropped = $0 { return true } else { return false } })
        XCTAssertTrue(violations.contains { if case .nominalDroppedAtFullRate = $0 { return true } else { return false } })
    }

    func testAuditCatchesAnIncoherentSampler() {
        let records = Fixtures.samplingWorkload()
        let violations = SamplingAudit.verify(IncoherentSampler(policy: .standard), policy: .standard, records: records)
        XCTAssertTrue(violations.contains { if case .incoherentRequest = $0 { return true } else { return false } },
                      violations.map(\.description).joined(separator: "\n"))
    }

    func testAuditCatchesAKeepRateOffTarget() {
        let records = Fixtures.samplingWorkload()
        let violations = SamplingAudit.verify(HalfRateSampler(inner: Sampler()), policy: .standard, records: records)
        // Half of 0.5 is 0.25 at `.fair` — 25 points off, well outside tolerance.
        XCTAssertTrue(violations.contains {
            if case .keepRateOffTarget(let thermal, _, _) = $0 { return thermal == .fair } else { return false }
        }, violations.map(\.description).joined(separator: "\n"))
    }

    func testAuditCatchesTheUnmixedKeyMapping() {
        // Sequential request IDs hash into a narrow band under raw FNV-1a;
        // the shipped sampler mixes the key first. This is the bug the audit
        // found during development, preserved as a regression control.
        let records = Fixtures.samplingWorkload()
        let violations = SamplingAudit.verify(UnmixedSampler(policy: .standard), policy: .standard, records: records)
        XCTAssertTrue(violations.contains { if case .keepRateOffTarget = $0 { return true } else { return false } },
                      violations.map(\.description).joined(separator: "\n"))
    }

    func testUnitMappingIsUniformOverSequentialKeys() {
        var buckets = Array(repeating: 0, count: 10)
        for i in 0..<20_000 {
            let unit = Sampler.unit(for: Digest(string: "req-\(i)"))
            let index = min(9, max(0, Int(unit * 10)))
            buckets[index] += 1
        }
        for count in buckets {
            XCTAssertGreaterThan(count, 1_700, "\(buckets)")
            XCTAssertLessThan(count, 2_300, "\(buckets)")
        }
    }
}

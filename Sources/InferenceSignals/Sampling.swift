import Foundation

// MARK: - Policy

/// How much *nominal* traffic to keep at each thermal state.
///
/// The policy has no entry for `.tail` or `.error` on purpose: those classes
/// are always kept, and making that a structural property of the type —
/// there is no field that could hold a lower rate — is stronger than a
/// comment saying "please don't". Degrading under thermal pressure means
/// thinning the healthy middle of the distribution, never the tail you
/// enabled telemetry to see.
public struct SamplingPolicy: Hashable, Sendable, Codable {
    public let nominalKeepRate: [ThermalState: Double]
    /// Applied on top of the thermal rate in Low Power Mode, in (0, 1].
    public let lowPowerMultiplier: Double

    public enum ConfigurationError: Error, Equatable, Sendable {
        case missingThermalState(ThermalState)
        case rateOutOfRange(ThermalState, Double)
        case rateIncreasesWithPressure(from: ThermalState, to: ThermalState)
        case multiplierOutOfRange(Double)
    }

    /// Validates that every thermal state has a rate in [0, 1], that the
    /// rate never *increases* as pressure rises, and that the low-power
    /// multiplier is in (0, 1].
    public init(nominalKeepRate: [ThermalState: Double], lowPowerMultiplier: Double = 1) throws {
        var previous: (ThermalState, Double)?
        for state in ThermalState.allCases {
            guard let rate = nominalKeepRate[state] else {
                throw ConfigurationError.missingThermalState(state)
            }
            guard rate.isFinite, rate >= 0, rate <= 1 else {
                throw ConfigurationError.rateOutOfRange(state, rate)
            }
            if let previous, rate > previous.1 {
                throw ConfigurationError.rateIncreasesWithPressure(from: previous.0, to: state)
            }
            previous = (state, rate)
        }
        guard lowPowerMultiplier.isFinite, lowPowerMultiplier > 0, lowPowerMultiplier <= 1 else {
            throw ConfigurationError.multiplierOutOfRange(lowPowerMultiplier)
        }
        self.nominalKeepRate = nominalKeepRate
        self.lowPowerMultiplier = lowPowerMultiplier
    }

    /// 100% → 50% → 10% → 2% of nominal traffic as the device heats up;
    /// halved again in Low Power Mode.
    public static let standard: SamplingPolicy = {
        // These literals satisfy every validation rule above; a `try?`
        // fallback to "keep everything" keeps a future typo from becoming
        // a launch crash while still being obviously wrong on a dashboard.
        (try? SamplingPolicy(nominalKeepRate: [.nominal: 1.0, .fair: 0.5, .serious: 0.1, .critical: 0.02],
                             lowPowerMultiplier: 0.5)) ?? .keepEverything
    }()

    public static let keepEverything: SamplingPolicy = {
        // Cannot fail: all rates are 1, which is in range and monotone.
        (try? SamplingPolicy(nominalKeepRate: [.nominal: 1, .fair: 1, .serious: 1, .critical: 1]))
            ?? SamplingPolicy(uncheckedRate: 1)
    }()

    private init(uncheckedRate: Double) {
        nominalKeepRate = Dictionary(uniqueKeysWithValues: ThermalState.allCases.map { ($0, uncheckedRate) })
        lowPowerMultiplier = 1
    }

    /// Keep probability for a record class under a device envelope.
    /// `.tail` and `.error` are 1 unconditionally.
    public func keepProbability(for recordClass: RecordClass, device: DeviceEnvelope) -> Double {
        switch recordClass {
        case .tail, .error:
            return 1
        case .nominal:
            let base = nominalKeepRate[device.thermal] ?? 1
            let multiplier = device.energy == .lowPowerMode ? lowPowerMultiplier : 1
            return min(1, max(0, base * multiplier))
        }
    }
}

// MARK: - Decision

public enum SamplingDecision: Hashable, Sendable {
    case keep(SamplingReason)
    case drop(keepProbability: Double)

    public var isKept: Bool {
        if case .keep = self { return true }
        return false
    }
}

public enum SamplingReason: Hashable, Sendable {
    /// The record's class is never sampled out.
    case protectedClass(RecordClass)
    /// A nominal record whose request hashed under the keep rate.
    case withinRate(Double)
}

/// Anything that decides whether a record survives. The library ships one
/// implementation; the protocol exists so `SamplingAudit` can be pointed at
/// a deliberately wrong one in tests.
///
/// `decide` is called by `SignalCollector.ingest` while the collector's
/// lock is held. It must be a pure function of the record: an
/// implementation that calls back into the collector would deadlock.
public protocol SamplingDeciding: Sendable {
    func decide(_ record: SignalRecord) -> SamplingDecision
}

/// Deterministic, request-coherent head sampling.
///
/// The decision is a pure function of `(record.samplingKey, record.device,
/// record.recordClass)`. Because `SessionTracer` stamps every record of a
/// request with the device envelope observed when that request *started*,
/// all nominal records of one request see the same key and the same rate,
/// and are kept or dropped together — a request never shows up in the fleet
/// as a tool call with no completion.
public struct Sampler: SamplingDeciding {
    public let policy: SamplingPolicy

    public init(policy: SamplingPolicy = .standard) {
        self.policy = policy
    }

    public func decide(_ record: SignalRecord) -> SamplingDecision {
        let probability = policy.keepProbability(for: record.recordClass, device: record.device)
        if record.recordClass != .nominal {
            return .keep(.protectedClass(record.recordClass))
        }
        if probability >= 1 { return .keep(.withinRate(1)) }
        if probability <= 0 { return .drop(keepProbability: 0) }
        let unit = Sampler.unit(for: record.samplingKey)
        return unit < probability ? .keep(.withinRate(probability)) : .drop(keepProbability: probability)
    }

    /// Maps a digest to a uniform value in [0, 1). Same key ⇒ same unit ⇒
    /// same decision.
    ///
    /// FNV-1a is a fine *identity* hash but its high bits are not uniform
    /// for short, similar inputs — request IDs like `req-1`, `req-2`, … land
    /// in a narrow band, and the first version of this sampler kept 80% of
    /// nominal traffic at a 50% rate. `SamplingAudit` caught it. The
    /// MurmurHash3 finalizer below spreads the bits before the top 53 are
    /// taken as the mantissa.
    public static func unit(for key: Digest) -> Double {
        var z = key.value
        z ^= z >> 33
        z &*= 0xff51_afd7_ed55_8ccd
        z ^= z >> 33
        z &*= 0xc4ce_b9fe_1a85_ec53
        z ^= z >> 33
        return Double(z >> 11) / Double(1 << 53)
    }
}

// MARK: - Audit

/// Checks a sampler against the properties the README claims for it. Run in
/// tests against `Sampler` (must pass) and against a sabotaged decider
/// (must fail) — a check that cannot fail is not a check.
public enum SamplingAudit {

    public enum Violation: Hashable, Sendable, CustomStringConvertible {
        case protectedRecordDropped(requestID: Identifier?, RecordClass)
        case incoherentRequest(requestID: Identifier)
        case nominalDroppedAtFullRate(requestID: Identifier?)
        case keepRateOffTarget(thermal: ThermalState, observed: Double, expected: Double)

        public var description: String {
            switch self {
            case .protectedRecordDropped(let id, let cls):
                return "\(cls) record dropped (request \(id?.rawValue ?? "-"))"
            case .incoherentRequest(let id):
                return "request \(id.rawValue) partially kept"
            case .nominalDroppedAtFullRate(let id):
                return "nominal record dropped at rate 1.0 (request \(id?.rawValue ?? "-"))"
            case .keepRateOffTarget(let thermal, let observed, let expected):
                return "\(thermal): kept \(observed) of nominal, expected \(expected)"
            }
        }
    }

    /// - Parameters:
    ///   - tolerance: absolute tolerance on the empirical nominal keep rate,
    ///     checked only for thermal states with at least `minimumSamples`
    ///     nominal records.
    public static func verify(_ decider: some SamplingDeciding,
                              policy: SamplingPolicy,
                              records: [SignalRecord],
                              tolerance: Double = 0.05,
                              minimumSamples: Int = 500) -> [Violation] {
        var violations: [Violation] = []
        var perRequest: [Identifier: Set<Bool>] = [:]
        var nominalSeen: [ThermalState: Int] = [:]
        var nominalKept: [ThermalState: Int] = [:]

        for record in records {
            let decision = decider.decide(record)
            let kept = decision.isKept
            if record.recordClass != .nominal, !kept {
                violations.append(.protectedRecordDropped(requestID: record.requestID, record.recordClass))
            }
            if record.recordClass == .nominal {
                let probability = policy.keepProbability(for: .nominal, device: record.device)
                if probability >= 1, !kept {
                    violations.append(.nominalDroppedAtFullRate(requestID: record.requestID))
                }
                if record.device.energy == .unconstrained {
                    nominalSeen[record.device.thermal, default: 0] += 1
                    if kept { nominalKept[record.device.thermal, default: 0] += 1 }
                }
                if let id = record.requestID {
                    perRequest[id, default: []].insert(kept)
                }
            }
        }

        for (id, outcomes) in perRequest where outcomes.count > 1 {
            violations.append(.incoherentRequest(requestID: id))
        }

        for state in ThermalState.allCases {
            let seen = nominalSeen[state] ?? 0
            guard seen >= minimumSamples, seen > 0 else { continue }
            let observed = Double(nominalKept[state] ?? 0) / Double(seen)
            let expected = policy.keepProbability(for: .nominal,
                                                  device: DeviceEnvelope(thermal: state, energy: .unconstrained))
            if abs(observed - expected) > tolerance {
                violations.append(.keepRateOffTarget(thermal: state, observed: observed, expected: expected))
            }
        }

        // Deterministic ordering so test failures read the same every run.
        return violations.sorted { $0.description < $1.description }
    }
}

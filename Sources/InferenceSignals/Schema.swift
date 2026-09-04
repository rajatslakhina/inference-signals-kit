import Foundation

// MARK: - Attribution

/// A Dynamic Profile identity. One `LanguageModelSession` changes who it is
/// mid-task (planner → executor → reviewer), and a regression in one profile
/// must be distinguishable from the others, so every record carries the
/// profile that was live when its request *started*.
public struct ProfileID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let id: Identifier
    public init(_ id: Identifier) { self.id = id }
    public var description: String { id.rawValue }
}

/// Where the inference ran. Saturation and latency mean different things
/// per tier, and a router that silently moved traffic to the cloud shows up
/// here first.
public enum ExecutionTier: String, Sendable, Codable, CaseIterable {
    case onDevice
    case privateCloudCompute
    case remote
}

// MARK: - Prompt shape (never prompt text)

/// What the envelope knows about a prompt. There is no field for the text,
/// and the only string-typed members are validated `Identifier`s, so the
/// record is redaction-safe by its type rather than by a scrubbing pass
/// someone has to remember to run.
public struct PromptShape: Hashable, Sendable, Codable {
    public var promptTokens: Int
    public var instructionTokens: Int
    /// Tokens the executor reported as served from a reused KV-cache prefix.
    public var reusedPrefixTokens: Int
    public var contextWindowTokens: Int
    public var attachmentCount: Int
    /// Order-independent digest of the tool names available to the request.
    public var toolSetDigest: Digest
    /// Digest of the structured-output schema requested, if any.
    public var schemaDigest: Digest?

    public init(promptTokens: Int,
                instructionTokens: Int,
                reusedPrefixTokens: Int = 0,
                contextWindowTokens: Int,
                attachmentCount: Int = 0,
                toolSetDigest: Digest,
                schemaDigest: Digest? = nil) {
        // Negative counts are a caller bug, not a reason to trap or to emit
        // a negative headroom. Clamp at the boundary.
        self.promptTokens = max(0, promptTokens)
        self.instructionTokens = max(0, instructionTokens)
        self.reusedPrefixTokens = max(0, reusedPrefixTokens)
        self.contextWindowTokens = max(0, contextWindowTokens)
        self.attachmentCount = max(0, attachmentCount)
        self.toolSetDigest = toolSetDigest
        self.schemaDigest = schemaDigest
    }

    /// Fraction of the window still free: `1 - prompt/window`, clamped to
    /// [0, 1]. A window of zero reports zero headroom rather than dividing.
    public var contextHeadroom: Double {
        guard contextWindowTokens > 0 else { return 0 }
        let used = Double(promptTokens) / Double(contextWindowTokens)
        return min(1, max(0, 1 - used))
    }

    /// Fraction of prompt tokens served from a reused prefix, in [0, 1].
    public var prefixReuseRate: Double {
        guard promptTokens > 0 else { return 0 }
        return min(1, Double(reusedPrefixTokens) / Double(promptTokens))
    }
}

// MARK: - Device envelope

public enum ThermalState: String, Sendable, Codable, CaseIterable, Comparable {
    case nominal, fair, serious, critical

    public var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum EnergyState: String, Sendable, Codable, CaseIterable {
    case unconstrained
    case lowPowerMode
}

public struct DeviceEnvelope: Hashable, Sendable, Codable {
    public var thermal: ThermalState
    public var energy: EnergyState

    public init(thermal: ThermalState, energy: EnergyState) {
        self.thermal = thermal
        self.energy = energy
    }

    public static let nominal = DeviceEnvelope(thermal: .nominal, energy: .unconstrained)
}

// MARK: - Failures

/// The error taxonomy for a non-deterministic subsystem. None of these is an
/// exception in the executor's sense — a guardrail refusal returns cleanly —
/// which is exactly why they need their own signal.
public enum InferenceFailure: String, Sendable, Codable, CaseIterable {
    case guardrailRefusal
    case toolLoopNonTermination
    case structuredDecodeFailure
    case contextWindowExceeded
    case deadlineExceeded
    case cancelled
    case executorError
}

// MARK: - Latency quartet

/// The four latencies Apple's Instruments template exposes, plus the queue
/// wait it cannot see because it only starts observing when the framework
/// does.
public struct LatencySample: Hashable, Sendable, Codable {
    public var queueWait: Nanoseconds
    public var timeToFirstToken: Nanoseconds
    public var total: Nanoseconds
    public var outputTokens: Int

    public init(queueWait: Nanoseconds,
                timeToFirstToken: Nanoseconds,
                total: Nanoseconds,
                outputTokens: Int) {
        self.queueWait = queueWait
        self.timeToFirstToken = timeToFirstToken
        self.total = total
        self.outputTokens = max(0, outputTokens)
    }

    /// Output tokens per second over the generation phase (total − TTFT).
    /// Returns `nil` rather than infinity when the generation phase is
    /// instantaneous or produced no tokens.
    public var tokensPerSecond: Double? {
        let generation = Saturating.subtract(total.value, timeToFirstToken.value)
        guard generation > 0, outputTokens > 0 else { return nil }
        return Double(outputTokens) / (Double(generation) / 1_000_000_000)
    }
}

// MARK: - Record

/// Classification that drives sampling and buffer eviction. Errors and tail
/// latencies are the records the fleet exists to catch; they are never
/// sampled out and never evicted in favour of a nominal record.
public enum RecordClass: String, Sendable, Codable, CaseIterable, Comparable {
    case nominal
    case tail
    case error

    /// Higher rank survives longer.
    public var rank: Int {
        switch self {
        case .nominal: return 0
        case .tail: return 1
        case .error: return 2
        }
    }

    public static func < (lhs: RecordClass, rhs: RecordClass) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum SignalPayload: Hashable, Sendable, Codable {
    case sessionStarted
    case sessionEnded(requestCount: Int)
    case profileSwitched(from: ProfileID?)
    case toolCall(toolDigest: Digest, sequence: Int)
    case inferenceCompleted(LatencySample, PromptShape)
    case inferenceFailed(InferenceFailure, PromptShape, elapsed: Nanoseconds)
}

/// One row of the single schema shared by the Instruments trace and the
/// production stream. Both sinks encode this exact type, so the dev-time
/// picture and the fleet picture cannot drift apart.
public struct SignalRecord: Hashable, Sendable, Codable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var sessionID: Identifier
    public var requestID: Identifier?
    public var profile: ProfileID
    public var tier: ExecutionTier
    public var device: DeviceEnvelope
    public var recordedAt: Instant
    public var recordClass: RecordClass
    public var payload: SignalPayload

    public init(sessionID: Identifier,
                requestID: Identifier?,
                profile: ProfileID,
                tier: ExecutionTier,
                device: DeviceEnvelope,
                recordedAt: Instant,
                recordClass: RecordClass,
                payload: SignalPayload) {
        self.schemaVersion = SignalRecord.schemaVersion
        self.sessionID = sessionID
        self.requestID = requestID
        self.profile = profile
        self.tier = tier
        self.device = device
        self.recordedAt = recordedAt
        self.recordClass = recordClass
        self.payload = payload
    }

    /// The identity sampling decisions are keyed on. Every record of one
    /// request shares it, so a request is kept or dropped whole; session
    /// lifecycle records key on the session instead.
    public var samplingKey: Digest {
        Digest(string: (requestID ?? sessionID).rawValue)
    }
}

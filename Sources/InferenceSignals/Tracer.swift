import Foundation

// MARK: - Device envelope source

public protocol DeviceEnvelopeProviding: Sendable {
    func current() -> DeviceEnvelope
}

/// A fixed envelope, for tests and for the demo's pressure picker.
public final class StaticEnvelopeProvider: DeviceEnvelopeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var envelope: DeviceEnvelope

    public init(_ envelope: DeviceEnvelope = .nominal) { self.envelope = envelope }

    public func current() -> DeviceEnvelope {
        lock.lock(); defer { lock.unlock() }
        return envelope
    }

    public func set(_ envelope: DeviceEnvelope) {
        lock.lock(); defer { lock.unlock() }
        self.envelope = envelope
    }
}

#if canImport(Darwin)
/// Reads `ProcessInfo` on Apple platforms. On Linux this type does not
/// exist, and the module still compiles because nothing else depends on it.
public struct ProcessInfoEnvelopeProvider: DeviceEnvelopeProviding {
    public init() {}

    public func current() -> DeviceEnvelope {
        let info = ProcessInfo.processInfo
        let thermal: ThermalState
        switch info.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        return DeviceEnvelope(thermal: thermal,
                              energy: info.isLowPowerModeEnabled ? .lowPowerMode : .unconstrained)
    }
}
#endif

// MARK: - Handles

/// An opaque handle to an in-flight request. Deliberately not the request's
/// identifier: a handle from one tracer is meaningless to another, and the
/// tracer rejects handles it did not issue instead of trapping.
public struct RequestHandle: Hashable, Sendable {
    fileprivate let tracerToken: UInt64
    fileprivate let serial: UInt64
}

public enum TracerError: Error, Equatable, Sendable {
    case sessionNotStarted
    case sessionAlreadyEnded
    case unknownHandle
    case invalidTransition(from: RequestPhase, event: String)
}

public enum RequestPhase: String, Sendable, Codable {
    case enqueued
    case running
    case streaming
    case finished
}

// MARK: - Tracer

/// Mirrors the Instruments tree — session → request → inference → tool
/// calls — and emits `SignalRecord`s for the collector.
///
/// Every timing is a difference of two `Instant`s from the injected clock,
/// and every record of a request carries the profile and device envelope
/// captured when that request was *enqueued*. A profile switch after that
/// point does not retroactively reassign the request: the planner profile
/// that produced a slow request keeps the blame even if the session has
/// moved on to executing.
public final class SessionTracer: @unchecked Sendable {
    public let sessionID: Identifier
    public let tier: ExecutionTier
    public let toolLoopPolicy: ToolLoopPolicy

    private let clock: any MonotonicClock
    private let environment: any DeviceEnvelopeProviding
    private let collector: SignalCollector
    private let tailPolicy: TailPolicy
    private let lock = NSLock()
    private let token: UInt64

    private struct Request {
        let id: Identifier
        let profile: ProfileID
        let device: DeviceEnvelope
        let shape: PromptShape
        let enqueuedAt: Instant
        var startedAt: Instant?
        var firstTokenAt: Instant?
        var phase: RequestPhase = .enqueued
        var loop: ToolLoopMonitor
        var loopFlagged = false
        var toolCalls = 0
    }

    private var started = false
    private var ended = false
    private var profile: ProfileID
    private var requests: [UInt64: Request] = [:]
    private var nextSerial: UInt64 = 0
    private var requestCount = 0
    private static let tokenSource = TokenSource()

    public init(sessionID: Identifier,
                initialProfile: ProfileID,
                tier: ExecutionTier,
                clock: any MonotonicClock,
                environment: any DeviceEnvelopeProviding,
                collector: SignalCollector,
                tailPolicy: TailPolicy,
                toolLoopPolicy: ToolLoopPolicy = .standard) {
        self.sessionID = sessionID
        self.profile = initialProfile
        self.tier = tier
        self.clock = clock
        self.environment = environment
        self.collector = collector
        self.tailPolicy = tailPolicy
        self.toolLoopPolicy = toolLoopPolicy
        self.token = SessionTracer.tokenSource.next()
    }

    public var currentProfile: ProfileID {
        lock.lock(); defer { lock.unlock() }
        return profile
    }

    public var openRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    // MARK: Session lifecycle

    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        let record = makeRecord(requestID: nil, profile: profile, device: environment.current(),
                                recordClass: .nominal, payload: .sessionStarted)
        lock.unlock()
        collector.ingest(record)
    }

    public func switchProfile(to newProfile: ProfileID) {
        lock.lock()
        let previous = profile
        profile = newProfile
        let record = makeRecord(requestID: nil, profile: newProfile, device: environment.current(),
                                recordClass: .nominal, payload: .profileSwitched(from: previous))
        lock.unlock()
        collector.ingest(record)
    }

    /// Ends the session. Requests still open are failed as `.cancelled`
    /// so no request can vanish without a terminal record.
    public func end() {
        lock.lock()
        guard started, !ended else { lock.unlock(); return }
        ended = true
        let open = requests.keys.sorted()
        var records: [SignalRecord] = []
        for serial in open {
            if let record = terminate(serial: serial, failure: .cancelled) {
                records.append(record)
            }
        }
        records.append(makeRecord(requestID: nil, profile: profile, device: environment.current(),
                                  recordClass: .nominal, payload: .sessionEnded(requestCount: requestCount)))
        lock.unlock()
        for record in records { collector.ingest(record) }
    }

    // MARK: Request lifecycle

    /// Enqueues a request. Queue wait is measured from here to
    /// `markRunning`. Throws if the session is not open.
    public func enqueue(requestID: Identifier, shape: PromptShape) throws -> RequestHandle {
        lock.lock(); defer { lock.unlock() }
        guard started else { throw TracerError.sessionNotStarted }
        guard !ended else { throw TracerError.sessionAlreadyEnded }
        let serial = nextSerial
        nextSerial &+= 1
        requests[serial] = Request(id: requestID,
                                   profile: profile,
                                   device: environment.current(),
                                   shape: shape,
                                   enqueuedAt: clock.now(),
                                   loop: ToolLoopMonitor(policy: toolLoopPolicy))
        Saturating.increment(&requestCount)
        collector.noteRequestStarted(profile: profile)
        return RequestHandle(tracerToken: token, serial: serial)
    }

    /// The executor picked the request up.
    public func markRunning(_ handle: RequestHandle) throws {
        lock.lock(); defer { lock.unlock() }
        guard handle.tracerToken == token, var request = requests[handle.serial] else {
            throw TracerError.unknownHandle
        }
        guard request.phase == .enqueued else {
            throw TracerError.invalidTransition(from: request.phase, event: "markRunning")
        }
        request.startedAt = clock.now()
        request.phase = .running
        requests[handle.serial] = request
    }

    /// The first output token arrived. Idempotent: only the first call
    /// sets the timestamp.
    public func markFirstToken(_ handle: RequestHandle) throws {
        lock.lock(); defer { lock.unlock() }
        guard handle.tracerToken == token, var request = requests[handle.serial] else {
            throw TracerError.unknownHandle
        }
        guard request.phase == .running || request.phase == .streaming else {
            throw TracerError.invalidTransition(from: request.phase, event: "markFirstToken")
        }
        if request.firstTokenAt == nil { request.firstTokenAt = clock.now() }
        request.phase = .streaming
        requests[handle.serial] = request
    }

    /// Records a tool call and returns the loop monitor's verdict. The first
    /// non-termination verdict on a request also emits a
    /// `toolLoopNonTermination` error record, once, whether or not the
    /// caller acts on the verdict.
    @discardableResult
    public func recordToolCall(_ handle: RequestHandle, _ signature: ToolCallSignature) throws -> ToolLoopVerdict {
        lock.lock()
        guard handle.tracerToken == token, var request = requests[handle.serial] else {
            lock.unlock()
            throw TracerError.unknownHandle
        }
        guard request.phase != .finished else {
            lock.unlock()
            throw TracerError.invalidTransition(from: request.phase, event: "recordToolCall")
        }
        let verdict = request.loop.observe(signature)
        Saturating.increment(&request.toolCalls)
        var records = [makeRecord(requestID: request.id, profile: request.profile, device: request.device,
                                  recordClass: .nominal,
                                  payload: .toolCall(toolDigest: signature.toolDigest, sequence: request.toolCalls))]
        if verdict.isNonTermination, !request.loopFlagged {
            request.loopFlagged = true
            let elapsed = clock.now().elapsed(since: request.enqueuedAt)
            records.append(makeRecord(requestID: request.id, profile: request.profile, device: request.device,
                                      recordClass: .error,
                                      payload: .inferenceFailed(.toolLoopNonTermination, request.shape,
                                                                elapsed: elapsed)))
        }
        requests[handle.serial] = request
        lock.unlock()
        for record in records { collector.ingest(record) }
        return verdict
    }

    /// Completes the request. A completion with no `markFirstToken` reports
    /// TTFT equal to total (the whole response arrived at once); one with no
    /// `markRunning` reports zero queue wait measured from enqueue.
    public func complete(_ handle: RequestHandle, outputTokens: Int) throws {
        lock.lock()
        guard handle.tracerToken == token, let request = requests[handle.serial] else {
            lock.unlock()
            throw TracerError.unknownHandle
        }
        guard request.phase != .finished else {
            lock.unlock()
            throw TracerError.invalidTransition(from: request.phase, event: "complete")
        }
        let now = clock.now()
        let startedAt = request.startedAt ?? request.enqueuedAt
        let queueWait = startedAt.elapsed(since: request.enqueuedAt)
        let total = now.elapsed(since: startedAt)
        let ttft = (request.firstTokenAt ?? now).elapsed(since: startedAt)
        let sample = LatencySample(queueWait: queueWait,
                                   timeToFirstToken: min(ttft, total),
                                   total: total,
                                   outputTokens: outputTokens)
        let recordClass = tailPolicy.classify(total: total, profile: request.profile)
        let record = makeRecord(requestID: request.id, profile: request.profile, device: request.device,
                                recordClass: recordClass,
                                payload: .inferenceCompleted(sample, request.shape))
        requests[handle.serial] = nil
        lock.unlock()
        collector.ingest(record)
    }

    public func fail(_ handle: RequestHandle, _ failure: InferenceFailure) throws {
        lock.lock()
        guard handle.tracerToken == token, requests[handle.serial] != nil else {
            lock.unlock()
            throw TracerError.unknownHandle
        }
        let record = terminate(serial: handle.serial, failure: failure)
        lock.unlock()
        if let record { collector.ingest(record) }
    }

    // MARK: Internals (caller holds the lock)

    private func terminate(serial: UInt64, failure: InferenceFailure) -> SignalRecord? {
        guard let request = requests[serial] else { return nil }
        let elapsed = clock.now().elapsed(since: request.enqueuedAt)
        requests[serial] = nil
        return makeRecord(requestID: request.id, profile: request.profile, device: request.device,
                          recordClass: .error,
                          payload: .inferenceFailed(failure, request.shape, elapsed: elapsed))
    }

    private func makeRecord(requestID: Identifier?,
                            profile: ProfileID,
                            device: DeviceEnvelope,
                            recordClass: RecordClass,
                            payload: SignalPayload) -> SignalRecord {
        SignalRecord(sessionID: sessionID,
                     requestID: requestID,
                     profile: profile,
                     tier: tier,
                     device: device,
                     recordedAt: clock.now(),
                     recordClass: recordClass,
                     payload: payload)
    }
}

/// Process-unique tracer tokens so a handle cannot be replayed against a
/// different tracer.
private final class TokenSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }
}

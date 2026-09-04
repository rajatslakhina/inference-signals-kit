import Foundation

// MARK: - Sinks

/// Where flushed records go: an in-memory list under test, an `os_signpost`
/// bridge for Instruments, a file spool or uploader in production. All of
/// them receive the same `SignalRecord` values — that is the "one schema"
/// half of the design.
public protocol SignalSink: Sendable {
    /// Delivers a batch. Throwing means *none* of the batch was accepted and
    /// the collector will re-offer it to the buffer.
    func deliver(_ records: [SignalRecord]) async throws
}

/// Keeps every delivered record. Bounded so a test cannot leak forever.
public actor InMemorySink: SignalSink {
    public private(set) var delivered: [SignalRecord] = []
    public private(set) var batches: Int = 0
    public let capacity: Int

    public init(capacity: Int = 100_000) {
        self.capacity = max(1, capacity)
    }

    public func deliver(_ records: [SignalRecord]) async throws {
        Saturating.increment(&batches)
        delivered.append(contentsOf: records)
        if delivered.count > capacity {
            delivered.removeFirst(delivered.count - capacity)
        }
    }
}

/// Encodes records as JSON Lines. Deterministic key order so two sinks
/// encoding the same record produce byte-identical output.
public struct JSONLinesEncoder: Sendable {
    private let encoder: JSONEncoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func encode(_ record: SignalRecord) throws -> Data {
        try encoder.encode(record)
    }

    public func encodeLines(_ records: [SignalRecord]) throws -> Data {
        var output = Data()
        for record in records {
            output.append(try encode(record))
            output.append(0x0A)
        }
        return output
    }
}

// MARK: - Collector

/// Ingest, classify, count, sample, buffer, flush.
///
/// `ingest` is synchronous and lock-protected on purpose: instrumentation
/// sits on the inference path, and an `await` per token would turn the
/// observer into a scheduling participant. The only asynchronous operation
/// is `flush`, which drains the buffer under the lock *before* awaiting the
/// sink, so a concurrent flush finds an empty buffer rather than the same
/// batch — every record is delivered at most once, and a failed delivery
/// re-offers the batch through the buffer's own eviction policy rather than
/// duplicating it or growing without bound.
///
/// Aggregates are updated *before* sampling. Sampling thins what you ship;
/// it must never thin what you count, or the dashboard's error rate would
/// change every time the device warmed up.
public final class SignalCollector: @unchecked Sendable {
    public let sampler: any SamplingDeciding
    public let samplingPolicy: SamplingPolicy
    public let tailPolicy: TailPolicy
    public let maximumProfiles: Int
    private let sink: any SignalSink
    private let lock = NSLock()

    private var buffer: any RecordBuffering
    private var profiles: [ProfileID: ProfileSignals] = [:]
    private var recordsIngested = 0
    private var recordsSampledOut = 0
    private var recordsDelivered = 0
    private var deliveryFailures = 0
    private var device: DeviceEnvelope = .nominal
    private var flushesInFlight = 0

    public enum ConfigurationError: Error, Equatable, Sendable {
        case nonPositiveMaximumProfiles(Int)
    }

    public init(sink: any SignalSink,
                buffer: any RecordBuffering,
                sampler: (any SamplingDeciding)? = nil,
                samplingPolicy: SamplingPolicy = .standard,
                tailPolicy: TailPolicy,
                maximumProfiles: Int = 32) throws {
        guard maximumProfiles > 0 else {
            throw ConfigurationError.nonPositiveMaximumProfiles(maximumProfiles)
        }
        self.sink = sink
        self.buffer = buffer
        self.samplingPolicy = samplingPolicy
        self.sampler = sampler ?? Sampler(policy: samplingPolicy)
        self.tailPolicy = tailPolicy
        self.maximumProfiles = maximumProfiles
    }

    /// The device envelope the *collector* reports in its snapshot. The
    /// envelope stamped on records comes from the tracer's provider at
    /// request start; this one is informational.
    public func updateDevice(_ envelope: DeviceEnvelope) {
        lock.lock(); defer { lock.unlock() }
        device = envelope
    }

    /// Synchronous. Counts, classifies for sampling, buffers.
    public func ingest(_ record: SignalRecord) {
        lock.lock(); defer { lock.unlock() }
        Saturating.increment(&recordsIngested)
        aggregate(record)
        switch sampler.decide(record) {
        case .keep:
            _ = buffer.offer(record)
        case .drop:
            Saturating.increment(&recordsSampledOut)
        }
    }

    /// Counts a request against its profile. Called by the tracer at
    /// request start so traffic reflects attempts, not just outcomes.
    public func noteRequestStarted(profile: ProfileID) {
        lock.lock(); defer { lock.unlock() }
        let key = attributionKey(for: profile)
        profiles[key, default: ProfileSignals(profile: key)].noteRequestStarted()
    }

    private func aggregate(_ record: SignalRecord) {
        let key = attributionKey(for: record.profile)
        profiles[key, default: ProfileSignals(profile: key)].apply(record)
    }

    /// Folds profiles beyond the cap into `SignalsSnapshot.overflowProfile`
    /// so the aggregate map is bounded no matter what IDs arrive.
    private func attributionKey(for profile: ProfileID) -> ProfileID {
        if profiles[profile] != nil { return profile }
        if profiles.count < maximumProfiles { return profile }
        return SignalsSnapshot.overflowProfile
    }

    /// Drains the buffer and delivers it. Safe to call concurrently.
    /// Returns the number of records delivered by *this* call.
    @discardableResult
    public func flush() async -> Int {
        await flushBatch().count
    }

    /// Like `flush()`, but returns the records this call delivered — empty
    /// if the buffer was already drained by a concurrent flush or if the
    /// sink rejected the batch (in which case it has been re-offered).
    public func flushBatch() async -> [SignalRecord] {
        // The lock is never held across the `await`: every critical section
        // is a synchronous helper below, so the sink can suspend for as long
        // as it likes without blocking `ingest` on the inference path.
        let batch = takeBatch()
        defer { finishFlush() }
        guard !batch.isEmpty else { return [] }

        do {
            try await sink.deliver(batch)
            noteDelivered(batch.count)
            return batch
        } catch {
            requeue(batch)
            return []
        }
    }

    private func takeBatch() -> [SignalRecord] {
        lock.lock(); defer { lock.unlock() }
        flushesInFlight = Saturating.add(flushesInFlight, 1)
        return buffer.drain()
    }

    private func finishFlush() {
        lock.lock(); defer { lock.unlock() }
        flushesInFlight = max(0, flushesInFlight - 1)
    }

    private func noteDelivered(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        recordsDelivered = Saturating.add(recordsDelivered, count)
    }

    /// Re-offers a failed batch through the buffer so retention obeys the
    /// same class-aware bound as fresh records. The batch is oldest-first,
    /// so its internal order survives; relative to records ingested during
    /// the failed delivery it is re-sequenced after them, which is why
    /// consumers order by `recordedAt`, never by arrival.
    private func requeue(_ batch: [SignalRecord]) {
        lock.lock(); defer { lock.unlock() }
        Saturating.increment(&deliveryFailures)
        for record in batch {
            _ = buffer.offer(record)
        }
    }

    public func snapshot() -> SignalsSnapshot {
        lock.lock(); defer { lock.unlock() }
        let ring = buffer as? PriorityRingBuffer
        return SignalsSnapshot(
            profiles: profiles,
            recordsIngested: recordsIngested,
            recordsSampledOut: recordsSampledOut,
            bufferOccupancy: buffer.occupancy,
            bufferCapacity: buffer.capacity,
            bufferEvictions: ring?.evictions ?? [:],
            bufferRefusals: ring?.refusals ?? 0,
            recordsDelivered: recordsDelivered,
            deliveryFailures: deliveryFailures,
            device: device,
            samplingRateNominal: samplingPolicy.keepProbability(for: .nominal, device: device)
        )
    }

    /// Records currently buffered, oldest first, without draining them.
    public func peekBuffer() -> [SignalRecord] {
        lock.lock(); defer { lock.unlock() }
        return buffer.contents
    }

    /// Number of flushes currently awaiting a sink. Exposed for tests.
    public var inFlightFlushes: Int {
        lock.lock(); defer { lock.unlock() }
        return flushesInFlight
    }
}

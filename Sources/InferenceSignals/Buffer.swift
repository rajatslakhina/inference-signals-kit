import Foundation

/// What happened to a record offered to a buffer.
public enum Admission: Hashable, Sendable {
    /// Stored without displacing anything.
    case admitted
    /// Stored; the oldest record of `evicted` class was dropped to make room.
    case admittedByEvicting(RecordClass)
    /// Not stored: the buffer is full of records that outrank this one.
    case refused
}

/// A bounded store of records between ingest and flush.
public protocol RecordBuffering: Sendable {
    var capacity: Int { get }
    var occupancy: Int { get }
    /// Records currently held, oldest first.
    var contents: [SignalRecord] { get }
    mutating func offer(_ record: SignalRecord) -> Admission
    mutating func drain() -> [SignalRecord]
}

/// A bounded buffer with class-aware eviction.
///
/// Storage is hard-capped at `capacity` records. When full, an incoming
/// record displaces the *oldest record of the lowest class present*, but only
/// if that class does not outrank the incoming record; a nominal record
/// arriving into a buffer full of errors is refused, never admitted at an
/// error's expense. Within a class the policy is drop-oldest, so even a flood
/// of errors stays bounded — a telemetry buffer that grows without limit under
/// an incident is a second incident.
///
/// Three per-class FIFO queues plus a global sequence number give O(1)
/// eviction and an exact oldest-first merge on drain.
public struct PriorityRingBuffer: RecordBuffering {
    public let capacity: Int

    private struct Entry: Sendable {
        let sequence: UInt64
        let record: SignalRecord
    }

    /// One queue per class, indexed by `RecordClass.rank`. `head` is the
    /// index of the oldest live entry; entries before it are already
    /// evicted and are compacted away once they dominate the array.
    private var queues: [[Entry]]
    private var heads: [Int]
    private var nextSequence: UInt64 = 0

    public private(set) var evictions: [RecordClass: Int] = [:]
    public private(set) var refusals: Int = 0

    public enum ConfigurationError: Error, Equatable, Sendable {
        case nonPositiveCapacity(Int)
    }

    public init(capacity: Int) throws {
        guard capacity > 0 else { throw ConfigurationError.nonPositiveCapacity(capacity) }
        self.capacity = capacity
        queues = Array(repeating: [], count: RecordClass.allCases.count)
        heads = Array(repeating: 0, count: RecordClass.allCases.count)
    }

    public var occupancy: Int {
        var total = 0
        for rank in queues.indices {
            total = Saturating.add(total, liveCount(rank))
        }
        return total
    }

    /// Entries held in the backing arrays, live or awaiting compaction.
    /// Exposed so a test can prove that evicting does not leak: it stays
    /// below `3 × capacity + 32` however many records pass through.
    public var storageFootprint: Int {
        queues.reduce(0) { Saturating.add($0, $1.count) }
    }

    private func liveCount(_ rank: Int) -> Int {
        guard queues.indices.contains(rank), heads.indices.contains(rank) else { return 0 }
        return max(0, queues[rank].count - heads[rank])
    }

    public var contents: [SignalRecord] {
        var live: [Entry] = []
        for rank in queues.indices where heads.indices.contains(rank) {
            let queue = queues[rank]
            let head = min(heads[rank], queue.count)
            live.append(contentsOf: queue[head...])
        }
        return live.sorted { $0.sequence < $1.sequence }.map(\.record)
    }

    public mutating func offer(_ record: SignalRecord) -> Admission {
        let incomingRank = record.recordClass.rank
        guard queues.indices.contains(incomingRank) else { return .refused }

        var admission = Admission.admitted
        if occupancy >= capacity {
            // Lowest class present, searching upward from nominal.
            guard let victimRank = queues.indices.first(where: { liveCount($0) > 0 }),
                  victimRank <= incomingRank,
                  let victimClass = RecordClass.allCases.first(where: { $0.rank == victimRank })
            else {
                Saturating.increment(&refusals)
                return .refused
            }
            dropOldest(rank: victimRank)
            evictions[victimClass, default: 0] = Saturating.add(evictions[victimClass] ?? 0, 1)
            admission = .admittedByEvicting(victimClass)
        }

        queues[incomingRank].append(Entry(sequence: nextSequence, record: record))
        nextSequence &+= 1
        return admission
    }

    private mutating func dropOldest(rank: Int) {
        guard queues.indices.contains(rank), heads.indices.contains(rank),
              heads[rank] < queues[rank].count else { return }
        heads[rank] += 1
        // Compact once the dead prefix is at least half the array so the
        // amortised cost stays O(1) and the array never grows unbounded.
        if heads[rank] >= 32, heads[rank] * 2 >= queues[rank].count {
            queues[rank].removeFirst(heads[rank])
            heads[rank] = 0
        }
    }

    public mutating func drain() -> [SignalRecord] {
        let drained = contents
        for rank in queues.indices {
            queues[rank].removeAll(keepingCapacity: true)
            heads[rank] = 0
        }
        return drained
    }
}

// MARK: - Audit

/// Properties a buffer must hold. Run against `PriorityRingBuffer` (passes)
/// and against a naive drop-oldest buffer (fails on the class invariant).
public enum BufferAudit {

    public enum Violation: Hashable, Sendable, CustomStringConvertible {
        case capacityExceeded(occupancy: Int, capacity: Int)
        case higherClassEvictedForLower(evicted: RecordClass, incoming: RecordClass)
        case higherClassEvictedWhileLowerHeld(evicted: RecordClass, held: RecordClass)
        case protectedRefusedWhileLowerHeld(incoming: RecordClass, held: RecordClass)
        case orderNotOldestFirst

        public var description: String {
            switch self {
            case .capacityExceeded(let occupancy, let capacity):
                return "occupancy \(occupancy) exceeded capacity \(capacity)"
            case .higherClassEvictedForLower(let evicted, let incoming):
                return "\(evicted) evicted to admit \(incoming)"
            case .higherClassEvictedWhileLowerHeld(let evicted, let held):
                return "\(evicted) evicted while a \(held) record was still held"
            case .protectedRefusedWhileLowerHeld(let incoming, let held):
                return "\(incoming) refused while a \(held) record was still held"
            case .orderNotOldestFirst:
                return "drain order is not oldest-first"
            }
        }
    }

    public static func verify(_ makeBuffer: () -> any RecordBuffering,
                              records: [SignalRecord]) -> [Violation] {
        var buffer = makeBuffer()
        var violations: Set<Violation> = []

        for record in records {
            let before = buffer.contents
            let lowestHeld = before.map(\.recordClass).min()
            let admission = buffer.offer(record)

            if buffer.occupancy > buffer.capacity {
                violations.insert(.capacityExceeded(occupancy: buffer.occupancy, capacity: buffer.capacity))
            }
            switch admission {
            case .admittedByEvicting(let evicted):
                if evicted > record.recordClass {
                    violations.insert(.higherClassEvictedForLower(evicted: evicted, incoming: record.recordClass))
                }
                if let lowestHeld, evicted > lowestHeld {
                    violations.insert(.higherClassEvictedWhileLowerHeld(evicted: evicted, held: lowestHeld))
                }
            case .refused:
                if let lowestHeld, record.recordClass > lowestHeld {
                    violations.insert(.protectedRefusedWhileLowerHeld(incoming: record.recordClass, held: lowestHeld))
                }
            case .admitted:
                break
            }
        }

        let drained = buffer.drain()
        let stamps = drained.map(\.recordedAt)
        if stamps != stamps.sorted() {
            violations.insert(.orderNotOldestFirst)
        }
        return violations.sorted { $0.description < $1.description }
    }
}

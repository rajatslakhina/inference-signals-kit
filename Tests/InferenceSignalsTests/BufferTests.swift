import XCTest
@testable import InferenceSignals

/// The obvious implementation: one FIFO, drop the oldest whatever it is.
struct NaiveDropOldestBuffer: RecordBuffering {
    let capacity: Int
    private var storage: [SignalRecord] = []
    init(capacity: Int) { self.capacity = capacity }
    var occupancy: Int { storage.count }
    var contents: [SignalRecord] { storage }
    mutating func offer(_ record: SignalRecord) -> Admission {
        var admission = Admission.admitted
        if storage.count >= capacity, !storage.isEmpty {
            let victim = storage.removeFirst()
            admission = .admittedByEvicting(victim.recordClass)
        }
        storage.append(record)
        return admission
    }
    mutating func drain() -> [SignalRecord] {
        defer { storage.removeAll() }
        return storage
    }
}

/// Never evicts; grows without bound.
struct UnboundedBuffer: RecordBuffering {
    let capacity: Int
    private var storage: [SignalRecord] = []
    init(capacity: Int) { self.capacity = capacity }
    var occupancy: Int { storage.count }
    var contents: [SignalRecord] { storage }
    mutating func offer(_ record: SignalRecord) -> Admission {
        storage.append(record)
        return .admitted
    }
    mutating func drain() -> [SignalRecord] {
        defer { storage.removeAll() }
        return storage
    }
}

final class BufferTests: XCTestCase {

    private func classes(_ buffer: some RecordBuffering) -> [RecordClass] {
        buffer.contents.map(\.recordClass)
    }

    func testCapacityMustBePositive() {
        XCTAssertThrowsSpecific(try PriorityRingBuffer(capacity: 0),
                                PriorityRingBuffer.ConfigurationError.nonPositiveCapacity(0))
        XCTAssertThrowsSpecific(try PriorityRingBuffer(capacity: -3),
                                PriorityRingBuffer.ConfigurationError.nonPositiveCapacity(-3))
    }

    func testAdmitsUntilFullThenEvictsOldestNominal() throws {
        var buffer = try PriorityRingBuffer(capacity: 3)
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "a", at: 1)), .admitted)
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "b", at: 2)), .admitted)
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "c", at: 3)), .admitted)
        XCTAssertEqual(buffer.occupancy, 3)
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "d", at: 4)), .admittedByEvicting(.nominal))
        XCTAssertEqual(buffer.occupancy, 3)
        XCTAssertEqual(buffer.contents.map { $0.requestID?.rawValue }, ["b", "c", "d"])
        XCTAssertEqual(buffer.evictions[.nominal], 1)
    }

    func testErrorDisplacesNominalNeverTheReverse() throws {
        var buffer = try PriorityRingBuffer(capacity: 2)
        _ = buffer.offer(Fixtures.record(request: "n1", at: 1))
        _ = buffer.offer(Fixtures.record(request: "n2", at: 2))
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "e1", recordClass: .error, at: 3)),
                       .admittedByEvicting(.nominal))
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "e2", recordClass: .error, at: 4)),
                       .admittedByEvicting(.nominal))
        XCTAssertEqual(classes(buffer), [.error, .error])
        // Full of errors: a nominal record is refused, a tail record too.
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "n3", at: 5)), .refused)
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "t1", recordClass: .tail, at: 6)), .refused)
        XCTAssertEqual(buffer.refusals, 2)
        XCTAssertEqual(classes(buffer), [.error, .error])
        // Another error displaces the oldest error: still bounded.
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "e3", recordClass: .error, at: 7)),
                       .admittedByEvicting(.error))
        XCTAssertEqual(buffer.contents.map { $0.requestID?.rawValue }, ["e2", "e3"])
    }

    func testTailOutranksNominalAndIsOutrankedByError() throws {
        var buffer = try PriorityRingBuffer(capacity: 2)
        _ = buffer.offer(Fixtures.record(request: "t1", recordClass: .tail, at: 1))
        _ = buffer.offer(Fixtures.record(request: "n1", at: 2))
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "t2", recordClass: .tail, at: 3)),
                       .admittedByEvicting(.nominal))
        XCTAssertEqual(classes(buffer), [.tail, .tail])
        XCTAssertEqual(buffer.offer(Fixtures.record(request: "e1", recordClass: .error, at: 4)),
                       .admittedByEvicting(.tail))
        XCTAssertEqual(buffer.contents.map { $0.requestID?.rawValue }, ["t2", "e1"])
    }

    func testDrainIsOldestFirstAcrossClassesAndEmptiesTheBuffer() throws {
        var buffer = try PriorityRingBuffer(capacity: 10)
        _ = buffer.offer(Fixtures.record(request: "1", recordClass: .error, at: 1))
        _ = buffer.offer(Fixtures.record(request: "2", at: 2))
        _ = buffer.offer(Fixtures.record(request: "3", recordClass: .tail, at: 3))
        _ = buffer.offer(Fixtures.record(request: "4", at: 4))
        let drained = buffer.drain()
        XCTAssertEqual(drained.map { $0.requestID?.rawValue }, ["1", "2", "3", "4"])
        XCTAssertEqual(buffer.occupancy, 0)
        XCTAssertEqual(buffer.drain(), [])
    }

    func testLongRunningEvictionDoesNotGrowStorage() throws {
        // 50,000 offers into a 16-slot buffer: occupancy must stay at 16 and
        // the dead prefix must be compacted (otherwise memory grows with
        // every eviction even though `occupancy` looks fine).
        var buffer = try PriorityRingBuffer(capacity: 16)
        for i in 0..<50_000 {
            _ = buffer.offer(Fixtures.record(request: "r\(i)", at: Int64(i)))
        }
        XCTAssertEqual(buffer.occupancy, 16)
        XCTAssertEqual(buffer.evictions[.nominal], 50_000 - 16)
        let ids = buffer.drain().compactMap { $0.requestID?.rawValue }
        XCTAssertEqual(ids.first, "r49984")
        XCTAssertEqual(ids.last, "r49999")
        XCTAssertLessThan(buffer.storageFootprint, 64)
    }

    // MARK: Audit — positive and negative controls

    private func mixedWorkload() -> [SignalRecord] {
        var rng = SplitMix64(seed: 3)
        return (0..<2_000).map { i in
            let roll = rng.nextUnit()
            let recordClass: RecordClass = roll < 0.1 ? .error : (roll < 0.25 ? .tail : .nominal)
            return Fixtures.record(request: "r\(i)", recordClass: recordClass, at: Int64(i))
        }
    }

    func testAuditPassesForPriorityRingBuffer() throws {
        let make: () -> any RecordBuffering = {
            // The capacity is positive, so the initializer cannot throw;
            // falling back to the unbounded buffer would fail the audit
            // loudly rather than hide a wiring mistake.
            if let ring = try? PriorityRingBuffer(capacity: 32) { return ring }
            return UnboundedBuffer(capacity: 32)
        }
        let violations = BufferAudit.verify(make, records: mixedWorkload())
        XCTAssertEqual(violations, [], violations.map(\.description).joined(separator: "\n"))
    }

    func testAuditCatchesNaiveDropOldest() {
        let violations = BufferAudit.verify({ NaiveDropOldestBuffer(capacity: 32) }, records: mixedWorkload())
        XCTAssertTrue(violations.contains { if case .higherClassEvictedForLower = $0 { return true } else { return false } },
                      violations.map(\.description).joined(separator: "\n"))
    }

    func testAuditCatchesUnboundedGrowth() {
        let violations = BufferAudit.verify({ UnboundedBuffer(capacity: 32) }, records: mixedWorkload())
        XCTAssertTrue(violations.contains { if case .capacityExceeded = $0 { return true } else { return false } })
    }
}

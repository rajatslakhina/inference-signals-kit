import XCTest
@testable import InferenceSignals

final class PrimitiveTests: XCTestCase {

    // MARK: Saturating

    func testAddSaturatesAtBothEnds() {
        XCTAssertEqual(Saturating.add(Int64.max, 1), Int64.max)
        XCTAssertEqual(Saturating.add(Int64.min, -1), Int64.min)
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    func testSubtractAndMultiplySaturate() {
        XCTAssertEqual(Saturating.subtract(Int64.min, 1), Int64.min)
        XCTAssertEqual(Saturating.subtract(Int64.max, -1), Int64.max)
        XCTAssertEqual(Saturating.multiply(Int64.max, 2), Int64.max)
        XCTAssertEqual(Saturating.multiply(Int64.max, -2), Int64.min)
        XCTAssertEqual(Saturating.multiply(-3, 4), -12)
    }

    func testIntClampingHandlesNonFiniteAndOutOfRange() {
        XCTAssertEqual(Saturating.int(clamping: .nan), 0)
        XCTAssertEqual(Saturating.int(clamping: .infinity), Int.max)
        XCTAssertEqual(Saturating.int(clamping: -.infinity), Int.min)
        XCTAssertEqual(Saturating.int(clamping: 1e30), Int.max)
        XCTAssertEqual(Saturating.int(clamping: Double(Int.max)), Int.max)
        XCTAssertEqual(Saturating.int(clamping: 41.9), 41)
        XCTAssertEqual(Saturating.int64(clamping: 1e300), Int64.max)
    }

    func testDivideNeverTraps() {
        XCTAssertNil(Saturating.divide(5, by: 0))
        XCTAssertEqual(Saturating.divide(Int64.min, by: -1), Int64.max)
        XCTAssertEqual(Saturating.divide(9, by: 3), 3)
    }

    // MARK: Time

    func testElapsedClampsOutOfOrderInstants() {
        let a = Instant(nanoseconds: 100)
        let b = Instant(nanoseconds: 50)
        XCTAssertEqual(b.elapsed(since: a), .zero)
        XCTAssertEqual(a.elapsed(since: b).value, 50)
        XCTAssertEqual(Instant(nanoseconds: .min).elapsed(since: Instant(nanoseconds: .max)), .zero)
        XCTAssertEqual(Instant(nanoseconds: .max).elapsed(since: Instant(nanoseconds: .min)).value, .max)
    }

    func testNanosecondsClampNegativeAndSaturate() {
        XCTAssertEqual(Nanoseconds(-5).value, 0)
        XCTAssertEqual(Nanoseconds.seconds(Int64.max).value, Int64.max)
        XCTAssertEqual((Nanoseconds(Int64.max) + .milliseconds(1)).value, Int64.max)
        XCTAssertEqual(Nanoseconds.milliseconds(3).milliseconds, 3, accuracy: 1e-9)
    }

    func testManualClockAdvances() {
        let clock = ManualClock(start: 10)
        clock.advance(.milliseconds(1))
        XCTAssertEqual(clock.now().nanoseconds, 1_000_010)
    }

    func testSystemClockAdvances() {
        let clock = SystemClock()
        let first = clock.now()
        Thread.sleep(forTimeInterval: 0.002)
        let second = clock.now()
        // Strictly greater: a clock that returned a constant would fail.
        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThanOrEqual(second.elapsed(since: first).value, 1_000_000)
    }

    // MARK: Identifier

    func testIdentifierRejectsAnythingThatCouldCarryText() {
        XCTAssertThrowsSpecific(try Identifier(""), Identifier.ValidationError.empty)
        XCTAssertThrowsSpecific(try Identifier("summarise my email from Alice"),
                                Identifier.ValidationError.disallowedCharacter(" "))
        XCTAssertThrowsSpecific(try Identifier("a\nb"), Identifier.ValidationError.disallowedCharacter("\n"))
        XCTAssertThrowsSpecific(try Identifier("naïve"), Identifier.ValidationError.disallowedCharacter("ï"))
        XCTAssertThrowsSpecific(try Identifier("e\u{301}"), Identifier.ValidationError.disallowedCharacter("e\u{301}"))
        XCTAssertThrowsSpecific(try Identifier(String(repeating: "x", count: 65)),
                                Identifier.ValidationError.tooLong(65))
        XCTAssertNoThrow(try Identifier(String(repeating: "x", count: 64)))
        XCTAssertNoThrow(try Identifier("planner.v2_beta-3"))
    }

    func testIdentifierLiteralFallsBackVisiblyInsteadOfTrapping() {
        XCTAssertEqual(Identifier.literal("has space").rawValue, "invalid")
        XCTAssertEqual(Identifier.literal("ok").rawValue, "ok")
    }

    func testIdentifierDecodingRevalidates() throws {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(Identifier.self, from: Data("\"has space\"".utf8)))
        XCTAssertEqual(try decoder.decode(Identifier.self, from: Data("\"fine\"".utf8)).rawValue, "fine")
    }

    // MARK: Digest

    func testFNV1aMatchesPublishedVectors() {
        // Reference vectors for 64-bit FNV-1a.
        XCTAssertEqual(Digest(string: "").value, 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(Digest(string: "a").value, 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(Digest(string: "foobar").value, 0x85944171f73967e8)
    }

    func testUnorderedDigestIgnoresRegistrationOrder() {
        XCTAssertEqual(Digest(unorderedNames: ["b", "a", "c"]), Digest(unorderedNames: ["c", "b", "a"]))
        XCTAssertNotEqual(Digest(unorderedNames: ["a", "b"]), Digest(unorderedNames: ["a", "b", "c"]))
        XCTAssertNotEqual(Digest(unorderedNames: ["ab", "c"]), Digest(unorderedNames: ["a", "bc"]))
    }

    // MARK: SplitMix64

    func testSplitMixIsDeterministicAndBounded() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<100 {
            XCTAssertEqual(a.next(), b.next())
        }
        var c = SplitMix64(seed: 1)
        for _ in 0..<1_000 {
            let unit = c.nextUnit()
            XCTAssertGreaterThanOrEqual(unit, 0)
            XCTAssertLessThan(unit, 1)
            let value = c.next(in: 3...7)
            XCTAssertTrue((3...7).contains(value))
        }
        XCTAssertEqual(c.next(in: 5...5), 5)
        // Full-width range must not trap on the span computation.
        XCTAssertTrue((Int.min...Int.max).contains(c.next(in: Int.min...Int.max)))
        XCTAssertTrue((-10...10).contains(c.next(in: -10...10)))
    }
}

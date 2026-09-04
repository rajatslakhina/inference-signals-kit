import Foundation

// MARK: - Saturating arithmetic

/// Every arithmetic operation in this module that could trap goes through
/// here. A telemetry layer that can crash the feature it observes is worse
/// than no telemetry, so overflow saturates and division by zero is a value,
/// never a trap.
public enum Saturating {

    @inlinable
    public static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow { return rhs < 0 ? .min : .max }
        return value
    }

    @inlinable
    public static func subtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        if overflow { return rhs > 0 ? .min : .max }
        return value
    }

    @inlinable
    public static func multiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        if overflow { return (lhs < 0) != (rhs < 0) ? .min : .max }
        return value
    }

    @inlinable
    public static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow { return rhs < 0 ? .min : .max }
        return value
    }

    @inlinable
    public static func increment(_ value: inout Int) {
        value = add(value, 1)
    }

    /// `Int(Double)` traps on NaN, ±infinity and out-of-range values. This
    /// clamps instead. The ceiling is derived from `Int.max` rather than a
    /// 64-bit literal so the same code is correct where `Int` is 32 bits.
    @inlinable
    public static func int(clamping value: Double) -> Int {
        if value.isNaN { return 0 }
        // `Double(Int.max)` rounds up to 2^63 (or 2^31), which is itself out
        // of range, so compare with `>=` and return the exact maximum.
        if value >= Double(Int.max) { return .max }
        if value <= Double(Int.min) { return .min }
        return Int(value)
    }

    @inlinable
    public static func int64(clamping value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }

    /// Division that returns `nil` instead of trapping on a zero divisor
    /// or on `Int64.min / -1`.
    @inlinable
    public static func divide(_ lhs: Int64, by rhs: Int64) -> Int64? {
        if rhs == 0 { return nil }
        if lhs == .min && rhs == -1 { return .max }
        return lhs / rhs
    }
}

// MARK: - Time

/// A monotonic instant in nanoseconds since an arbitrary process-local
/// origin. Wall-clock time is never used for latency: the fleet's clocks
/// jump, and a negative "time to first token" is a bug report nobody can
/// act on.
public struct Instant: Hashable, Comparable, Sendable, Codable {
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Elapsed time from `earlier` to `self`, clamped to zero when the
    /// arguments arrive out of order. A span can only ever report a
    /// non-negative duration.
    public func elapsed(since earlier: Instant) -> Nanoseconds {
        Nanoseconds(Swift.max(0, Saturating.subtract(nanoseconds, earlier.nanoseconds)))
    }

    public func advanced(by delta: Nanoseconds) -> Instant {
        Instant(nanoseconds: Saturating.add(nanoseconds, delta.value))
    }
}

/// A non-negative duration in nanoseconds.
public struct Nanoseconds: Hashable, Comparable, Sendable, Codable {
    public let value: Int64

    /// Negative inputs are clamped to zero; a duration cannot be negative.
    public init(_ value: Int64) { self.value = Swift.max(0, value) }

    public static let zero = Nanoseconds(0)

    public static func milliseconds(_ ms: Int64) -> Nanoseconds {
        Nanoseconds(Saturating.multiply(ms, 1_000_000))
    }

    public static func seconds(_ s: Int64) -> Nanoseconds {
        Nanoseconds(Saturating.multiply(s, 1_000_000_000))
    }

    public var milliseconds: Double { Double(value) / 1_000_000 }
    public var seconds: Double { Double(value) / 1_000_000_000 }

    public static func < (lhs: Nanoseconds, rhs: Nanoseconds) -> Bool {
        lhs.value < rhs.value
    }

    public static func + (lhs: Nanoseconds, rhs: Nanoseconds) -> Nanoseconds {
        Nanoseconds(Saturating.add(lhs.value, rhs.value))
    }
}

/// The only clock the module reads. Injected so every timing path is
/// deterministic under test.
public protocol MonotonicClock: Sendable {
    func now() -> Instant
}

/// Backed by `DispatchTime.now()`, which is monotonic on every Apple
/// platform and on Linux.
public struct SystemClock: MonotonicClock {
    public init() {}
    public func now() -> Instant {
        let raw = DispatchTime.now().uptimeNanoseconds
        // `uptimeNanoseconds` is UInt64; clamp rather than trap if a machine
        // has been up for 292 years.
        let clamped = raw > UInt64(Int64.max) ? Int64.max : Int64(raw)
        return Instant(nanoseconds: clamped)
    }
}

/// A clock a test (or the demo's simulator) advances by hand.
public final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64

    public init(start: Int64 = 0) { current = start }

    public func now() -> Instant {
        lock.lock(); defer { lock.unlock() }
        return Instant(nanoseconds: current)
    }

    public func advance(_ delta: Nanoseconds) {
        lock.lock(); defer { lock.unlock() }
        current = Saturating.add(current, delta.value)
    }

    /// Moves the clock to an absolute value, backwards included. Exists so
    /// a test can prove the tracer survives a clock that misbehaves.
    public func rewind(to nanoseconds: Int64) {
        lock.lock(); defer { lock.unlock() }
        current = nanoseconds
    }
}

// MARK: - Identifiers

/// A short, character-restricted identifier. This is the only `String`-backed
/// value the wire schema carries, and its validation is what makes the
/// envelope redaction-safe by construction: a prompt, a user's name or a tool
/// argument cannot be smuggled into a field whose type refuses spaces,
/// punctuation and anything over 64 characters.
public struct Identifier: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let maximumLength = 64

    public let rawValue: String

    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case tooLong(Int)
        case disallowedCharacter(Character)
    }

    /// Accepts `[A-Za-z0-9._-]{1,64}` only.
    public init(_ rawValue: String) throws {
        if rawValue.isEmpty { throw ValidationError.empty }
        if rawValue.count > Identifier.maximumLength {
            throw ValidationError.tooLong(rawValue.count)
        }
        for character in rawValue where !Identifier.isAllowed(character) {
            throw ValidationError.disallowedCharacter(character)
        }
        self.rawValue = rawValue
    }

    /// Non-throwing construction for compile-time literals. Any literal that
    /// would fail validation is replaced by `"invalid"` rather than trapping,
    /// and the failure is visible in the wire data instead of in a crash log.
    public static func literal(_ rawValue: String) -> Identifier {
        (try? Identifier(rawValue)) ?? Identifier(unchecked: "invalid")
    }

    private init(unchecked: String) { rawValue = unchecked }

    private static func isAllowed(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true  // 0-9 A-Z a-z
        case 0x2D, 0x2E, 0x5F: return true                        // - . _
        default: return false
        }
    }

    public var description: String { rawValue }

    // Decoding re-validates so a hand-edited or hostile record cannot bypass
    // the invariant.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Digests

/// 64-bit FNV-1a. Chosen over `Hasher` deliberately: Swift seeds `Hasher`
/// per process, so a tool-set digest computed with `hashValue` would change
/// on every launch and the fleet could never group by it.
public struct Digest: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: UInt64

    public init(value: UInt64) { self.value = value }

    public static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    public static let prime: UInt64 = 0x0000_0100_0000_01b3

    public init(bytes: some Sequence<UInt8>) {
        var hash = Digest.offsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* Digest.prime
        }
        value = hash
    }

    public init(string: String) {
        self.init(bytes: string.utf8)
    }

    /// Order-independent digest of a set of names: sorted, NUL-joined.
    /// Two tool sets with the same members produce the same digest whatever
    /// order the app registered them in.
    public init(unorderedNames names: some Sequence<String>) {
        let joined = names.sorted().joined(separator: "\u{0}")
        self.init(string: joined)
    }

    public var description: String {
        String(value, radix: 16, uppercase: false)
    }
}

// MARK: - Deterministic random

/// SplitMix64. Used wherever the module needs a reproducible sequence —
/// the simulated executor and the sampler's tie-breaking — so a test that
/// fails once fails every time.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Uniform integer in `range`. An empty range returns its lower bound
    /// instead of trapping.
    public mutating func next(in range: ClosedRange<Int>) -> Int {
        let (span, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        if overflow {
            // The range covers more than half of `Int`; wrapping addition of
            // a full-width draw is uniform over it.
            return range.lowerBound &+ Int(truncatingIfNeeded: next())
        }
        if span <= 0 { return range.lowerBound }
        let width = UInt64(span) &+ 1
        return range.lowerBound &+ Int(next() % width)
    }
}

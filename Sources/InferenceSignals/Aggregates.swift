import Foundation

/// Which completions count as tail. A request whose total latency exceeds
/// its profile's budget is a tail record and is never sampled out.
public struct TailPolicy: Hashable, Sendable, Codable {
    public let defaultBudget: Nanoseconds
    public let budgets: [ProfileID: Nanoseconds]

    public init(defaultBudget: Nanoseconds, budgets: [ProfileID: Nanoseconds] = [:]) {
        self.defaultBudget = defaultBudget
        self.budgets = budgets
    }

    public func budget(for profile: ProfileID) -> Nanoseconds {
        budgets[profile] ?? defaultBudget
    }

    public func classify(total: Nanoseconds, profile: ProfileID) -> RecordClass {
        total > budget(for: profile) ? .tail : .nominal
    }
}

/// Running mean without storing samples. Sum is a `Double`, so it cannot
/// overflow; count saturates.
public struct RunningMean: Hashable, Sendable, Codable {
    public private(set) var sum: Double = 0
    public private(set) var count: Int = 0

    public init() {}

    public mutating func record(_ value: Double) {
        guard value.isFinite else { return }
        sum += value
        Saturating.increment(&count)
    }

    public var mean: Double? { count > 0 ? sum / Double(count) : nil }
}

/// Golden signals for one profile. Every field is bounded: histograms are
/// fixed-bucket, means are (sum, count), and counters saturate.
public struct ProfileSignals: Hashable, Sendable, Codable {
    public let profile: ProfileID

    // Traffic
    public private(set) var requestsStarted: Int = 0
    public private(set) var completions: Int = 0
    public private(set) var toolCalls: Int = 0

    // Errors
    public private(set) var failures: [InferenceFailure: Int] = [:]

    // Latency quartet (+ queue wait)
    public private(set) var queueWaitMilliseconds = BoundedHistogram.latencyMilliseconds()
    public private(set) var timeToFirstTokenMilliseconds = BoundedHistogram.latencyMilliseconds()
    public private(set) var totalMilliseconds = BoundedHistogram.latencyMilliseconds()
    public private(set) var tokensPerSecond = BoundedHistogram.tokensPerSecond()

    // Saturation
    public private(set) var contextHeadroom = RunningMean()
    public private(set) var prefixReuseRate = RunningMean()
    public private(set) var completionsUnderPressure: Int = 0

    public init(profile: ProfileID) { self.profile = profile }

    public var failureCount: Int {
        failures.values.reduce(0) { Saturating.add($0, $1) }
    }

    /// Failures over started requests, in [0, 1]; `nil` before any request.
    public var errorRate: Double? {
        guard requestsStarted > 0 else { return nil }
        return min(1, Double(failureCount) / Double(requestsStarted))
    }

    mutating func apply(_ record: SignalRecord) {
        switch record.payload {
        case .sessionStarted, .sessionEnded, .profileSwitched:
            break
        case .toolCall:
            Saturating.increment(&toolCalls)
        case .inferenceCompleted(let sample, let shape):
            Saturating.increment(&completions)
            queueWaitMilliseconds.record(sample.queueWait.milliseconds)
            timeToFirstTokenMilliseconds.record(sample.timeToFirstToken.milliseconds)
            totalMilliseconds.record(sample.total.milliseconds)
            if let tps = sample.tokensPerSecond { tokensPerSecond.record(tps) }
            contextHeadroom.record(shape.contextHeadroom)
            prefixReuseRate.record(shape.prefixReuseRate)
            if record.device.thermal >= .serious || record.device.energy == .lowPowerMode {
                Saturating.increment(&completionsUnderPressure)
            }
        case .inferenceFailed(let failure, let shape, _):
            failures[failure] = Saturating.add(failures[failure] ?? 0, 1)
            contextHeadroom.record(shape.contextHeadroom)
            prefixReuseRate.record(shape.prefixReuseRate)
        }
    }

    mutating func noteRequestStarted() {
        Saturating.increment(&requestsStarted)
    }
}

/// Everything the collector knows, as a value. Safe to hand to a view.
public struct SignalsSnapshot: Hashable, Sendable {
    public var profiles: [ProfileID: ProfileSignals]
    /// Profiles beyond `maximumProfiles` are folded into this bucket so a
    /// runaway profile-ID generator cannot grow the dictionary forever.
    public static let overflowProfile = ProfileID(.literal("_overflow"))

    public var recordsIngested: Int
    public var recordsSampledOut: Int
    public var bufferOccupancy: Int
    public var bufferCapacity: Int
    public var bufferEvictions: [RecordClass: Int]
    public var bufferRefusals: Int
    public var recordsDelivered: Int
    public var deliveryFailures: Int
    public var device: DeviceEnvelope

    public var samplingRateNominal: Double
}

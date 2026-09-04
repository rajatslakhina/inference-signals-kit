import Foundation

/// Limits on a single request's tool-calling loop.
public struct ToolLoopPolicy: Hashable, Sendable, Codable {
    /// Hard cap on tool calls per request.
    public let maximumCalls: Int
    /// Longest repeating pattern the monitor looks for.
    public let maximumPeriod: Int
    /// How many consecutive repetitions of a pattern count as a loop.
    public let repetitionsToFlag: Int

    public enum ConfigurationError: Error, Equatable, Sendable {
        case nonPositive(String, Int)
        case periodExceedsWindow(period: Int, repetitions: Int, maximumCalls: Int)
    }

    public init(maximumCalls: Int, maximumPeriod: Int, repetitionsToFlag: Int) throws {
        guard maximumCalls > 0 else { throw ConfigurationError.nonPositive("maximumCalls", maximumCalls) }
        guard maximumPeriod > 0 else { throw ConfigurationError.nonPositive("maximumPeriod", maximumPeriod) }
        guard repetitionsToFlag > 1 else { throw ConfigurationError.nonPositive("repetitionsToFlag", repetitionsToFlag) }
        // A pattern of `maximumPeriod` calls repeated `repetitionsToFlag`
        // times must fit inside the call budget, or cycle detection can
        // never fire before the budget does and is dead configuration.
        let (needed, overflow) = maximumPeriod.multipliedReportingOverflow(by: repetitionsToFlag)
        guard !overflow, needed <= maximumCalls else {
            throw ConfigurationError.periodExceedsWindow(period: maximumPeriod,
                                                         repetitions: repetitionsToFlag,
                                                         maximumCalls: maximumCalls)
        }
        self.maximumCalls = maximumCalls
        self.maximumPeriod = maximumPeriod
        self.repetitionsToFlag = repetitionsToFlag
    }

    /// 24 calls, patterns up to length 4, three repetitions.
    public static let standard: ToolLoopPolicy = {
        (try? ToolLoopPolicy(maximumCalls: 24, maximumPeriod: 4, repetitionsToFlag: 3))
            ?? ToolLoopPolicy(unchecked: (24, 4, 3))
    }()

    private init(unchecked values: (Int, Int, Int)) {
        maximumCalls = values.0
        maximumPeriod = values.1
        repetitionsToFlag = values.2
    }
}

/// One tool invocation as the monitor sees it: which tool, and a digest of
/// its arguments. The arguments themselves never enter the module.
public struct ToolCallSignature: Hashable, Sendable {
    public let toolDigest: Digest
    public let argumentsDigest: Digest

    public init(toolName: String, argumentsDigest: Digest) {
        self.toolDigest = Digest(string: toolName)
        self.argumentsDigest = argumentsDigest
    }

    public init(toolDigest: Digest, argumentsDigest: Digest) {
        self.toolDigest = toolDigest
        self.argumentsDigest = argumentsDigest
    }
}

public enum ToolLoopVerdict: Hashable, Sendable {
    case proceed(callsSoFar: Int)
    case budgetExhausted(calls: Int)
    /// The last `period × repetitions` calls are `repetitions` copies of the
    /// same `period`-long pattern.
    case cycleDetected(period: Int, repetitions: Int)

    public var isNonTermination: Bool {
        if case .proceed = self { return false }
        return true
    }
}

/// Detects a request's tool loop failing to terminate.
///
/// Two detectors, because they catch different failures. The call budget
/// catches a model that keeps finding *new* things to do; cycle detection
/// catches a model that is calling the same tool with the same arguments
/// and getting the same answer — which would burn the whole budget without
/// it, and which is the signature of a tool result the model cannot parse.
///
/// Memory is bounded at `maximumPeriod × repetitionsToFlag` signatures; the
/// history is a sliding window, not the full transcript.
public struct ToolLoopMonitor: Sendable {
    public let policy: ToolLoopPolicy
    public private(set) var callCount: Int = 0
    private var window: [ToolCallSignature] = []
    /// `maximumPeriod × repetitionsToFlag`; the policy initializer proved
    /// the product fits.
    private var windowCapacity: Int { policy.maximumPeriod * policy.repetitionsToFlag }
    /// Signatures currently retained. Never exceeds `windowCapacity`.
    public var windowSize: Int { window.count }

    public init(policy: ToolLoopPolicy = .standard) {
        self.policy = policy
    }

    public mutating func observe(_ signature: ToolCallSignature) -> ToolLoopVerdict {
        Saturating.increment(&callCount)
        window.append(signature)
        if window.count > windowCapacity {
            window.removeFirst(window.count - windowCapacity)
        }

        if callCount > policy.maximumCalls {
            return .budgetExhausted(calls: callCount)
        }

        // Shortest period first so a period-1 loop is reported as period 1,
        // not as period 2 repeated fewer times.
        for period in 1...policy.maximumPeriod {
            let span = period * policy.repetitionsToFlag
            guard window.count >= span else { break }
            let tail = window.suffix(span)
            if isRepetition(of: period, in: Array(tail)) {
                return .cycleDetected(period: period, repetitions: policy.repetitionsToFlag)
            }
        }
        return .proceed(callsSoFar: callCount)
    }

    /// True if `calls` is `calls.count / period` exact copies of its first
    /// `period` elements. `calls.count` is a multiple of `period` by
    /// construction of the caller.
    private func isRepetition(of period: Int, in calls: [ToolCallSignature]) -> Bool {
        guard period > 0, calls.count >= period, calls.count % period == 0 else { return false }
        for index in period..<calls.count where calls[index] != calls[index - period] {
            return false
        }
        return true
    }
}

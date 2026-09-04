import Foundation

/// A synthetic Dynamic Profile for the simulated executor: how fast it is,
/// how often it fails, and how much it uses tools.
public struct SimulatedProfile: Hashable, Sendable {
    public let id: ProfileID
    public let contextWindowTokens: Int
    public let promptTokens: ClosedRange<Int>
    public let outputTokens: ClosedRange<Int>
    public let timeToFirstToken: ClosedRange<Int>     // milliseconds
    public let tokensPerSecond: ClosedRange<Int>
    public let toolCalls: ClosedRange<Int>
    public let toolNames: [String]
    /// Probability a request fails, and how the failure is distributed.
    public let failureRate: Double
    /// Probability a request is 4× slower than its draw — the tail.
    public let tailRate: Double
    /// Probability a tool-using request gets stuck in a period-2 loop.
    public let loopRate: Double

    public init(id: ProfileID,
                contextWindowTokens: Int,
                promptTokens: ClosedRange<Int>,
                outputTokens: ClosedRange<Int>,
                timeToFirstToken: ClosedRange<Int>,
                tokensPerSecond: ClosedRange<Int>,
                toolCalls: ClosedRange<Int>,
                toolNames: [String],
                failureRate: Double,
                tailRate: Double,
                loopRate: Double) {
        self.id = id
        self.contextWindowTokens = max(1, contextWindowTokens)
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.timeToFirstToken = timeToFirstToken
        self.tokensPerSecond = tokensPerSecond
        self.toolCalls = toolCalls
        self.toolNames = toolNames
        self.failureRate = SimulatedProfile.unit(failureRate)
        self.tailRate = SimulatedProfile.unit(tailRate)
        self.loopRate = SimulatedProfile.unit(loopRate)
    }

    /// Clamps to [0, 1]; NaN becomes 0.
    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return value > 0 ? 1 : 0 }
        return min(1, max(0, value))
    }

    /// The three-phase agent from WWDC26 session 242, with numbers shaped
    /// to make the dashboard readable: the planner is slow and loops, the
    /// executor calls tools, the reviewer is fast and terse.
    public static let planner = SimulatedProfile(
        id: ProfileID(.literal("planner")), contextWindowTokens: 4096,
        promptTokens: 900...2_800, outputTokens: 80...300,
        timeToFirstToken: 180...600, tokensPerSecond: 14...30,
        toolCalls: 0...2, toolNames: ["search_notes", "list_calendar"],
        failureRate: 0.06, tailRate: 0.08, loopRate: 0.04)

    public static let executor = SimulatedProfile(
        id: ProfileID(.literal("executor")), contextWindowTokens: 4096,
        promptTokens: 600...2_000, outputTokens: 20...160,
        timeToFirstToken: 90...300, tokensPerSecond: 18...40,
        toolCalls: 1...5, toolNames: ["create_event", "send_message", "lookup_contact", "search_notes"],
        failureRate: 0.10, tailRate: 0.05, loopRate: 0.06)

    public static let reviewer = SimulatedProfile(
        id: ProfileID(.literal("reviewer")), contextWindowTokens: 4096,
        promptTokens: 300...1_200, outputTokens: 10...60,
        timeToFirstToken: 60...200, tokensPerSecond: 20...45,
        toolCalls: 0...0, toolNames: [],
        failureRate: 0.03, tailRate: 0.03, loopRate: 0)

    public static let standard: [SimulatedProfile] = [.planner, .executor, .reviewer]
}

public enum SimulatedOutcome: Hashable, Sendable {
    /// `intendedTail` is what the simulator *drew*; whether the tracer
    /// classified the record as tail is decided by the `TailPolicy`.
    case completed(intendedTail: Bool, generation: Nanoseconds)
    case failed(InferenceFailure)
    case loopDetected(ToolLoopVerdict)
}

/// Drives a `SessionTracer` through synthetic requests on a `ManualClock`.
/// Deterministic for a given seed; the demo uses it to generate traffic
/// and the tests use it to prove every record class is reachable.
public struct SimulatedExecutor: Sendable {
    private var rng: SplitMix64
    private var counter: UInt64 = 0
    /// Extra queue wait and slowdown applied when the device is hot.
    public var pressure: DeviceEnvelope = .nominal

    public init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
    }

    private var slowdown: Double {
        var factor = 1.0
        switch pressure.thermal {
        case .nominal: factor = 1.0
        case .fair: factor = 1.3
        case .serious: factor = 1.9
        case .critical: factor = 3.0
        }
        if pressure.energy == .lowPowerMode { factor *= 1.4 }
        return factor
    }

    private func scaled(_ milliseconds: Int64, by factor: Double) -> Nanoseconds {
        let value = Double(milliseconds) * factor
        return .milliseconds(Saturating.int64(clamping: value))
    }

    /// Runs one request against `tracer`, advancing `clock` as it goes.
    public mutating func run(profile: SimulatedProfile,
                             on tracer: SessionTracer,
                             clock: ManualClock) throws -> SimulatedOutcome {
        counter &+= 1
        let requestID = try Identifier("req-\(counter)")
        let promptTokens = rng.next(in: profile.promptTokens)
        let reused = rng.next(in: 0...promptTokens)
        let shape = PromptShape(promptTokens: promptTokens,
                                instructionTokens: rng.next(in: 100...400),
                                reusedPrefixTokens: reused,
                                contextWindowTokens: profile.contextWindowTokens,
                                attachmentCount: rng.nextUnit() < 0.1 ? 1 : 0,
                                toolSetDigest: Digest(unorderedNames: profile.toolNames),
                                schemaDigest: rng.nextUnit() < 0.5 ? Digest(string: "schema.v1") : nil)

        let handle = try tracer.enqueue(requestID: requestID, shape: shape)
        let queueWait = scaled(Int64(rng.next(in: 0...40)), by: slowdown)
        clock.advance(queueWait)
        try tracer.markRunning(handle)

        if rng.nextUnit() < profile.failureRate {
            let failures: [InferenceFailure] = [.guardrailRefusal, .structuredDecodeFailure,
                                                .contextWindowExceeded, .deadlineExceeded, .executorError]
            let index = rng.next(in: 0...(failures.count - 1))
            let failure = failures.indices.contains(index) ? failures[index] : .executorError
            clock.advance(scaled(Int64(rng.next(in: 50...400)), by: slowdown))
            try tracer.fail(handle, failure)
            return .failed(failure)
        }

        let isTail = rng.nextUnit() < profile.tailRate
        let factor = slowdown * (isTail ? 4 : 1)
        clock.advance(scaled(Int64(rng.next(in: profile.timeToFirstToken)), by: factor))
        try tracer.markFirstToken(handle)

        // Tool calls, possibly looping.
        let toolCalls = max(0, rng.next(in: profile.toolCalls))
        if let firstTool = profile.toolNames.first, toolCalls > 0, rng.nextUnit() < profile.loopRate {
            // A period-2 loop: the same tool alternating between two argument
            // digests, which is what a model stuck re-reading an unparseable
            // tool result looks like. Runs until the monitor objects.
            let a = ToolCallSignature(toolName: firstTool, argumentsDigest: Digest(string: "args-a"))
            let b = ToolCallSignature(toolName: firstTool, argumentsDigest: Digest(string: "args-b"))
            for step in 0..<tracer.toolLoopPolicy.maximumCalls {
                clock.advance(.milliseconds(Int64(rng.next(in: 10...60))))
                let verdict = try tracer.recordToolCall(handle, step % 2 == 0 ? a : b)
                if verdict.isNonTermination {
                    try tracer.fail(handle, .toolLoopNonTermination)
                    return .loopDetected(verdict)
                }
            }
        } else if !profile.toolNames.isEmpty {
            for step in 0..<toolCalls {
                // `toolNames` is non-empty here, so the modulus is positive
                // and the index is in range.
                let index = step % profile.toolNames.count
                guard profile.toolNames.indices.contains(index) else { break }
                let name = profile.toolNames[index]
                clock.advance(.milliseconds(Int64(rng.next(in: 10...60))))
                try tracer.recordToolCall(handle, ToolCallSignature(toolName: name,
                                                                    argumentsDigest: Digest(string: "args-\(counter)-\(step)")))
            }
        }

        let outputTokens = rng.next(in: profile.outputTokens)
        let tokensPerSecond = max(1, rng.next(in: profile.tokensPerSecond))
        let generationMilliseconds = Saturating.divide(Saturating.multiply(Int64(outputTokens), 1_000),
                                                       by: Int64(tokensPerSecond)) ?? 0
        clock.advance(scaled(generationMilliseconds, by: factor))
        try tracer.complete(handle, outputTokens: outputTokens)

        return .completed(intendedTail: isTail, generation: .milliseconds(generationMilliseconds))
    }
}

import XCTest
@testable import InferenceSignals

final class ToolLoopTests: XCTestCase {

    private func signature(_ tool: String, _ args: String) -> ToolCallSignature {
        ToolCallSignature(toolName: tool, argumentsDigest: Digest(string: args))
    }

    func testPolicyValidation() {
        XCTAssertThrowsSpecific(try ToolLoopPolicy(maximumCalls: 0, maximumPeriod: 1, repetitionsToFlag: 2),
                                ToolLoopPolicy.ConfigurationError.nonPositive("maximumCalls", 0))
        XCTAssertThrowsSpecific(try ToolLoopPolicy(maximumCalls: 5, maximumPeriod: 0, repetitionsToFlag: 2),
                                ToolLoopPolicy.ConfigurationError.nonPositive("maximumPeriod", 0))
        XCTAssertThrowsSpecific(try ToolLoopPolicy(maximumCalls: 5, maximumPeriod: 1, repetitionsToFlag: 1),
                                ToolLoopPolicy.ConfigurationError.nonPositive("repetitionsToFlag", 1))
        // 4 × 3 = 12 > 10: cycle detection could never fire before the budget.
        XCTAssertThrowsSpecific(try ToolLoopPolicy(maximumCalls: 10, maximumPeriod: 4, repetitionsToFlag: 3),
                                ToolLoopPolicy.ConfigurationError.periodExceedsWindow(period: 4, repetitions: 3, maximumCalls: 10))
        XCTAssertThrowsSpecific(try ToolLoopPolicy(maximumCalls: Int.max, maximumPeriod: Int.max, repetitionsToFlag: 2),
                                ToolLoopPolicy.ConfigurationError.periodExceedsWindow(period: Int.max, repetitions: 2, maximumCalls: Int.max))
        XCTAssertEqual(ToolLoopPolicy.standard.maximumCalls, 24)
    }

    func testDistinctCallsProceedUntilBudget() throws {
        var monitor = ToolLoopMonitor(policy: try ToolLoopPolicy(maximumCalls: 6, maximumPeriod: 2, repetitionsToFlag: 3))
        for i in 1...6 {
            XCTAssertEqual(monitor.observe(signature("t", "arg-\(i)")), .proceed(callsSoFar: i))
        }
        XCTAssertEqual(monitor.observe(signature("t", "arg-7")), .budgetExhausted(calls: 7))
        XCTAssertEqual(monitor.observe(signature("t", "arg-8")), .budgetExhausted(calls: 8))
    }

    func testPeriodOneLoopIsFlaggedAtThirdRepetition() throws {
        var monitor = ToolLoopMonitor(policy: try ToolLoopPolicy(maximumCalls: 24, maximumPeriod: 4, repetitionsToFlag: 3))
        XCTAssertEqual(monitor.observe(signature("read", "x")), .proceed(callsSoFar: 1))
        XCTAssertEqual(monitor.observe(signature("read", "x")), .proceed(callsSoFar: 2))
        XCTAssertEqual(monitor.observe(signature("read", "x")), .cycleDetected(period: 1, repetitions: 3))
    }

    func testPeriodTwoLoopIsReportedAsPeriodTwo() throws {
        var monitor = ToolLoopMonitor(policy: try ToolLoopPolicy(maximumCalls: 24, maximumPeriod: 4, repetitionsToFlag: 3))
        let a = signature("read", "a"), b = signature("read", "b")
        for call in [a, b, a, b, a] {
            XCTAssertEqual(monitor.observe(call), .proceed(callsSoFar: monitor.callCount))
        }
        XCTAssertEqual(monitor.observe(b), .cycleDetected(period: 2, repetitions: 3))
    }

    func testPeriodThreeLoopNeedsNineCalls() throws {
        var monitor = ToolLoopMonitor(policy: try ToolLoopPolicy(maximumCalls: 24, maximumPeriod: 4, repetitionsToFlag: 3))
        let pattern = [signature("a", "1"), signature("b", "2"), signature("c", "3")]
        var verdicts: [ToolLoopVerdict] = []
        for i in 0..<9 {
            let index = i % pattern.count
            verdicts.append(monitor.observe(pattern[index]))
        }
        XCTAssertEqual(verdicts.prefix(8).filter(\.isNonTermination).count, 0)
        XCTAssertEqual(verdicts.last, .cycleDetected(period: 3, repetitions: 3))
    }

    func testPatternLongerThanMaximumPeriodIsNotFlaggedAsCycle() throws {
        var monitor = ToolLoopMonitor(policy: try ToolLoopPolicy(maximumCalls: 30, maximumPeriod: 2, repetitionsToFlag: 3))
        let pattern = [signature("a", "1"), signature("b", "2"), signature("c", "3")]
        for i in 0..<12 {
            let verdict = monitor.observe(pattern[i % pattern.count])
            if case .cycleDetected = verdict { XCTFail("period 3 exceeds maximumPeriod 2 and must not be reported") }
        }
    }

    func testDifferentArgumentsBreakTheCycle() throws {
        var monitor = ToolLoopMonitor(policy: try ToolLoopPolicy(maximumCalls: 24, maximumPeriod: 4, repetitionsToFlag: 3))
        _ = monitor.observe(signature("read", "x"))
        _ = monitor.observe(signature("read", "x"))
        XCTAssertEqual(monitor.observe(signature("read", "y")), .proceed(callsSoFar: 3))
        XCTAssertEqual(monitor.observe(signature("read", "y")), .proceed(callsSoFar: 4))
        XCTAssertEqual(monitor.observe(signature("read", "y")), .cycleDetected(period: 1, repetitions: 3))
    }

    func testWindowIsBoundedAndCountSaturates() throws {
        var monitor = ToolLoopMonitor(policy: try ToolLoopPolicy(maximumCalls: Int.max, maximumPeriod: 2, repetitionsToFlag: 2))
        for i in 0..<10_000 { _ = monitor.observe(signature("t", "\(i)")) }
        XCTAssertEqual(monitor.callCount, 10_000)
        XCTAssertLessThanOrEqual(monitor.windowSize, 4)
    }

    func testSignatureDigestsAreStableAcrossConstruction() {
        let byName = ToolCallSignature(toolName: "search", argumentsDigest: Digest(string: "q"))
        let byDigest = ToolCallSignature(toolDigest: Digest(string: "search"), argumentsDigest: Digest(string: "q"))
        XCTAssertEqual(byName, byDigest)
    }
}

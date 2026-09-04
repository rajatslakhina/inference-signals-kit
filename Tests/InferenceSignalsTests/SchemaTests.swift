import XCTest
@testable import InferenceSignals

final class SchemaTests: XCTestCase {

    func testRecordRoundTripsThroughJSON() throws {
        let record = Fixtures.record(request: "req-1", recordClass: .tail, thermal: .fair, energy: .lowPowerMode, at: 1_234)
        let data = try JSONLinesEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SignalRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.schemaVersion, SignalRecord.schemaVersion)
    }

    func testEncodingIsDeterministicWithSortedKeys() throws {
        let record = Fixtures.record(request: "req-1", at: 5)
        // Two independently constructed encoders must agree byte for byte,
        // and the key order must be the sorted one — an encoder without
        // `.sortedKeys` would emit declaration order (`schemaVersion` first)
        // and fail the prefix assertion.
        let a = try JSONLinesEncoder().encode(record)
        let b = try JSONLinesEncoder().encode(record)
        XCTAssertEqual(a, b)
        let text = String(decoding: a, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"device":{"energy":"unconstrained","thermal":"nominal"},"payload":"#), text)
        XCTAssertTrue(text.hasSuffix(#""schemaVersion":1,"sessionID":"session-1","tier":"onDevice"}"#), text)
        let lines = try JSONLinesEncoder().encodeLines([record, record])
        XCTAssertEqual(lines.filter { $0 == 0x0A }.count, 2)
    }

    /// Walks every leaf of an encoded record and proves the only strings are
    /// validated identifiers or enum tags — nowhere for a prompt to hide.
    func testWireFormatCarriesNoFreeFormStrings() throws {
        let record = Fixtures.record(request: "req-1", recordClass: .error, at: 9,
                                     payload: .inferenceFailed(.structuredDecodeFailure, Fixtures.shape(), elapsed: .milliseconds(3)))
        let data = try JSONLinesEncoder().encode(record)
        let json = try JSONSerialization.jsonObject(with: data)
        var strings: [String] = []
        collectStrings(json, into: &strings)
        XCTAssertFalse(strings.isEmpty)
        let enumTags: Set<String> = Set(ExecutionTier.allCases.map(\.rawValue)
                                        + ThermalState.allCases.map(\.rawValue)
                                        + EnergyState.allCases.map(\.rawValue)
                                        + RecordClass.allCases.map(\.rawValue)
                                        + InferenceFailure.allCases.map(\.rawValue)
                                        + ["inferenceFailed", "inferenceCompleted", "sessionStarted",
                                           "sessionEnded", "profileSwitched", "toolCall"])
        for string in strings {
            let isIdentifier = (try? Identifier(string)) != nil
            XCTAssertTrue(isIdentifier || enumTags.contains(string), "unexpected free-form string: \(string)")
        }
        // The prompt shape is numbers and digests only.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("prompt\":\""))
        XCTAssertTrue(text.contains("\"promptTokens\":1000"))
    }

    func testDecodingRejectsAnIdentifierThatWouldCarryText() throws {
        let record = Fixtures.record(request: "req-1")
        var text = String(decoding: try JSONLinesEncoder().encode(record), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"req-1\"", with: "\"summarise this email\"")
        XCTAssertThrowsError(try JSONDecoder().decode(SignalRecord.self, from: Data(text.utf8)))
    }

    func testSamplingKeyIsPerRequestFallingBackToSession() {
        let a = Fixtures.record(request: "r1", payload: .toolCall(toolDigest: Digest(string: "x"), sequence: 1))
        let b = Fixtures.record(request: "r1")
        let c = Fixtures.record(request: "r2")
        let session = Fixtures.record(request: nil, payload: .sessionStarted)
        XCTAssertEqual(a.samplingKey, b.samplingKey)
        XCTAssertNotEqual(a.samplingKey, c.samplingKey)
        XCTAssertEqual(session.samplingKey, Digest(string: Fixtures.session.rawValue))
    }

    func testRecordClassAndThermalOrdering() {
        XCTAssertLessThan(RecordClass.nominal, .tail)
        XCTAssertLessThan(RecordClass.tail, .error)
        XCTAssertEqual(RecordClass.allCases.map(\.rank), [0, 1, 2])
        XCTAssertLessThan(ThermalState.nominal, .critical)
        XCTAssertEqual(ThermalState.allCases.map(\.rank), [0, 1, 2, 3])
    }

    private func collectStrings(_ value: Any, into strings: inout [String]) {
        switch value {
        case let string as String:
            strings.append(string)
        case let array as [Any]:
            for element in array { collectStrings(element, into: &strings) }
        case let object as [String: Any]:
            for (_, element) in object { collectStrings(element, into: &strings) }
        default:
            break
        }
    }
}

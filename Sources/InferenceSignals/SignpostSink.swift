import Foundation

#if canImport(os)
import os

/// Bridges records into Instruments as signpost events, so the dev-time
/// trace and the production stream are the same rows. Each record is
/// encoded with the same `JSONLinesEncoder` a file spool would use — there
/// is no second schema for the profiler.
///
/// Only the JSON of a `SignalRecord` is logged, and a `SignalRecord` cannot
/// carry prompt text (see `Identifier`), so `.public` privacy is safe here.
public struct SignpostSink: SignalSink {
    private let signposter: OSSignposter
    private let encoder = JSONLinesEncoder()

    public init(subsystem: String, category: String = "InferenceSignals") {
        signposter = OSSignposter(subsystem: subsystem, category: category)
    }

    public func deliver(_ records: [SignalRecord]) async throws {
        for record in records {
            let data = try encoder.encode(record)
            let line = String(decoding: data, as: UTF8.self)
            signposter.emitEvent("InferenceSignal", "\(line, privacy: .public)")
        }
    }
}
#endif

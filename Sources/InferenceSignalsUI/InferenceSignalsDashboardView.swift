#if canImport(SwiftUI)
import SwiftUI
import InferenceSignals

// MARK: - Configuration

/// Everything the dashboard needs, owned by the app. The app decides which
/// profiles exist, what "slow" means per profile, how hard to sample under
/// pressure and how big the buffer is; the view only renders the result.
public struct DashboardConfiguration: Sendable {
    public var profiles: [SimulatedProfile]
    public var tailPolicy: TailPolicy
    public var samplingPolicy: SamplingPolicy
    public var bufferCapacity: Int
    public var seed: UInt64
    public var toolLoopPolicy: ToolLoopPolicy

    public init(profiles: [SimulatedProfile],
                tailPolicy: TailPolicy,
                samplingPolicy: SamplingPolicy,
                bufferCapacity: Int,
                seed: UInt64,
                toolLoopPolicy: ToolLoopPolicy = .standard) {
        self.profiles = profiles
        self.tailPolicy = tailPolicy
        self.samplingPolicy = samplingPolicy
        self.bufferCapacity = bufferCapacity
        self.seed = seed
        self.toolLoopPolicy = toolLoopPolicy
    }
}

// MARK: - Model

@MainActor
@Observable
public final class DashboardModel {
    public private(set) var snapshot: SignalsSnapshot?
    public private(set) var recentDeliveries: [SignalRecord] = []
    public private(set) var lastOutcome: String = "Idle"
    public private(set) var setupError: String?
    public var thermal: ThermalState = .nominal { didSet { applyEnvelope() } }
    public var lowPower: Bool = false { didSet { applyEnvelope() } }
    public var isRunning = false

    private let configuration: DashboardConfiguration
    private let clock = ManualClock()
    private let environment = StaticEnvelopeProvider()
    private let sink = InMemorySink(capacity: 2_000)
    private var collector: SignalCollector?
    private var tracer: SessionTracer?
    private var executor: SimulatedExecutor
    private var profileCursor = 0
    private var driver: Task<Void, Never>?

    public init(configuration: DashboardConfiguration) {
        self.configuration = configuration
        self.executor = SimulatedExecutor(seed: configuration.seed)
        do {
            let buffer = try PriorityRingBuffer(capacity: configuration.bufferCapacity)
            let collector = try SignalCollector(sink: sink,
                                                buffer: buffer,
                                                samplingPolicy: configuration.samplingPolicy,
                                                tailPolicy: configuration.tailPolicy)
            self.collector = collector
            let tracer = SessionTracer(sessionID: .literal("demo-session"),
                                       initialProfile: configuration.profiles.first?.id ?? ProfileID(.literal("default")),
                                       tier: .onDevice,
                                       clock: clock,
                                       environment: environment,
                                       collector: collector,
                                       tailPolicy: configuration.tailPolicy,
                                       toolLoopPolicy: configuration.toolLoopPolicy)
            tracer.start()
            self.tracer = tracer
            snapshot = collector.snapshot()
        } catch {
            setupError = String(describing: error)
        }
    }

    private func applyEnvelope() {
        let envelope = DeviceEnvelope(thermal: thermal, energy: lowPower ? .lowPowerMode : .unconstrained)
        environment.set(envelope)
        executor.pressure = envelope
        collector?.updateDevice(envelope)
        snapshot = collector?.snapshot()
    }

    /// Runs one simulated request on the next profile in rotation, then
    /// switches the session to the profile after it (planner → executor →
    /// reviewer → planner …).
    public func step() {
        guard let tracer, let collector, !configuration.profiles.isEmpty else { return }
        let index = profileCursor % configuration.profiles.count
        guard configuration.profiles.indices.contains(index) else { return }
        let profile = configuration.profiles[index]
        profileCursor = Saturating.add(profileCursor, 1)
        if tracer.currentProfile != profile.id {
            tracer.switchProfile(to: profile.id)
        }
        do {
            let outcome = try executor.run(profile: profile, on: tracer, clock: clock)
            lastOutcome = describe(outcome, profile: profile)
        } catch {
            lastOutcome = "Tracer error: \(error)"
        }
        snapshot = collector.snapshot()
    }

    public func flush() {
        guard let collector else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await collector.flush()
            let delivered = await self.sink.delivered
            self.recentDeliveries = Array(delivered.suffix(40).reversed())
            self.snapshot = collector.snapshot()
        }
    }

    /// Starts or pauses a driver that issues one request every 120 ms and
    /// flushes every 20 requests.
    public func toggleRunning() {
        if isRunning {
            driver?.cancel()
            driver = nil
            isRunning = false
        } else {
            isRunning = true
            driver = Task { @MainActor [weak self] in
                var steps = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    self.step()
                    steps = Saturating.add(steps, 1)
                    if steps % 20 == 0 { self.flush() }
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
        }
    }

    private func describe(_ outcome: SimulatedOutcome, profile: SimulatedProfile) -> String {
        switch outcome {
        case .completed(let intendedTail, let generation):
            return "\(profile.id): completed in \(Saturating.int(clamping: generation.milliseconds)) ms generation\(intendedTail ? " (tail draw)" : "")"
        case .failed(let failure):
            return "\(profile.id): failed — \(failure.rawValue)"
        case .loopDetected(let verdict):
            return "\(profile.id): tool loop flagged — \(verdict)"
        }
    }
}

// MARK: - View

public struct InferenceSignalsDashboardView: View {
    @State private var model: DashboardModel

    public init(configuration: DashboardConfiguration) {
        _model = State(initialValue: DashboardModel(configuration: configuration))
    }

    public var body: some View {
        NavigationStack {
            List {
                if let error = model.setupError {
                    Section("Configuration rejected") {
                        Text(error).font(.footnote.monospaced())
                    }
                }
                controls
                if let snapshot = model.snapshot {
                    pipeline(snapshot)
                    ForEach(sortedProfiles(snapshot), id: \.profile) { signals in
                        profileSection(signals, snapshot: snapshot)
                    }
                }
                deliveries
            }
            .navigationTitle("Inference Signals")
        }
    }

    private var controls: some View {
        Section("Device pressure") {
            Picker("Thermal", selection: $model.thermal) {
                ForEach(ThermalState.allCases, id: \.self) { state in
                    Text(state.rawValue.capitalized).tag(state)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Low Power Mode", isOn: $model.lowPower)
            HStack {
                Button(model.isRunning ? "Pause traffic" : "Run traffic") { model.toggleRunning() }
                    .buttonStyle(.borderedProminent)
                Button("One request") { model.step() }
                    .buttonStyle(.bordered)
                Button("Flush") { model.flush() }
                    .buttonStyle(.bordered)
            }
            Text(model.lastOutcome)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func pipeline(_ snapshot: SignalsSnapshot) -> some View {
        Section("Pipeline") {
            row("Nominal keep rate", percent(snapshot.samplingRateNominal))
            row("Ingested / sampled out", "\(snapshot.recordsIngested) / \(snapshot.recordsSampledOut)")
            row("Buffer", "\(snapshot.bufferOccupancy) / \(snapshot.bufferCapacity)")
            row("Evicted nominal · tail · error",
                "\(snapshot.bufferEvictions[.nominal] ?? 0) · \(snapshot.bufferEvictions[.tail] ?? 0) · \(snapshot.bufferEvictions[.error] ?? 0)")
            row("Refused (buffer full of higher class)", "\(snapshot.bufferRefusals)")
            row("Delivered / delivery failures", "\(snapshot.recordsDelivered) / \(snapshot.deliveryFailures)")
        }
    }

    private func profileSection(_ signals: ProfileSignals, snapshot: SignalsSnapshot) -> some View {
        Section("Profile · \(signals.profile.description)") {
            row("Requests / completions / tool calls",
                "\(signals.requestsStarted) / \(signals.completions) / \(signals.toolCalls)")
            row("Error rate", signals.errorRate.map(percent) ?? "—")
            if !signals.failures.isEmpty {
                ForEach(signals.failures.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { failure in
                    row("  \(failure.rawValue)", "\(signals.failures[failure] ?? 0)")
                        .foregroundStyle(failure == .toolLoopNonTermination ? Color.red : Color.primary)
                }
            }
            row("Queue wait p50 / p95", quartet(signals.queueWaitMilliseconds))
            row("TTFT p50 / p95", quartet(signals.timeToFirstTokenMilliseconds))
            row("Total p50 / p95", quartet(signals.totalMilliseconds))
            row("Tokens/s p50 / p95", quartet(signals.tokensPerSecond, unit: " t/s"))
            row("Context headroom (mean)", signals.contextHeadroom.mean.map(percent) ?? "—")
            row("KV prefix reuse (mean)", signals.prefixReuseRate.mean.map(percent) ?? "—")
            row("Completions under pressure", "\(signals.completionsUnderPressure)")
        }
    }

    private var deliveries: some View {
        Section("Last flush (newest first)") {
            if model.recentDeliveries.isEmpty {
                Text("Nothing delivered yet — tap Flush.").foregroundStyle(.secondary)
            }
            ForEach(Array(model.recentDeliveries.enumerated()), id: \.offset) { _, record in
                HStack(alignment: .top) {
                    Text(record.recordClass.rawValue)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color(for: record.recordClass).opacity(0.2))
                        .clipShape(Capsule())
                    VStack(alignment: .leading) {
                        Text("\(record.profile.description) · \(record.requestID?.rawValue ?? "session")")
                            .font(.footnote.monospaced())
                        Text(summary(of: record.payload))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func sortedProfiles(_ snapshot: SignalsSnapshot) -> [ProfileSignals] {
        snapshot.profiles.values.sorted { $0.profile.description < $1.profile.description }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).font(.body.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Saturating.int(clamping: (value * 100).rounded()))%"
    }

    private func quartet(_ histogram: BoundedHistogram, unit: String = " ms") -> String {
        guard let p50 = histogram.p50, let p95 = histogram.p95 else { return "—" }
        return "\(Saturating.int(clamping: p50.rounded())) / \(Saturating.int(clamping: p95.rounded()))\(unit)"
    }

    private func color(for recordClass: RecordClass) -> Color {
        switch recordClass {
        case .nominal: return .green
        case .tail: return .orange
        case .error: return .red
        }
    }

    private func summary(of payload: SignalPayload) -> String {
        switch payload {
        case .sessionStarted: return "session started"
        case .sessionEnded(let count): return "session ended after \(count) requests"
        case .profileSwitched(let from): return "profile switched from \(from?.description ?? "none")"
        case .toolCall(let digest, let sequence): return "tool call #\(sequence) · tool \(digest)"
        case .inferenceCompleted(let sample, let shape):
            let tps = sample.tokensPerSecond.map { "\(Saturating.int(clamping: $0.rounded())) t/s" } ?? "— t/s"
            return "ttft \(Saturating.int(clamping: sample.timeToFirstToken.milliseconds)) ms · total \(Saturating.int(clamping: sample.total.milliseconds)) ms · \(tps) · headroom \(percent(shape.contextHeadroom))"
        case .inferenceFailed(let failure, _, let elapsed):
            return "\(failure.rawValue) after \(Saturating.int(clamping: elapsed.milliseconds)) ms"
        }
    }
}
#endif

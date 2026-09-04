# InferenceSignals

**Golden signals for a subsystem that is allowed to be wrong.**

Xcode 27 ships an Instruments template for the Foundation Models framework: sessions → requests → inferences → tool calls, with the instructions and tools that were live at each moment and where the time went. It is excellent, and it has two properties that make it an architecture problem rather than a tooling tip. It only runs on a device you are holding, and it only sees traffic that goes through the framework. Neither of those is where probabilistic failures live. The fleet is, and the feature your team wired straight to a vendor SDK is invisible to it.

`InferenceSignals` is the layer that survives shipping: a redaction-safe event envelope, the four inference latencies plus the queue wait Instruments cannot see, saturation as KV-cache reuse and context-window headroom, an error taxonomy for failures that never throw, per-Dynamic-Profile attribution, sampling that thins the middle of the distribution under thermal pressure and *never* the tail, a bounded buffer that evicts by class, and one schema shared by the `os_signpost` bridge and the production stream — so the dev-time picture and the fleet picture are the same rows.

The core module imports nothing but `Foundation`. Every decision in it is unit-tested on Linux, and the properties the README claims are proven by audits that are also run against deliberately broken implementations.

- **Library:** this repo — `InferenceSignals` (core) + `InferenceSignalsUI` (SwiftUI dashboard)
- **Demo app:** (added after the companion repo is pushed — see below)

---

## Why this matters

A conventional service has an SLO because its behaviour is a function of its inputs. An inference call is not. It can complete cleanly and be wrong; it can refuse politely and count as success in every HTTP-shaped metric you own; it can call the same tool forty times and return `200`. Session 243's own demo is the whole argument in miniature — a feature that never errored, never crashed, and quietly did the wrong thing because the wrong instruction was live. Nothing but the trace made that visible.

So the four golden signals need re-deriving for this subsystem, and three decisions follow that a senior engineer has to make before the first line ships:

1. **What is an error?** A guardrail refusal, a tool loop that never terminates, a structured-output decode failure and a blown deadline are all errors, and none of them is an exception. They need their own taxonomy (`InferenceFailure`) or they are invisible.
2. **What may leave the device?** A prompt is user data. The envelope must be incapable of carrying it — not scrubbed, *incapable* — or the first incident will be a privacy one.
3. **What do you drop when the device is hot?** Thermal pressure is exactly when inference misbehaves, and exactly when a naïve sampler starts throwing telemetry away. Dropping uniformly under pressure discards the records you enabled telemetry to see.

The observability commitment is made at architecture time, before a line ships, in the choice of which abstraction every inference call goes through. This package is what that abstraction hangs the signals on.

## What's in it

| Type | Role |
|---|---|
| `SignalRecord` | The one wire row. `Codable`, deterministic JSON, `schemaVersion` field. The only string-typed members are validated `Identifier`s. |
| `Identifier` | `[A-Za-z0-9._-]{1,64}`, validated on construction *and* on decode. Rejects spaces, punctuation, combining marks — anything a prompt would contain. |
| `PromptShape` | Token counts, context window, reused-prefix tokens, attachment count, an order-independent `toolSetDigest`, an optional `schemaDigest`. No text field exists. |
| `LatencySample` | Queue wait, time to first token, total, output tokens; `tokensPerSecond` is `nil` (not ∞) when the generation phase is instantaneous. |
| `InferenceFailure` | `guardrailRefusal`, `toolLoopNonTermination`, `structuredDecodeFailure`, `contextWindowExceeded`, `deadlineExceeded`, `cancelled`, `executorError`. |
| `SessionTracer` | Mirrors the Instruments tree. Profile and device envelope are frozen at *enqueue*; a mid-request profile switch does not reassign blame. Issues opaque `RequestHandle`s that cannot be replayed against another tracer. `end()` cancels open requests so none vanish. |
| `ToolLoopMonitor` | A call budget plus period-1…4 cycle detection over a sliding window; the first non-termination verdict emits one error record whether or not the caller acts on it. |
| `TailPolicy` | Per-profile latency budgets; a completion over budget is `.tail` and is never sampled out. |
| `SamplingPolicy` / `Sampler` | Nominal keep rate per thermal state (100 → 50 → 10 → 2 %, halved in Low Power Mode). The policy type has no field for `.tail` or `.error` rates — protection is structural. Decisions are deterministic and request-coherent. |
| `PriorityRingBuffer` | Hard-capped. Evicts the oldest record of the lowest class present, only if it does not outrank the incoming one; refuses otherwise. Three FIFO queues, O(1) eviction, oldest-first drain, compaction proven not to leak. |
| `SignalCollector` | Synchronous, lock-protected ingest (no `await` on the inference path). Aggregates *before* sampling. `flush()` drains under the lock before awaiting the sink, so concurrent flushes deliver every record exactly once and a failed delivery re-offers through the buffer's own bound. Profile map capped with an `_overflow` bucket. |
| `BoundedHistogram` | Fixed log-spaced buckets, `bounds.count + 1` counters forever, interpolated quantiles. |
| `ProfileSignals` / `SignalsSnapshot` | Traffic, errors, the latency quartet, saturation gauges — per profile, as a value. |
| `SignpostSink` (Apple only) / `InMemorySink` / `JSONLinesEncoder` | Same encoder, same rows, different destinations. |
| `SamplingAudit` / `BufferAudit` | Executable versions of the README's claims. Both are run against the shipped types and against sabotaged ones. |
| `SimulatedExecutor` / `SimulatedProfile` | A deterministic planner / executor / reviewer workload on a `ManualClock`, used by the demo and by the tests that prove every record class is reachable. |

## Design decisions

### The envelope cannot carry a prompt — by type, not by policy

`SignalRecord` has exactly one string-backed type, `Identifier`, and it refuses anything outside `[A-Za-z0-9._-]{1,64}` at construction and again on decode. Everything about a prompt travels as *shape*: token counts, a digest of the sorted tool names, a digest of the output schema. `SchemaTests.testWireFormatCarriesNoFreeFormStrings` walks every leaf of an encoded record and asserts that each string is either a valid identifier or an enum tag.

**Rejected:** a redaction pass over a free-form `metadata: [String: String]`. It puts the privacy property in a function someone has to remember to call, and the first feature that logs `prompt.prefix(40)` "for debugging" defeats it.

### Tail and error records are protected structurally

`SamplingPolicy` stores a keep rate per thermal state for nominal records and nothing else. There is no field in which to configure "10% of errors." `keepProbability(for: .error, …)` returns `1` from a `switch`, not from a lookup. Under `.critical` thermal state in Low Power Mode the sampler keeps 1% of healthy completions and 100% of refusals, loops, decode failures and over-budget completions — the tail of the distribution is the whole point of fleet telemetry, and pressure is when it moves.

**Rejected:** a single sampling rate with an "errors are important" comment. Tried the industry-standard way. Also rejected: tail sampling at flush time (decide after the request is complete). It is more accurate and it is what a server-side collector does, but on device it means holding every record until its request finishes, which is the unbounded growth this design refuses.

### Sampling is a pure function of `(request key, envelope-at-enqueue, class)`

`SessionTracer` stamps every record of a request with the device envelope observed when that request was enqueued. The sampler hashes the request ID, mixes it, and compares it with the keep rate for that envelope. All nominal records of one request therefore see the same key and the same rate, and are kept or dropped together — the fleet never receives a tool call with no completion.

This found a real bug. The first version took FNV-1a's top 53 bits directly as the unit in `[0, 1)`. FNV-1a is a fine identity hash, but for short, sequential inputs (`req-1`, `req-2`, …) its high bits cluster, and the sampler kept 80% of nominal traffic at a configured 50%. `SamplingAudit.keepRateOffTarget` caught it; the fix is a MurmurHash3 finalizer before the bits are taken, and the unmixed version is kept in the tests as a negative control so the audit is proven to detect that class of mistake.

**Rejected:** `Hasher`. Swift seeds it per process, so the same request would be kept on one launch and dropped on the next, and the fleet could never group by tool-set digest either.

### Aggregates are computed before sampling

`SignalCollector.ingest` updates the per-profile histograms and counters, *then* asks the sampler. Sampling thins what you ship; it must never thin what you count. Otherwise the error rate on the dashboard changes every time the device warms up.

### The buffer evicts by class, and is bounded even for errors

`PriorityRingBuffer` is hard-capped. When full, an incoming record displaces the oldest record of the lowest class present, but only if that class does not outrank it. A nominal record arriving into a buffer full of errors is *refused* (counted, never admitted at an error's expense). Within a class the policy is drop-oldest, so a flood of errors is still bounded. A telemetry buffer that grows without limit during an incident is a second incident.

`BufferAudit` checks capacity, the class rules and oldest-first drain order; it is run against the shipped buffer (passes), a naive single-FIFO drop-oldest buffer (fails on `higherClassEvictedForLower`), and an unbounded buffer (fails on `capacityExceeded`).

**Rejected:** a priority queue ordered by `(class, time)`. Simpler to describe, but drain order would no longer be oldest-first across classes, and O(log n) per offer on the inference path for no benefit over three FIFOs.

### Ingest is synchronous; only flush is `async`

Instrumentation sits on the inference path. An actor-isolated `ingest` means an `await` per tool call and per token, which turns the observer into a scheduling participant in the thing it observes. `SignalCollector` is a lock-protected class; every critical section is a synchronous helper, and the lock is never held across the sink's `await`. `flush()` drains the buffer under the lock *before* suspending, so a concurrent flush finds an empty buffer rather than the same batch; `CollectorTests.testConcurrentFlushesDeliverEveryRecordExactlyOnce` parks one delivery inside a gated sink, ingests 300 more records, races eight flushes against it, and asserts 800 unique deliveries.

**Trade-off, documented:** when a delivery fails, the batch is re-offered through the buffer and re-sequenced *after* anything ingested during the outage. The batch's internal order survives; cross-batch order does not. Consumers order by `recordedAt`, never by arrival.

### Attribution is frozen at enqueue

A Dynamic Profile session becomes a planner, then an executor, then a reviewer. If the session switches profile while a request is in flight, the request keeps the profile that issued it — the planner that produced a slow request keeps the blame after the session has moved on. The same holds for the device envelope: a request enqueued at `.serious` is a `.serious` request even if the device cools before it completes. `TracerTests.testAttributionIsFrozenAtEnqueue` proves both.

### Tool loops are two detectors, not one

A call budget catches a model that keeps finding *new* things to do. It does not catch the more common failure — the same tool with the same arguments, three times, because the model cannot parse the result — until the whole budget is burned. Cycle detection (period 1…4, sliding window, memory bounded at `period × repetitions`) catches that on the third repetition. `ToolLoopPolicy` refuses a configuration where the cycle window cannot fit inside the budget, because that detector would be dead code.

### No trapping arithmetic reachable from the public API

Every duration is a difference of two monotonic `Instant`s clamped at zero (a clock that goes backwards produces `0`, never a negative TTFT — tested). Counters saturate. `Int(Double)` goes through `Saturating.int(clamping:)`, which handles NaN, ±∞ and derives its ceiling from `Int.max` rather than a 64-bit literal. `tokensPerSecond` is optional rather than infinite. `SplitMix64.next(in:)` handles a full-width range without overflowing the span. There are no force-unwraps in the module.

## Verification

Run on Linux (Swift 6.0.3, `swift:6.0` container in CI):

```
rm -rf .build
swift build -Xswiftc -warnings-as-errors            # Build complete, 0 warnings
swift build --build-tests -Xswiftc -warnings-as-errors
swift test                                          # Executed 88 tests, with 0 failures
```

The 88 XCTest cases cover: saturating arithmetic at both ends; identifier validation (spaces, newlines, combining marks, length 65) and re-validation on decode; FNV-1a against published vectors; histogram bucket search, interpolation and the overflow bucket; sampling-policy validation (a rate that *rises* with pressure is rejected); determinism and request coherence; the three sampling audits against `Sampler` (passes) and against a flat-rate sampler, an incoherent sampler, a half-rate sampler and the unmixed FNV sampler (each fails on the intended violation); buffer class rules, refusal, drain order and a 50 000-offer compaction test with a storage-footprint bound; buffer audits against the shipped buffer, naive drop-oldest and unbounded; tool-loop period 1/2/3 detection, budget exhaustion and the no-false-positive case; tracer timing, frozen attribution, cancel-on-end, invalid transitions, non-transferable handles and a rewound clock; collector aggregation-before-sampling, exactly-once concurrent flush, failed-delivery re-offer under the buffer bound and the profile cap; wire-format string audit and JSON round trip; simulator determinism and reachability of every record class.

The macOS CI job compiles `InferenceSignalsUI` for `generic/platform=iOS Simulator`. **Nothing in this repo has been run on a Simulator or a device** — see the demo repo's README for what was and was not verified there.

## Using it

```swift
let collector = try SignalCollector(sink: SignpostSink(subsystem: "com.example.app"),
                                    buffer: try PriorityRingBuffer(capacity: 512),
                                    samplingPolicy: .standard,
                                    tailPolicy: TailPolicy(defaultBudget: .milliseconds(1_500)))

let tracer = SessionTracer(sessionID: try Identifier("session-\(UUID().uuidString.prefix(8))"),
                           initialProfile: ProfileID(try Identifier("planner")),
                           tier: .onDevice,
                           clock: SystemClock(),
                           environment: ProcessInfoEnvelopeProvider(),
                           collector: collector,
                           tailPolicy: TailPolicy(defaultBudget: .milliseconds(1_500)))
tracer.start()

let handle = try tracer.enqueue(requestID: try Identifier("req-\(n)"), shape: shape)
try tracer.markRunning(handle)
// … on first streamed token:
try tracer.markFirstToken(handle)
// … on each tool call the model makes:
let verdict = try tracer.recordToolCall(handle, ToolCallSignature(toolName: call.name,
                                                                  argumentsDigest: Digest(string: call.argumentsJSON)))
if verdict.isNonTermination { try tracer.fail(handle, .toolLoopNonTermination) }
// … on completion:
try tracer.complete(handle, outputTokens: response.tokenCount)

await collector.flush()
```

`Package.swift`:

```swift
.package(url: "https://github.com/rajatslakhina/inference-signals-kit.git", from: "1.0.0")
```

## Layout

```
Sources/InferenceSignals/     Primitives · Schema · Histogram · Sampling · Buffer
                              ToolLoop · Aggregates · Collector · Tracer
                              SignpostSink (Apple only) · Simulation
Sources/InferenceSignalsUI/   InferenceSignalsDashboardView (+ DashboardModel)
Tests/InferenceSignalsTests/  88 XCTest cases, Linux-runnable
```

## License

MIT — see `LICENSE`.

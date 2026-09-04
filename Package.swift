// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "inference-signals-kit",
    // Only platforms CI actually builds are declared. Linux needs no
    // declaration; the macOS job compiles the UI module for
    // `generic/platform=iOS Simulator`.
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "InferenceSignals", targets: ["InferenceSignals"]),
        .library(name: "InferenceSignalsUI", targets: ["InferenceSignalsUI"])
    ],
    targets: [
        .target(name: "InferenceSignals"),
        .target(name: "InferenceSignalsUI", dependencies: ["InferenceSignals"]),
        .testTarget(name: "InferenceSignalsTests", dependencies: ["InferenceSignals"])
    ]
)

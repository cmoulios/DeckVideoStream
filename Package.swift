// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeckVideoStream",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DeckVideoStream", targets: ["DeckVideoStream"]),
        .executable(name: "dvs-harness", targets: ["dvs-harness"]),
    ],
    targets: [
        // Engine-agnostic predictive video frame source: demux/decode on
        // its own threads, decode-ahead ring, pinned loop ranges. Knows
        // nothing about any host app's mixer; it takes a position oracle.
        .target(name: "DeckVideoStream"),
        // Spike / measurement CLI (throughput, cold access, reorder, memory).
        // Swift 5 mode: scaffolding, not shipped.
        .executableTarget(
            name: "dvs-harness",
            dependencies: ["DeckVideoStream"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DeckVideoStreamTests", dependencies: ["DeckVideoStream"]),
    ]
)

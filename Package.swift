// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacSnap",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacSnap", targets: ["MacSnap"]),
    ],
    targets: [
        // Pure, headless-testable pieces: document model, op log, renderer,
        // stitcher, config, persistence.
        .target(
            name: "MacSnapCore",
            path: "Sources/MacSnapCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The AppKit application: capture overlay, editor, previews/pins,
        // scroll capture, hotkeys, menu bar.
        .executableTarget(
            name: "MacSnap",
            dependencies: ["MacSnapCore"],
            path: "Sources/MacSnap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacSnapCoreTests",
            dependencies: ["MacSnapCore"],
            path: "Tests/MacSnapCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

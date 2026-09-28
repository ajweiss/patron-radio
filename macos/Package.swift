// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PatronRadio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PatronRadio", targets: ["PatronRadio"]),
    ],
    targets: [
        // Everything testable without a UI: stream parsing, loudness, the
        // playback state machine, station data and the audio pipeline.
        .target(
            name: "PatronRadioCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app: status item, popover, settings window.
        .executableTarget(
            name: "PatronRadio",
            dependencies: ["PatronRadioCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PatronRadioCoreTests",
            dependencies: ["PatronRadioCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

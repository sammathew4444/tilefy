// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tilefy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Tilefy", targets: ["Tilefy"]),
    ],
    targets: [
        // Pure tiling logic. No AppKit or Accessibility, so it is fully unit-testable.
        .target(name: "TilefyCore"),
        // The menu bar app: Accessibility, hotkeys, settings UI.
        .executableTarget(name: "Tilefy", dependencies: ["TilefyCore"]),
        .testTarget(name: "TilefyCoreTests", dependencies: ["TilefyCore"]),
        // Real-window tests. See scripts/e2e.sh. Only ever touches windows it opened itself.
        .executableTarget(name: "TilefyE2E", dependencies: ["TilefyCore", "CTilefyE2E"]),
        .target(name: "CTilefyE2E"),
    ]
)

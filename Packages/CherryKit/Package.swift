// swift-tools-version:6.0
import PackageDescription

// Hexagonal layout:
//   CherryCore      – domain, protocol codecs, ports, application services (no UI, no IOKit, no TCA)
//   CherryAdapters  – driven adapters: IOKit HID, URLSession catalog, on-disk firmware cache
//   CherrySimulation – in-memory stand-ins for the driven adapters (UI tests, demo mode, profiling)
//   CherryPresentation – Chinese text for errors, lighting values and automation results (Foundation only), shared by
//                     the UI, App Intents, the control service and the CLI
//   CherryFeatures  – driving adapter: TCA reducers + SwiftUI views, talking to the core through dependency clients
//   CherryControl   – local control protocol (Unix socket, line-delimited JSON): client + socket server, Foundation only
//   CherryControlService – driving adapter: maps control requests to KeyboardAutomation inside the app process
//   CherryCLI       – the `cherry` command and `cherry mcp` (swift-sdk, CLI only): goes through the running app, or assembles
//                     the core itself and connects to the keyboard directly when no app answers
// The app target is the composition root that wires adapters into the feature clients.
let package = Package(
    name: "CherryKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CherryCore", targets: ["CherryCore"]),
        .library(name: "CherryAdapters", targets: ["CherryAdapters"]),
        .library(name: "CherryPresentation", targets: ["CherryPresentation"]),
        .library(name: "CherryFeatures", targets: ["CherryFeatures"]),
        .library(name: "CherrySimulation", targets: ["CherrySimulation"]),
        .executable(name: "CherryProfiler", targets: ["CherryProfiler"]),
        .library(name: "CherryControl", targets: ["CherryControl"]),
        .library(name: "CherryControlService", targets: ["CherryControlService"]),
        .executable(name: "cherry", targets: ["CherryCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
        // swift-sdk 的传输协议用到 `Logger`；版本由 swift-sdk 决定，这里只为能直接引用这个模块。
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(name: "CherryCore"),
        .executableTarget(name: "CherryProfiler", dependencies: [
            "CherryCore", "CherryAdapters", "CherrySimulation", "CherryFeatures",
            .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        ]),
        .target(
            name: "CherryAdapters",
            dependencies: ["CherryCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "CherryPresentation", dependencies: ["CherryCore"]),
        .target(
            name: "CherryFeatures",
            dependencies: [
                "CherryCore",
                "CherryPresentation",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(name: "CherryCoreTests", dependencies: ["CherryCore"]),
        .target(name: "CherryControl"),
        .target(name: "CherryControlService", dependencies: ["CherryCore", "CherryControl", "CherryPresentation"]),
        .executableTarget(name: "CherryCLI", dependencies: [
            "CherryControl", "CherryControlService", "CherryCore", "CherryAdapters", "CherrySimulation",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .testTarget(name: "CherryControlTests", dependencies: ["CherryControl"]),
        .testTarget(name: "CherryControlServiceTests", dependencies: [
            "CherryControlService", "CherryControl", "CherryCore", "CherrySimulation",
        ]),
        .testTarget(name: "CherryCLITests", dependencies: [
            "CherryCLI", "CherryControl", "CherryControlService", "CherryCore", "CherrySimulation",
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "CherrySimulation", dependencies: ["CherryCore", "CherryAdapters"]),
        .testTarget(name: "CherryAdaptersTests", dependencies: ["CherryAdapters", "CherryCore"]),
        .testTarget(name: "CherrySimulationTests", dependencies: ["CherrySimulation", "CherryAdapters", "CherryCore"]),
        .testTarget(
            name: "CherryFeaturesTests",
            dependencies: [
                "CherryFeatures",
                "CherryPresentation",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ]
)

// swift-tools-version:6.0
import PackageDescription

// Hexagonal layout:
//   CherryCore      – domain, protocol codecs, ports, application services (no UI, no IOKit, no TCA)
//   CherryAdapters  – driven adapters: IOKit HID, URLSession catalog, on-disk firmware cache
//   CherrySimulation – in-memory stand-ins for the driven adapters (UI tests, demo mode, profiling)
//   CherryFeatures  – driving adapter: TCA reducers + SwiftUI views, talking to the core through dependency clients
// The app target is the composition root that wires adapters into the feature clients.
let package = Package(
    name: "CherryKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CherryCore", targets: ["CherryCore"]),
        .library(name: "CherryAdapters", targets: ["CherryAdapters"]),
        .library(name: "CherryFeatures", targets: ["CherryFeatures"]),
        .library(name: "CherrySimulation", targets: ["CherrySimulation"]),
        .executable(name: "CherryProfiler", targets: ["CherryProfiler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
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
        .target(
            name: "CherryFeatures",
            dependencies: [
                "CherryCore",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(name: "CherryCoreTests", dependencies: ["CherryCore"]),
        .target(name: "CherrySimulation", dependencies: ["CherryCore", "CherryAdapters"]),
        .testTarget(name: "CherryAdaptersTests", dependencies: ["CherryAdapters", "CherryCore"]),
        .testTarget(name: "CherrySimulationTests", dependencies: ["CherrySimulation", "CherryAdapters", "CherryCore"]),
        .testTarget(
            name: "CherryFeaturesTests",
            dependencies: [
                "CherryFeatures",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ]
)

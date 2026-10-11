// swift-tools-version:6.0
import PackageDescription

// Hexagonal layout:
//   CherryCore      – domain, protocol codecs, ports, application services (no UI, no IOKit, no TCA)
//   CherryAdapters  – driven adapters: IOKit HID, URLSession catalog, on-disk firmware cache
//   CherryFeatures  – driving adapter: TCA reducers + SwiftUI views, talking to the core through dependency clients
// The app target is the composition root that wires adapters into the feature clients.
let package = Package(
    name: "CherryKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CherryCore", targets: ["CherryCore"]),
        .library(name: "CherryAdapters", targets: ["CherryAdapters"]),
        .library(name: "CherryFeatures", targets: ["CherryFeatures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
    ],
    targets: [
        .target(name: "CherryCore"),
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
        .testTarget(name: "CherryAdaptersTests", dependencies: ["CherryAdapters", "CherryCore"]),
        .testTarget(
            name: "CherryFeaturesTests",
            dependencies: [
                "CherryFeatures",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ]
)

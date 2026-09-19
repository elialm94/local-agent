// swift-tools-version:5.9
import PackageDescription

// PairCore and PairCLI are platform-independent (Foundation only) so the
// deterministic logic can be built and tested on Linux CI. PairApp is the
// native macOS application and is only declared when the manifest is
// evaluated on macOS.

var products: [Product] = [
    .library(name: "PairCore", targets: ["PairCore"]),
    .executable(name: "pair-cli", targets: ["PairCLI"]),
]

var targets: [Target] = [
    .target(
        name: "PairCore",
        path: "Sources/PairCore",
        swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .executableTarget(
        name: "PairCLI",
        dependencies: ["PairCore"],
        path: "Sources/PairCLI"
    ),
    .testTarget(
        name: "PairCoreTests",
        dependencies: ["PairCore"],
        path: "Tests/PairCoreTests",
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "Pair", targets: ["PairApp"]))
targets.append(
    .executableTarget(
        name: "PairApp",
        dependencies: ["PairCore"],
        path: "Sources/PairApp",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SwiftUI"),
            .linkedFramework("ApplicationServices"),
            .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("Security"),
            .linkedFramework("Network"),
        ]
    )
)
#endif

let package = Package(
    name: "Pair",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageVersions: [.v5]
)

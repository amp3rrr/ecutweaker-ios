// swift-tools-version:5.9
// EcuCore: platform-independent port of EcuTweaker's `ecu` module and ELM327 logic.
// The iOS app (App/) compiles these sources directly via XcodeGen; this package
// exists so the core can be built and unit-tested with `swift test` on Linux/macOS.
import PackageDescription

let package = Package(
    name: "EcuCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "EcuCore", targets: ["EcuCore"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "EcuCore",
            dependencies: [.target(name: "CZlib", condition: .when(platforms: [.linux]))],
            path: "Sources/EcuCore"
        ),
        .testTarget(
            name: "EcuCoreTests",
            dependencies: ["EcuCore"],
            path: "Tests/EcuCoreTests",
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)

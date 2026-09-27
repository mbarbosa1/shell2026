// swift-tools-version: 5.9
import PackageDescription

// See README.md. PersonDistanceCore is portable (no ARKit) so its tests run on a Mac;
// PersonDistanceIOS adds ARKit and Vision and only compiles for iOS.
let package = Package(
    name: "PersonDistance",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PersonDistanceIOS",
            targets: ["PersonDistanceIOS"]
        ),
    ],
    targets: [
        .target(
            name: "PersonDistanceCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "PersonDistanceIOS",
            dependencies: ["PersonDistanceCore"]
        ),
        .testTarget(
            name: "PersonDistanceCoreTests",
            dependencies: ["PersonDistanceCore"]
        ),
    ]
)

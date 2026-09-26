// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ItemRecognition",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ItemRecognition",
            targets: ["ItemRecognition"]
        ),
    ],
    targets: [
        .target(
            name: "ItemRecognition",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "ItemRecognitionTests",
            dependencies: ["ItemRecognition"]
        ),
    ]
)

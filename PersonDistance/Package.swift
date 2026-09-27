// swift-tools-version: 5.9
import PackageDescription

// See README.md. Only the iOS (ARKit) target exists so far; the portable PersonDistanceCore
// target in the plan is added when something needs it.
let package = Package(
    name: "PersonDistance",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "PersonDistanceIOS",
            targets: ["PersonDistanceIOS"]
        ),
    ],
    targets: [
        .target(
            name: "PersonDistanceIOS"
        ),
    ]
)

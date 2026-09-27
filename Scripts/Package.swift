// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProductCatalog",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ProductDatabase", targets: ["ProductDatabase"]),
        .library(name: "CatalogIntegration", targets: ["CatalogIntegration"]),
    ],
    dependencies: [.package(path: "../ItemRecognition")],
    targets: [
        .target(name: "ProductDatabase", path: "SwiftData"),
        .target(name: "CatalogIntegration", dependencies: ["ProductDatabase", .product(name: "ItemRecognition", package: "ItemRecognition")], path: "RecognitionIntegration",
                resources: [.process("Resources")]),
        .testTarget(name: "ProductCatalogTests", dependencies: ["ProductDatabase", "CatalogIntegration", .product(name: "ItemRecognition", package: "ItemRecognition")], path: "Tests"),
    ]
)

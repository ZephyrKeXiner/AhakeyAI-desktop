// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VibeBar", targets: ["VibeBar"]),
        .executable(name: "VibeBarSmoke", targets: ["VibeBarSmoke"]),
    ],
    dependencies: [
        .package(path: "Vendor/DynamicNotchKit"),
    ],
    targets: [
        .target(
            name: "VibeBar",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ],
            path: "Sources/VibeBar"
        ),
        .executableTarget(
            name: "VibeBarSmoke",
            dependencies: ["VibeBar"],
            path: "Sources/VibeBarSmoke"
        ),
    ]
)

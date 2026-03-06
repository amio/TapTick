// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapTickKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "TapTickKit", targets: ["TapTickKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "TapTickKit",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/TapTickKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "TapTickTests",
            dependencies: ["TapTickKit"],
            path: "Tests/TapTickTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
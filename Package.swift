// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyMagicKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "KeyMagicKit", targets: ["KeyMagicKit"]),
    ],
    targets: [
        .target(
            name: "KeyMagicKit",
            path: "Sources/KeyMagicKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "KeyMagicTests",
            dependencies: ["KeyMagicKit"],
            path: "Tests/KeyMagicTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MagikeysKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "MagikeysKit", targets: ["MagikeysKit"]),
    ],
    targets: [
        .target(
            name: "MagikeysKit",
            path: "Sources/MagikeysKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "MagikeysTests",
            dependencies: ["MagikeysKit"],
            path: "Tests/MagikeysTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SoTellMe",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "SoTellMe",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/SoTellMe",
            resources: [
                .copy("Resources/vocab_corrections.json")
            ]
        )
    ]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenCodeAnswer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenCodeAnswer",
            path: "Sources/OpenCodeAnswer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

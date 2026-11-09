// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HandheldManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HandheldManager", targets: ["HandheldManager"])
    ],
    targets: [
        .executableTarget(
            name: "HandheldManager",
            path: "Sources/HandheldManager"
        ),
        .testTarget(
            name: "HandheldManagerTests",
            dependencies: ["HandheldManager"]
        )
    ]
)

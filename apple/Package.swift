// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.18.3"))
    ],
    targets: [
        .executableTarget(
            name: "Companion",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Companion"
        )
    ]
)

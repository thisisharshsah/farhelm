// swift-tools-version:5.9
// What the Companion apps on iPhone, iPad and Apple Watch share: how they
// talk to Companion on the Mac, the shapes of what it sends, pairing, and
// finding a Mac on the network. No UI here.
import PackageDescription

let package = Package(
    name: "CompanionKit",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "CompanionKit", targets: ["CompanionKit"]),
    ],
    dependencies: [
        // Reaching the Mac away from its network: the relay link, shared
        // with the Mac app so both ends speak one protocol.
        .package(path: "../../Shared/CompanionLink"),
    ],
    targets: [
        .target(name: "CompanionKit", dependencies: [
            .product(name: "CompanionLink", package: "CompanionLink"),
        ]),
        .testTarget(name: "CompanionKitTests", dependencies: ["CompanionKit"]),
    ]
)

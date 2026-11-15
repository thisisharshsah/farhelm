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
    targets: [
        .target(name: "CompanionKit"),
        .testTarget(name: "CompanionKitTests", dependencies: ["CompanionKit"]),
    ]
)

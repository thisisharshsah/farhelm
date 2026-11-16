// swift-tools-version:5.9
// How Companion's apps reach the Mac when they are not on its network: a key
// from the pairing, envelopes sealed with it, and a relay that passes them
// along without being able to read them. Shared by the Mac app and the
// iPhone, iPad and Watch apps, so both ends speak exactly one protocol.
import PackageDescription

let package = Package(
    name: "CompanionLink",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "CompanionLink", targets: ["CompanionLink"]),
    ],
    targets: [
        .target(name: "CompanionLink"),
        .testTarget(name: "CompanionLinkTests", dependencies: ["CompanionLink"]),
    ]
)

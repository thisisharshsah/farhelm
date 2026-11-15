// swift-tools-version:5.9
// Companion's design, shared by the Mac app and the iPhone, iPad and
// Apple Watch apps: the colors, the glass, the bubbles, the working mark,
// the fire ball and the plan. One source, so a change shows everywhere.
import PackageDescription

let package = Package(
    name: "CompanionDesign",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "CompanionDesign", targets: ["CompanionDesign"]),
    ],
    targets: [
        .target(name: "CompanionDesign"),
    ]
)

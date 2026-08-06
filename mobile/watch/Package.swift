// swift-tools-version: 6.0
import PackageDescription

/// The watch's crypto and relay client, as a package so it can be tested on a
/// Mac without a watch, a simulator, or Xcode. The SwiftUI app in `App/` is a
/// thin shell over this — which is the point: the part that must be right is the
/// part that runs under `swift test`.
let package = Package(
    name: "ForgeWatch",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ForgeCrypto", targets: ["ForgeCrypto"]),
        .library(name: "ForgeWatchKit", targets: ["ForgeWatchKit"]),
        .library(name: "ForgeWatchUI", targets: ["ForgeWatchUI"]),
    ],
    targets: [
        .target(name: "ForgeCrypto"),
        .target(name: "ForgeWatchKit", dependencies: ["ForgeCrypto"]),
        // The SwiftUI screens. A package target rather than loose files in an
        // Xcode project so `swift build` typechecks them on a Mac — watchOS-only
        // API is behind `#if os(watchOS)` for exactly that reason.
        .target(name: "ForgeWatchUI", dependencies: ["ForgeWatchKit"]),
        // The cross-language fixture is read from the repo at its canonical
        // path rather than copied in as a resource: a copy can go stale against
        // the Rust crate that mints it, and a stale interop fixture is exactly
        // the thing these tests exist to rule out.
        .testTarget(name: "ForgeCryptoTests", dependencies: ["ForgeCrypto"]),
        .testTarget(name: "ForgeWatchKitTests", dependencies: ["ForgeWatchKit"]),
    ]
)

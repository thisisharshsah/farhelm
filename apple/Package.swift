// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Chromium (CEF) for the browser, fetched into Vendor/cef by
// scripts/fetch-cef.sh. build.sh always leaves a wrapper library in
// .build/cef (CEF's, or an empty one), so the package builds either way;
// without CEF the code in CEFKit compiles to stubs and the browser is WebKit.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let cefFlags = ["-I", "\(root)/Vendor/cef", "-fobjc-arc", "-DNDEBUG"]
let cefLinker: [LinkerSetting] = [
    .unsafeFlags(["-L", "\(root)/.build/cef", "-lcef_dll_wrapper"]),
    .linkedFramework("Cocoa")
]

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.18.3")),
        // The terminal in the workspace: a full terminal emulator on a
        // pseudo-terminal. Pinned, so a build is the same every time.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        // Companion's design, shared with the iPhone, iPad and Watch apps.
        .package(path: "Shared/CompanionDesign"),
        // How the apps reach this Mac away from its network, through a
        // relay that cannot read what it carries. Shared with the apps.
        .package(path: "Shared/CompanionLink"),
        // Advanced mode's board as plain data and rules (tasks, runs,
        // what a supervisor may change, what the work cost), with its
        // own tests. Shared, so the apps can show the same board.
        .package(path: "Shared/CompanionBoard")
    ],
    targets: [
        .executableTarget(
            name: "Companion",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CompanionDesign", package: "CompanionDesign"),
                .product(name: "CompanionLink", package: "CompanionLink"),
                .product(name: "CompanionBoard", package: "CompanionBoard"),
                "CEFKit",
                "CrashKit"
            ],
            path: "Sources/Companion"
        ),
        // What runs inside a fatal signal, for crash recording: C, because
        // a signal handler may not allocate memory or take a lock.
        .target(
            name: "CrashKit",
            path: "Sources/CrashKit"
        ),
        .target(
            name: "CEFKit",
            path: "Sources/CEFKit",
            cSettings: [.unsafeFlags(cefFlags)],
            cxxSettings: [.unsafeFlags(cefFlags + ["-fno-rtti"])],
            linkerSettings: cefLinker
        ),
        // Chromium's helper processes, bundled by build.sh.
        .executableTarget(
            name: "CompanionHelper",
            path: "Sources/CompanionHelper",
            cxxSettings: [.unsafeFlags(cefFlags + ["-fno-rtti"])],
            linkerSettings: cefLinker
        )
    ],
    cxxLanguageStandard: .cxx20
)

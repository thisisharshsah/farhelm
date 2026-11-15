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
        .package(path: "Shared/CompanionDesign")
    ],
    targets: [
        .executableTarget(
            name: "Companion",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CompanionDesign", package: "CompanionDesign"),
                "CEFKit"
            ],
            path: "Sources/Companion"
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

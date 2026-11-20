// swift-tools-version:5.9
// Advanced mode's board, as plain data and rules: tasks and runs, how a
// task moves, what a supervisor may change and what it may answer in the
// person's place, what the work cost, and which model suits a task. No interface, no files, no network and no clock of
// its own (the time is always handed in), so every rule here can be
// tested, and the iPhone, iPad and Watch apps can show the same board.
import PackageDescription

let package = Package(
    name: "CompanionBoard",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "CompanionBoard", targets: ["CompanionBoard"]),
    ],
    targets: [
        .target(name: "CompanionBoard"),
        .testTarget(name: "CompanionBoardTests", dependencies: ["CompanionBoard"]),
    ]
)

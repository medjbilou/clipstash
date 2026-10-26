// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipStash",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClipCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ClipStash", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
    ]
)

// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexIsland",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexIsland", targets: ["CodexIsland"])],
    targets: [
        .target(name: "IslandCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "CodexIsland", dependencies: ["IslandCore"],
                          linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
        .testTarget(name: "IslandPresentationTests", dependencies: ["CodexIsland"])
    ]
)

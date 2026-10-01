// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GoldWareOS",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GoldWareOS",
            path: "Sources/GoldWareOS",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)

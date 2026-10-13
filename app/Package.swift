// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GoldWareOS",
    platforms: [.macOS(.v14)],
    targets: [
        // SMC access and the fan helper's protocol, shared by the app and the root helper.
        .target(name: "SMCKit", path: "Sources/SMCKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(
            name: "GoldWareOS",
            dependencies: ["SMCKit"],
            path: "Sources/GoldWareOS",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Installed as a LaunchDaemon from the control center's Fans card (one password prompt).
        .executableTarget(name: "GoldWareFanHelper", dependencies: ["SMCKit"], path: "Sources/GoldWareFanHelper"),
    ]
)

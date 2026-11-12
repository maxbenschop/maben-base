// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MabenBase",
    platforms: [.macOS(.v14)],
    targets: [
        // Connections, drivers (Postgres, MySQL, SQLite), schema reading and SQL building. No UI, no dependencies.
        .target(name: "BaseCore", path: "Sources/BaseCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The app.
        .executableTarget(name: "Base", dependencies: ["BaseCore"], path: "Sources/Base"),
        // `base-tool query <url> <sql>`: runs SQL through the same drivers and prints the result.
        .executableTarget(name: "BaseTool", dependencies: ["BaseCore"], path: "Sources/BaseTool"),
        .testTarget(name: "BaseCoreTests", dependencies: ["BaseCore"], path: "Tests/BaseCoreTests"),
    ]
)

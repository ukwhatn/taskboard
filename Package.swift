// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "taskboard",
    defaultLocalization: "ja",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "TaskboardKit", targets: ["TaskboardKit"]),
        .library(name: "TaskboardDaemon", targets: ["TaskboardDaemon"]),
        .executable(name: "taskboard", targets: ["taskboard"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.27.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", exact: "2.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "TaskboardKit", resources: [.copy("Resources/Agent.xcstrings"), .copy("Resources/Prompts")]),
        .target(
            name: "TaskboardDaemon",
            dependencies: [
                "TaskboardKit",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HummingbirdWSCompression", package: "hummingbird-websocket"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "taskboard",
            dependencies: [
                "TaskboardDaemon",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

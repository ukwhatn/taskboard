// swift-tools-version: 6.2
// 音声入力の認識と校正を、音声ファイルで比べる（README.md）。Whisper の部品はアプリのファイルを symlink で読む
import PackageDescription

let package = Package(
    name: "voice-eval",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "taskboard", path: "../.."),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceEval",
            dependencies: [
                .product(name: "TaskboardKit", package: "taskboard"),
                .product(name: "TaskboardDaemon", package: "taskboard"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

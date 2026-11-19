import Foundation
import Logging

/// ログに出た文と metadata を全部集める（外部の CLI の文や秘密がログに出ていないかを見る）
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
    var joined: String { all.joined(separator: "\n") }

    var logger: Logger { Logger(label: "test") { _ in Handler(lines: self) } }

    private struct Handler: LogHandler {
        let lines: LogLines
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            lines.add("\(event.message) \(metadata.merging(event.metadata ?? [:], uniquingKeysWith: { $1 }))")
        }
    }
}

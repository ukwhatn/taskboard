import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// イベントのログ（JSON Lines の行・ファイルの回し方・直近の分）
@MainActor
@Suite struct EventLogTests {
    private let start = Date(timeIntervalSince1970: 1_791_000_000)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "event-log-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    // MARK: 行

    @Test("1 行は改行で終わり、ms まで入った ISO8601 の時刻で書き、使わない欄は書かない")
    func lineFormat() throws {
        let event = AppEvent(at: Date(timeIntervalSince1970: 1_791_000_000.25), type: "session.switch", id: "a1b2c3d4", pane: "w1:p2", stage: "opened", ms: 0)
        let line = String(decoding: try event.line(), as: UTF8.self)
        #expect(line == #"{"at":"2026-10-03T04:00:00.250Z","id":"a1b2c3d4","ms":0,"pane":"w1:p2","stage":"opened","type":"session.switch"}"# + "\n")
    }

    @Test("書いた行を読み直すと同じイベントになる（日本語のペイン名も）")
    func lineRoundTrip() throws {
        let event = AppEvent(
            at: Date(timeIntervalSince1970: 1_791_000_000.125), type: "session.switch", id: "x", machine: "studio", pane: "調査:p1", mode: "chat",
            stage: "reloaded", ms: 12, totalMS: 340, reused: true)
        let decoded = try JSONDecoder().decode(AppEvent.self, from: try event.line())
        #expect(decoded == event)
    }

    // MARK: ファイル

    @Test("上限を超える行を書く前に回し、今のファイルを含めて 3 世代まで残す")
    func rotation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = EventLogWriter(directory: directory, name: "app-events", maxBytes: 100, generations: 3)
        // 1 行 40 バイト。2 行で 80、3 行目で 120 になるので、2 行ごとにファイルが替わる
        for index in 0..<7 {
            writer.append(Data((String(format: "%02d", index) + String(repeating: "x", count: 37) + "\n").utf8))
        }
        writer.flush()
        #expect(try lines(writer.file(generation: 0)).map { String($0.prefix(2)) } == ["06"])
        #expect(try lines(writer.file(generation: 1)).map { String($0.prefix(2)) } == ["04", "05"])
        #expect(try lines(writer.file(generation: 2)).map { String($0.prefix(2)) } == ["02", "03"])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "app-events.3.jsonl").path))
    }

    @Test("上限より長い 1 行でも、空のファイルには書く（回し続けない）")
    func oversizedLine() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = EventLogWriter(directory: directory, maxBytes: 10, generations: 2)
        writer.append(Data((String(repeating: "y", count: 30) + "\n").utf8))
        writer.flush()
        #expect(try lines(writer.currentFile) == [String(repeating: "y", count: 30)])
        #expect(!FileManager.default.fileExists(atPath: writer.file(generation: 1).path))
    }

    @Test("書き足すときは前のファイルの後ろに続ける")
    func appendsToExistingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = EventLogWriter(directory: directory)
        first.append(Data("a\n".utf8))
        first.flush()
        let second = EventLogWriter(directory: directory)
        second.append(Data("b\n".utf8))
        second.flush()
        #expect(try lines(second.currentFile) == ["a", "b"])
    }

    @Test("直近の 50 件だけをメモリに持つ。書く先が無ければファイルを作らない")
    func recentLimit() {
        let log = EventLog(writer: nil)
        for index in 0..<55 { log.record(AppEvent(at: start, type: "session.switch", id: "\(index)")) }
        #expect(log.recent.count == 50)
        #expect(log.recent.first?.id == "5")
        #expect(log.recent.last?.id == "54")
        #expect(log.fileURL == nil)
    }
}

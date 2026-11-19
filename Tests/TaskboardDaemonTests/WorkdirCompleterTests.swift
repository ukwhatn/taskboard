import Foundation
import Testing

@testable import TaskboardDaemon

@Suite("作業ディレクトリの補完")
struct WorkdirCompleterTests {
    /// home に見立てた一時ディレクトリ。dev・Documents・案件・.config・devtools（symlink）・dev.txt（ファイル）を置く
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("workdir-\(UUID().uuidString)").path
        for dir in ["dev/8_tools/taskboard", "dev/8_tools/kairan", "Documents", "案件/決済", ".config"] {
            try FileManager.default.createDirectory(atPath: "\(home)/\(dir)", withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: "\(home)/devtools", withDestinationPath: "\(home)/dev/8_tools")
        FileManager.default.createFile(atPath: "\(home)/dev.txt", contents: Data())
        return home
    }

    @Test("入力の最後の / より後ろを名前の頭として、ディレクトリだけを返す。~ は入力のまま残し、symlink の先がディレクトリなら入れる")
    func completesDirectories() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(WorkdirCompleter.complete("~/", home: home) == ["~/dev", "~/devtools", "~/Documents", "~/案件"])
        #expect(WorkdirCompleter.complete("~/de", home: home) == ["~/dev", "~/devtools"])
        #expect(WorkdirCompleter.complete("~/dev/8_tools/", home: home) == ["~/dev/8_tools/kairan", "~/dev/8_tools/taskboard"])
        #expect(WorkdirCompleter.complete("~/案", home: home) == ["~/案件"])
        #expect(WorkdirCompleter.complete("\(home)/dev/8_tools/t", home: "/nowhere") == ["\(home)/dev/8_tools/taskboard"])
    }

    @Test("名前の頭は大文字と小文字を区別しない。打ち切った名前そのものは返さない。. で始まる名前は . を打ったときだけ")
    func matching() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(WorkdirCompleter.complete("~/DOC", home: home) == ["~/Documents"])
        #expect(WorkdirCompleter.complete("~/dev", home: home) == ["~/devtools"])
        #expect(WorkdirCompleter.complete("~/.", home: home) == ["~/.config"])
    }

    @Test("~ か / で始まらない入力、/ を含まない入力、無い親では何も返さない")
    func nothing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(WorkdirCompleter.complete("", home: home).isEmpty)
        #expect(WorkdirCompleter.complete("~", home: home).isEmpty)
        #expect(WorkdirCompleter.complete("dev/", home: home).isEmpty)
        #expect(WorkdirCompleter.complete("~/nowhere/", home: home).isEmpty)
        #expect(WorkdirCompleter.complete("~/dev.txt/", home: home).isEmpty)
        #expect(WorkdirCompleter.complete("~other/", home: home).isEmpty)
    }

    @Test("候補は名前の順で limit 件まで")
    func limit() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for index in 1...25 {
            try FileManager.default.createDirectory(atPath: "\(home)/many/d\(index)", withIntermediateDirectories: true)
        }
        let all = WorkdirCompleter.complete("~/many/", home: home)
        #expect(all.count == WorkdirCompleter.limit)
        #expect(all.prefix(3) == ["~/many/d1", "~/many/d2", "~/many/d3"])
    }
}

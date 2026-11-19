import Foundation
import Testing

@testable import TaskboardDaemon

@Suite("host の会話の CLI の版・ログインシェルの env・会話の予約")
struct ClaudeCLITests {
    @Test("版の並びは数で比べ、数でない部分は文字で比べる。短い方が前")
    func precedes() {
        #expect(VerifiedCLI.precedes("2.1.99", "2.1.302"))
        #expect(!VerifiedCLI.precedes("2.1.302", "2.1.99"))
        #expect(!VerifiedCLI.precedes("2.1.302", "2.1.302"))
        #expect(VerifiedCLI.precedes("2.1", "2.1.0"))
        #expect(VerifiedCLI.precedes("2.1.3-beta", "2.1.3-rc"))
        #expect(VerifiedCLI.precedes("", "1"))
    }

    @Test("起こす版は、実行ファイルが残っていて要る capabilities を全部持つもののうち最も新しいもの")
    func newest() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let verified = VerifiedCLI(entries: [
            .init(version: "2.1.302", path: "/v/2.1.302", capabilities: ["defer"], verifiedAt: at),
            .init(version: "2.1.99", path: "/v/2.1.99", capabilities: ["defer", "hooks"], verifiedAt: at),
            .init(version: "2.1.400", path: "/v/2.1.400", capabilities: ["defer", "hooks"], verifiedAt: at),
        ])
        #expect(verified.newest(requiring: ["defer"]) { $0 != "/v/2.1.400" }?.version == "2.1.302", "消えた実行ファイルは選ばない")
        #expect(verified.newest(requiring: ["defer", "hooks"]) { _ in true }?.version == "2.1.400")
        #expect(verified.newest(requiring: ["defer", "hooks"]) { $0 == "/v/2.1.99" }?.version == "2.1.99")
        #expect(verified.newest(requiring: ["fork"]) { _ in true } == nil)
        #expect(VerifiedCLI().newest(requiring: []) { _ in true } == nil)
    }

    @Test("codex の記録は Claude Code と別のファイル（verified-codex.json）に書き、片方の書式の版はもう片方を読まない")
    func codexRecordIsSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tb-verified-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try VerifiedCLI.record(.init(version: "0.162.1", path: "/codex", capabilities: [], verifiedAt: Date()), .codex, supportDirectory: directory)
        #expect(VerifiedCLI.file(.codex, supportDirectory: directory).lastPathComponent == "verified-codex.json")
        #expect(VerifiedCLI.load(.codex, supportDirectory: directory)?.newest(requiring: []) { _ in true }?.path == "/codex")
        #expect(VerifiedCLI.load(.claude, supportDirectory: directory) == nil)
    }

    @Test("入っている版：codex は `<版>-<target>/bin/codex`（版でない名前と実行できないものは外す）")
    func installedCodex() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tb-releases-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, mode) in [("0.153.4-aarch64-apple-darwin", 0o755), ("0.162.1-aarch64-apple-darwin", 0o755), ("0.170.0-aarch64-apple-darwin", 0o644), ("current", 0o755)] {
            let url = directory.appending(path: name).appending(path: "bin/codex")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        let installed = VerifiedCLI.installed(.codex, in: directory).sorted { VerifiedCLI.precedes($0.version, $1.version) }
        #expect(installed.map(\.version) == ["0.153.4", "0.162.1"])
        #expect(installed.last?.path == directory.appending(path: "0.162.1-aarch64-apple-darwin/bin/codex").path)
        #expect(VerifiedCLI.installed(.codex, in: directory.appending(path: "none")).isEmpty)
    }

    @Test("記録は同じ版を置き換えて書き、0600 で読み直せる。書式の版が違えば読まない")
    func recordAndLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tb-verified-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        try VerifiedCLI.record(.init(version: "2.1.302", path: "/a", capabilities: ["defer"], verifiedAt: at), .claude, supportDirectory: directory)
        try VerifiedCLI.record(.init(version: "2.1.302", path: "/b", capabilities: ["defer", "hooks"], verifiedAt: at), .claude, supportDirectory: directory)
        try VerifiedCLI.record(.init(version: "2.1.303", path: "/c", capabilities: [], verifiedAt: at), .claude, supportDirectory: directory)
        let loaded = try #require(VerifiedCLI.load(.claude, supportDirectory: directory))
        #expect(loaded.entries.map(\.path) == ["/b", "/c"])
        let file = VerifiedCLI.file(.claude, supportDirectory: directory)
        #expect(((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0) & 0o777 == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names == ["verified-cli.json"], "書きかけのファイルを残さない")
        try Data(#"{"format":\#(VerifiedCLI.currentFormat(.claude) + 1),"entries":[]}"#.utf8).write(to: file)
        #expect(VerifiedCLI.load(.claude, supportDirectory: directory) == nil)
        try Data("壊れた".utf8).write(to: file)
        #expect(VerifiedCLI.load(.claude, supportDirectory: directory) == nil)
    }

    @Test("ログインシェルの env は印の行より後だけを読み、会話を取り違える変数とシェルの場所の値を外す")
    func loginEnvironment() {
        let marker = "\n\(LoginShellEnvironment.marker)\n"
        let body = [
            "PATH=/opt/homebrew/bin:/usr/bin", "LANG=ja_JP.UTF-8", "GREETING=こんにちは=世界", "MULTI=一行目\n二行目",
            "CLAUDE_CODE_SESSION_ID=old", "CLAUDECODE=1", "TASKBOARD_CONVERSATION_ID=c1", "HERDR_PANE_ID=w1:p1", "TERM_PROGRAM=ghostty",
            "PWD=/tmp", "OLDPWD=/", "SHLVL=2", "_=/usr/bin/env", "=empty", "NOEQUALS",
        ].joined(separator: "\0") + "\0"
        let output = "zshrc が出した文字\nPATH=/wrong\0" + marker + body
        #expect(
            LoginShellEnvironment.parse(output) == [
                "PATH": "/opt/homebrew/bin:/usr/bin", "LANG": "ja_JP.UTF-8", "GREETING": "こんにちは=世界", "MULTI": "一行目\n二行目",
            ])
        #expect(LoginShellEnvironment.parse("PATH=/usr/bin\0") == nil, "印が無い")
        #expect(LoginShellEnvironment.parse(marker + "PWD=/tmp\0") == nil, "残る変数が無い")
        #expect(LoginShellEnvironment.parse("") == nil)
        #expect(LoginShellEnvironment.parse(marker + "A=" + String(repeating: "x", count: LoginShellEnvironment.byteLimit)) == nil, "大きすぎる")
        // 印が 2 回出たら（.zshrc が同じ文字を出した）後ろの方から読む
        #expect(LoginShellEnvironment.parse(marker + "A=1\0" + marker + "B=2\0") == ["B": "2"])
    }

    @Test("会話の予約は、同じ持ち主なら取り直せ、ほかの持ち主には渡さない。外すのは持ち主のものだけ")
    func reservations() {
        let reservations = SessionReservations()
        #expect(reservations.reserve("claude/s-1", owner: "conv-1"))
        #expect(reservations.reserve("claude/s-1", owner: "conv-1"))
        #expect(!reservations.reserve("claude/s-1", owner: "launch-1"))
        #expect(reservations.reserve("claude/s-2", owner: "conv-1"))
        reservations.release("claude/s-1", owner: "launch-1")
        #expect(reservations.owner(of: "claude/s-1") == "conv-1", "持ち主でなければ外さない")
        reservations.release("claude/s-1", owner: "conv-1")
        #expect(reservations.owner(of: "claude/s-1") == nil && reservations.owner(of: "claude/s-2") == "conv-1")
        reservations.release(owner: "conv-1")
        #expect(reservations.owner(of: "claude/s-2") == nil)
        #expect(reservations.reserve("claude/s-1", owner: "launch-1"))
    }
}

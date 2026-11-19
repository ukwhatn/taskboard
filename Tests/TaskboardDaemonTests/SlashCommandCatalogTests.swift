import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("/ の候補の読み取り")
struct SlashCommandCatalogTests {
    private func write(_ text: String, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    @Test("~/.claude と作業ディレクトリ・親の .claude から skill と command を集める。近い方の同名を残し、呼べない skill は出さない")
    func collects() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "slash-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        let project = home.appending(path: "dev/app")
        let cwd = project.appending(path: "sub")
        try write("---\nname: yomiyasu\ndescription: 日本語の推敲\nlicense: MIT\n---\n# yomiyasu", to: home.appending(path: ".claude/skills/yomiyasu/SKILL.md"))
        try write("---\nname: shadcn\ndescription: 内部用\nuser-invocable: false\n---\n", to: home.appending(path: ".claude/skills/shadcn/SKILL.md"))
        try write("---\ndescription: >\n  長い説明の\n  続き\n---\n", to: home.appending(path: ".claude/skills/folded/SKILL.md"))
        try write("---\ndescription: \"ユーザーの方\"\n---\n", to: home.appending(path: ".claude/skills/deploy/SKILL.md"))
        try write("PR を作る\n\n本文", to: home.appending(path: ".claude/commands/pr.md"))
        try write("---\ndescription: 作業ディレクトリの方\n---\n", to: project.appending(path: ".claude/skills/deploy/SKILL.md"))
        try write("---\nname: \n---\n", to: cwd.appending(path: ".claude/skills/local/SKILL.md"))
        try write("x", to: home.appending(path: ".claude/skills/no-skill-md/README.md"))

        let list = SlashCommandCatalog.list(cwd: cwd.path, home: home.path, builtins: [])
        #expect(list.map(\.name) == ["deploy", "folded", "local", "pr", "yomiyasu"])
        #expect(list.first { $0.name == "deploy" }?.description == "作業ディレクトリの方")
        #expect(list.first { $0.name == "deploy" }?.scope == .project)
        #expect(list.first { $0.name == "folded" }?.description == "長い説明の 続き")
        #expect(list.first { $0.name == "pr" } == SlashCommand(name: "pr", description: "PR を作る", kind: .command, scope: .user))
        #expect(list.first { $0.name == "yomiyasu" } == SlashCommand(name: "yomiyasu", description: "日本語の推敲", kind: .skill, scope: .user))
        // 作業ディレクトリが無い・相対のときは ~/.claude だけ
        #expect(SlashCommandCatalog.list(cwd: nil, home: home.path, builtins: []).map(\.name) == ["deploy", "folded", "pr", "yomiyasu"])
        #expect(SlashCommandCatalog.list(cwd: "relative", home: home.path, builtins: []).count == 4)
    }

    @Test("組み込みのコマンドを後に足して名前の順に混ぜる。同じ名前の skill・command があれば利用者の方を残す")
    func builtins() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "slash-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        try write("---\nname: simplify\ndescription: 自分の整理\n---\n", to: home.appending(path: ".claude/skills/simplify/SKILL.md"))
        let list = SlashCommandCatalog.list(cwd: nil, home: home.path)
        #expect(list.first { $0.name == "simplify" } == SlashCommand(name: "simplify", description: "自分の整理", kind: .skill, scope: .user))
        let mcp = try #require(list.first { $0.name == "mcp" })
        #expect(mcp.kind == .builtin && mcp.scope == .builtin)
        #expect(list.map(\.name) == list.map(\.name).sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending })
        #expect(Set(list.map(\.name)).count == list.count)
    }

    @Test("組み込みの一覧は名前が重ならず、どれにも説明がある")
    func builtinList() {
        let all = BuiltinSlashCommands.all
        #expect(Set(all.map(\.name)).count == all.count)
        #expect(all.allSatisfy { !$0.description.isEmpty && $0.kind == .builtin })
        // 削除済み・条件付きで出ないものは持たない
        #expect(!all.contains { ["vim", "pr-comments", "ultraplan", "setup-bedrock", "stop"].contains($0.name) })
    }

    @Test("作業ディレクトリから親へ、ホームと / の手前まで")
    func directories() {
        #expect(SlashCommandCatalog.projectDirectories(cwd: "/Users/me/dev/app/", home: "/Users/me") == ["/Users/me/dev/app", "/Users/me/dev"])
        #expect(SlashCommandCatalog.projectDirectories(cwd: "/Users/me", home: "/Users/me") == [])
        #expect(SlashCommandCatalog.projectDirectories(cwd: "/opt/work", home: "/Users/me") == ["/opt/work", "/opt"])
        #expect(SlashCommandCatalog.projectDirectories(cwd: nil, home: "/Users/me") == [])
    }
}

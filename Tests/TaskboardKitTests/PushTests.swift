import Foundation
import Testing
@testable import TaskboardKit

@Suite struct PermissionPromptTests {
    /// Claude Code 2.1.290 の Bash の確認（P9 で使い捨ての herdr に写した画面。パスだけ短くした）
    static let bash = """

         ▐▛███▛█   Claude Code v2.1.290
        ▝▜██████▀  Haiku 4.5 · Claude Enterprise

        ❯ Use the Bash tool to run exactly: touch c.txt && echo made ; then use the Write tool to create the file b.txt in the
          current directory with content hi. Do nothing else.

          Ran 1 shell command

        ⏺ Write(b.txt)

        ───────────────────────────────────────────────────────────────────────────────
         Bash command
         Create file c.txt and echo made
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         touch c.txt && echo made
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and always allow access to /tmp/p/promptdir from this project
           3. No

         Esc to cancel · Tab to amend
        """

    /// 同じ版の Write の確認
    static let write = """
        ⏺ Write(b.txt)

        ───────────────────────────────────────────────────────────────────────────────
         Create file
         b.txt
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
          1 hi
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to create b.txt?
         ❯ 1. Yes
           2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)
           3. No

         Esc to cancel · Tab to amend
        """

    static func screen(command lines: [String], rule width: Int) -> String {
        let rule = String(repeating: "╌", count: width)
        return (["⏺ Bash(…)", "", String(repeating: "─", count: width), " Bash command", " Run the build"]
            + [rule] + lines.map { " " + $0 } + [rule, " Do you want to proceed?", " ❯ 1. Yes", "   2. No", "", " Esc to cancel"])
            .joined(separator: "\n")
    }

    @Test("Bash の確認: ツールは見出し、中身はコマンド")
    func bash() throws {
        let prompt = try #require(PermissionPrompt(screen: Self.bash))
        #expect(prompt.tool == "Bash command")
        #expect(prompt.summary == "touch c.txt && echo made")
        #expect(prompt.hash.count == 64)
        #expect(PermissionPrompt.isPermissionPrompt(Self.bash))
    }

    @Test("ファイルの確認: 中身（ファイルの文）ではなく、見出しの下の行（ファイル名）を出す")
    func write() throws {
        let prompt = try #require(PermissionPrompt(screen: Self.write))
        #expect(prompt.tool == "Create file")
        #expect(prompt.summary == "b.txt")
        #expect(prompt.hash != PermissionPrompt(screen: Self.bash)?.hash)
    }

    @Test("pane の幅が変わって折り返しと罫線の長さが変わっても、同じ確認は同じハッシュ。中身が違えば違う")
    func hashIgnoresWrapping() throws {
        let wide = try #require(PermissionPrompt(screen: Self.screen(command: ["swift build -c release --product taskboard"], rule: 80)))
        let narrow = try #require(PermissionPrompt(screen: Self.screen(command: ["swift build -c release", "  --product taskboard"], rule: 30)))
        let other = try #require(PermissionPrompt(screen: Self.screen(command: ["swift build -c release --product taskboardd"], rule: 80)))
        #expect(wide.hash == narrow.hash)
        #expect(wide.hash != other.hash)
        // 折り返しの行は空白 1 つでつなぐ
        #expect(narrow.summary == "swift build -c release --product taskboard")
    }

    @Test("確認の上にある会話の文と、カーソルの位置はハッシュに入れない")
    func hashIgnoresTranscriptAndCursor() throws {
        let base = try #require(PermissionPrompt(screen: Self.bash))
        let moreTranscript = try #require(PermissionPrompt(screen: "⏺ 別の発言\n" + Self.bash))
        let cursorMoved = try #require(PermissionPrompt(screen: Self.bash.replacingOccurrences(of: " ❯ 1. Yes\n   2.", with: "   1. Yes\n ❯ 2.")))
        #expect(base.hash == moreTranscript.hash)
        #expect(base.hash == cursorMoved.hash)
    }

    @Test("中身は 120 字で切って … を付ける。日本語も字で数える")
    func truncate() throws {
        let long = String(repeating: "あ", count: 200)
        let prompt = try #require(PermissionPrompt(screen: Self.screen(command: ["echo " + long], rule: 40)))
        #expect(prompt.summary.count == PermissionPrompt.summaryLimit)
        #expect(prompt.summary.hasSuffix("…") && prompt.summary.hasPrefix("echo あ"))
        let exact = String(repeating: "a", count: PermissionPrompt.summaryLimit)
        #expect(PermissionPrompt(screen: Self.screen(command: [exact], rule: 40))?.summary == exact)
    }

    @Test("権限の確認でない画面: 質問の選択肢・下の 20 行より上に残った確認・空の画面は nil")
    func notPrompts() {
        #expect(PermissionPrompt(screen: "") == nil)
        #expect(PermissionPrompt(screen: "Which one?\n ❯ 1. Swift\n   2. Rust\n") == nil)
        let scrolledAway = Self.bash + String(repeating: "\n⏺ 続きの作業", count: 25)
        #expect(PermissionPrompt(screen: scrolledAway) == nil)
        #expect(!PermissionPrompt.isPermissionPrompt(scrolledAway))
    }

    @Test("上の枠が無い画面でも、「1. Yes」の上の数行を確認とみなす")
    func noBorder() throws {
        let prompt = try #require(PermissionPrompt(screen: " Fetch\n https://example.com\n Do you want to allow this fetch?\n ❯ 1. Yes\n   2. No"))
        #expect(prompt.tool == "Fetch" && prompt.summary == "https://example.com")
    }
}

@Suite struct PushWireTests {
    let machine = MachineID(rawValue: "m")
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func waiting(_ request: ConversationRequest) -> InboxItem {
        let conversation = Conversation(
            id: "c1", machine: machine, taskNumber: 148, agentSessionID: "s1", cwd: "/", runner: .host, phase: .waiting, createdAt: t0, updatedAt: t0)
        return InboxItem(
            id: "conversation/c1/\(request.id)", kind: .conversationRequest(conversation, request), group: .waiting, machine: machine, taskNumber: 148,
            title: "P9 の実装", details: [], at: t0)
    }

    func permission() -> InboxItem {
        waiting(
            ConversationRequest(
                id: "r1", kind: .permission, toolName: "Bash", toolUseID: "t1",
                waiting: RequestWaiting(id: "t1", since: t0, permission: .init(tool: "Bash", summary: "git push"))))
    }

    @Test("権限の確認の通知は、本文の 2 行目にツールと中身が入り、確認を持つ。質問は最初の問いが入り、確認を持たない")
    func waitingBody() throws {
        let note = try #require(InboxNotification.make(permission(), machineName: "Mac Studio"))
        #expect(note.title == "応答待ち" && note.subtitle == "Mac Studio・#148")
        #expect(note.body == "P9 の実装\nBash：git push")
        #expect(note.permission == PermissionPrompt(tool: "Bash", summary: "git push", hash: "t1") && note.threadID == "m/#148")
        let question = waiting(
            ConversationRequest(
                id: "r2", kind: .question, toolName: "AskUserQuestion", toolUseID: "t2",
                waiting: RequestWaiting(id: "t2", since: t0, questions: [AskQuestion(id: "q1", question: "進めますか", options: [AskOption(label: "A")])])))
        let asked = try #require(InboxNotification.make(question, machineName: ""))
        #expect(asked.permission == nil && asked.body == "P9 の実装\n進めますか")
    }

    @Test("まとめる鍵: PR はマシンを含めない（2 台が同じ PR を持つ）、ほかはマシンを含める")
    func collapseKey() throws {
        let notice = PRNotice(machine: machine, url: "https://github.com/o/r/pull/1", label: "o/r#1", title: "t", kind: .ciFailed, at: t0)
        let pr = InboxItem(id: "pr/\(notice.id)", kind: .pullRequest(notice), group: .notice, machine: machine, taskNumber: nil, title: "t", details: [], at: t0)
        let other = InboxItem(
            id: "pr/\(notice.id)", kind: .pullRequest(PRNotice(machine: MachineID(rawValue: "n"), url: notice.url, label: "o/r#1", title: "t", kind: .ciFailed, at: t0)),
            group: .notice, machine: MachineID(rawValue: "n"), taskNumber: nil, title: "t", details: [], at: t0)
        #expect(InboxNotification.make(pr, machineName: "")?.collapseKey == InboxNotification.make(other, machineName: "")?.collapseKey)
        #expect(InboxNotification.make(permission(), machineName: "")?.collapseKey == "m/conversation/c1/r1")
    }

    @Test("端末のトークン: 64〜200 字の偶数の hex だけ")
    func tokenFormat() {
        #expect(PushRegistration.isValidToken(String(repeating: "ab", count: 32)))
        #expect(PushRegistration.isValidToken(String(repeating: "0F", count: 100)))
        #expect(!PushRegistration.isValidToken(String(repeating: "ab", count: 31)))
        #expect(!PushRegistration.isValidToken(String(repeating: "a", count: 65)))
        #expect(!PushRegistration.isValidToken(String(repeating: "zz", count: 32)))
        #expect(!PushRegistration.isValidToken(String(repeating: "ab", count: 101)))
    }

    @Test("登録は JSON で往復する")
    func wire() throws {
        let registration = PushRegistration(
            token: String(repeating: "ab", count: 32), environment: .sandbox, topic: "uk.whatn.taskboard.ios", kinds: [.approval, .ciFailed], sound: true,
            machineName: "Mac Studio", connection: "conn:1")
        let data = try WireJSON.encoder().encode(registration)
        #expect(try WireJSON.decoder().decode(PushRegistration.self, from: data) == registration)
        #expect(String(decoding: data, as: UTF8.self).contains(#""kinds":["approval","ciFailed"]"#))
    }
}

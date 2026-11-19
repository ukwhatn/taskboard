import Foundation
import Testing

@testable import TaskboardKit

@Suite("起動プロンプトのテンプレート")
struct LaunchTests {
    private let machine = MachineID(rawValue: "m1")
    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    private func board(columnTemplate: String? = nil) -> Board {
        var columns = BoardColumn.standard
        if let columnTemplate, let i = columns.firstIndex(where: { $0.id == "review_req" }) { columns[i].promptTemplate = columnTemplate }
        return Board(id: "b", machine: machine, name: "default", position: 0, columns: columns, createdAt: t0, promptTemplate: "/task #{{id}} {{title}}\n{{status}}\n{{links}}\n{{note}}")
    }

    @Test("置換子を埋め、リンクは改行区切り、status は id（ラベル）")
    func render() {
        let task = BoardTask(
            machine: machine, number: 137, boardID: "b", columnID: "working", title: "日本語のタイトル / ASCII", note: "備考\n2 行目",
            links: [TaskLink(id: 1, url: "https://github.com/o/r/pull/1", kind: .githubPR, addedAt: t0), TaskLink(id: 2, url: "https://x.atlassian.net/browse/A-1", kind: .jira, addedAt: t0)],
            createdAt: t0, updatedAt: t0)
        let text = PromptTemplate.render(board().promptTemplate, task: task, board: board())
        #expect(text == "/task #137 日本語のタイトル / ASCII\nworking（作業中）\nhttps://github.com/o/r/pull/1\nhttps://x.atlassian.net/browse/A-1\n備考\n2 行目")
    }

    @Test("ボードが無ければ status は列 id、リンク無しは空、空テンプレートは空のまま")
    func renderWithoutBoard() {
        let task = BoardTask(machine: machine, number: 0, boardID: "b", columnID: "todo", title: "", createdAt: t0, updatedAt: t0)
        #expect(PromptTemplate.render("{{id}}|{{status}}|{{links}}|{{note}}|{{title}}", task: task, board: nil) == "0|todo|||")
        #expect(PromptTemplate.render("", task: task, board: board()).isEmpty)
    }

    @Test("列の上書きがあればそれ、無ければボード既定。空文字の上書きは無視")
    func templateLookup() {
        let b = board(columnTemplate: "/pr-review #{{id}}")
        #expect(PromptTemplate.template(for: "review_req", in: b) == "/pr-review #{{id}}")
        #expect(PromptTemplate.template(for: "working", in: b) == b.promptTemplate)
        #expect(PromptTemplate.template(for: "review_req", in: board(columnTemplate: "")) == b.promptTemplate)
    }

    @Test("モデルと effort から引数を組み、同じ引数から同じ選び方に戻る（cco・ccf・ccs と同じ引数）")
    func choiceRoundTrip() {
        let cco = ["--dangerously-skip-permissions", "--model", "claude-opus-5-5[1m]", "--effort", "medium"]
        #expect(LaunchChoice.standard.args == cco)
        #expect(LaunchChoice(kind: .claude, args: cco) == .standard)
        for model in ["opus", "claude-fable-5-1[1m]", "claude-sonnet-5-5", "claude-opus-4-8"] {
            for effort in Effort.allCases {
                let choice = LaunchChoice(kind: .claude, model: model, effort: effort)
                #expect(LaunchChoice(kind: .claude, args: choice.args) == choice, "\(model) \(effort)")
            }
        }
        #expect(LaunchChoice(kind: .claude, model: "claude-sonnet-5-5", effort: .high).args == ["--dangerously-skip-permissions", "--model", "claude-sonnet-5-5", "--effort", "high"])
    }

    @Test("どのモデルの名前も（一覧に無い新しい名前も）名前のまま構造に戻し、確認の旗が無い引数も戻す。ほかの引数があればカスタムとして引数のまま持つ")
    func choiceFromForeignArgs() {
        #expect(LaunchChoice(kind: .claude, args: ["--model", "sonnet"]) == LaunchChoice(kind: .claude, model: "sonnet"))
        #expect(LaunchChoice(kind: .claude, args: ["--model", "claude-opus-5-5", "--effort", "max"]) == LaunchChoice(kind: .claude, model: "claude-opus-5-5", effort: .max))
        #expect(LaunchChoice(kind: .claude, args: []) == LaunchChoice(kind: .claude))
        let haiku = LaunchChoice(kind: .claude, args: ["--model", "haiku"])
        #expect(!haiku.isCustom && haiku.model == "haiku" && haiku.args == ["--dangerously-skip-permissions", "--model", "haiku"])
        #expect(LaunchChoice(kind: .claude, args: ["--model", "claude-opus-6"]).model == "claude-opus-6")
        #expect(LaunchChoice(kind: .claude, args: ["--model", "--effort", "high"]).isCustom, "値の代わりに旗が来たらモデルにしない")
        #expect(LaunchChoice(kind: .claude, args: ["--effort", "ultra"]).isCustom)
        #expect(LaunchChoice(kind: .claude, args: ["--model", "opus", "--model", "fable"]).isCustom)
        #expect(LaunchChoice(kind: .claude, args: ["--model"]).isCustom)
        #expect(LaunchChoice(kind: .claude, args: ["--verbose", "--model", "opus"]).isCustom)
        #expect(LaunchChoice(kind: .codex, args: []) == LaunchChoice(kind: .codex))
        #expect(LaunchChoice(kind: .codex, args: ["--model", "gpt-5"]).args == ["--model", "gpt-5"])
    }

    @Test("Codex のモデルと effort は --model と -c model_reasoning_effort= の引数にし、同じ引数（-m も）から戻す。ほかの引数があればカスタム")
    func codexChoice() {
        var choice = LaunchChoice(kind: .codex)
        choice.select(codexModel: "gpt-5.5-codex")
        choice.select(codexEffort: "high")
        #expect(choice.args == ["--model", "gpt-5.5-codex", "-c", "model_reasoning_effort=high"])
        #expect(LaunchChoice(kind: .codex, args: choice.args) == choice)
        #expect(LaunchChoice(kind: .codex, args: ["-m", "gpt-5"]) == LaunchChoice(kind: .codex, args: ["--model", "gpt-5"]))
        #expect(LaunchChoice(kind: .codex, args: ["--model", "gpt-5"]).codexModel == "gpt-5")
        #expect(LaunchChoice(kind: .codex, args: ["-c", "model_reasoning_effort=low"]).codexEffort == "low")
        #expect(LaunchChoice(kind: .codex, args: ["--search", "--model", "gpt-5"]).isCustom)
        #expect(LaunchChoice(kind: .codex, args: ["-c", "sandbox_mode=danger-full-access"]).isCustom)
        var custom = LaunchChoice(kind: .codex, args: ["--search"])
        custom.select(codexModel: "gpt-5")
        #expect(!custom.isCustom && custom.args == ["--model", "gpt-5"])
        custom.select(codexModel: nil)
        #expect(custom.args.isEmpty)
        #expect(choice.summary(ClaudeModels(nil)) == "Codex・gpt-5.5-codex・high")
        choice.select(kind: .claude)
        #expect(choice == .standard && choice.codexModel == nil)
    }

    @Test("カスタムはモデルか effort を選び直すまで置き換えない。エージェントを変えると、その既定")
    func choiceSelection() {
        let models = ClaudeModels(nil)
        var choice = LaunchChoice(kind: .claude, args: ["--model", "haiku", "--verbose"])
        #expect(choice.summary(models) == "Claude Code・カスタム")
        choice.select(effort: .high)
        #expect(!choice.isCustom && choice.effort == .high && choice.model == nil)
        choice.select(model: "claude-fable-5-1[1m]")
        #expect(choice.summary(models) == "Claude Code・Fable 5.1・high")
        choice.select(model: "claude-opus-6")
        #expect(choice.summary(models) == "Claude Code・claude-opus-6・high", "一覧に無いモデルは名前のまま")
        choice.select(kind: .codex)
        #expect(choice.args.isEmpty && choice.model == nil && choice.summary(models) == "Codex")
        choice.select(kind: .claude)
        #expect(choice == .standard)
        #expect(LaunchChoice(kind: .codex, model: "opus", effort: .max).args.isEmpty, "Codex にモデルと effort は付けない")
    }

    @Test("hook の案内: タスクの番号と題、マシンと案件、今の列、案件の全部の列の id・名前・説明")
    func guidance() {
        let task = BoardTask(machine: machine, number: 148, boardID: "b", columnID: "working", title: "taskboard アプリを受入条件まで仕上げる", createdAt: t0, updatedAt: t0)
        var b = board()
        b.columns = BoardColumn.standard
        let text = SessionGuidance.text(task: task, board: b, machineName: "この Mac")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "このセッションは taskboard のタスク #148「taskboard アプリを受入条件まで仕上げる」に紐づいている")
        #expect(lines[1] == "- マシン: この Mac")
        #expect(lines[2] == "- 案件: default")
        #expect(lines[3] == "- 今の列: working（作業中）")
        #expect(lines[4].contains("work_add・work_update") && lines[4].contains("task_update") && lines[4].contains("doc_publish"))
        #expect(lines[5].hasPrefix("- 人への問い:") && lines[5].contains("AskUserQuestion") && lines[5].contains("ask_user"))
        #expect(lines[6] == "- 列（移すときは説明に従う）:")
        // 列の 9 行の後に、委任範囲の見出しと 7 項目の 8 行
        #expect(lines.count == 7 + 9 + 8)
        #expect(lines[16].hasPrefix("- 委任範囲（") && lines[16].contains("問わずに決めて実行する") && !lines[16].contains("delegation_record"))
        #expect(lines[17] == "  - implementation（実装の進め方（PR の分け方・順序・設計の細部））: delegate（委任）・組み込みの初期値")
        #expect(lines[7] == "  - standing（常設）: 期限なく続く仕事（定常の運用・問い合わせ対応など）。完了にしない")
        #expect(lines[8] == "  - review_req（レビュー依頼）: 他人の PR・チケットのレビューを頼まれたタスク。レビューを提出してもマージまでここに置き、自分の作業の列へ移さない")
        #expect(lines[15] == "  - wontfix（見送り）: やらないと決めた")
        #expect(SessionGuidance.title(task: task) == "#148 taskboard アプリを受入条件まで仕上げる")
    }

    @Test("案件が分からなければ案件と列の行を出さない。説明が空の列は名前まで、並びは列の位置の順、今の列が無ければその行を出さない")
    func guidanceWithoutBoard() {
        let task = BoardTask(machine: machine, number: 3, boardID: "b", columnID: "x", title: "題", createdAt: t0, updatedAt: t0)
        #expect(SessionGuidance.text(task: task, board: nil, machineName: "この Mac").split(separator: "\n").count == 4 + 8)
        var b = board()
        b.columns = [
            BoardColumn(id: "c-1", label: "保留", kind: .open, position: 1, description: "  人の返事を待つ  "),
            BoardColumn(id: "todo", label: "未着手", kind: .open, position: 0),
        ]
        let lines = SessionGuidance.text(task: task, board: b, machineName: "この Mac").split(separator: "\n").map(String.init)
        #expect(lines.count == 8 + 8)
        #expect(lines[6] == "  - todo（未着手）")
        #expect(lines[7] == "  - c-1（保留）: 人の返事を待つ")
    }

    @Test("会話の題の付け直し: 無いか、hook が付けた形（#番号 ）で古いときだけ。人の付けた題と別のタスクの番号の題は触らない")
    func retitle() {
        let task = BoardTask(machine: machine, number: 476, boardID: "b", columnID: "working", title: "[技術] attr-meta の公開APIを作る", createdAt: t0, updatedAt: t0)
        let wanted = "#476 [技術] attr-meta の公開APIを作る"
        #expect(SessionGuidance.retitle(current: nil, task: task) == wanted)
        #expect(SessionGuidance.retitle(current: "  ", task: task) == wanted)
        #expect(SessionGuidance.retitle(current: "#476 タスクタイトルからつけて", task: task) == wanted)
        #expect(SessionGuidance.retitle(current: "#476 無題", task: task) == wanted)
        #expect(SessionGuidance.retitle(current: wanted, task: task) == nil)
        #expect(SessionGuidance.retitle(current: "attr-meta の調査", task: task) == nil)
        #expect(SessionGuidance.retitle(current: "#4760 別のタスク", task: task) == nil)
        #expect(SessionGuidance.retitle(current: "#47 別のタスク", task: task) == nil)
        #expect(SessionGuidance.retitle(current: "#476", task: task) == nil, "番号だけの題は人が付けたものとして扱う")
    }

    @Test("題の無いタスク（無題）の案内には、題を付ける依頼を入れる")
    func guidanceUntitled() {
        let task = BoardTask(machine: machine, number: 9, boardID: "b", columnID: "x", title: SessionGuidance.untitledTaskTitle, createdAt: t0, updatedAt: t0)
        let lines = SessionGuidance.text(task: task, board: nil, machineName: "この Mac").split(separator: "\n").map(String.init)
        #expect(lines.count == 5 + 8)
        #expect(lines[4] == "- 題: まだ無い。やることが分かったら task_update の title で付ける")
    }

    @Test("MCP の instructions は列の説明に従うよう書き、レビュー依頼の決め打ちの文を持たない")
    func mcpInstructions() {
        #expect(SessionGuidance.mcpInstructions.contains("列の説明に従う"))
        #expect(SessionGuidance.mcpInstructions.contains("session_guide"))
        #expect(!SessionGuidance.mcpInstructions.contains("review_req（"))
    }

    @Test("オーケストレーターの起動プロンプトは役割だけを書き、見回りをさせずに人の指示を待たせる")
    func orchestratorPrompt() {
        let lines = OrchestratorInfo.startPrompt.split(separator: "\n").map(String.init)
        #expect(lines.first == "このセッションは、このマシンの taskboard のオーケストレーター")
        #expect(lines.contains { $0.hasPrefix("- 役割: ") })
        #expect(lines.last == "ユーザーの指示を待機してください。")
        #expect(!OrchestratorInfo.startPrompt.contains("見回"))
    }

    @Test("新しい案件の既定のテンプレートを埋めると、番号・題・列・リンク・備考が入る")
    func defaultTemplates() {
        let task = BoardTask(
            machine: machine, number: 7, boardID: "b", columnID: "review_req", title: "題", note: "備考",
            links: [TaskLink(id: 1, url: "https://github.com/o/r/pull/1", kind: .githubPR, addedAt: t0)], createdAt: t0, updatedAt: t0)
        var b = board()
        b.columns = BoardColumn.standard
        b.promptTemplate = PromptTemplate.defaultBoardTemplate
        let text = PromptTemplate.render(PromptTemplate.defaultBoardTemplate, task: task, board: b)
        #expect(text.hasPrefix("タスク #7 に着手してください。\n題: 題\n列: review_req（レビュー依頼）\n関連URL:\nhttps://github.com/o/r/pull/1\n備考:\n備考\n"))
        #expect(!text.contains("/task") && !text.contains("✅"))
        #expect(PromptTemplate.render(PromptTemplate.defaultReviewRequestTemplate, task: task, board: b) == "/pr-review https://github.com/o/r/pull/1\n#7 題")
    }

    @Test("作業ディレクトリの候補はブックマークが先、最近使ったものは重ならない分")
    func workdirCandidates() {
        let dirs = WorkingDirectories(
            bookmarks: [WorkdirBookmark(id: 1, path: "/a", createdAt: t0), WorkdirBookmark(id: 2, path: "/b", createdAt: t0)], recent: ["/c", "/a", "/d"])
        #expect(dirs.candidates == ["/a", "/b", "/c", "/d"])
        #expect(dirs.isBookmarked("/b") && !dirs.isBookmarked("/c"))
    }

    @Test("入力中の候補: 打った文字を含むブックマーク・最近使ったものが先、続けて daemon が返したディレクトリ。打ったものそのものと重なりは出さない")
    func workdirSuggestions() {
        let dirs = WorkingDirectories(
            bookmarks: [WorkdirBookmark(id: 1, path: "~/dev/8_tools/taskboard", createdAt: t0)], recent: ["/Users/u/dev/案件/決済", "~/dev/kairan", "~/dev/8_tools"])
        #expect(dirs.suggestions(for: "", completions: ["~/dev"]).isEmpty)
        #expect(dirs.suggestions(for: "TASK", completions: []) == ["~/dev/8_tools/taskboard"])
        #expect(dirs.suggestions(for: "決済", completions: []) == ["/Users/u/dev/案件/決済"])
        #expect(
            dirs.suggestions(for: "~/dev/8_tools", completions: ["~/dev/8_tools-old"])
                == ["~/dev/8_tools/taskboard", "~/dev/8_tools-old"])
        #expect(
            dirs.suggestions(for: "~/dev/", completions: ["~/dev/8_tools", "~/dev/kairan", "~/dev/zz"])
                == ["~/dev/8_tools/taskboard", "~/dev/kairan", "~/dev/8_tools", "~/dev/zz"])
    }

}

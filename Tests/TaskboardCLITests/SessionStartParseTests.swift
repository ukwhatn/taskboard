import Foundation
import Testing

@testable import taskboard

@Suite("import taskherd: [session_start] の読み取り")
struct SessionStartParseTests {
    static let toml = """
        [general]
        name = "x"

        [session_start]
        prompt_template = \"\"\"
        /task 以下のタスクに着手してください

        #{{id}} {{title}}
          - インデント付き "引用" と \\\\ バックスラッシュ
        \"\"\"

        [session_start.templates]
        "review_req" = "/pr-review #{{id}} {{title}}\\n\\n{{links}}\\n\\n- ✅をつけてください"
        planning = "plan {{id}}"

        [github.accounts]
        "github.com/foo" = "bar"
        """

    @Test("複数行文字列は開始直後の改行を捨て、中身はそのまま。templates はエスケープを解く")
    func parse() {
        let config = TaskherdFiles.parseSessionStart(Self.toml)
        #expect(config.promptTemplate == "/task 以下のタスクに着手してください\n\n#{{id}} {{title}}\n  - インデント付き \"引用\" と \\ バックスラッシュ\n")
        #expect(config.templates["review_req"] == "/pr-review #{{id}} {{title}}\n\n{{links}}\n\n- ✅をつけてください")
        #expect(config.templates["planning"] == "plan {{id}}")
        #expect(config.templates.count == 2)
    }

    @Test("節が無ければ空、1 行の基本文字列も読める")
    func absentAndSingleLine() {
        #expect(TaskherdFiles.parseSessionStart("[general]\nname = \"x\"\n") == TaskherdFiles.SessionStartConfig())
        let config = TaskherdFiles.parseSessionStart("[session_start]\nprompt_template = \"one line {{id}}\" # comment\n")
        #expect(config.promptTemplate == "one line {{id}}")
    }
}

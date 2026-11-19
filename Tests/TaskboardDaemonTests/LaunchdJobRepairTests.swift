import Testing

@testable import TaskboardDaemon

struct LaunchdJobRepairTests {
    /// `launchctl print` の書式（字下げはタブ。入れ子の `state` は 2 段）
    private func printed(state: String, lastExit: String?) -> String {
        var lines = [
            "gui/502/uk.whatn.taskboardd = {",
            "\tactive count = 0",
            "\tpath = /Users/me/Library/LaunchAgents/uk.whatn.taskboardd.plist",
            "\tstate = \(state)",
            "",
            "\tendpoints = {",
            "\t\tstate = active",
            "\t}",
            "\truns = 2941",
        ]
        if let lastExit { lines.append("\tlast exit code = \(lastExit)") }
        lines += ["\tjob state = spawn failed", "}"]
        return lines.joined(separator: "\n")
    }

    @Test("起動の制約で断られ続けている job（spawn scheduled・78: EX_CONFIG）は登録し直す対象")
    func refusedJobIsStuck() {
        #expect(LaunchdJobRepair.isStuck(printed(state: "spawn scheduled", lastExit: "78: EX_CONFIG")))
        #expect(LaunchdJobRepair.isStuck(printed(state: "not running", lastExit: "78")))
    }

    @Test("動いている job は、前の終わり方が 78 でも登録し直さない")
    func runningJobIsNotStuck() {
        #expect(!LaunchdJobRepair.isStuck(printed(state: "running", lastExit: "78: EX_CONFIG")))
        #expect(!LaunchdJobRepair.isStuck(printed(state: "running", lastExit: "(never exited)")))
    }

    @Test("ほかの終わり方（0・1・780）と、まだ終わったことの無い job は対象にしない")
    func otherExitsAreNotStuck() {
        #expect(!LaunchdJobRepair.isStuck(printed(state: "spawn scheduled", lastExit: "0")))
        #expect(!LaunchdJobRepair.isStuck(printed(state: "spawn scheduled", lastExit: "1: Operation not permitted")))
        #expect(!LaunchdJobRepair.isStuck(printed(state: "spawn scheduled", lastExit: "780")))
        #expect(!LaunchdJobRepair.isStuck(printed(state: "spawn scheduled", lastExit: nil)))
        #expect(!LaunchdJobRepair.isStuck(""))
    }

    @Test("読み込まれていない job は、ssh で入れた（Background）なら user の domain、ほかは gui の domain に読み込む")
    func plistDomain() {
        #expect(LaunchdJobRepair.domain(ofPlist: ["Label": "x", "LimitLoadToSessionType": "Background"], uid: 501) == "user/501")
        #expect(LaunchdJobRepair.domain(ofPlist: ["Label": "x"], uid: 501) == "gui/501")
        #expect(LaunchdJobRepair.domain(ofPlist: ["Label": "x", "LimitLoadToSessionType": "Aqua"], uid: 501) == "gui/501")
    }
}

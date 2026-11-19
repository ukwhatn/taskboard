import Testing
@testable import TaskboardKit

@Suite struct DaemonLocationTests {
    @Test("環境に書いた接続先を読み戻せる")
    func roundTrip() {
        let location = DaemonLocation(port: 5799, supportDirectory: "/tmp/tb-一時")
        #expect(location.environment == ["TASKBOARD_DAEMON_PORT": "5799", "TASKBOARD_SUPPORT_DIR": "/tmp/tb-一時"])
        #expect(DaemonLocation(environment: location.environment) == location)
    }

    @Test("片方だけ・数でない port・範囲外・空のディレクトリは読まない")
    func rejectsPartial() {
        #expect(DaemonLocation(environment: [:]) == nil)
        #expect(DaemonLocation(environment: ["TASKBOARD_DAEMON_PORT": "5799"]) == nil)
        #expect(DaemonLocation(environment: ["TASKBOARD_SUPPORT_DIR": "/tmp/x"]) == nil)
        #expect(DaemonLocation(environment: ["TASKBOARD_DAEMON_PORT": "abc", "TASKBOARD_SUPPORT_DIR": "/tmp/x"]) == nil)
        #expect(DaemonLocation(environment: ["TASKBOARD_DAEMON_PORT": "0", "TASKBOARD_SUPPORT_DIR": "/tmp/x"]) == nil)
        #expect(DaemonLocation(environment: ["TASKBOARD_DAEMON_PORT": "65536", "TASKBOARD_SUPPORT_DIR": "/tmp/x"]) == nil)
        #expect(DaemonLocation(environment: ["TASKBOARD_DAEMON_PORT": "5799", "TASKBOARD_SUPPORT_DIR": ""]) == nil)
    }
}

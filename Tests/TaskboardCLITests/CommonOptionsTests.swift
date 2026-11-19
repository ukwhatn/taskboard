import Testing

@testable import taskboard

@Suite("共通オプション: 会話を起こした daemon に繋ぐ")
struct CommonOptionsTests {
    let started = ["TASKBOARD_DAEMON_PORT": "5799", "TASKBOARD_SUPPORT_DIR": "/tmp/tb-temp"]

    @Test("引数が無ければ、会話を起こした daemon の port と support ディレクトリを使う")
    func inheritsDaemon() throws {
        let options = try CommonOptions.parse([]).inheritingDaemon(from: started)
        #expect(options.port == 5799)
        #expect(options.supportDir == "/tmp/tb-temp")
    }

    @Test("引数で渡した値は環境より優先する")
    func argumentsWin() throws {
        let options = try CommonOptions.parse(["--port", "5781", "--support-dir", "/tmp/mine"]).inheritingDaemon(from: started)
        #expect(options.port == 5781)
        #expect(options.supportDir == "/tmp/mine")
    }

    @Test("環境に無ければ既定の 5780 と既定のディレクトリ")
    func defaults() throws {
        let options = try CommonOptions.parse([]).inheritingDaemon(from: [:])
        #expect(options.port == 5780)
        #expect(options.supportDir == nil)
    }
}

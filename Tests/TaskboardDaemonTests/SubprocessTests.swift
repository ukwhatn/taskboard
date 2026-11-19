import Foundation
import Testing

@testable import TaskboardDaemon

@Suite("短命な子プロセス: 出力の読み切りと打ち切り")
struct SubprocessTests {
    private let sh = URL(fileURLWithPath: "/bin/sh")
    /// 待ちきらずに返ったと言える上限（各テストの timeout の 20 秒と、子の sleep の 30 秒より短い）。swift test の全体では、同じプロセスのほかのテストがスレッドを使い切り、
    /// 子の終わりの後の猶予（1 秒の asyncAfter）が 3.7 秒まで遅れた（別のプロセスの同じ timer は同じ負荷でも 0.07 秒）
    private let promptly: TimeInterval = 15

    @Test("stdout と stderr を両方読み、パイプの容量を超える stderr でも詰まらない")
    func largeOutput() async throws {
        let out = try await Subprocess.run(sh, ["-c", "head -c 200000 /dev/zero | tr '\\0' e >&2; echo 日本語 ok"])
        #expect(out == "日本語 ok\n")
        let error = await #expect(throws: SubprocessError.self) {
            try await Subprocess.run(self.sh, ["-c", "echo bad >&2; exit 3"])
        }
        #expect(error.map { "\($0)" }?.contains("bad") == true)
    }

    @Test("子が終わってもパイプを握った孫が残るとき、timeout を待たずに返る")
    func grandchildHoldsPipe() async throws {
        let started = Date()
        let out = try await Subprocess.run(sh, ["-c", "sleep 30 & echo done"], timeout: .seconds(20))
        #expect(out == "done\n")
        #expect(Date().timeIntervalSince(started) < promptly)
    }

    @Test("timeout で打ち切り、SIGTERM を無視する子も止める")
    func timeout() async throws {
        let started = Date()
        let error = await #expect(throws: SubprocessError.self) {
            try await Subprocess.run(self.sh, ["-c", "trap '' TERM; sleep 30"], timeout: .seconds(1))
        }
        #expect(error.map { "\($0)" }?.contains("打ち切った") == true)
        #expect(Date().timeIntervalSince(started) < promptly)
    }

    @Test("出力が上限を超えたら、timeout を待たずに子を止めて失敗にする。上限までなら読める")
    func outputLimit() async throws {
        let started = Date()
        let error = await #expect(throws: SubprocessError.self) {
            try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/yes"), [], timeout: .seconds(20), outputLimit: 1 << 20)
        }
        #expect(error.map { "\($0)" }?.contains("超えた") == true)
        #expect(Date().timeIntervalSince(started) < promptly)
        let out = try await Subprocess.run(sh, ["-c", "head -c 1000 /dev/zero | tr '\\0' a"], outputLimit: 1000)
        #expect(out.count == 1000)
    }
}

import Darwin
import Foundation

/// 前の host が落ちて残った会話の子。host は子を別の process group の頭にするので、host が落ちても launchd は子を止めず、親は launchd（pid 1）に替わる。
/// 残った子と、起き直した host が `--resume` した子が同じ transcript に書かないよう、host は bind の前にこれで探して止める。
/// 子の控え（ファイル）は使わない。子を起こしてから書き終えるまでの間に host が落ちると取りこぼすので、子の env の印（`marker`）で探す。
/// OS の実行ファイル（/bin/zsh など）の env は他のプロセスから読めないが、Claude Code の CLI は読める。CLI が起こしたシェルは CLI の group にいるので、group ごと止まる。
/// env は会話のシェルから起こしたものすべてに受け継がれるので、印だけでは選ばない: 起こした host の置き場（`hostMarker`）が自分と同じで、アプリ（.app の中の実行ファイル）でないものに限る。
enum OrphanedChildren {
    static let marker = "TASKBOARD_CONVERSATION_ID"
    /// 子を起こした host の置き場（`AgentHostServer.directory`）
    static let hostMarker = "TASKBOARD_AGENT_HOST"

    /// 本人のプロセスのうち、親が launchd で、`host` の host が起こした子の印を持ち、印の値が `matching` に合うものの process group。自分の group と 1 以下は含めない
    static func groups(host: String, matching: @escaping @Sendable (String) -> Bool) async -> [pid_t] {
        await ProcessTable.offPool {
            let own = getpgrp()
            var groups = Set<pid_t>()
            for entry in ProcessTable.processes(uid: geteuid()) where entry.ppid == 1 && entry.pgid > 1 && entry.pgid != own {
                guard let process = ProcessTable.arguments(of: entry.pid), isChild(process, of: host),
                    let value = process.environment[marker], !value.isEmpty, matching(value)
                else { continue }
                groups.insert(entry.pgid)
            }
            return groups.sorted()
        }
    }

    static func isChild(_ process: ProcessTable.Arguments, of host: String) -> Bool {
        process.environment[hostMarker] == host && !process.executable.contains(".app/Contents/")
    }

    /// group ごとに TERM を送り、`grace` の間に終わらなかった group に KILL を送る
    static func stop(_ groups: [pid_t], grace: Duration) async {
        guard !groups.isEmpty else { return }
        for group in groups { killpg(group, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        var alive = groups
        while !alive.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            alive = alive.filter { killpg($0, 0) == 0 }
        }
        for group in alive { killpg(group, SIGKILL) }
    }
}

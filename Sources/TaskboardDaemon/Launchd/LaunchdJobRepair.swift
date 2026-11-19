import Foundation
import Logging

/// daemon と agent host は、launchd の相手の job が起動を断られ続けているか、plist があるのに読み込まれていなければ、plist から登録し直す。
/// 再起動の後の LaunchAgent は BTM が実行ファイルのハッシュに結んだ起動の制約を持ち、ビルドし直した実行ファイルを断る。
/// launchd は BTM でその制約を直そうとするが、BTM の項目が作り直されていると直せず、10 秒ごとに exit 78 を繰り返す
/// （`launchctl bootout` と `bootstrap` で登録し直すと戻る）。macOS 27.2 に上げた再起動の後は、Background の job（ssh で入れた host）が
/// どの domain にも読み込まれなかった
public enum LaunchdJobRepair {
    public static let daemonLabel = "uk.whatn.taskboardd"
    public static let agentHostLabel = "uk.whatn.taskboard-agent-host"
    /// 前の版が入れた herdr の server の job。`install-launchd` が見つけたら外す
    public static let herdrLabel = "uk.whatn.taskboard-herdr"

    /// 見張る相手の label。daemon は host を、host は daemon を見張る。launchd から起こされたとき
    /// （`XPC_SERVICE_NAME` が自分の label）だけ値がある（手で動かした daemon や一時の support ディレクトリの host が、この Mac の job を登録し直さないように）
    public static var peerLabels: [String] {
        switch ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] {
        case daemonLabel: [agentHostLabel]
        case agentHostLabel: [daemonLabel]
        default: []
        }
    }

    /// `peers` の job を見張り続け、直すべき形が続けて見えたら登録し直す。取り消されるまで返らない
    public static func watch(_ peers: [String], logger: Logger, every interval: Duration = .seconds(30)) async {
        guard !peers.isEmpty else { return }
        var seenBefore: Set<String> = []
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            for peer in peers {
                guard let problem = await problem(peer) else { seenBefore.remove(peer); continue }
                // launchd 自身の直し（BTM で制約を更新する・ログインで読み込む）を待つため、2 回続けて見えたときだけ手を出す
                guard seenBefore.remove(peer) != nil else { seenBefore.insert(peer); continue }
                await repair(peer, problem, logger: logger)
            }
        }
    }

    enum Problem: Equatable {
        /// 読み込まれているが、起動を断られ続けている
        case stuck(domain: String)
        /// plist はあるのに、どの domain にも読み込まれていない
        case notLoaded(domain: String)
    }

    /// `launchctl print` の出力から、job が動いておらず、最後の起動が設定の失敗（78: EX_CONFIG）で終わったかを読む
    static func isStuck(_ printed: String) -> Bool {
        var state: String?
        var lastExit: String?
        for line in printed.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let field = line.dropFirst()
            if field.hasPrefix("state = ") { state = String(field.dropFirst("state = ".count)) }
            if field.hasPrefix("last exit code = ") { lastExit = String(field.dropFirst("last exit code = ".count)) }
        }
        guard let lastExit, state != "running" else { return false }
        return lastExit == "78" || lastExit.hasPrefix("78:")
    }

    /// plist を読み込む domain。`install-launchd` が画面にログインしていない Mac で入れた job は `LimitLoadToSessionType` が Background で、user の domain に置く
    static func domain(ofPlist plist: [String: Any], uid: uid_t) -> String {
        plist["LimitLoadToSessionType"] as? String == "Background" ? "user/\(uid)" : "gui/\(uid)"
    }

    private static func problem(_ label: String) async -> Problem? {
        let uid = getuid()
        for domain in ["gui/\(uid)", "user/\(uid)"] {
            guard let outcome = try? await Subprocess.capture(launchctl, ["print", "\(domain)/\(label)"], timeout: .seconds(5)),
                outcome.status == 0
            else { continue }
            return isStuck(String(decoding: outcome.stdout, as: UTF8.self)) ? .stuck(domain: domain) : nil
        }
        guard let data = try? Data(contentsOf: plistURL(label)),
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return .notLoaded(domain: domain(ofPlist: plist, uid: uid))
    }

    private static func repair(_ label: String, _ problem: Problem, logger: Logger) async {
        let plist = plistURL(label).path
        let domain: String
        switch problem {
        case .stuck(let stuckDomain):
            domain = stuckDomain
            logger.warning("launchd keeps refusing to start the job; reloading it from its plist", metadata: ["label": .string(label), "domain": .string(domain)])
            _ = try? await Subprocess.capture(launchctl, ["bootout", "\(domain)/\(label)"], timeout: .seconds(15))
        case .notLoaded(let plistDomain):
            domain = plistDomain
            logger.warning("the job is not loaded; loading it from its plist", metadata: ["label": .string(label), "domain": .string(domain)])
        }
        let started = try? await Subprocess.capture(launchctl, ["bootstrap", domain, plist], timeout: .seconds(15))
        if started?.status != 0 {
            let message = started.map { String(decoding: $0.stderr, as: UTF8.self) } ?? "launchctl を起こせなかった"
            logger.error("reloading the job failed", metadata: ["label": .string(label), "error": .string(message)])
        }
    }

    private static func plistURL(_ label: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/LaunchAgents/\(label).plist")
    }

    private static let launchctl = URL(filePath: "/bin/launchctl")
}

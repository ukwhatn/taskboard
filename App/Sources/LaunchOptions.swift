import Foundation

/// 起動引数。デバッグ用の口と fixtures の差し替えだけを受ける。
struct LaunchOptions: Sendable, Equatable {
    /// DEBUG ビルドで loopback に開く制御用 HTTP の port。無ければ開かない。
    var debugPort: Int?
    /// 本物の daemon の代わりに読む fixtures の名前（`Fixtures/<name>.json`）。
    var scenario: String?
    /// 接続する daemon の URL（例: `http://127.0.0.1:5780`）。無ければ Mac は同一 Mac の daemon、iOS は未接続。
    var daemonURL: URL?
    /// その daemon の token ファイル。シミュレータはホストのファイルを読めるので、同一 Mac の daemon に繋ぐのに使う。
    var tokenFile: String?
    /// 通知の許可を求めない（シミュレータでの自動確認。許可のダイアログが画面に被るため）
    var noNotifications = false
    /// 通知の許可を、ダイアログを出さない仮の許可（provisional）で求める。シミュレータで APNs と通知の操作を確かめるため
    /// （シミュレータの許可のダイアログは simctl では押せない）
    var provisionalNotifications = false
    /// debug の口で起こしたアプリの設定の保存先に、初めに入れる plist（`defaults export uk.whatn.taskboard <path>` で写したユーザーの設定など）
    var defaultsFile: String?
    /// Keychain に保存した接続先を読まない（同じ Mac の daemon だけに繋ぐ）。bundle ID を替えた複製で本物のデータを確かめるとき、
    /// Keychain の確認がユーザーの画面に出ないように付ける
    var localOnly = false
    /// どの daemon にも繋がず、Keychain の接続先も読まない（test host。テストはそれぞれ fixtures の `AppModel` を作る）
    var offline = false
    /// fixtures・debug の口で起こしたアプリでも主スレッドを見張る（止まりの記録と、iPhone・iPad の daemon への送り口の確かめ）
    var watchdog = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--debug-port":
                options.debugPort = iterator.next().flatMap(Int.init)
            case "--scenario":
                options.scenario = iterator.next()
            case "--daemon-url":
                options.daemonURL = iterator.next().flatMap(URL.init(string:))
            case "--token-file":
                options.tokenFile = iterator.next()
            case "--no-notifications":
                options.noNotifications = true
            case "--provisional-notifications":
                options.provisionalNotifications = true
            case "--watchdog":
                options.watchdog = true
            case "--local-only":
                options.localOnly = true
            case "--defaults-file":
                options.defaultsFile = iterator.next()
            default:
                if arg.hasPrefix("--debug-port=") { options.debugPort = Int(arg.dropFirst("--debug-port=".count)) }
                if arg.hasPrefix("--defaults-file=") { options.defaultsFile = String(arg.dropFirst("--defaults-file=".count)) }
                if arg.hasPrefix("--scenario=") { options.scenario = String(arg.dropFirst("--scenario=".count)) }
                if arg.hasPrefix("--daemon-url=") { options.daemonURL = URL(string: String(arg.dropFirst("--daemon-url=".count))) }
                if arg.hasPrefix("--token-file=") { options.tokenFile = String(arg.dropFirst("--token-file=".count)) }
            }
        }
        return options
    }
}

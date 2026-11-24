import Foundation
import TaskboardKit

/// 画面に出す失敗の文（docs/ui-copy.md「エラー」）。事象、原因、対処の順に組む。
/// 例外の文字列と daemon の `message` は出さない。原因が分からなければ事象と対処だけにする
struct UserFacingError: Error, Hashable, Sendable, Identifiable {
    /// 「{操作}できませんでした」
    var event: String
    var cause: String?
    var remedy: String?
    let id = UUID()

    /// 事象はリテラルで渡すと String Catalog に入る（`String` を受けないのは、catalog に入れ忘れた文をコンパイルで止めるため）
    init(_ event: LocalizedStringResource, cause: String? = nil, remedy: String? = nil) {
        self.event = String(localized: event)
        self.cause = cause
        self.remedy = remedy
    }

    /// 失敗した操作（事象）と、起きたエラーから組む。取り消し（画面を閉じた等）なら nil
    init?(_ event: LocalizedStringResource, error: any Error) {
        if let already = error as? UserFacingError {
            self = UserFacingError(event, cause: already.cause, remedy: already.remedy)
            return
        }
        guard let reason = Self.reason(error) else { return nil }
        self.init(event, cause: reason.cause, remedy: reason.remedy)
    }

    var text: String {
        [event, cause, remedy].compactMap { $0 }.map { $0.hasSuffix("。") ? $0 : $0 + "。" }.joined()
    }

    /// 原因と対処だけ（空状態の題に事象を書いたとき、その下に出す）。どちらも無ければ nil
    var detail: String? {
        let parts = [cause, remedy].compactMap { $0 }.map { $0.hasSuffix("。") ? $0 : $0 + "。" }
        return parts.isEmpty ? nil : parts.joined()
    }

    static let retry = String(localized: "時間をおいて、やり直してください")
    static let checkNetwork = String(localized: "ネットワークと、接続先のMacが起動しているかを確認してください")
    static let updateDaemon = String(localized: "接続先のMacのTaskboardを更新してください")
    /// 接続し直している間の知らせ（チャット・会話・端末）
    static let reconnecting = String(localized: "接続が切れました。接続し直しています…")

    /// エラーの原因と対処。取り消しは nil
    static func reason(_ error: any Error) -> (cause: String?, remedy: String?)? {
        switch error {
        case is CancellationError:
            return nil
        case let error as SessionSourceError:
            return reason(error)
        case let error as URLError:
            return reason(error)
        case AppModel.ActionError.notWritable(let access):
            return reason(access)
        case ConnectionStore.Failure.keychain:
            return (String(localized: "Keychainに書き込めません"), retry)
        default:
            return (nil, retry)
        }
    }

    /// 書き込めない理由。書き込めるのに供給元が操作を持たないときは、原因を書かず対処だけにする
    static func reason(_ access: WriteAccess) -> (cause: String?, remedy: String?)? {
        switch access {
        case .readOnly: (String(localized: "この接続先は表示用のデータです"), nil)
        case .hidden: (String(localized: "1台だけ表示で隠しているMacです"), nil)
        case .unknown: (nil, checkNetwork)
        case .writable: (nil, retry)
        }
    }

    static func reason(_ error: SessionSourceError) -> (cause: String?, remedy: String?) {
        switch error {
        case .unauthorized: (String(localized: "接続先のトークンが一致しません"), String(localized: "［設定］>［接続先］で資格情報を入力し直してください"))
        case .forbidden: (String(localized: "Cloudflare Accessに拒否されました"), String(localized: "［設定］>［接続先］でClient IDとClient Secretを確認してください"))
        // 本文の無い 404 は、その操作を持たない古い daemon
        case .httpStatus(404): (String(localized: "接続先のMacのTaskboardがこの操作に対応していません"), updateDaemon)
        case .httpStatus: (nil, retry)
        case .invalidResponse: (String(localized: "接続先のMacから読み取れない応答が届きました"), updateDaemon)
        case .disconnected: (String(localized: "接続先のMacとの接続が切れています"), checkNetwork)
        case .rejected(let rejection): reason(rejection)
        }
    }

    static func reason(_ error: URLError) -> (cause: String?, remedy: String?)? {
        switch error.code {
        case .cancelled: nil
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: (String(localized: "ネットワークに接続できません"), String(localized: "ネットワークを確認してください"))
        case .timedOut: (String(localized: "接続先のMacから応答がありません"), checkNetwork)
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: (String(localized: "接続先のMacに接続できません"), checkNetwork)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            (String(localized: "接続先との安全な通信を確立できません"), String(localized: "接続先のURLを確認してください"))
        default: (String(localized: "接続先のMacと通信できません"), checkNetwork)
        }
    }

    static func reason(_ rejection: DaemonRejection) -> (cause: String?, remedy: String?) {
        let p = rejection.params
        func name(_ key: String) -> String { p[key].map { "【\($0)】" } ?? "" }
        func count(_ key: String) -> String { p[key] ?? "" }
        guard let code = rejection.code else { return (nil, retry) }
        switch code {
        case .notFound:
            let kind = p["kind"].flatMap(DaemonErrorCode.Kind.init(rawValue:))
            return (String(localized: "\(kind?.noun ?? String(localized: "対象"))が見つかりません"), nil)
        case .askNotOpen: return (String(localized: "この質問は回答済みです"), nil)
        case .askUnanswered: return (String(localized: "未回答の質問が\(count("count"))問あります"), String(localized: "すべての質問に回答してください"))
        case .commentNotDraft: return (String(localized: "このコメントは送信済みです"), nil)
        case .commentIsDraft: return (String(localized: "下書きのコメントは解決にできません"), String(localized: "レビューを送信してから解決にしてください"))
        case .docFormatMismatch: return (String(localized: "同じ名前で形式の違う文書があります"), nil)
        case .boardArchived: return (String(localized: "案件\(name("name"))はアーカイブされています"), String(localized: "［設定］>［案件］でアーカイブから戻してください"))
        case .boardLast: return (String(localized: "最後の案件です"), String(localized: "先にほかの案件を追加してください"))
        case .boardHasTasks: return (String(localized: "案件\(name("name"))にタスクが\(count("count"))件あります"), String(localized: "タスクをほかの案件に移動してから、削除してください"))
        case .boardNameEmpty: return (nil, String(localized: "案件の名前を入力してください"))
        case .boardNameTaken: return (String(localized: "同じ名前の案件\(name("name"))があります"), String(localized: "別の名前を入力してください"))
        case .columnLabelEmpty: return (nil, String(localized: "列の名前を入力してください"))
        case .columnLabelDuplicate: return (String(localized: "列\(name("label"))が重複しています"), String(localized: "別の名前を入力してください"))
        case .defaultColumnLocked:
            switch p["change"] {
            case "kind": return (String(localized: "デフォルトの列\(name("label"))は、完了扱いを変更できません"), nil)
            case "remove": return (String(localized: "列\(name("label"))は削除できません"), nil)
            default: return (String(localized: "デフォルトの列\(name("label"))は、削除も完了扱いの変更もできません"), nil)
            }
        case .noOpenColumn: return (String(localized: "進行中の列が1つもなくなります"), String(localized: "進行中の列を1つ以上残してください"))
        case .columnHasTasks: return (String(localized: "列\(name("label"))にタスクが\(count("count"))件あります"), String(localized: "移動先の列を選んでください"))
        case .scheduleNameEmpty: return (nil, String(localized: "名前を入力してください"))
        case .cronInvalid: return (String(localized: "cron式を読み取れません"), String(localized: "「分 時 日 月 曜日」の5つを半角の空白で区切って入力してください"))
        case .intervalTooShort: return (nil, String(localized: "間隔は\(count("minimum"))分以上にしてください"))
        case .scheduleRunExists: return (String(localized: "同じ時刻の実行が既にあります"), nil)
        case .textTooLong: return (nil, String(localized: "\(p["limit"].flatMap(Int.init)?.formatted() ?? "")文字以内にしてください"))
        case .orchestratorRunning: return (String(localized: "オーケストレーターは既に起動しています"), nil)
        case .orchestratorMissing: return (String(localized: "オーケストレーターが起動していません"), String(localized: "［起動］を押してください"))
        case .orchestratorStarting: return (String(localized: "オーケストレーターを起動しています"), String(localized: "起動が終わってから、やり直してください"))
        case .orchestratorResident: return (String(localized: "常駐がオンのオーケストレーターは停止できません"), String(localized: "［設定］>［セッション］で常駐をオフにしてください"))
        case .sessionRunning: return (String(localized: "このセッションは既に起動しています"), nil)
        case .pairingCodeInvalid: return (String(localized: "コードが違うか、有効期限が切れています"), String(localized: "接続先のMacで新しいコードを表示して、入力し直してください"))
        case .pairingTooManyFailures: return (String(localized: "コードの入力に何度も失敗しました"), String(localized: "\(count("seconds"))秒たってから、やり直してください"))
        case .githubFailed: return (String(localized: "GitHubからPRを取得できません"), String(localized: "接続先のMacで「gh auth status」を実行して、ログインを確認してください"))
        case .deviceNotAllowed: return (String(localized: "このデバイスには、この操作の権限がありません"), String(localized: "接続先のMacで操作してください"))
        case .sessionCommandFailed: return (String(localized: "接続先のMacでセッションを操作できません"), retry)
        case .notWaiting: return (String(localized: "このセッションは応答待ちではありません"), nil)
        case .attachmentTooLarge: return (String(localized: "画像が\(count("limit"))MBを超えています"), String(localized: "小さい画像を貼り付けてください"))
        case .attachmentUnsupported: return (String(localized: "この形式の画像は送信できません"), String(localized: "PNG・JPEG・GIF・WebPの画像を貼り付けてください"))
        case .attachmentMissing: return (String(localized: "画像が接続先のMacに見つかりません"), String(localized: "画像を貼り付け直してください"))
        case .questionPending: return (String(localized: "セッションが質問への回答を待っています"), String(localized: "上の質問に答えてください"))
        case .conversationLimit: return (String(localized: "接続先のMacで起動しているセッションが上限の\(count("limit"))件に達しています"), String(localized: "使っていないセッションを終了してください"))
        case .claudeUnverified: return (String(localized: "接続先のMacのClaude Codeのバージョンを確認できていません"), String(localized: "接続先のMacで「taskboard conversation check」を実行してください"))
        case .codexUnverified: return (String(localized: "接続先のMacのCodexのバージョンを確認できていません"), String(localized: "接続先のMacで「taskboard conversation check --engine codex」を実行してください"))
        case .codexOutdated: return (String(localized: "接続先のMacのCodexのバージョンが古いため、この操作はできません"), String(localized: "接続先のMacでCodexを更新してください"))
        case .conversationStopped: return (String(localized: "セッションが動いていません"), String(localized: "もう一度送信してください"))
        case .conversationRunning: return (String(localized: "セッションが起動しています"), String(localized: "終了してから削除してください"))
        case .conversationBusy: return (String(localized: "セッションが作業中です"), String(localized: "作業が終わってから、やり直してください"))
        case .conversationChanged: return (String(localized: "ほかの画面でセッションの内容が変わりました"), String(localized: "開き直してから、やり直してください"))
        case .conversationNotSent: return (String(localized: "このセッションでは、まだ送信していません"), String(localized: "1回送信してから、やり直してください"))
        case .runNoConversation: return (String(localized: "このタスクには、コードを実行するセッションがありません"), String(localized: "タスクのセッションを開始してから、実行してください"))
        case .runLimit: return (String(localized: "このシェルでは別のコードを実行中です"), String(localized: "実行中のコードが終わってから、やり直してください"))
        case .engineUnsupported:
            return (String(localized: "\(p["engine"].flatMap(AgentKind.init(rawValue:))?.label ?? String(localized: "この種類"))のセッションでは、この操作はできません"), nil)
        case .unavailable: return (String(localized: "接続先のMacでこの機能が動いていません"), updateDaemon)
        case .invalidRequest, .internalError: return (nil, retry)
        }
    }
}

extension DaemonErrorCode.Kind {
    var noun: String {
        switch self {
        case .board: String(localized: "案件")
        case .column: String(localized: "列")
        case .task: String(localized: "タスク")
        case .workItem: String(localized: "作業項目")
        case .document: String(localized: "文書")
        case .ask: String(localized: "質問")
        case .comment: String(localized: "コメント")
        case .revision: String(localized: "文書の版")
        case .schedule: String(localized: "定期起動")
        case .wake: String(localized: "再開の予定")
        case .watch: String(localized: "PR・issueの監視")
        case .device: String(localized: "デバイス")
        case .session: String(localized: "セッション")
        case .launch: String(localized: "起動")
        case .claim: String(localized: "レビューの受け取り")
        case .pullRequest: String(localized: "PR")
        case .conversation: String(localized: "セッション")
        case .message: String(localized: "メッセージ")
        case .file: String(localized: "ファイル")
        case .run: String(localized: "実行の結果")
        }
    }
}

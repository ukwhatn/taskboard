import Foundation

// MARK: - 止まりの記録（iPhone・iPad のアプリ → daemon）

/// iPhone・iPad の手元の記録は Mac から読めないので、主スレッドの止まりを接続先の daemon へ送り、daemon のログに 1 件 1 行で残す
public struct AppDiagnosticReport: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// アプリの見張り（`MainThreadWatchdog`）が数えた止まり。戻ったときに送る
        case stall
        /// MetricKit の `MXHangDiagnostic`。OS が翌日ごろにまとめて渡す
        case hang
    }

    /// 同じ記録を 2 回残さないための鍵。アプリが決める
    public var id: String
    public var kind: Kind
    /// 止まりが終わった時刻（MetricKit は payload の終わりの時刻）
    public var at: Date
    public var durationMS: Int
    /// 止まったときに開いていた画面（`task.side.chat` など）
    public var screen: String?
    public var appVersion: String?
    public var osVersion: String?
    /// 主スレッドの積み重ね（上が止まっていた所）。`<binary>+<offset>` の形で、記号には直していない
    public var frames: [String]

    public init(
        id: String, kind: Kind, at: Date, durationMS: Int, screen: String? = nil, appVersion: String? = nil, osVersion: String? = nil,
        frames: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.durationMS = durationMS
        self.screen = screen
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.frames = frames
    }

    public static let idLimit = 64
    public static let textLimit = 128
    public static let frameLimit = 40
    public static let frameTextLimit = 160
    /// 1 日。これより長い値は時計の誤り
    public static let durationLimit = 86_400_000

    /// daemon が断る理由。nil なら受け付ける
    public var violation: String? {
        if !(1...Self.idLimit).contains(id.count) { return "idは1〜\(Self.idLimit)字" }
        if !(0...Self.durationLimit).contains(durationMS) { return "durationMSは0〜\(Self.durationLimit)" }
        for (name, value) in [("screen", screen), ("appVersion", appVersion), ("osVersion", osVersion)] where (value?.count ?? 0) > Self.textLimit {
            return "\(name)は\(Self.textLimit)字まで"
        }
        if frames.count > Self.frameLimit { return "framesは\(Self.frameLimit)個まで" }
        if frames.contains(where: { $0.count > Self.frameTextLimit }) { return "framesの1つは\(Self.frameTextLimit)字まで" }
        return nil
    }
}

/// `POST /v1/devices/current/diagnostics`（端末の token だけ）
public struct AppDiagnosticsUpload: Codable, Hashable, Sendable {
    public var reports: [AppDiagnosticReport]

    public init(reports: [AppDiagnosticReport]) {
        self.reports = reports
    }

    public static let reportLimit = 20
}

/// 受け付けた記録のうち、ログに残した数と残さなかった数（前に受けた id と、端末ごとの上限を越えた分）
public struct AppDiagnosticsResult: Codable, Hashable, Sendable {
    public var logged: Int
    public var skipped: Int

    public init(logged: Int, skipped: Int) {
        self.logged = logged
        self.skipped = skipped
    }
}

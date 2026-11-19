import CryptoKit
import Foundation
import TaskboardKit
#if os(iOS)
import MetricKit
#endif

/// MetricKit の止まりの診断（`MXHangDiagnostic`）を、daemon へ送る記録にする。
/// 本物の診断はシミュレータでは届かないので、debug の口（`/diagnostics/hang`）は同じ値をここに渡して確かめる
enum HangDiagnostics {
    /// `MXHangDiagnostic` から取り出す値
    struct Values: Equatable {
        var durationMS: Int
        /// payload の終わりの時刻（止まった時刻そのものは診断に無い）
        var end: Date
        var appVersion: String?
        var osVersion: String?
        /// `MXCallStackTree.jsonRepresentation()`
        var callStackTree: Data
    }

    /// 根から先頭の `leadingFrames` 個は全部、その後はアプリの実行ファイルの枠だけを、合わせて上限まで残す。
    /// 止まりの積み重ねは SwiftUI と UIKit の枠が長く続き、上から順に切るとアプリの枠まで届かない
    static let leadingFrames = 25

    static func report(_ values: Values, appBinary: String) -> AppDiagnosticReport {
        let frames = frames(callStackTree: values.callStackTree, appBinary: appBinary)
        let digest = SHA256.hash(data: Data("\(values.end.timeIntervalSince1970)|\(values.durationMS)|\(frames.joined(separator: "|"))".utf8))
        let id = "hang-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return AppDiagnosticReport(
            id: id, kind: .hang, at: values.end, durationMS: min(max(0, values.durationMS), AppDiagnosticReport.durationLimit),
            appVersion: values.appVersion.map(clip), osVersion: values.osVersion.map(clip), frames: frames)
    }

    /// 止まりの元のスレッド（`threadAttributed`。無ければ最初のスレッド）を、根から標本の多い枝をたどって `<binary>+0x<offset>` に並べる
    static func frames(callStackTree data: Data, appBinary: String) -> [String] {
        guard let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stacks = tree["callStacks"] as? [[String: Any]],
            let stack = stacks.first(where: { $0["threadAttributed"] as? Bool == true }) ?? stacks.first
        else { return [] }
        var chain: [(binary: String, text: String)] = []
        var level = stack["callStackRootFrames"] as? [[String: Any]] ?? []
        while let frame = level.max(by: { ($0["sampleCount"] as? Int ?? 0) < ($1["sampleCount"] as? Int ?? 0) }), chain.count < 512 {
            let binary = frame["binaryName"] as? String ?? "?"
            let offset = frame["offsetIntoBinaryTextSegment"] as? Int ?? 0
            chain.append((binary, clip("\(binary)+0x\(String(offset, radix: 16))", limit: AppDiagnosticReport.frameTextLimit)))
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        let leading = chain.prefix(leadingFrames)
        let app = chain.dropFirst(leadingFrames).filter { $0.binary == appBinary }
        return Array((leading + app).prefix(AppDiagnosticReport.frameLimit).map(\.text))
    }

    private static func clip(_ text: String) -> String { clip(text, limit: AppDiagnosticReport.textLimit) }

    private static func clip(_ text: String, limit: Int) -> String { String(text.prefix(limit)) }
}

#if os(iOS)
/// MetricKit の診断を受ける。診断は OS が前の日の分をまとめて、起動の後に主スレッドの外で渡す
final class HangDiagnosticsReceiver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let deliver: @MainActor @Sendable ([AppDiagnosticReport]) -> Void
    private let appBinary = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Taskboard"

    init(deliver: @escaping @MainActor @Sendable ([AppDiagnosticReport]) -> Void) {
        self.deliver = deliver
        super.init()
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { payload in
            (payload.hangDiagnostics ?? []).map { hang in
                HangDiagnostics.report(
                    HangDiagnostics.Values(
                        durationMS: Int(hang.hangDuration.converted(to: .milliseconds).value), end: payload.timeStampEnd,
                        appVersion: "build \(hang.metaData.applicationBuildVersion)", osVersion: hang.metaData.osVersion,
                        callStackTree: hang.callStackTree.jsonRepresentation()),
                    appBinary: appBinary)
            }
        }
        guard !reports.isEmpty else { return }
        let deliver = deliver
        Task { @MainActor in deliver(reports) }
    }
}
#endif

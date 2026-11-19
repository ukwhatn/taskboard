import Foundation
import Hummingbird
import Logging
import TaskboardKit

/// iPhone・iPad の主スレッドの止まりの記録を、daemon のログに 1 件 1 行で残す
extension APIServer {
    static func registerDiagnosticsRoutes(v1: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, encoder: JSONEncoder, logger: Logger) {
        v1.post("devices/current/diagnostics") { request, context in
            guard case .device(let device) = context.principal else { throw APIError.invalid("端末の token で呼ぶ（daemon の token では送れない）") }
            let body = try await request.decode(as: AppDiagnosticsUpload.self, context: context)
            guard (1...AppDiagnosticsUpload.reportLimit).contains(body.reports.count) else {
                throw APIError.invalid("reportsは1〜\(AppDiagnosticsUpload.reportLimit)件")
            }
            if let violation = body.reports.lazy.compactMap(\.violation).first { throw APIError.invalid(violation) }
            let (admitted, skipped) = await dependencies.diagnostics.admit(body.reports, device: device)
            for report in admitted {
                logger.warning("app \(report.kind.rawValue)", metadata: diagnosticsMetadata(report, device: device))
            }
            return try json(AppDiagnosticsResult(logged: admitted.count, skipped: skipped), encoder)
        }
    }

    /// 1 行に収めるため、端末から来た文の改行と制御文字は空白にする
    static func diagnosticsMetadata(_ report: AppDiagnosticReport, device: String) -> Logger.Metadata {
        func line(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        }
        var metadata: Logger.Metadata = [
            "device": .string(device), "id": .string(line(report.id)), "ms": .stringConvertible(report.durationMS),
            "at": .string(report.at.formatted(.iso8601)),
        ]
        if let screen = report.screen { metadata["screen"] = .string(line(screen)) }
        if let app = report.appVersion { metadata["app"] = .string(line(app)) }
        if let os = report.osVersion { metadata["os"] = .string(line(os)) }
        if !report.frames.isEmpty { metadata["frames"] = .string(report.frames.map(line).joined(separator: " < ")) }
        return metadata
    }
}

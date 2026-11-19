import Foundation
import Network
import SwiftUI
import TaskboardKit

#if os(iOS)
import SafariServices
#endif

/// 別の端末でコネクタを認証するとき、認証のページの戻り先（この端末の localhost の port）をアプリが受ける。
/// loopback だけで受け、受け始めたら `ready` を呼ぶ。戻り先の path に、認証のページと同じ state と（code か error）の付いた要求を 1 回受けたら閉じる。
/// 受けられなければ（port が使われている・待ち受けが落ちた）`failed` を呼ぶ。`stop` の後はどれも呼ばない
@MainActor
final class ConnectorCallbackCatcher {
    private var listener: NWListener?
    private let redirect: OAuthRedirect
    private let ready: () -> Void
    private let received: (URL) -> Void
    private let failed: () -> Void

    init?(redirect: OAuthRedirect, ready: @escaping () -> Void, received: @escaping (URL) -> Void, failed: @escaping () -> Void) {
        guard let port = redirect.address.port.flatMap({ UInt16(exactly: $0) }).flatMap(NWEndpoint.Port.init(rawValue:)) else { return nil }
        self.redirect = redirect
        self.ready = ready
        self.received = received
        self.failed = failed
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters, on: port) else { return nil }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { @MainActor in self?.becameReady() }
            case .failed, .waiting: Task { @MainActor in self?.fail() }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func becameReady() {
        guard listener != nil else { return }
        ready()
    }

    private func fail() {
        guard listener != nil else { return }
        stop()
        failed()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let line = Self.requestTarget(buffer) {
                    self.answer(connection, target: line)
                } else if isComplete || error != nil || buffer.count > OAuthLinks.callbackLimit * 2 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func answer(_ connection: NWConnection, target: String) {
        let callback = listener == nil ? nil : OAuthLinks.callback(requestTarget: target, redirect: redirect)
        let body = callback == nil ? "" : "<!doctype html><meta charset=\"utf-8\"><title>taskboard</title><p>\(String(localized: "認証が終わりました。taskboardに戻ってください。"))</p>"
        let head = callback == nil ? "HTTP/1.1 404 Not Found" : "HTTP/1.1 200 OK"
        let response = "\(head)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        guard let callback else { return }
        stop()
        received(callback)
    }

    /// 要求の 1 行目（`GET <target> HTTP/1.1`）の target。行が揃っていなければ nil
    private static func requestTarget(_ buffer: Data) -> String? {
        guard let end = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let parts = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" else { return "" }
        return String(parts[1])
    }
}

#if os(iOS)
/// アプリの中の Safari。認証の間アプリを前に置いたまま（戻り先をアプリが受けられる）、Universal Link でほかのアプリに移らない
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { finished() }
    }
}
#endif

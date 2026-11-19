import Foundation
import Testing
@testable import TaskboardKit

@Suite struct AuthFailureTests {
    let base = URL(string: "https://studio-taskboard.example.com")!

    func response(_ url: String, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("daemon の 401 と Access の 403 を分ける")
    func statusCodes() {
        #expect(DaemonClient.authFailure(response("https://studio-taskboard.example.com/v1/state", 401), base: base) == .unauthorized)
        #expect(DaemonClient.authFailure(response("https://studio-taskboard.example.com/v1/state", 403), base: base) == .forbidden)
        #expect(DaemonClient.authFailure(response("https://studio-taskboard.example.com/v1/state", 200), base: base) == nil)
        #expect(DaemonClient.authFailure(response("https://studio-taskboard.example.com/v1/state", 500), base: base) == nil)
    }

    @Test("失効したサービストークンは Access のログイン画面へ 302 される。追った先が別ホストの 200 でも、Access に断られたとして扱う")
    func redirectedToAccessLogin() {
        #expect(DaemonClient.authFailure(response("https://team.cloudflareaccess.com/cdn-cgi/access/login/studio-taskboard.example.com", 200), base: base) == .forbidden)
        // WebSocket の upgrade はリダイレクトを追わず 302 のまま返る
        #expect(DaemonClient.authFailure(response("https://studio-taskboard.example.com/v1/stream", 302), base: base) == .forbidden)
    }

    @Test("Access の内側では、daemon の印が付いた 401 だけを token の違いとし、印の無い 401 は Access の拒否とする")
    func accessStrict401() {
        let marked = HTTPURLResponse(
            url: URL(string: "https://studio-taskboard.example.com/v1/state")!, statusCode: 401, httpVersion: nil,
            headerFields: [DaemonAuthHeader.name: DaemonAuthHeader.invalid])!
        #expect(DaemonClient.authFailure(marked, base: base, behindAccess: true) == .unauthorized)
        #expect(DaemonClient.authFailure(response("https://studio-taskboard.example.com/v1/state", 401), base: base, behindAccess: true) == .forbidden)
        let deviceForbidden = HTTPURLResponse(
            url: URL(string: "https://studio-taskboard.example.com/v1/pairings")!, statusCode: 403, httpVersion: nil,
            headerFields: [DaemonAuthHeader.name: DaemonAuthHeader.forbidden])!
        #expect(DaemonClient.authFailure(deviceForbidden, base: base, behindAccess: true) == .rejected(DaemonRejection(status: 403, message: "この端末ではできない", code: .deviceNotAllowed)))
    }

    @Test("同一 Mac の daemon（loopback）は Access を通らない")
    func loopback() {
        let local = URL(string: "http://127.0.0.1:5780")!
        #expect(DaemonClient.authFailure(response("http://127.0.0.1:5780/v1/state", 200), base: local) == nil)
        #expect(DaemonClient.authFailure(response("http://127.0.0.1:5780/v1/state", 401), base: local) == .unauthorized)
    }
}

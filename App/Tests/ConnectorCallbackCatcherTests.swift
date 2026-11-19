import Foundation
import TaskboardKit
import Testing

@testable import Taskboard

/// 別の端末でコネクタを認証するとき、戻り先の localhost の port をアプリが受ける
@MainActor
@Suite struct ConnectorCallbackCatcherTests {
    private func redirect() -> OAuthRedirect {
        OAuthRedirect(address: URL(string: "http://localhost:\(Int.random(in: 41000...48999))/callback")!, state: "s1")
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func get(_ url: URL) async throws -> (Int, String) {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test("受け始めたら ready を呼び、戻り先の path の要求を受けて callback のアドレスを渡し、閉じる。ほかの path（favicon など）と state の違う要求は 404 で受け流す")
    func receivesCallback() async throws {
        let redirect = redirect()
        var ready = false
        var received: [URL] = []
        let catcher = try #require(ConnectorCallbackCatcher(redirect: redirect, ready: { ready = true }, received: { received.append($0) }, failed: {}))
        defer { catcher.stop() }
        try await until { ready }
        #expect(ready)
        let address = redirect.address.absoluteString
        let other = try await get(redirect.address.deletingLastPathComponent().appending(path: "favicon.ico"))
        #expect(other.0 == 404 && received.isEmpty)
        let stale = try await get(URL(string: address + "?code=c0&state=s0")!)
        #expect(stale.0 == 404 && received.isEmpty)
        let page = try await get(URL(string: address + "?code=c1&state=s1")!)
        #expect(page.0 == 200 && page.1.contains("認証が終わりました"))
        #expect(received.map(\.absoluteString) == [address + "?code=c1&state=s1"])
        // 受けた後は閉じている（同じ port に 2 回目は届かない）
        await #expect(throws: (any Error).self) { _ = try await self.get(URL(string: address + "?code=c2&state=s1")!) }
        #expect(received.count == 1)
    }

    @Test("port が使われていれば ready を呼ばずに failed を呼ぶ（アドレスを貼る形に替える）")
    func failsWhenPortTaken() async throws {
        let redirect = redirect()
        var firstReady = false
        let first = try #require(ConnectorCallbackCatcher(redirect: redirect, ready: { firstReady = true }, received: { _ in }, failed: {}))
        defer { first.stop() }
        try await until { firstReady }
        var ready = false
        var failed = false
        let second = ConnectorCallbackCatcher(redirect: redirect, ready: { ready = true }, received: { _ in }, failed: { failed = true })
        defer { second?.stop() }
        try await until { failed }
        #expect(failed && !ready)
    }
}

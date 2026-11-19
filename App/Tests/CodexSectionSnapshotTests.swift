import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 設定の［接続先］の Codex の区画。fixtures `settings` のマシンに codex の値を入れて、Mac の設定の幅で描く
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct CodexSectionSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    nonisolated static let connectors = [
        CodexMachineInfo.Connector(name: "codex_apps", authStatus: "bearerToken", runtimeStatus: nil, toolCount: 100, toolsError: false),
        CodexMachineInfo.Connector(name: "context7", authStatus: "notLoggedIn", runtimeStatus: nil, toolCount: 2, toolsError: false),
        CodexMachineInfo.Connector(name: "linear", authStatus: "oAuth", runtimeStatus: nil, toolCount: 0, toolsError: true),
        CodexMachineInfo.Connector(name: "notion", authStatus: "oAuth", runtimeStatus: nil, toolCount: 12, toolsError: false),
    ]

    private func render(
        _ info: CodexMachineInfo, name: String, height: CGFloat, authorizing: [String: ConnectorAuthorization] = [:], testName: String = #function
    ) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await LaunchSnapshotTests.loadedModel("settings")
        let fleetID = try #require(model.orderedAllMachines.first?.id)
        model.fleet.setCodexMachine(info, for: LaunchSnapshotTests.machine(model))
        let view = Form { CodexSection(fleetID: fleetID, title: "Codex", authorizing: authorizing) }.formStyle(.grouped).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: height), variant: appearance), named: name, testName: testName)
    }

    @Test("アカウントとコネクタ（ツールの数、未ログイン、接続できません）", arguments: Matrix.cases([720]))
    func signedIn(name: String) async throws {
        try await render(
            CodexMachineInfo(
                connected: true, version: "0.162.1", account: .init(kind: "chatgpt", planType: "enterprise_cbp_usage_based"), models: [],
                connectors: Self.connectors),
            name: name, height: 400)
    }

    @Test("ほかの端末で戻り先を受けられず、開いたページのアドレスを貼る形", arguments: Matrix.cases([720]))
    func pasting(name: String) async throws {
        let page = try #require(URL(string: "http://127.0.0.1:47821/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A54173%2Fcallback%2Fx&state=s"))
        try await render(
            CodexMachineInfo(connected: true, account: .init(kind: "chatgpt", planType: "pro"), connectors: Self.connectors), name: name, height: 500,
            authorizing: ["context7": ConnectorAuthorization(page: page, wait: .paste, address: "http://example.com/", invalid: true)])
    }

    @Test("古い Codex（コネクタを読めない）", arguments: Matrix.cases([720]))
    func olderCodex(name: String) async throws {
        try await render(CodexMachineInfo(connected: true, version: "0.144.5", account: .init(kind: nil, planType: nil)), name: name, height: 220)
    }

    @Test("Codex に接続できない", arguments: Matrix.cases([720]))
    func disconnected(name: String) async throws {
        try await render(CodexMachineInfo(connected: false), name: name, height: 180)
    }
}

@Suite("Codex の区画の文")
struct CodexLabelsTests {
    @Test("アカウントの種類とプランを契約の名前で出す。プランの識別子は出さない")
    func account() {
        #expect(CodexLabels.account(.init(kind: "chatgpt", planType: "enterprise_cbp_usage_based")) == "ChatGPT Enterprise")
        #expect(CodexLabels.account(.init(kind: "chatgpt", planType: "prolite")) == "ChatGPT Pro")
        #expect(CodexLabels.account(.init(kind: "chatgpt", planType: "self_serve_business_usage_based")) == "ChatGPT Business")
        #expect(CodexLabels.account(.init(kind: "chatgpt", planType: "unknown")) == "ChatGPT")
        #expect(CodexLabels.account(.init(kind: "apiKey", planType: nil)) == "APIキー")
        #expect(CodexLabels.account(.init(kind: nil, planType: nil)) == "ログインしていません")
        #expect(CodexLabels.account(nil) == "")
    }

    @Test("コネクタの状態は Claude のコネクタの語に読み替える")
    func status() {
        let connectors = CodexSectionSnapshotTests.connectors
        #expect(connectors.map(CodexLabels.status) == ["connected", "connected", "failed", "connected"])
        #expect(connectors.map { CodexLabels.detail($0, status: CodexLabels.status($0)) } == ["ツール100個", "ツール2個・未ログイン", "接続できません", "ツール12個"])
        let starting = CodexMachineInfo.Connector(name: "x", authStatus: nil, runtimeStatus: "authenticationRequired", toolCount: 0, toolsError: false)
        #expect(CodexLabels.status(starting) == "needs-auth")
    }

    @Test("［認証を解除］は OAuth で認証済みのコネクタだけに出す。トークンの認証・未認証・認証待ちには出さない")
    func canLogout() {
        #expect(CodexSectionSnapshotTests.connectors.map(CodexLabels.canLogout) == [false, false, true, true])
        let expired = CodexMachineInfo.Connector(name: "x", authStatus: "oAuth", runtimeStatus: "authenticationRequired", toolCount: 0, toolsError: false)
        #expect(!CodexLabels.canLogout(expired))
    }
}

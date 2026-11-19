import Foundation
import Testing

@testable import TaskboardKit

@Suite("Wire JSON")
struct WireTests {
    @Test("DaemonEvent は event / data の形で往復する")
    func eventRoundTrip() throws {
        let events: [DaemonEvent] = [
            .machineUpdated(MachineInfo(id: MachineID(rawValue: "m1"), name: "studio", daemonVersion: "0.1.0")),
            .stateSnapshot(StateSnapshot(machine: MachineInfo(id: MachineID(rawValue: "m1"), name: "studio", daemonVersion: "0.1.0"), generatedAt: Date(timeIntervalSince1970: 1_791_000_000))),
        ]
        let encoder = WireJSON.encoder()
        let decoder = WireJSON.decoder()
        for event in events {
            let data = try encoder.encode(event)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["event"] as? String == event.name)
            #expect(object["data"] != nil)
            #expect(try decoder.decode(DaemonEvent.self, from: data) == event)
        }
    }

    @Test("知らない event 名は decode エラーになる")
    func unknownEventFails() {
        let data = Data(#"{"event":"session.exploded","data":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try WireJSON.decoder().decode(DaemonEvent.self, from: data)
        }
    }

    @Test("設定とオーケストレーターのイベントは往復し、MachineState に入る")
    func settingsAndOrchestratorEvents() throws {
        let info = OrchestratorInfo(
            enabled: true, lastError: "起動できない: timeout",
            lastReply: OrchestratorReply(text: "PR を 2 件見た", at: Date(timeIntervalSince1970: 1_791_000_000)))
        let events: [DaemonEvent] = [.settingsUpdated(MachineSettings(orchestrator: .init(enabled: false, agentArgs: []), idleStopMinutes: 30)), .orchestratorUpdated(info)]
        var state = MachineState()
        for event in events {
            #expect(try WireJSON.decoder().decode(DaemonEvent.self, from: WireJSON.encoder().encode(event)) == event)
            state.apply(event)
        }
        #expect(state.settings?.idleStopMinutes == 30)
        #expect(state.orchestrator == info)
    }

    @Test("区切る使用率を返さない前の daemon の設定は、既定の使用率で読む")
    func settingsWithoutUsagePause() throws {
        let json = #"{"orchestrator":{"enabled":true,"agentArgs":[]},"idleStopMinutes":60}"#
        let settings = try WireJSON.decoder().decode(MachineSettings.self, from: Data(json.utf8))
        #expect(settings.idleStopMinutes == 60)
        #expect(settings.usagePause == MachineSettings.UsagePause(fiveHourPercent: 90, sevenDayPercent: 99))
    }

    @Test("オーケストレーターの返事はお知らせに 1 行で出て、1 日を過ぎると消える")
    func orchestratorReplyInInbox() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        var state = MachineState(machine: MachineInfo(id: MachineID(rawValue: "m1"), name: "s", daemonVersion: "0"))
        state.orchestrator = OrchestratorInfo(enabled: true, lastReply: OrchestratorReply(text: "\nPR を 2 件見た\n\n#12 は CI 待ち\n3 行目", at: at))
        let items = state.inboxItems(now: at.addingTimeInterval(60))
        #expect(items.count == 1)
        #expect(items.first?.group == .notice)
        #expect(items.first?.title == "PR を 2 件見た")
        #expect(items.first?.detail == "オーケストレーター・#12 は CI 待ち")
        #expect(state.inboxItems(now: at.addingTimeInterval(25 * 3600)).isEmpty)
    }

    @Test("P6 までの daemon の orchestrator・taskSession・state も読める")
    func decodesOlderShapes() throws {
        let decoder = WireJSON.decoder()
        let info = try decoder.decode(OrchestratorInfo.self, from: Data(#"{}"#.utf8))
        #expect(info.enabled == false && info.lastReply == nil)
        let ref = try decoder.decode(TaskSessionRef.self, from: Data(#"{"id":1,"agent":"claude","sessionID":"s","cwd":"/x","label":"","linkedAt":"2026-10-01T00:00:00Z"}"#.utf8))
        #expect(ref.launchArgs == [])
        let snap = try decoder.decode(StateSnapshot.self, from: Data(#"{"machine":{"id":"m1","name":"s","herdrConnected":true,"daemonVersion":"0"},"sessions":[],"generatedAt":"2026-10-01T00:00:00Z"}"#.utf8))
        #expect(snap.settings == nil && snap.orchestrator == nil)
    }

    @Test("MachineState はイベントを順に畳み込む")
    func machineStateApply() {
        let m = MachineID(rawValue: "m1")
        var state = MachineState()
        state.apply(.stateSnapshot(StateSnapshot(machine: MachineInfo(id: m, name: "n", daemonVersion: "v"), generatedAt: Date())))
        #expect(state.machine?.name == "n")
        state.apply(.machineUpdated(MachineInfo(id: m, name: "renamed", daemonVersion: "v")))
        #expect(state.machine?.name == "renamed")
    }
}

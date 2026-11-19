import Foundation
import Testing

@testable import TaskboardKit

@Suite("概況の部品")
struct PanelKitTests {
    private let machine = MachineID(rawValue: "m-test")

    private func gauge(_ id: String, value: String = "4") -> PanelPartSpec {
        PanelPartSpec(id: id, content: .gauge(PanelGauge(label: "回答", value: value, basis: PanelBasis(kind: .denominator, value: "6", amount: 6))))
    }

    private func table(_ id: String, primary: Bool = false, columns: [String] = ["番号", "内容"], cells: [String] = ["D3", "表示名"]) -> PanelPartSpec {
        PanelPartSpec(id: id, content: .table(PanelTable(title: "判断事項", columns: columns, rows: [PanelRow(cells: cells)], primary: primary)))
    }

    private func html(_ markup: String) -> PanelPartSpec {
        PanelPartSpec(id: "free", content: .html(PanelHTML(html: markup)))
    }

    private func message(_ parts: [PanelPartSpec]) -> String? {
        do {
            _ = try PanelValidation.check(parts)
            return nil
        } catch let invalid as PanelInvalid {
            return invalid.message
        } catch {
            return "\(error)"
        }
    }

    @Test("会話が渡す JSON は kind と各型の欄が同じ階層で、読んで書き直しても同じ部品になる")
    func flatJSON() throws {
        let json = """
            [{"id": "answers", "kind": "gauge", "label": "梅田さんの回答", "value": "4", "basis": {"kind": "denominator", "value": "6", "amount": 6}, "amount": 4, "tone": "attention"},
             {"id": "plan", "kind": "plan", "groups": ["M3"]},
             {"id": "progress", "kind": "gauge", "label": "動作確認", "bind": {"source": "work", "group": "M3"}},
             {"id": "flow", "kind": "diagram", "style": "flow", "nodes": [{"label": "記録"}, {"label": "突き合わせ", "tone": "waiting"}]},
             {"id": "trend", "kind": "chart", "style": "line", "title": "一致", "series": [{"points": [{"x": "11/18", "y": 12}]}], "target": 20, "target_label": "全件"}]
            """
        let parts = try JSONDecoder().decode([PanelPartSpec].self, from: Data(json.utf8))
        guard case .gauge(let answers) = parts[0].content else { Issue.record("gauge でない"); return }
        #expect(answers.label == "梅田さんの回答" && answers.tone == .attention && answers.basis?.amount == 6 && answers.note.isEmpty)
        #expect(parts[1].bind == PanelBinding(source: .work), "plan は bind を省いても作業項目に紐づく")
        #expect(parts[2].bind == PanelBinding(source: .work, group: "M3"))
        guard case .chart(let chart) = parts[4].content else { Issue.record("chart でない"); return }
        #expect(chart.targetLabel == "全件" && chart.series[0].name.isEmpty)
        let again = try JSONDecoder().decode([PanelPartSpec].self, from: try JSONEncoder().encode(parts))
        #expect(again == parts)
    }

    @Test("予算を超えた登録は、どれを超えたかを書いた誤りになる")
    func budgets() {
        #expect(message((1...8).map { gauge("g\($0)") }) == nil)
        #expect(message((1...9).map { gauge("g\($0)") }) == "計器（gauge）は 8 個まで（9 個ある）。人が次に判断するのに使う値だけを残す")
        #expect(message([table("a", primary: true), table("b", primary: true), table("c", primary: true)]) == "主表（primary の table）は 2 個まで（3 個ある）")
        #expect(message([table("a", columns: ["1", "2", "3", "4", "5", "6"], cells: [])]) == "a: 列は 1〜5 個（6 個ある）")
        let long = String(repeating: "あ", count: 21)
        #expect(message([table("a", cells: ["D3", long])]) == "a: セルと列の見出しは 1 行で 20 字まで（「\(long)」）")
        #expect(message([table("a", cells: ["D3", String(repeating: "a", count: 20)])]) == nil, "20 字ちょうどは通る")
        #expect(message([gauge("x"), gauge("x")]) == "部品の id「x」が重複している")
        #expect(message([gauge("日本語")]) == "部品の id「日本語」は使えない。英数字と . _ - で 1〜40 字にする")
        #expect(message([gauge("g", value: "")]) == "g: value が空", "紐づけない計器は値が必要")
        #expect(message([PanelPartSpec(id: "g", content: .gauge(PanelGauge(label: "済み")), bind: PanelBinding(source: .work))]) == nil)
        let points = (0..<51).map { PanelPoint(x: "\($0)", y: Double($0)) }
        #expect(
            message([PanelPartSpec(id: "c", content: .chart(PanelChart(style: .bar, title: "件数", series: [PanelSeries(points: points)])))])
                == "c: 点は全部の系列で 50 個まで（51 個ある）")
        #expect(message((1...21).map { gauge("p\($0)") })?.hasPrefix("部品は 20 個まで") == true)
        #expect(message([PanelPartSpec(id: "d", content: .diagram(PanelDiagram(style: .flow, nodes: [])))]) == "d: nodes が空")
    }

    @Test("bind は計器・表・計画だけ、計画の bind は work だけ")
    func bindKinds() {
        #expect(
            message([PanelPartSpec(id: "h", content: .html(PanelHTML(html: "<p>a</p>")), bind: PanelBinding(source: .links))])
                == "h: bind は gauge・table・plan だけで使える（html に付いている）")
        #expect(message([PanelPartSpec(id: "p", content: .plan(PanelPlan()), bind: PanelBinding(source: .links))]) == "p: plan の bind の source は work だけ（links が渡された）")
    }

    @Test("自由の部品は script と外部の読み込みを断り、色と余白の直書きは受け付けて注意を返す。本文の #172 は色と読まない")
    func htmlChecks() throws {
        #expect(message([html("<p>a</p><script>alert(1)</script>")]) == "free: html に script とイベントの属性は使えない（「<script」）")
        #expect(message([html("<button onclick=\"x()\">押す</button>")])?.contains("イベントの属性") == true)
        #expect(message([html("<img src=\"https://example.com/a.png\">")])?.hasPrefix("free: html から外部の読み込みはできない") == true)
        #expect(message([html("<div style=\"background:url(//example.com/a.png)\"></div>")])?.hasPrefix("free: html から外部の読み込み") == true)
        #expect(message([html("<link rel=\"stylesheet\" href=\"x.css\">")])?.hasPrefix("free: html から外部の読み込み") == true)
        #expect(try PanelValidation.check([html("<a href=\"https://example.com\">PR</a>")]).isEmpty, "押して開くリンクは読み込みでない")

        let warnings = try PanelValidation.check([html("<p class=\"tb-muted\">#172 の 3 件</p><div style=\"color:#ff0000;padding:12px\">x</div>")])
        #expect(warnings == ["free: 色を直接書いている（#ff0000）。var(--tb-…) の色の変数か tb- のクラスに置き換える", "free: 余白を数値で直接書いている（padding:12px）。var(--tb-space-…) に置き換える"])
        #expect(try PanelValidation.check([html("<p>#172 と #fff の話</p><div style=\"color:var(--tb-text)\">x</div>")]).isEmpty)
    }

    private func item(_ id: Int64, _ group: String, _ state: WorkItem.State, code: String = "", position: Int) -> WorkItem {
        WorkItem(
            machine: machine, itemID: id, taskNumber: 1, title: "項目\(id)", state: state, blockerKind: state == .wait ? .approval : nil, group: group, code: code,
            position: position, source: "session", createdAt: .distantPast, updatedAt: .distantPast)
    }

    @Test("計画はまとまりを計画順に並べ、中は作業中・待ち・未着手・済みの順。最初の済んでいないまとまりが今のまとまり")
    func planGroups() {
        let items = [
            item(1, "M1", .done, position: 0), item(2, "M1", .done, position: 1),
            item(3, "M2", .done, code: "M2.1", position: 2), item(4, "M2", .todo, position: 3), item(5, "M2", .doing, position: 4),
            item(6, "M2", .wait, position: 5), item(7, "M2", .drop, position: 6), item(8, "M3", .todo, position: 7),
        ]
        let groups = WorkPlan.groups(items)
        #expect(groups.map(\.name) == ["M1", "M2", "M3"])
        #expect(groups.map(\.fractionLabel) == ["2 / 2", "1 / 4", "0 / 1"], "見送りは数えない")
        #expect(groups.map(\.isCurrent) == [false, true, false])
        #expect(groups[0].isFinished && !groups[1].isFinished)
        #expect(groups[1].items.map(\.itemID) == [5, 6, 4, 3, 7])
        #expect(WorkPlan.groups(items, only: ["M3", "M1", "X"]).map(\.name) == ["M3", "M1"])
        #expect(WorkPlan.groups([]).isEmpty)
        #expect(items[2].codedTitle == "M2.1 項目3" && items[3].codedTitle == "項目4")
    }

    @Test("まとまりと番号を持たない前の版の作業項目の JSON は空で読む")
    func oldWorkItemJSON() throws {
        let json = """
            {"machine": "m-test", "itemID": 3, "taskNumber": 1, "title": "古い", "state": "todo", "blockerText": "", "dependsOn": [], "deliverableRef": "",
             "owner": "", "position": 0, "source": "manual", "createdAt": 0, "updatedAt": 0}
            """
        let item = try JSONDecoder().decode(WorkItem.self, from: Data(json.utf8))
        #expect(item.group.isEmpty && item.code.isEmpty)
    }

    @Test("紐づけた計器と表は state の今の値で描く。作業項目が進めば値も進む")
    func resolveWork() {
        var state = MachineState(machine: MachineInfo(id: machine, name: "Mac mini", daemonVersion: "test"))
        let task = BoardTask(machine: machine, number: 1, boardID: "b", columnID: "working", title: "移行", createdAt: .distantPast, updatedAt: .distantPast)
        state.tasks[task.id] = task
        for value in [item(1, "M3", .done, code: "M3.1", position: 0), item(2, "M3", .doing, code: "M3.2", position: 1), item(3, "M4", .todo, position: 2)] {
            state.workItems[value.id] = value
        }
        let bound = PanelPartSpec(id: "g", content: .gauge(PanelGauge(label: "M3")), bind: PanelBinding(source: .work, group: "M3"))
        #expect(state.resolve(bound, task: task)?.gauge?.value == "1 / 2")
        #expect(state.resolve(bound, task: task)?.gauge?.basis?.amount == 2)
        let rows = state.resolve(PanelPartSpec(id: "t", content: .table(PanelTable(title: "項目")), bind: PanelBinding(source: .work)), task: task)?.rows
        #expect(rows?.map(\.cells) == [["M3.2", "項目2", "作業中"], ["M3.1", "項目1", "完了"], ["", "項目3", "着手できる"]])

        var next = state.workItems[WorkItemKey(machine: machine, id: 2)]!
        next.state = .done
        state.workItems[next.id] = next
        #expect(state.resolve(bound, task: task)?.gauge?.value == "2 / 2")
        #expect(state.resolve(bound, task: task)?.gauge?.tone == .done)
        #expect(state.resolve(gauge("plain"), task: task) == nil, "紐づけない部品は解決しない")
    }

    @Test("会話が 2 ターン以上更新していない部品だけが古い。紐づけた部品は古くならない")
    func staleness() {
        let fresh = PanelPart(spec: gauge("a"), updatedAt: .distantPast, updatedTurn: 4)
        let stale = PanelPart(spec: gauge("b"), updatedAt: .distantPast, updatedTurn: 3)
        let bound = PanelPart(spec: PanelPartSpec(id: "c", content: .plan(PanelPlan()), bind: PanelBinding(source: .work)), updatedAt: .distantPast, updatedTurn: 0)
        let panel = OverviewPanel(machine: machine, taskNumber: 1, parts: [fresh, stale, bound], turn: 5, updatedAt: .distantPast)
        #expect(panel.parts.map(panel.isStale) == [false, true, false])
    }

    @Test("fixtures の overview-panels は全部の種類の部品を持ち、予算と書式を守る（daemon が受け付ける登録と同じ）")
    func fixtureParts() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Fixtures/overview-panels.json")
        let snapshot = try WireJSON.decoder().decode(StateSnapshot.self, from: Data(contentsOf: url))
        let panel = try #require(snapshot.panels.first)
        #expect(Set(panel.parts.map(\.spec.content.kind)) == Set(PanelContent.Kind.allCases))
        #expect(try PanelValidation.check(panel.parts.map(\.spec)).isEmpty)
        var state = MachineState()
        state.apply(.stateSnapshot(snapshot))
        let task = try #require(state.tasks[panel.id])
        #expect(state.childTasks(of: task).map(\.number) == [215])
        #expect(WorkPlan.groups(state.workItems(forTask: task.number)).map(\.fractionLabel) == ["2 / 2", "1 / 4", "0 / 2"])
    }
}

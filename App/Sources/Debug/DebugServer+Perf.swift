#if DEBUG
import Foundation
import Network
import os
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// 計測
    func respondPerf(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("POST", "/perf/start"):
            // 画面の更新間隔を記録する。/perf/stop で集計を返す
            FrameMonitor.shared.start()
            return .json(200, ["ok": true])
        case ("POST", "/counters"):
            // {"reset": true} で数え直し、省くとそこまでの body の回数を返して数えるのを止める（DebugCounters。全案件の画面の帯が組まれたかを見る）
            if request.jsonBody?["reset"] as? Bool == true {
                DebugCounters.reset()
                return .json(200, ["ok": true])
            }
            return .json(200, DebugCounters.snapshot())
        case ("POST", "/busy/start"):
            // 主スレッドの run loop の 1 回ごとの長さを集める（100 ms に届かない長い回も見る）
            MainThreadBusy.shared.start()
            return .json(200, ["ok": true])
        case ("POST", "/busy/stop"):
            let lengths = MainThreadBusy.shared.stop().map { (($0.end - $0.start) * 10000).rounded() / 10 }
            return .json(200, ["spans": lengths.count, "longestMs": Array(lengths.sorted(by: >).prefix(10))])
        case ("POST", "/perf/stop"):
            return .json(200, FrameMonitor.shared.stop())
        case ("GET", "/cpu"):
            // 起動からの主スレッドの CPU 時間（ms）。操作の前後で引いた差を比べる（ほかのビルドで混んでいても、待たされた時間が入らない）
            return .json(200, ["ms": MainThreadCPU.milliseconds()])
        case ("POST", "/hitch/start"):
            // {"intervalMs": 10}。主スレッドの止まりを、本番の main.hitch と同じ見張り（MainThreadWatchdog、100 ms 超え）で数え始める。/hitch/stop で集計を返す。
            // 本番は 100 ms ごとに合図を送るので止まりを最大 100 ms 短く数える。ここは既定で 10 ms ごとに送る
            HitchMonitor.shared.start(interval: .milliseconds(request.jsonBody?["intervalMs"] as? Int ?? 10))
            return .json(200, ["ok": true])
        case ("POST", "/hitch/stop"):
            return .json(200, HitchMonitor.shared.stop())
        case ("POST", "/main/block"):
            // {"ms": 2000}。主スレッドをわざと止める（見張りの確かめ。止めている間はこの口も答えない）
            let ms = min(60_000, max(0, request.jsonBody?["ms"] as? Int ?? 2000))
            usleep(UInt32(ms) * 1000)
            return .json(200, ["blockedMs": ms])
        #if os(iOS)
        case ("GET", "/diagnostics"):
            // daemon へ送る止まりの記録の溜まり（送り終えた接続先の id つき）
            return .json(200, ["entries": model.diagnostics.outbox.entries.map { entry in
                ["id": entry.report.id, "kind": entry.report.kind.rawValue, "ms": entry.report.durationMS, "frames": entry.report.frames.count,
                 "sentTo": entry.sentTo.sorted()] as [String: Any]
            }])
        case ("POST", "/diagnostics/hang"):
            // {"durationMS": 3200, "callStackTree": {MXCallStackTree.jsonRepresentation() と同じ形}}。MetricKit の止まりの診断が届いたのと同じ経路で記録にして送る
            // （本物の診断はシミュレータでは届かない）
            guard let body = request.jsonBody, let ms = body["durationMS"] as? Int, let tree = body["callStackTree"],
                  let data = try? JSONSerialization.data(withJSONObject: tree)
            else { return .json(400, ["error": "durationMS と callStackTree"]) }
            let report = HangDiagnostics.report(
                HangDiagnostics.Values(durationMS: ms, end: Date(), appVersion: "build debug", osVersion: DiagnosticsReporter.osVersion, callStackTree: data),
                appBinary: Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Taskboard")
            model.recordDiagnostics([report])
            return .json(200, ["id": report.id, "frames": report.frames])
        #endif
        #if os(macOS)
        case ("POST", "/mouse/move"):
            // {"count": 600, "intervalMs": 8, "region": "list"}。マウスの移動の代わりに、mouseMoved を窓の中で動かしながら窓に渡す（本物のカーソルは動かさない）。
            // region が list なら会話の列（窓の中で中身が一番高い NSScrollView）、window なら窓の中身の全体を、横に往復しながら 24 pt ずつ下へなめる。主スレッドの使用時間を返す
            let body = request.jsonBody ?? [:]
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let content = window.contentView else {
                return .json(404, ["error": "窓が無い"])
            }
            let list = body["region"] as? String == "list" ? Self.allScrollViews(in: content).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) } : nil
            let area = (list.map { $0.convert($0.bounds, to: nil) } ?? content.convert(content.bounds, to: nil)).insetBy(dx: 4, dy: 4)
            let count = body["count"] as? Int ?? 600
            let gap = Duration.milliseconds(body["intervalMs"] as? Int ?? 8)
            let across = 40
            let rows = max(1, Int(area.height / 24))
            // 前面に出ていないアプリの窓は mouseMoved を受けない（列に入れても窓に渡しても、hit test も tracking area の更新も走らなかった）。
            // 人がカーソルを載せている窓と同じに、key にして mouseMoved を受けさせ、窓に直に渡す
            window.makeKey()
            window.acceptsMouseMovedEvents = true
            MainThreadBusy.shared.start()
            for index in 0..<count {
                let row = (index / across) % rows
                let step = index % across
                let x = area.minX + area.width * CGFloat(row.isMultiple(of: 2) ? step : across - 1 - step) / CGFloat(across - 1)
                let location = NSPoint(x: x, y: area.maxY - CGFloat(row) * 24)
                if let event = NSEvent.mouseEvent(
                    with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: gap)
            }
            return .json(200, [
                "events": count, "busy": MainThreadBusy.summary(MainThreadBusy.shared.stop()), "region": list != nil ? "list" : "window",
            ])
        #endif
        case ("POST", "/fixture/work"):
            // {"number": 301, "id": 1150, "state": "doing"}。fixtures の作業項目の状態を変えた知らせを流す（作業項目の欄の重さを測る。scripts/ui/work-perf.py）
            guard let body = request.jsonBody, let number = body["number"] as? Int, let id = body["id"] as? Int, let raw = body["state"] as? String,
                  let state = WorkItem.State(rawValue: raw), let machine = model.fleet.allBoards.first?.machine,
                  var item = model.fleet.workItems(for: TaskKey(machine: machine, number: number)).first(where: { $0.itemID == Int64(id) })
            else { return .json(400, ["error": "number・id・state"]) }
            item.state = state
            item.updatedAt = Date()
            FixtureInjection.shared.yield(.workUpdated(item), to: item.machine)
            return .json(200, ["ok": true])
        case ("POST", "/fixture/flow"):
            // {"seconds": 10, "perSecond": 2}。動いている daemon が送り続けるのと同じ種類の知らせを、fixtures の各マシンに順に流す。
            // 会話の様子（新しい順に 8 つを、動いている・空いているに交互に回す）を 4 回に 3 回、残りは終わっていないタスクの作業項目を更新した知らせ。
            // 測る口に触らないので /hitch と並べて送れる
            let body = request.jsonBody ?? [:]
            let seconds = body["seconds"] as? Double ?? 10
            let gap = Duration.milliseconds(Int(1000 / max(0.1, body["perSecond"] as? Double ?? 2)))
            let states = model.fleet.allMachines.values.filter { $0.machine != nil }.sorted { $0.machine!.id.rawValue < $1.machine!.id.rawValue }
            let conversations = states.map { Array($0.conversations.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(8)) }
            let work = states.map { state in
                Array(state.workItems.values.filter { item in
                    (item.state == .doing || item.state == .todo)
                        && state.tasks[TaskKey(machine: item.machine, number: item.taskNumber)].map { !state.isTerminal($0) } ?? false
                }.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
            }
            let deadline = ContinuousClock.now + .seconds(seconds)
            var sent = 0
            while ContinuousClock.now < deadline {
                let machine = sent % max(1, states.count)
                let turn = sent / max(1, states.count)
                if turn % 4 != 3, !conversations[machine].isEmpty {
                    var conversation = conversations[machine][turn % conversations[machine].count]
                    conversation.updatedAt = Date()
                    conversation.phase = turn.isMultiple(of: 2) ? .running : .idle
                    FixtureInjection.shared.yield(.conversationUpdated(conversation), to: conversation.machine)
                } else if !work[machine].isEmpty {
                    var item = work[machine][turn % work[machine].count]
                    item.updatedAt = Date()
                    FixtureInjection.shared.yield(.workUpdated(item), to: item.machine)
                }
                sent += 1
                try? await Task.sleep(for: gap)
            }
            return .json(200, ["events": sent])
        case ("POST", "/bench"):
            // {"kind": "task-switch" | "open-close" | "sidebar", "count": 20, "gapMs": 300, "numbers": [番号]?, "board": 案件の id?, "reveal": false}。
            // 操作をしてから、画面の更新が 2 回届くまで（変更を描いた次の更新）の時間を 1 回ずつ測る。同じ区間の主スレッドの CPU 時間を cpu に返す
            // （CPU を割り当てられずに待った時間を含まないので、ほかのビルドで混んでいても比べられる）。
            // task-switch はタスクを順に開く。open-close は開いて閉じ、開くと閉じるを別に返す。sidebar は「すべての案件」と各案件を順に選ぶ。
            // session は今の画面のまま、セッションの状態が変わった知らせを届ける。
            // numbers を省くと、案件（board を省くと最初の案件）の終わっていないタスクから count 件
            let body = request.jsonBody ?? [:]
            let boards = model.fleet.allBoards
            guard let board = (body["board"] as? String).map({ id in boards.first { $0.id == id } }) ?? boards.first,
                  let state = model.fleet.machineState(for: board.machine)
            else { return .json(404, ["error": "案件が無い"]) }
            let count = body["count"] as? Int ?? 20
            let numbers = body["numbers"] as? [Int]
                ?? Array(state.tasks.values.filter { $0.boardID == board.id && !state.isTerminal($0) }.map(\.number).sorted().prefix(count))
            let gap = Duration.milliseconds(body["gapMs"] as? Int ?? 300)
            let reveal = body["reveal"] as? Bool ?? false
            func measure(_ action: () -> Void) async -> (ms: Double, cpu: Double) {
                let started = CACurrentMediaTime()
                let used = MainThreadCPU.milliseconds()
                action()
                let drawn = await FrameMonitor.shared.frames(2)
                let cpu = MainThreadCPU.milliseconds() - used
                try? await Task.sleep(for: gap)
                return ((drawn - started) * 1000, cpu)
            }
            func summary(_ samples: [(ms: Double, cpu: Double)]) -> [String: Any] {
                FrameMonitor.summary(samples.map(\.ms)).merging(["cpu": FrameMonitor.summary(samples.map(\.cpu))]) { a, _ in a }
            }
            switch body["kind"] as? String ?? "task-switch" {
            case "task-switch":
                var samples: [(ms: Double, cpu: Double)] = []
                for number in numbers {
                    samples.append(await measure { model.navigate(to: .task(TaskKey(machine: board.machine, number: number), revealBoard: reveal), from: .debug) })
                }
                return .json(200, summary(samples))
            case "open-close":
                var opens: [(ms: Double, cpu: Double)] = []
                var closes: [(ms: Double, cpu: Double)] = []
                for number in numbers {
                    opens.append(await measure { model.navigate(to: .task(TaskKey(machine: board.machine, number: number), revealBoard: reveal), from: .debug) })
                    closes.append(await measure { model.closeTask() })
                }
                return .json(200, ["open": summary(opens), "close": summary(closes)])
            case "sidebar":
                let boards = model.orderedMachines.flatMap { model.orderedBoards($0.state, fleetID: $0.id) }
                let items = [SidebarItem.overview] + boards.map { SidebarItem.board(machine: $0.machine, id: $0.id) }
                var samples: [(ms: Double, cpu: Double)] = []
                var passes: [[String: Any]] = []
                for index in 0..<count {
                    let item = items[index % items.count]
                    MainThreadBusy.shared.start()
                    samples.append(await measure {
                        model.closeTask()
                        model.sidebar = item
                    })
                    // 行き先ごとの run loop の 1 回の最長（止まりの元のコマ）
                    let lengths = MainThreadBusy.shared.stop().map { ($0.end - $0.start) * 1000 }
                    let longest = lengths.indices.max { lengths[$0] < lengths[$1] }
                    passes.append([
                        "item": "\(item)", "longestPassMs": longest.map { (lengths[$0] * 10).rounded() / 10 } ?? 0, "longestAt": longest ?? -1,
                        "firstPassesMs": lengths.prefix(6).map { ($0 * 10).rounded() / 10 },
                    ])
                }
                return .json(200, summary(samples).merging(["passes": passes]) { a, _ in a })
            default:
                return .json(400, ["error": "kind は task-switch・open-close・sidebar のどれか"])
            }
        case ("POST", "/bench/conversation"):
            // {"messages": 1500, "chunk": 10, "streamSeconds": 5, "deltaMs": 50, "thinking": false}。開いている会話に、開いたときに daemon が控えを最初から流すのと同じ出来事を作り、
            // chunk 件ずつ間を置いて届ける。届け始めてから全部を描き終わるまで（replayMs）とその間の主スレッドの使用時間（replayBusy）、続けて生成中の差分を流す間の画面の更新間隔（stream）・主スレッドの使用時間（busy）・body の回数（bodies）・流した字数（chars）を返す
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            let body = request.jsonBody ?? [:]
            let count = body["messages"] as? Int ?? 1500
            let chunk = max(1, body["chunk"] as? Int ?? 10)
            let seconds = body["streamSeconds"] as? Double ?? 5
            let deltaGap = Duration.milliseconds(body["deltaMs"] as? Int ?? 50)
            let events = BenchConversation.events(conversation: feed.key.id, count: count, thinking: body["thinking"] as? Bool ?? false)
            let started = CACurrentMediaTime()
            MainThreadBusy.shared.start()
            feed.streamSubscribed(epoch: "bench-\(UUID().uuidString.prefix(8))", through: events.count)
            for (index, event) in events.enumerated() {
                feed.streamEvent(event)
                if index % chunk == chunk - 1 { try? await Task.sleep(for: .milliseconds(1)) }
            }
            let target = BenchConversation.messageIDs(count: count).last
            while !feed.messages.contains(where: { $0.id == target }) { _ = await FrameMonitor.shared.frames(1) }
            let replayMs = (await FrameMonitor.shared.frames(2) - started) * 1000
            let replayBusy = MainThreadBusy.summary(MainThreadBusy.shared.stop())
            FrameMonitor.shared.start()
            DebugCounters.reset()
            MainThreadBusy.shared.start()
            let streamed = seconds > 0 ? await BenchConversation.stream(into: feed, seconds: seconds, gap: deltaGap) : 0
            var stream = FrameMonitor.shared.stop()
            stream["busy"] = MainThreadBusy.summary(MainThreadBusy.shared.stop())
            stream["bodies"] = DebugCounters.snapshot()
            stream["chars"] = streamed
            return .json(200, ["replayMs": replayMs, "replayBusy": replayBusy, "messages": feed.messages.count, "stream": stream])
        case ("POST", "/bench/stream"):
            // {"seconds": 10, "deltaMs": 50}。開いている会話に生成中の返答の差分を流し、終わった発言で置き換える。測る口（FrameMonitor・MainThreadBusy）に触らないので、
            // /conversation/scroll・/mouse/move と並べて送れる
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            let body = request.jsonBody ?? [:]
            let chars = await BenchConversation.stream(into: feed, seconds: body["seconds"] as? Double ?? 10, gap: .milliseconds(body["deltaMs"] as? Int ?? 50))
            return .json(200, ["chars": chars, "messages": feed.messages.count])
        case ("POST", "/bench/thinking"):
            // {"holdMs": 3000}。開いている会話に思考を書いている block を出し、holdMs の後に終わった思考の発言（履歴の行）で置き換える
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            await BenchConversation.thinking(into: feed, holdMs: request.jsonBody?["holdMs"] as? Int ?? 3000)
            return .json(200, ["messages": feed.messages.count])
        case ("POST", "/bench/table"):
            // {"rows": 50, "columns": 6}。開いている会話に、大きな表を含むアシスタントの発言を 1 つ届け、描き終わるまでの ms と、会話の一覧の中の NSTextView の数を返す
            // （一覧の行を組む途中で NSTextView を作ると、フォーカスのある入力欄の入力メソッドと同期を取り、日本語入力の IMK の答えを待って止まった）
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            let body = request.jsonBody ?? [:]
            let rows = body["rows"] as? Int ?? 50
            let columns = body["columns"] as? Int ?? 6
            let header = "| " + (1...columns).map { "列 \($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: columns) + "\n"
            let lines = (1...rows).map { row in "| " + (1...columns).map { "行 \(row) の値 \($0 * row)" }.joined(separator: " | ") + " |" }
            let id = "bench-table-\(UUID().uuidString.prefix(8))"
            let started = CACurrentMediaTime()
            feed.streamEvent(ConversationEvent(
                seq: feed.resumePoint.after + 1, conversationID: feed.key.id, at: Date(),
                kind: .messages([ChatMessage(id: id, role: .assistant, kind: .text, text: "大きな表です。\n\n" + header + lines.joined(separator: "\n") + "\n")], apiMessageID: id)))
            while !feed.messages.contains(where: { $0.id == id }) { _ = await FrameMonitor.shared.frames(1) }
            let drawnMs = (await FrameMonitor.shared.frames(2) - started) * 1000
            #if os(macOS)
            let lists = NSApp.windows.compactMap(\.contentView).flatMap { Self.all(ChatListView.self, in: $0) }
            let textViews = lists.reduce(0) { $0 + Self.all(NSTextView.self, in: $1).count }
            #else
            let textViews = 0
            #endif
            return .json(200, ["drawnMs": drawnMs, "cells": rows * columns, "listTextViews": textViews])
        case ("POST", "/bench/message"):
            // {"text": "...", "role": "assistant"}。開いている会話に発言を 1 つ届ける（fixtures に無い Markdown の要素を画面で見るため）
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            let body = request.jsonBody ?? [:]
            let id = "bench-message-\(UUID().uuidString.prefix(8))"
            let role: ChatMessage.Role = body["role"] as? String == "user" ? .user : .assistant
            feed.streamEvent(ConversationEvent(
                seq: feed.resumePoint.after + 1, conversationID: feed.key.id, at: Date(),
                kind: .messages([ChatMessage(id: id, role: role, kind: .text, text: body["text"] as? String ?? "")], apiMessageID: id)))
            return .json(200, ["id": id])
        case ("POST", "/bench/older"):
            // {"messages": 200}。開いている会話の前に、古いページを読んだのと同じに人の発言を足す（「古いページ 0」が一番古い）
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            let count = request.jsonBody?["messages"] as? Int ?? 200
            let batch = UUID().uuidString.prefix(8)
            let messages = (0..<count).map { ChatMessage(id: "older-\(batch)-\($0)", role: .user, kind: .text, text: "古いページ \($0)") }
            feed.mergeOlderPage(ConversationHistoryResponse(messages: messages, nextCursor: "more", agentSessionID: feed.debugTimeline.agentSessionID ?? "bench"))
            return .json(200, ["messages": feed.messages.count])
        default:
            return nil
        }
    }
}
/// 計測用: 主スレッドの CPU 時間（user と system の和、ms）。主スレッドから呼ぶ
enum MainThreadCPU {
    @MainActor
    static func milliseconds() -> Double {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        func ms(_ time: time_value_t) -> Double { Double(time.seconds) * 1000 + Double(time.microseconds) / 1000 }
        return ms(info.user_time) + ms(info.system_time)
    }
}

/// 計測用: 主スレッドの止まり（100 ms 超え）を本番の main.hitch と同じ見張りで集める。見張っている間は App Nap を止める
/// （fixtures のアプリは前面に出さないので、止めないと裏のアプリとして主スレッドを遅らされ、人が使うときに無い止まりまで数える）
@MainActor
final class HitchMonitor {
    static let shared = HitchMonitor()
    private var watchdog: MainThreadWatchdog?
    private var activity: NSObjectProtocol?
    private let collected = OSAllocatedUnfairLock(initialState: [Int]())

    func start(interval: DispatchTimeInterval) {
        _ = stop()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "perf gate")
        let collected = collected
        // 長い止まりも sample を取らずに、戻ったときの長さだけを数える
        let watchdog = MainThreadWatchdog(
            directory: FileManager.default.temporaryDirectory, threshold: .seconds(3600), interval: interval, sample: nil,
            onHitch: { ms in collected.withLock { $0.append(ms) } }, onStall: { ms, _ in collected.withLock { $0.append(ms) } })
        watchdog.start()
        self.watchdog = watchdog
    }

    /// 止まりの数・最大・長い順の 20 個（ms）
    func stop() -> [String: Any] {
        watchdog?.stop()
        watchdog = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        let hitches = collected.withLock { values in
            defer { values = [] }
            return values
        }
        return ["count": hitches.count, "maxMs": hitches.max() ?? 0, "longestMs": Array(hitches.sorted(by: >).prefix(20))]
    }
}
#endif

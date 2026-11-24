import Foundation
import Observation
import TaskboardKit

/// markdown の文書のシェルのコードブロックの［実行］。タスクの lead の会話のシェルで動かし（`POST /v1/docs/{id}/runs`）、結果はその会話に送られる。
/// 塊はコードの本文で見分ける（新しい版を読み込み直しても、同じコードの結果を出し直す）
enum DocumentRuns {
    /// 欄の中身。`__tbRuns.set(payload)` で描き直す
    struct Payload: Encodable {
        struct Labels: Encodable {
            var run: String
            var runHelp: String
            var stop: String
            var noOutput: String
            var sent: String
        }

        struct Block: Encodable {
            var code: String
            var status: String
            var running: Bool
            var failed: Bool
            var text: String
            var notes: [String]
            var error: String?
        }

        var labels: Labels
        /// 押せないときの理由（書き込めない接続先）。nil なら押せる
        var blocked: String?
        var blocks: [Block]
    }

    static let labels = Payload.Labels(
        run: String(localized: "実行"), runHelp: String(localized: "タスクのセッションのシェルで実行"), stop: String(localized: "停止"),
        noOutput: String(localized: "（出力はありません）"), sent: String(localized: "結果をタスクのセッションに送信しました"))

    static var style: String {
        """
        .tb-run-bar{display:flex;gap:\(Int(Space.inline))px;align-items:center;justify-content:flex-end;margin:-.25em 0 .5em}
        .tb-run-bar .tb-hint{margin-right:auto;font-size:.86em;color:GrayText}
        .tb-run{border:1px solid rgba(127,127,127,.3);border-radius:\(Int(Radius.box))px;padding:\(Int(Space.inline))px \(Int(Space.row))px;margin:0 0 .75em}
        .tb-run-status{font-size:.86em;color:GrayText}
        .tb-run-status.tb-failed{color:#d70015} @media (prefers-color-scheme: dark){.tb-run-status.tb-failed{color:#ff6961}}
        .tb-run-out{margin:\(Int(Space.inline))px 0 0;max-height:20em;overflow:auto;font-size:.86em}
        .tb-run-note{font-size:.8em;color:GrayText;margin-top:\(Int(Space.inline))px}
        @media print{.tb-run-bar,.tb-run{display:none}}
        """
    }

    /// 欄の描画と操作の受け渡し。押すと `{type:'runCode', code, language}`・`{type:'cancelRun', code}` を送る
    static let script = """
        (function(){
        const langs = new Set(['bash','sh','shell','console','zsh','fish']);
        const R = window.__tbRuns = { payload: null, blocks: [] };
        function post(m){ if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tb) window.webkit.messageHandlers.tb.postMessage(m); }
        function collect(){
          document.querySelectorAll('pre > code[class*="language-"]').forEach(function(code){
            const pre = code.parentElement;
            if (pre.dataset.tbRun) return;
            const m = /(?:^|\\s)language-([^\\s]+)/.exec(code.className);
            const lang = m ? m[1].toLowerCase() : '';
            if (!langs.has(lang)) return;
            pre.dataset.tbRun = '1';
            const bar = document.createElement('div'); bar.className = 'tb-run-bar';
            const hint = document.createElement('span'); hint.className = 'tb-hint';
            const run = document.createElement('button'); run.className = 'tb-button';
            const stop = document.createElement('button'); stop.className = 'tb-button'; stop.hidden = true;
            bar.append(hint, stop, run);
            const box = document.createElement('div'); box.className = 'tb-run'; box.hidden = true;
            pre.after(bar, box);
            const block = { code: code.textContent.replace(/\\n$/, ''), lang: lang, hint: hint, run: run, stop: stop, box: box };
            run.addEventListener('click', function(){ post({ type: 'runCode', code: block.code, language: block.lang }); });
            stop.addEventListener('click', function(){ post({ type: 'cancelRun', code: block.code }); });
            R.blocks.push(block);
          });
        }
        function render(b, labels, blocked, state){
          b.run.textContent = '▷ ' + labels.run; b.run.title = labels.runHelp;
          b.stop.textContent = labels.stop;
          b.hint.textContent = blocked || '';
          b.run.disabled = !!blocked || !!(state && state.running);
          b.stop.hidden = !(state && state.running);
          if (!state) { b.box.hidden = true; return; }
          b.box.hidden = false;
          const follow = !b.out || b.out.scrollTop + b.out.clientHeight >= b.out.scrollHeight - 4;
          b.box.replaceChildren();
          const status = document.createElement('div'); status.className = 'tb-run-status' + (state.failed ? ' tb-failed' : '');
          status.textContent = state.status;
          b.box.append(status);
          b.out = null;
          if (state.text) {
            const out = document.createElement('pre'); out.className = 'tb-run-out'; out.textContent = state.text;
            b.box.append(out); b.out = out;
          } else if (!state.running && !state.error) {
            const none = document.createElement('div'); none.className = 'tb-run-note'; none.textContent = labels.noOutput; b.box.append(none);
          }
          const notes = state.error ? [state.error] : state.notes.concat(state.running ? [] : [labels.sent]);
          notes.forEach(function(text){
            const note = document.createElement('div'); note.className = state.error ? 'tb-error' : 'tb-run-note'; note.textContent = text; b.box.append(note);
          });
          if (b.out && follow) b.out.scrollTop = b.out.scrollHeight;
        }
        R.set = function(p){
          R.payload = p; collect();
          const states = {}; p.blocks.forEach(function(s){ states[s.code] = s; });
          R.blocks.forEach(function(b){ render(b, p.labels, p.blocked, states[b.code]); });
        };
        })();
        """
}

/// 本文の欄でした操作（`DocumentRuns.script` の `postMessage`）
enum DocumentRunAction: Equatable {
    case run(code: String, language: String)
    case cancel(code: String)

    init?(message body: [String: Any]) {
        switch body["type"] as? String {
        case "runCode":
            guard let code = body["code"] as? String, let language = body["language"] as? String else { return nil }
            self = .run(code: code, language: language)
        case "cancelRun":
            guard let code = body["code"] as? String else { return nil }
            self = .cancel(code: code)
        default:
            return nil
        }
    }
}

/// 文書の画面の Run。始めて、動いている間は取り直して欄に返す（文書の画面は会話の出来事を購読していない）
@MainActor
@Observable
final class DocumentRunner {
    private struct Entry {
        var conversationID: String?
        var runID: String?
        var run: ConversationRun?
        var error: String?
        var poll: Task<Void, Never>?
    }

    /// コードの本文 → その塊で最後に始めた Run
    private var entries: [String: Entry] = [:]
    private(set) var payloadJSON = ""
    private var blocked: String?
    static let pollInterval: Duration = .milliseconds(400)

    func setBlocked(_ text: String?) {
        blocked = text
        publish()
    }

    func handle(_ action: DocumentRunAction, doc: DocKey, model: AppModel) {
        switch action {
        case .run(let code, let language):
            guard entries[code]?.run?.status != .running else { return }
            entries[code]?.poll?.cancel()
            entries[code] = Entry()
            publish()
            Task {
                do {
                    let run = try await model.requireSource(doc.machine).startDocRun(doc: doc.id, ConversationRunRequest(code: code, language: language))
                    entries[code] = Entry(conversationID: run.conversationID, runID: run.id, run: run)
                    publish()
                    poll(code, machine: doc.machine, model: model)
                } catch {
                    entries[code] = Entry(error: UserFacingError("実行できませんでした", error: error)?.text)
                    publish()
                }
            }
        case .cancel(let code):
            guard let entry = entries[code], let conversationID = entry.conversationID, let runID = entry.runID else { return }
            Task {
                do {
                    try await model.requireSource(doc.machine).cancelConversationRun(conversationID, run: runID)
                } catch {
                    entries[code]?.error = UserFacingError("停止できませんでした", error: error)?.text
                    publish()
                }
            }
        }
    }

    /// 画面を閉じた：取り直しをやめる（Run は daemon で動き続け、結果は会話に送られる）
    func stop() {
        for key in entries.keys {
            entries[key]?.poll?.cancel()
            entries[key]?.poll = nil
        }
    }

    /// 画面に戻った：動いていた Run の取り直しを始め直す
    func resume(machine: MachineID, model: AppModel) {
        for (code, entry) in entries where entry.run?.status == .running && entry.poll == nil { poll(code, machine: machine, model: model) }
    }

    private func poll(_ code: String, machine: MachineID, model: AppModel) {
        entries[code]?.poll = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
                guard let entry = entries[code], let conversationID = entry.conversationID, let runID = entry.runID else { return }
                do {
                    let run = try await model.requireSource(machine).conversationRun(conversationID, run: runID)
                    guard entries[code]?.runID == runID else { return }
                    entries[code]?.run = run
                    publish()
                    if run.status != .running { return }
                } catch {
                    entries[code]?.error = UserFacingError("実行の結果を取得できませんでした", error: error)?.text
                    publish()
                    return
                }
            }
        }
    }

    private func publish() {
        let blocks = entries.map { code, entry -> DocumentRuns.Payload.Block in
            guard let run = entry.run else {
                let status = entry.error == nil ? RunStatusText.label(.running, exitCode: nil) : RunStatusText.failedToStart
                return .init(code: code, status: status, running: entry.error == nil, failed: entry.error != nil, text: "", notes: [], error: entry.error)
            }
            var notes: [String] = []
            if run.newShell == true { notes.append(String(localized: "新しいシェルで実行しました。前の実行の変数と作業フォルダは引き継いでいません。")) }
            if run.truncated { notes.append(String(localized: "先頭の1MBだけを表示しています。")) }
            return .init(
                code: code, status: RunStatusText.label(run.status, exitCode: run.exitCode), running: run.status == .running,
                failed: [.failed, .timedOut].contains(run.status), text: run.output + (run.tail ?? ""), notes: notes, error: entry.error)
        }
        let payload = DocumentRuns.Payload(labels: DocumentRuns.labels, blocked: blocked, blocks: blocks)
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else { return }
        payloadJSON = json
    }
}

/// Run の状態の文（チャットのコードの塊の下の欄と文書の欄で同じもの）
enum RunStatusText {
    static func label(_ status: ConversationRun.Status, exitCode: Int32?) -> String {
        switch status {
        case .running: String(localized: "実行中…")
        case .succeeded: String(localized: "完了")
        case .failed: exitCode.map { String(localized: "失敗（終了コード\($0)）") } ?? String(localized: "失敗")
        case .cancelled: String(localized: "停止済み")
        case .timedOut: String(localized: "10分を超えたため停止しました")
        }
    }

    static let failedToStart = String(localized: "失敗")
}

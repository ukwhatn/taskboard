#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// 文書・質問・コメント・レビュー・PR
    func respondDocuments(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("POST", "/doc/open"):
            guard let body = request.jsonBody, let id = body["id"] as? Int else { return .json(400, ["error": "id が要る"]) }
            guard let task = taskFor(body, model) else { return .json(404, ["error": "タスクが無い"]) }
            let key = DocKey(machine: task.machine, id: Int64(id))
            guard model.fleet.document(for: key) != nil else { return .json(404, ["error": "文書が無い"]) }
            model.navigate(to: .doc(key), from: .debug)
            return .json(200, ["ok": true])
        case ("GET", "/doc/text"):
            guard let web = DocumentWebController.current else { return .json(404, ["error": "文書が開いていない"]) }
            return .json(200, await web.debugProbe())
        case ("POST", "/doc/screenshot"):
            guard let web = DocumentWebController.current, let png = await web.debugSnapshot() else { return .json(404, ["error": "文書が開いていない"]) }
            return HTTPResponse(status: 200, contentType: "image/png", body: png)
        case ("POST", "/doc/select"):
            // {"text": "..."}。本文の最初の一致を選ぶ（作ったドラッグは WKWebView の選択にならない）。選んだ所の枠も返す
            guard let text = request.jsonBody?["text"] as? String else { return .json(400, ["error": "text が要る"]) }
            guard let web = DocumentWebController.current else { return .json(404, ["error": "文書が開いていない"]) }
            let found = await web.debugSelect(text)
            try? await Task.sleep(for: .milliseconds(300))
            return .json(200, ["found": found, "rect": web.selectionRect.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] } as Any])
        case ("POST", "/doc/js"):
            // {"script": "..."}。本文の欄を押す（欄の中の操作は MessageProxy を通る本物の経路）。結果は文字にして返す
            guard let script = request.jsonBody?["script"] as? String else { return .json(400, ["error": "script が要る"]) }
            guard let web = DocumentWebController.current else { return .json(404, ["error": "文書が開いていない"]) }
            let result = await web.debugEvaluate(script)
            return .json(200, ["result": result.map { "\($0)" } as Any, "pendingInput": web.formsPendingInput])
        case ("POST", "/doc/close"):
            model.closeDoc()
            return .json(200, ["ok": true])
        case ("POST", "/ask/answer"):
            // AskForm の「回答を送る」と同じ経路
            guard let body = request.jsonBody, let askID = body["askID"] as? Int, let raw = body["answers"] as? [[String: Any]] else {
                return .json(400, ["error": "askID と answers が要る"])
            }
            guard let ask = model.fleet.machines.values.lazy.flatMap(\.asks.values).first(where: { $0.askID == Int64(askID) }) else {
                return .json(404, ["error": "質問が無い"])
            }
            let answers = raw.compactMap { a -> AskAnswer? in
                guard let q = a["questionID"] as? String else { return nil }
                return AskAnswer(questionID: q, selected: a["selected"] as? [String] ?? [], freeText: a["freeText"] as? String)
            }
            do {
                try await model.answer(ask, answers)
                return .json(200, ["ok": true])
            } catch {
                return .json(500, ["error": "\(error)"])
            }
        case ("POST", "/comment"):
            guard let body = request.jsonBody, let docID = body["docID"] as? Int, let text = body["body"] as? String else {
                return .json(400, ["error": "docID と body が要る"])
            }
            guard let doc = model.fleet.machines.values.lazy.flatMap(\.documents.values).first(where: { $0.docID == Int64(docID) }) else {
                return .json(404, ["error": "文書が無い"])
            }
            let anchor = (body["quote"] as? String).map { CommentAnchor(exact: $0) }
            do {
                let comment = try await model.addComment(doc.id, rev: doc.latestRev, anchor: anchor, body: text)
                return .json(200, ["ok": true, "id": comment.id, "state": comment.state.rawValue])
            } catch {
                return .json(500, ["error": "\(error)"])
            }
        case ("POST", "/review/submit"):
            guard let body = request.jsonBody, let task = taskFor(body, model) else { return .json(404, ["error": "タスクが無い"]) }
            do {
                try await model.submitReview(task: task.id, summary: body["summary"] as? String ?? "")
                return .json(200, ["ok": true])
            } catch {
                return .json(500, ["error": "\(error)"])
            }
        case ("GET", "/prs"):
            return .json(200, [
                "selected": model.selectedPR as Any,
                "items": model.fleet.allPullRequests.map {
                    ["url": $0.url, "label": $0.shortLabel, "account": "\($0.account)@\($0.host)", "category": $0.category.rawValue, "checks": $0.checks?.rawValue as Any, "review": $0.reviewDecision as Any, "machine": $0.machine.rawValue]
                },
                "accounts": model.fleet.machines.values.flatMap { state in
                    (state.prs?.accounts ?? []).map { ["machine": state.machine?.name as Any, "account": $0.id, "fetchedAt": $0.fetchedAt.map { ISO8601DateFormatter().string(from: $0) } as Any, "error": $0.error as Any] }
                },
            ])
        case ("POST", "/prs/open"):
            // 通知の PR を押したのと同じ（結んだタスクの PR の欄、無ければタスクなしの画面）
            guard let url = request.jsonBody?["url"] as? String else { return .json(400, ["error": "url が要る"]) }
            model.navigate(to: .pullRequest(url: url), from: .debug)
            return .json(200, ["ok": true])
        case ("POST", "/prs/refresh"):
            await model.refreshPullRequests()
            return .json(200, ["ok": true, "count": model.fleet.allPullRequests.count])
        case ("GET", "/prs/detail"):
            guard let url = request.query["url"] else { return .json(400, ["error": "url が要る"]) }
            do {
                let detail = try await model.pullRequestDetail(url: url)
                return .json(200, ["label": detail.shortLabel, "state": detail.state, "checks": detail.checks.count, "files": detail.files.count, "reviews": detail.reviews.count, "bodyLength": detail.body.count])
            } catch {
                return .json(502, ["error": "\(error)"])
            }
        default:
            return nil
        }
    }
}
#endif

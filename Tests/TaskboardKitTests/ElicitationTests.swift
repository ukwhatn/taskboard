import Foundation
import Testing

@testable import TaskboardKit

@Suite("MCP の server からの問い")
struct ElicitationTests {
    private func form(_ json: String) -> Elicitation.Form { Elicitation.Form(schema: Data(json.utf8)) }

    private func formQuestion(_ json: String) -> Elicitation {
        Elicitation(serverName: "github", message: "入れてください", mode: .form, form: form(json))
    }

    /// MCP の仕様の例（連絡先）に、整数・真偽・2 つの書き方の選択と format を足したもの
    private let contact = """
        {"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema",
         "properties":{
          "name":{"type":"string","title":"名前","minLength":1,"maxLength":5},
          "email":{"type":"string","format":"email"},
          "age":{"type":"integer","minimum":18,"maximum":120,"default":30},
          "ratio":{"type":"number","minimum":0,"maximum":1},
          "agree":{"type":"boolean","default":false},
          "color":{"type":"string","enum":["red","green"],"enumNames":["赤","緑"],"default":"red"},
          "size":{"type":"string","oneOf":[{"const":"s","title":"小"},{"const":"l","title":"大"}]},
          "site":{"type":"string","format":"uri"},
          "day":{"type":"string","format":"date"},
          "at":{"type":"string","format":"date-time"}
         },
         "required":["name","email"]}
        """

    @Test("仕様の範囲の form を、書いた順の欄にする（文字・数・整数・真偽・2 つの書き方の選択、format・長さ・範囲・既定・必須）")
    func parsesSupportedFields() throws {
        let parsed = form(contact)
        #expect(!parsed.unsupported)
        #expect(parsed.fields.map(\.key) == ["name", "email", "age", "ratio", "agree", "color", "size", "site", "day", "at"])
        let name = try #require(parsed.fields.first)
        #expect(name.kind == .text && name.title == "名前" && name.minLength == 1 && name.maxLength == 5 && name.required)
        #expect(parsed.fields[1].format == .email && parsed.fields[1].required)
        #expect(parsed.fields[2].kind == .integer && parsed.fields[2].minimum == 18 && parsed.fields[2].defaultValue == .number(30))
        #expect(parsed.fields[3].kind == .number && !parsed.fields[3].required)
        #expect(parsed.fields[4].kind == .boolean && parsed.fields[4].defaultValue == .bool(false))
        #expect(parsed.fields[5].options == [.init(value: "red", title: "赤"), .init(value: "green", title: "緑")])
        #expect(parsed.fields[6].options == [.init(value: "s", title: "小"), .init(value: "l", title: "大")])
        #expect(parsed.fields[9].format == .dateTime)
    }

    @Test(
        "仕様の範囲の外は、入力欄にできない印にする",
        arguments: [
            // 入れ子の object
            #"{"type":"object","properties":{"a":{"type":"object","properties":{}}}}"#,
            // 多く選ぶ選択（配列）
            #"{"type":"object","properties":{"a":{"type":"array","items":{"type":"string","enum":["x"]}}}}"#,
            // 知らない制約（pattern）
            #"{"type":"object","properties":{"a":{"type":"string","pattern":"^x$"}}}"#,
            // 知らない format
            #"{"type":"object","properties":{"a":{"type":"string","format":"ipv4"}}}"#,
            // 文字でない選択肢
            #"{"type":"object","properties":{"a":{"type":"string","enum":[1,2]}}}"#,
            // 選択肢に無い既定
            #"{"type":"object","properties":{"a":{"type":"string","enum":["x"],"default":"y"}}}"#,
            // 型の違う既定
            #"{"type":"object","properties":{"a":{"type":"boolean","default":"yes"}}}"#,
            // 真偽を数の範囲に使う
            #"{"type":"object","properties":{"a":{"type":"number","minimum":true}}}"#,
            // 欄に無い必須
            #"{"type":"object","properties":{"a":{"type":"string"}},"required":["b"]}"#,
            // 上の段の知らない鍵
            #"{"type":"object","properties":{},"additionalProperties":{"type":"string"}}"#,
            // object でない
            #"{"type":"string"}"#,
            // JSON でない
            #"{"type":"object","#,
        ])
    func marksUnsupported(_ json: String) {
        #expect(form(json) == .unsupportedForm)
    }

    @Test("上限：欄 20・選択肢 100・schema 64KB を超えたら入力欄にしない")
    func enforcesLimits() {
        func fields(_ count: Int) -> String {
            "{\"type\":\"object\",\"properties\":{" + (0..<count).map { "\"f\($0)\":{\"type\":\"boolean\"}" }.joined(separator: ",") + "}}"
        }
        #expect(!form(fields(20)).unsupported)
        #expect(form(fields(21)).unsupported)
        func options(_ count: Int) -> String {
            "{\"type\":\"object\",\"properties\":{\"c\":{\"type\":\"string\",\"enum\":[" + (0..<count).map { "\"o\($0)\"" }.joined(separator: ",") + "]}}}"
        }
        #expect(!form(options(100)).unsupported)
        #expect(form(options(101)).unsupported)
        let padding = String(repeating: "あ", count: 22_000)
        #expect(form("{\"type\":\"object\",\"description\":\"\(padding)\",\"properties\":{}}").unsupported, "64KB を超える")
        #expect(!form("{\"type\":\"object\",\"description\":\"\(padding.prefix(21_000))\",\"properties\":{}}").unsupported)
    }

    @Test("答えを確かめる：必須・知らない欄・型・長さ・範囲・format・選択肢の外を断る")
    func checksAnswers() throws {
        let question = formQuestion(contact)
        let base: [String: ElicitationValue] = ["name": .string("山田"), "email": .string("a@example.com")]
        #expect(throws: Never.self) { try question.check(.accept, content: base) }
        #expect(throws: Never.self) {
            try question.check(
                .accept,
                content: base.merging(
                    [
                        "age": .number(42), "ratio": .number(0.5), "agree": .bool(true), "color": .string("green"), "size": .string("l"),
                        "site": .string("https://example.com/x"), "day": .string("2026-02-28"), "at": .string("2026-10-20T07:00:00+09:00"),
                    ], uniquingKeysWith: { $1 }))
        }
        func rejects(_ extra: [String: ElicitationValue], dropping: String? = nil) -> ElicitationAnswerError? {
            var content = base.merging(extra, uniquingKeysWith: { $1 })
            if let dropping { content[dropping] = nil }
            do {
                try question.check(.accept, content: content)
                return nil
            } catch {
                return error
            }
        }
        #expect(rejects([:], dropping: "email") == .missing("email"))
        #expect(rejects(["extra": .string("x")]) == .unknownField("extra"))
        #expect(rejects(["age": .string("42")]) == .wrongType("age"))
        #expect(rejects(["age": .number(42.5)]) == .wrongType("age"), "整数の欄に小数")
        #expect(rejects(["age": .number(17)]) == .outOfRange("age"))
        #expect(rejects(["ratio": .number(1.01)]) == .outOfRange("ratio"))
        #expect(rejects(["agree": .string("true")]) == .wrongType("agree"))
        #expect(rejects(["name": .string("")]) == .outOfRange("name"), "minLength")
        #expect(rejects(["name": .string("山田太郎です")]) == .outOfRange("name"), "maxLength は文字数（6 字）で数える")
        #expect(rejects(["name": .string("🙂🙂🙂")]) == nil, "絵文字も 1 字")
        #expect(rejects(["email": .string("a@b")]) == .badFormat("email"))
        #expect(rejects(["email": .string("a b@example.com")]) == .badFormat("email"))
        #expect(rejects(["site": .string("example.com")]) == .badFormat("site"))
        #expect(rejects(["day": .string("2026-02-30")]) == .badFormat("day"), "暦に無い日")
        #expect(rejects(["at": .string("2026-10-20 07:00")]) == .badFormat("at"))
        #expect(rejects(["color": .string("赤")]) == .notAnOption("color"), "出す名前でなく値で答える")
        #expect(rejects(["size": .string("m")]) == .notAnOption("size"))
    }

    @Test("答えの文字は 10KB まで（maxLength が無くても）")
    func capsText() throws {
        let question = formQuestion(#"{"type":"object","properties":{"note":{"type":"string"}}}"#)
        #expect(throws: Never.self) { try question.check(.accept, content: ["note": .string(String(repeating: "a", count: 10 * 1024))]) }
        #expect(throws: ElicitationAnswerError.outOfRange("note")) {
            try question.check(.accept, content: ["note": .string(String(repeating: "あ", count: 3500))])
        }
    }

    @Test("受ける答え：断る・取り消すは中身を持たない。入力欄にできない form・開けない url・知らない形は断る・取り消すだけ")
    func allowedActions() throws {
        let question = formQuestion(contact)
        #expect(question.allowedActions == [.accept, .decline, .cancel])
        #expect(throws: Never.self) { try question.check(.decline, content: nil) }
        #expect(throws: ElicitationAnswerError.contentNotAllowed) { try question.check(.cancel, content: ["name": .string("x")]) }

        let unsupported = formQuestion(#"{"type":"object","properties":{"a":{"type":"array"}}}"#)
        #expect(unsupported.allowedActions == [.decline, .cancel])
        #expect(throws: ElicitationAnswerError.actionNotAllowed) { try unsupported.check(.accept, content: [:]) }

        let url = Elicitation(serverName: "linear", message: "認証してください", mode: .url, link: .init(scheme: "https", host: "example.com"), elicitationID: "e1")
        #expect(url.allowedActions == [.accept, .decline, .cancel])
        #expect(throws: Never.self) { try url.check(.accept, content: nil) }
        #expect(throws: ElicitationAnswerError.contentNotAllowed) { try url.check(.accept, content: [:]) }
        var unopenable = url
        unopenable.link = nil
        #expect(unopenable.allowedActions == [.decline, .cancel])

        let unknown = try WireJSON.decoder().decode(Elicitation.self, from: Data(#"{"serverName":"x","message":"m","mode":"openai/form"}"#.utf8))
        #expect(unknown.mode == .unknown && unknown.allowedActions == [.decline, .cancel])
    }

    @Test("engine の行から、道をたどった値を書いたままの文で取り出す（欄の順が残る）")
    func rawValueAtPath() throws {
        let line = Data(#"{"type":"control_request","request":{"subtype":"elicitation","requested_schema":{"type":"object","properties":{"z":{"type":"boolean"},"a":{"type":"string","title":"「}」と\"引用\""}}},"x":[1,{"y":2}]}}"#.utf8)
        let raw = try #require(JSONKeyOrder.value(at: ["request", "requested_schema"], in: line))
        #expect(Elicitation.Form(schema: raw).fields.map(\.key) == ["z", "a"])
        #expect(Elicitation.Form(schema: raw).fields.last?.title == "「}」と\"引用\"")
        #expect(JSONKeyOrder.value(at: ["request", "missing"], in: line) == nil)
        #expect(JSONKeyOrder.value(at: ["type", "x"], in: line) == nil)
        #expect(JSONKeyOrder.value(at: ["request"], in: Data("{".utf8)) == nil)
    }

    @Test("問いと答えは往復し、古い答え（action の無いもの）も読める。知らない欄の種類と format は unknown")
    func wireRoundTrip() throws {
        let request = ConversationRequest(
            id: "r1", kind: .elicitation, toolName: "elicitation", toolUseID: nil, waiting: RequestWaiting(id: "r1", since: Date(timeIntervalSince1970: 0)),
            elicitation: formQuestion(contact))
        let decoded = try WireJSON.decoder().decode(ConversationRequest.self, from: WireJSON.encoder().encode(request))
        #expect(decoded == request)
        let answer = ConversationAnswerRequest(requestID: "r1", action: .accept, content: ["age": .number(30), "agree": .bool(true), "name": .string("x")])
        #expect(try WireJSON.decoder().decode(ConversationAnswerRequest.self, from: WireJSON.encoder().encode(answer)) == answer)
        let old = try WireJSON.decoder().decode(ConversationAnswerRequest.self, from: Data(#"{"requestID":"r1","allow":true}"#.utf8))
        #expect(old.action == nil && old.content == nil && old.allow == true)
        let field = try WireJSON.decoder().decode(Elicitation.Field.self, from: Data(#"{"key":"a","kind":"slider","required":false,"format":"ipv6"}"#.utf8))
        #expect(field.kind == .unknown && field.format == .unknown)
    }

    @Test("MCP・CLI に出す回答待ちの文：form は欄ごと、url は scheme・host・port だけ（URL の全文は出さない）")
    func lines() throws {
        let waiting = RequestWaiting(id: "r1", since: Date(timeIntervalSince1970: 0))
        let formRequest = ConversationRequest(id: "r1", kind: .elicitation, toolName: "elicitation", toolUseID: nil, waiting: waiting, elicitation: formQuestion(contact))
        #expect(formRequest.lines.first == "回答待ち r1: MCP の確認（github）「入れてください」")
        #expect(formRequest.lines.contains("  - name「名前」 text（必須） 長さ 1〜5"))
        #expect(formRequest.lines.contains("  - color choice 選択肢: red / green"))
        let link = try #require(OAuthLinks.openable("https://Auth.Example.com:8443/cb?token=secret").flatMap(Elicitation.Link.init(openable:)))
        #expect(link == .init(scheme: "https", host: "auth.example.com", port: 8443))
        let url = Elicitation(serverName: "linear", message: "認証", mode: .url, link: link, elicitationID: "e1")
        let urlRequest = ConversationRequest(id: "r2", kind: .elicitation, toolName: "elicitation", toolUseID: nil, waiting: waiting, elicitation: url)
        #expect(urlRequest.lines.contains("  開く先: https://auth.example.com:8443（アプリで開く）"))
        #expect(try !String(decoding: WireJSON.encoder().encode(urlRequest), as: UTF8.self).contains("secret"), "回答待ちの型は URL の全文を持たない")
    }
}

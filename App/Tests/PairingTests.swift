import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

@Suite struct PairingFormTests {
    @Test("P7 までに Keychain に保存した接続先（pairedDeviceID が無い JSON）も読める")
    func oldSavedConnection() throws {
        let json = #"{"id":"6C0B8A5E-4B9A-4C35-9F1E-1A2B3C4D5E6F","name":"Mac Studio","url":"https:\/\/studio.example.com","token":"t","access":{"clientID":"a","clientSecret":"b"}}"#
        let connection = try JSONDecoder().decode(SavedConnection.self, from: Data(json.utf8))
        #expect(connection.name == "Mac Studio")
        #expect(connection.pairedDeviceID == nil)
        #expect(connection.access?.clientID == "a")
    }

    @Test("ペアリングした接続先は、token を変えない編集では端末のまま、token を入れ直すと daemon の token の接続先になる")
    func editPairedConnection() throws {
        let paired = SavedConnection(
            id: UUID(), name: "Mac Studio", url: URL(string: "https://studio.example.com")!, token: "device", access: nil, pairedDeviceID: "dev-1")
        var draft = ConnectionDraft(paired)
        draft.name = "Studio"
        let renamed = try draft.build().get()
        #expect(renamed.pairedDeviceID == "dev-1")
        #expect(renamed.token == "device")
        draft.token = "daemon"
        let replaced = try draft.build().get()
        #expect(replaced.pairedDeviceID == nil)
        #expect(replaced.token == "daemon")
    }

    @Test("コードで追加: 名前・URL・8 文字のコードが揃い、Access は両方か両方空のときだけ追加できる")
    func codeDraft() {
        var draft = CodeDraft(name: " Mac Studio ", url: "https://studio.example.com", code: "abcd-2345")
        let built = draft.build()
        #expect(built?.0.code == "ABCD2345")
        #expect(built?.1 == "Mac Studio")
        #expect(built?.0.access == nil)
        draft.accessID = "id"
        #expect(draft.build() == nil)
        draft.accessSecret = "secret"
        #expect(draft.build()?.0.access == AccessCredential(clientID: "id", clientSecret: "secret"))
        draft.code = "ABCD234"
        #expect(draft.build() == nil)
        draft.code = "ABCD2345"
        draft.url = "studio.example.com"
        #expect(draft.build() == nil)
        draft.url = "https://studio.example.com"
        draft.name = "  "
        #expect(draft.build() == nil)
    }

    @Test("残り時間は切り上げの分:秒で、過ぎたら 0:00")
    func remaining() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(PairingSheet.remaining(until: now.addingTimeInterval(300), now: now) == "残り5:00")
        #expect(PairingSheet.remaining(until: now.addingTimeInterval(59.2), now: now) == "残り1:00")
        #expect(PairingSheet.remaining(until: now.addingTimeInterval(9), now: now) == "残り0:09")
        #expect(PairingSheet.remaining(until: now.addingTimeInterval(-5), now: now) == "残り0:00")
    }

    @Test("「この Mac」の公開 URL は http(s) の URL だけ受け付ける")
    func publicationDraft() {
        #expect(PublicationDraft(url: "https://", accessID: "", accessSecret: "").build() == nil)
        #expect(PublicationDraft(url: "https://mac.example.com", accessID: "", accessSecret: "").build()?.access == nil)
        #expect(PublicationDraft(url: "ftp://mac.example.com", accessID: "", accessSecret: "").build() == nil)
    }

    @Test("足りない欄は、入力の仕方を返す")
    func validationMessages() {
        #expect(throws: (any Error).self) { try ConnectionDraft().build().get() }
        if case .failure(.message(let message)) = ConnectionDraft().build() { #expect(message == "名前を入力してください。") }
        if case .failure(.message(let message)) = PublicationDraft(url: "studio").validated() { #expect(message == "URLは「https://」から入力してください。") }
        if case .failure(.message(let message)) = CodeDraft(name: "Mac", url: "https://a.example.com", code: "ABC").validated() { #expect(message == "コードは8文字で入力してください。") }
        if case .failure(.message(let message)) = PublicationDraft(url: "https://a.example.com", accessID: "id").validated() {
            #expect(message == "Client IDとClient Secretは、両方入力するか両方空にしてください。")
        }
    }
}

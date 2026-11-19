import Foundation
import Testing
@testable import TaskboardKit

@Suite struct PairingTests {
    let access = AccessCredential(clientID: "id.access", clientSecret: "secret+/=")

    @Test("QR の中身は URI でない JSON で、往復でき、日本語の名前も残る")
    func payloadRoundTrip() throws {
        let payload = PairingPayload(url: URL(string: "https://studio-taskboard.example.com")!, code: "ABCD2345", access: access, name: "スタジオの Mac")
        let text = payload.encoded
        #expect(text.hasPrefix("{"))
        #expect(text.contains(#""taskboardPair":1"#))
        #expect(PairingPayload.decode(text) == payload)
        #expect(PairingPayload.decode("  " + text + "\n") == payload)
    }

    @Test("版・URL・コードのどれかが違えば読まない")
    func payloadRejects() {
        func encode(_ url: String, _ code: String) -> String {
            PairingPayload(url: URL(string: url)!, code: code, access: nil, name: "x").encoded
        }
        #expect(PairingPayload.decode(encode("ftp://example.com", "ABCD2345")) == nil)
        #expect(PairingPayload.decode(encode("https://example.com", "ABC")) == nil)
        #expect(PairingPayload.decode(encode("https://example.com", "ABCDEFGO")) == nil)
        #expect(PairingPayload.decode(encode("https://example.com", "ABCD2345").replacingOccurrences(of: #""taskboardPair":1"#, with: #""taskboardPair":2"#)) == nil)
        #expect(PairingPayload.decode(#"{"taskboardPair":1}"#) == nil)
        #expect(PairingPayload.decode("{not json") == nil)
        #expect(PairingPayload.decode("") == nil)
        #expect(PairingPayload.decode("taskboard://pair?code=ABCD2345") == nil)
    }

    @Test("打ったコードは大文字にし、- と空白を除く")
    func normalize() {
        #expect(PairingCode.normalize("abcd-2345") == "ABCD2345")
        #expect(PairingCode.normalize(" ABCD 2345 ") == "ABCD2345")
        #expect(PairingCode.normalize("ABCD234") == nil)
        #expect(PairingCode.normalize("ABCD23456") == nil)
        #expect(PairingCode.normalize("ABCDILOU") == nil)
        #expect(PairingCode.normalize("ＡＢＣＤ２３４５") == nil)
        #expect(PairingCode(code: "ABCD2345", expiresAt: .distantFuture).display == "ABCD-2345")
    }

    @Test("devices.updated を往復でき、current は false でも出す")
    func devicesEvent() throws {
        let json = #"{"event":"devices.updated","data":[{"id":"d1","name":"iPhone","platform":"ios","createdAt":"2026-10-05T01:00:00Z","current":false}]}"#
        let event = try WireJSON.decoder().decode(DaemonEvent.self, from: Data(json.utf8))
        guard case .devicesUpdated(let devices) = event else { Issue.record("違うイベント"); return }
        #expect(devices.map(\.name) == ["iPhone"])
        #expect(devices.first?.lastSeenAt == nil)
        let encoded = try WireJSON.encoder().encode(event)
        #expect(try WireJSON.decoder().decode(DaemonEvent.self, from: encoded) == event)
        #expect(String(decoding: try WireJSON.encoder().encode(devices[0]), as: UTF8.self).contains(#""current":false"#))
    }
}

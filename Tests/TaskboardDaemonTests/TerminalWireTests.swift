import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// テストから API を立てるときの依存
let testDependencies = APIServer.Dependencies()

@Suite("シェルの大きさ")
struct ShellSizeTests {
    @Test("cols / rows は 2...500 に丸める")
    func clampSize() {
        #expect(AgentHostShells.clamp(cols: 0, rows: -5) == (2, 2))
        #expect(AgentHostShells.clamp(cols: 80, rows: 24) == (80, 24))
        #expect(AgentHostShells.clamp(cols: 10_000, rows: 501) == (500, 500))
    }
}

@Suite("TerminalWire")
struct TerminalWireTests {
    @Test("サーバ → クライアントの電文が往復する")
    func serverMessagesRoundTrip() throws {
        let messages: [TerminalServerMessage] = [
            .frame(seq: 1, full: true, cols: 100, rows: 30),
            .frame(seq: 2, full: false, cols: 100, rows: 30),
            .mode(.observe), .mode(.control),
            .controllerBusy,
            .controlLost(.takenOver), .controlLost(.disconnected),
            .closed(reason: .paneNotFound, message: "terminal target w1:p9 not found"),
            .closed(reason: .queueOverflow, message: nil),
        ]
        let encoder = WireJSON.encoder()
        let decoder = WireJSON.decoder()
        for message in messages {
            let data = try encoder.encode(message)
            #expect(try decoder.decode(TerminalServerMessage.self, from: data) == message)
        }
        #expect(
            String(decoding: try encoder.encode(TerminalServerMessage.controlLost(.takenOver)), as: UTF8.self)
                == #"{"reason":"taken_over","type":"control_lost"}"#)
    }

    @Test("クライアント → サーバの電文が往復し、入力は base64")
    func clientMessagesRoundTrip() throws {
        let messages: [TerminalClientMessage] = [
            .acquire(takeover: false), .acquire(takeover: true),
            .input(Data("y\r".utf8)), .input(Data("日本語".utf8)), .input(Data()),
            .resize(cols: 120, rows: 40),
            .release,
        ]
        let encoder = WireJSON.encoder()
        let decoder = WireJSON.decoder()
        for message in messages {
            let data = try encoder.encode(message)
            #expect(try decoder.decode(TerminalClientMessage.self, from: data) == message)
        }
        #expect(
            String(decoding: try encoder.encode(TerminalClientMessage.input(Data("y\r".utf8))), as: UTF8.self)
                == #"{"bytes":"eQ0=","type":"input"}"#)
        #expect(throws: DecodingError.self) {
            try decoder.decode(TerminalClientMessage.self, from: Data(#"{"type":"input","bytes":"%%%"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(TerminalClientMessage.self, from: Data(#"{"type":"dance"}"#.utf8))
        }
    }
}

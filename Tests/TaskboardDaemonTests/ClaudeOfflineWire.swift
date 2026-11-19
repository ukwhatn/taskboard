import Foundation
import Testing

@testable import TaskboardDaemon

/// Claude Code 2.1.310 を、途中で切れる proxy（`HTTPS_PROXY`）越しに stream-json で動かして取った行（2026-10-25）。
/// 回線を切ると `api_retry` を 10 回（`error_status` は null、約 3 分）出した後に、この result でターンを終えた。
/// `usage`・`modelUsage` などの値の欄は省き、session は `s1` に替えてある
enum ClaudeOfflineWire {
    /// 張った接続を proxy が切った（ECONNRESET）
    static let droppedResult =
        #"{"duration_api_ms":1413,"stop_reason":"stop_sequence","session_id":"s1","total_cost_usd":0.0076885,"terminal_reason":"api_error","is_error":true,"num_turns":1,"subtype":"success","api_error_status":null,"result":"API Error: Connection dropped (ECONNRESET)","type":"result","duration_ms":176529,"user_message_uuid":"11111111-1111-4111-8111-000000000002","user_message_uuids":["11111111-1111-4111-8111-000000000002"],"queued_turn_count":0,"result_index":1,"model_usage_since_last_result":{}}"#
    /// proxy が待ち受けを閉じた（ECONNREFUSED）
    static let refusedResult =
        #"{"duration_api_ms":2367,"stop_reason":"stop_sequence","session_id":"s1","total_cost_usd":0.00038794,"terminal_reason":"api_error","is_error":true,"num_turns":1,"subtype":"success","api_error_status":null,"result":"API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)","type":"result","duration_ms":179272,"user_message_uuid":"11111111-1111-4111-8111-000000000002","user_message_uuids":["11111111-1111-4111-8111-000000000002"],"queued_turn_count":0,"result_index":1,"model_usage_since_last_result":{}}"#
    /// 最後の送り直し
    static let lastRetry =
        #"{"type":"system","subtype":"api_retry","attempt":10,"max_retries":10,"retry_delay_ms":33631,"error_status":null,"error":"unknown","session_id":"s1","uuid":"18d6a521-ad20-4447-b22e-293513f294f6"}"#
    /// 回線が戻った後の誤りでない result（同じ取り方。誤りでなくても `api_error_status` は null）
    static let completedResult =
        #"{"duration_api_ms":6317,"stop_reason":"end_turn","session_id":"s1","terminal_reason":"completed","is_error":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"さようなら","type":"result","duration_ms":4051}"#
}

struct ClaudeOfflineWireTests {
    private func result(_ line: String) throws -> ClaudeTurnResult {
        guard case .result(let result) = ClaudeStreamParser.parse(Data(line.utf8)) else { throw ParseFailure() }
        return result
    }

    private struct ParseFailure: Error {}

    @Test("API に繋がらずに終わった result だけを、接続の失敗と読む")
    func connectionFailures() throws {
        #expect(try result(ClaudeOfflineWire.droppedResult).connectionFailed)
        #expect(try result(ClaudeOfflineWire.refusedResult).connectionFailed)
        #expect(try !result(ClaudeOfflineWire.completedResult).connectionFailed, "誤りでない result も status は null")
        // HTTP の応答があった誤り（利用枠の上限・認証・過負荷）は status が付く。人の中断は terminal_reason が違う
        for status in [429, 401, 529] {
            let refused = ClaudeOfflineWire.droppedResult.replacingOccurrences(of: #""api_error_status":null"#, with: #""api_error_status":\#(status)"#)
            #expect(try !result(refused).connectionFailed)
        }
        let aborted = #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","api_error_status":null,"session_id":"s1"}"#
        #expect(try !result(aborted).connectionFailed)
        let older = #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","session_id":"s1"}"#
        #expect(try !result(older).connectionFailed, "status の欄が無い版は見分けられないので待たない")
    }
}

import Foundation

/// 端末のマウスの報告。報告のモードはシェルのアプリ（vim など）が入れ、エミュレータはクリックを SGR の列で書き出す
public enum TerminalMouse {
    /// エミュレータが書き出した入力から、SGR のマウスの報告（`ESC [ < 数字;数字;数字 M` か `m`）を取り除く。
    /// 操作権が無い間のクリックを pane に送らないため。報告の形に合わない列（打鍵の Esc や矢印キー）はそのまま残す
    public static func removingReports(from data: Data) -> Data {
        let bytes = [UInt8](data)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if let end = reportEnd(in: bytes, at: index) {
                index = end
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return Data(result)
    }

    /// `bytes[start]` から SGR の報告が始まっていれば、その次の位置
    private static func reportEnd(in bytes: [UInt8], at start: Int) -> Int? {
        let esc: UInt8 = 0x1B, bracket = UInt8(ascii: "["), less = UInt8(ascii: "<")
        guard start + 2 < bytes.count, bytes[start] == esc, bytes[start + 1] == bracket, bytes[start + 2] == less else { return nil }
        var index = start + 3
        var fields = 1
        var digits = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                digits += 1
            case UInt8(ascii: ";"):
                guard digits > 0 else { return nil }
                fields += 1
                digits = 0
            case UInt8(ascii: "M"), UInt8(ascii: "m"):
                return fields == 3 && digits > 0 ? index + 1 : nil
            default:
                return nil
            }
            index += 1
        }
        return nil
    }
}

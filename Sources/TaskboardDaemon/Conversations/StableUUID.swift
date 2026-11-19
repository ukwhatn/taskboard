import CryptoKit
import Foundation

/// 決まった文から作る UUID（同じ文なら同じ値）。daemon が送った後に落ちても、起き直した後に会話が受けた uuid（控えか記録の
/// `recentMessageIds`）と照らして二重に入れない。会話の id を先に決める（定期起動の回）のにも使う
enum StableUUID {
    static func make(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        // CLI は uuid の形を確かめるので、version と variant の位置を埋める。SHA-256 なので RFC 9562 の v5 ではないが、5 を置くのは
        // 前から回答の配送が同じ作り方で送っている uuid を変えないため（変えると、送った後に入れ替えた daemon が同じ回答を 2 回入れる）
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
                bytes[13], bytes[14], bytes[15]
            ))
        return uuid.uuidString.lowercased()
    }
}

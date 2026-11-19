import Foundation

/// ネットワークに繋がらずにターンが終わった Claude の会話へ、接続があるときに続きを送る間合い。
/// 送った続きもすぐに失敗したら（経路はあるのに外へ出られない）、間を広げて `delays.count` 回まで試し、それで止める。
/// 止めても印は残し、経路が一度切れてまた繋がったら（`NetworkPath.returns` が増えたら）数え直してすぐ送る
enum NetworkResumeRule {
    /// 続きを送るまでの間。i 番目は、続きを i 回送った後の失敗（0 番目は最初の失敗）
    static let delays: [TimeInterval] = [30, 300, 900]

    /// ターンが繋がらずに終わった：次に続きを送ってよい時刻（印の時刻）
    static func nextAttempt(tries: Int, now: Date) -> Date {
        now.addingTimeInterval(delays[min(tries, delays.count - 1)])
    }

    /// 試し切った（経路が戻るまで送らない）
    static func exhausted(tries: Int) -> Bool { tries >= delays.count }
}

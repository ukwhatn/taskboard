import Foundation

/// この端末の設定（UserDefaults）の保存先。`UserDefaults.standard` を直接使わず、ここを通す。
///
/// fixtures か debug の口（`--debug-port`）で起動したアプリ（`scripts/ui` の確かめ方）と snapshot test は、ユーザーのアプリと同じ bundle ID の保存先を共有する。
/// 分けないと、確かめるたびにユーザーのアプリの開き方やパネルの幅が書き換わり、並べて動かした確かめ方どうしも互いの値を上書きする
/// （開き方を変えた直後の snapshot test が、前の回と違う開き方で描いて失敗した）。そこで fixtures と debug の口のときは、別の領域を起動のたびに空から使う
enum AppDefaults {
    nonisolated(unsafe) private(set) static var store: UserDefaults = .standard

    /// fixtures・debug の口・test host で、ユーザーの設定と別の保存先を使っているか
    static var isScratch: Bool { store !== UserDefaults.standard }

    /// 保存先を空の別の領域にする。同時に動くものどうしは `name` を分ける（debug の口のポートなど）
    /// `seed` は初めに入れる値（`defaults export` で写したユーザーの設定など。ユーザーのアプリと同じ開き方で確かめる）
    static func useScratch(_ name: String, seed: [String: Any]? = nil) {
        let suite = "uk.whatn.taskboard.scratch.\(name)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        if let seed { defaults.setPersistentDomain(seed, forName: suite) }
        store = defaults
    }
}

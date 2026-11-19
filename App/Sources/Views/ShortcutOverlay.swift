import SwiftUI

/// ⌘/。今の画面で使えるショートカットを、場面ごとにまとめて出す。設定の［ショートカット］と同じ一覧（`ShortcutList`）
struct ShortcutOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sections = ShortcutCatalog.sections(
            taskOpen: model.selectedTask != nil, sessionOpen: model.selectedTask != nil || model.activeConversation != nil,
            conversationOpen: model.activeConversation != nil)
        SheetScaffold(title: String(localized: "ショートカット"), width: 520) {
            ShortcutList(sections: sections)
        } actions: {
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        #if os(macOS)
        .frame(minHeight: SheetMetrics.shortcutsHeight.lowerBound, idealHeight: SheetMetrics.shortcutsIdealHeight, maxHeight: SheetMetrics.shortcutsHeight.upperBound)
        #endif
    }
}

/// ショートカットの一覧。節ごとに、左に操作、右にキー（Mac の［システム設定］>［キーボード］と同じ並び）
struct ShortcutList: View {
    let sections: [ShortcutCatalog.Section]

    var body: some View {
        ForEach(sections) { section in
            Section(section.title) {
                ForEach(section.items, id: \.keys) { item in
                    LabeledContent(item.label) {
                        Text(item.keys).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// キーと操作の表。メニューとパレットの名前に揃え、キーの表記は Apple の順（⌃⌥⇧⌘）
enum ShortcutCatalog {
    struct Item {
        let keys: String
        let label: String
    }

    struct Section: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    /// タスク・セッション・会話の節は、開いているときだけ出す
    static func sections(taskOpen: Bool, sessionOpen: Bool, conversationOpen: Bool) -> [Section] {
        var sections = [
            Section(title: String(localized: "全体"), items: [
                Item(keys: "⌘K", label: String(localized: "検索・コマンド")),
                Item(keys: "⌘N", label: String(localized: "タスクを追加")),
                Item(keys: "⌘1〜⌘9", label: String(localized: "案件を選ぶ（サイドバーの順）")),
                Item(keys: "⌥⌘A", label: String(localized: "次の入力待ちへ移動")),
                Item(keys: "⌥⌘1 / 2 / 3", label: String(localized: "タスクの開き方を切り替える")),
                Item(keys: "⌃⌘1", label: String(localized: "1台だけ表示")),
                Item(keys: "⌘,", label: String(localized: "設定を開く")),
                Item(keys: "⌘/", label: String(localized: "ショートカットの一覧を表示")),
                Item(keys: "⇧↩ / ⌥↩", label: String(localized: "入力欄で改行")),
            ]),
            Section(title: String(localized: "ボード"), items: [
                Item(keys: "⌘B", label: String(localized: "会話と列を切り替える")),
                Item(keys: "↑ ↓ ← →", label: String(localized: "会話・カードを選ぶ（j・k・h・lでも）")),
                Item(keys: "↩", label: String(localized: "開く")),
                Item(keys: "Space", label: String(localized: "会話を展開・折りたたむ")),
                Item(keys: "1〜4", label: String(localized: "質問の選択肢を選ぶ")),
                Item(keys: "⌘Y", label: String(localized: "選んだ会話を許可・承認・回答")),
                Item(keys: "⌥⌘A", label: String(localized: "次の対応待ちの会話を選ぶ（会話の表示）")),
                Item(keys: "⌘↩", label: String(localized: "別ウインドウで開く")),
                Item(keys: "⌥⌘← / ⌥⌘→", label: String(localized: "隣の列へ移動")),
            ]),
        ]
        if taskOpen {
            sections.append(Section(title: String(localized: "タスク"), items: [
                Item(keys: "Esc", label: String(localized: "閉じる")),
                Item(keys: "⌘L", label: String(localized: "セッションの入力欄へ移動")),
                Item(keys: "⌃Tab / ⌃⇧Tab", label: String(localized: "次・前のセッションを表示")),
                Item(keys: "⌘クリック", label: String(localized: "セッションを右に並べる")),
                Item(keys: "⌃] / ⌃[", label: String(localized: "並べた右・左の入力欄へ移動")),
            ]))
            sections.append(Section(title: String(localized: "文書"), items: [
                Item(keys: "Esc", label: String(localized: "文書を閉じてタスクに戻る")),
                Item(keys: "⌥⌘↑ / ⌥⌘↓", label: String(localized: "前・次の文書を表示")),
            ]))
        }
        if sessionOpen {
            sections.append(Section(title: String(localized: "ターミナルとチャット"), items: [
                Item(keys: "⌘J", label: String(localized: "ボードに戻る")),
                Item(keys: "⌘F", label: String(localized: "検索")),
                Item(keys: "⌘+ / ⌘- / ⌘0", label: String(localized: "拡大・縮小・実際のサイズ")),
            ]))
        }
        if conversationOpen {
            var items = [
                Item(keys: "Esc", label: String(localized: "生成を停止")),
                Item(keys: "⌘↩", label: String(localized: "応答が終わってから送信")),
                Item(keys: "⌥⌘↩", label: String(localized: "フォークして送信")),
                Item(keys: "⌥⌘O", label: String(localized: "末尾からフォーク")),
                Item(keys: "⇧⌘W", label: String(localized: "会話を終了")),
                Item(keys: "⌥⌘↑ / ⌥⌘↓", label: String(localized: "前・次のメッセージへ移動")),
                Item(keys: "⇧⌘M", label: String(localized: "権限のモードを変更")),
                Item(keys: "⇧⌘I", label: String(localized: "モデルを変更")),
                Item(keys: "⇧⌘E", label: String(localized: "エフォートを変更")),
                Item(keys: "↑ / ↓", label: String(localized: "送ったメッセージを呼び出す（入力欄の先頭で）")),
            ]
            #if os(macOS)
            items.append(Item(keys: "⌥Space", label: String(localized: "押している間、音声入力")))
            #endif
            sections.append(Section(title: String(localized: "会話"), items: items))
        }
        return sections
    }
}

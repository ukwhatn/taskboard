#if os(iOS)
import PhotosUI
import SwiftUI
import TaskboardKit

/// iPhone の入力欄の左端の＋のメニュー。写真とファイルの添付と、入力欄の下の欄（`ConversationControlBar`）と同じ制御を置く。
/// モデル・effort・権限は会話の画面のシートで開く（＋のメニューにはポップオーバーを結べない）。クリップボードの画像は文の欄の長押しの［ペースト］で受ける
struct ConversationPhoneMenu: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let feed: ConversationFeed
    let writable: Bool
    let canAttach: Bool
    let attach: () -> Void
    let addImages: @MainActor @Sendable ([Data]) -> Void
    @State private var picking = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        let controls = ConversationControls(conversation, model: model)
        Menu {
            Section {
                Button("写真", systemImage: "photo.on.rectangle") { picking = true }
                    .disabled(!writable || !canAttach)
                Button("ファイル", systemImage: "paperclip", action: attach)
                    .disabled(!writable)
            }
            Section {
                if let name = controls.model {
                    item("モデル", value: name, systemImage: "cpu") { feed.openField = .model }
                }
                if let effort = controls.effort {
                    item("エフォート", value: effort, systemImage: "gauge.with.dots.needle.50percent") { feed.openField = .effort }
                }
                if let permission = controls.permission {
                    item("権限", value: permission, systemImage: "lock.shield") { feed.openField = .permission }
                }
                if controls.connectors {
                    Button("コネクタ", systemImage: "puzzlepiece.extension") { feed.sheet = .connectors }
                }
                if controls.context {
                    item("コンテキスト", value: controls.contextPercent.map { UsageText.percent(Double($0)) }, systemImage: "chart.pie") { feed.sheet = .context }
                }
                if controls.backgroundTasks > 0 {
                    item("バックグラウンドのタスク", value: String(localized: "\(controls.backgroundTasks)件"), systemImage: "clock.arrow.circlepath") { feed.sheet = .tasks }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .foregroundStyle(ChatPalette.secondaryText)
                .hitTarget()
        }
        .accessibilityLabel("添付と設定")
        .photosPicker(isPresented: $picking, selection: $photos, maxSelectionCount: max(1, ChatAttachment.maxCount - model.chatImages(for: conversation.key).count), matching: .images)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task { await load(picked) }
        }
        .task(id: conversation.machine) { await ConversationControls.loadModels(for: conversation, model: model) }
    }

    /// 題の下に今の値を出す項目（iPhone のメニューは 2 つめの Text を副題にする）
    private func item(_ title: LocalizedStringResource, value: String?, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
                if let value { Text(verbatim: value) }
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    private func load(_ picked: [PhotosPickerItem]) async {
        var images: [Data] = []
        for item in picked {
            if let data = try? await item.loadTransferable(type: Data.self) { images.append(data) }
        }
        if !images.isEmpty { addImages(images) }
    }
}

/// iPhone の戻るボタンの行の題。2 行目にタスクの番号とマシンを出す（上の帯を外した分の文脈）
struct PhoneConversationTitle: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        HStack(spacing: Space.inline) {
            StatusGlyph(conversation: conversation)
            VStack(spacing: 0) {
                Text(verbatim: conversation.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let machine = model.machineName(conversation.machine)
        return conversation.taskNumber.map { "#\($0) · \(machine)" } ?? machine
    }
}

/// iPhone の状態と欄（モデル・エフォート・権限）のシート。iPad と Mac はポップオーバーで開くので付けない
struct PhoneConversationSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    let conversation: Conversation?
    let feed: ConversationFeed
    let fail: (UserFacingError) -> Void

    func body(content: Content) -> some View {
        if AppModel.isPhone, let conversation {
            content
                .sheet(isPresented: Binding(get: { feed.showsInfo }, set: { feed.showsInfo = $0 })) {
                    PhoneInfoSheet(conversation: conversation, feed: feed)
                        .presentationDetents([.medium, .large])
                }
                .sheet(item: Binding(get: { feed.openField }, set: { feed.openField = $0 })) { field in
                    ConversationFieldPanel(field: field, conversation: conversation, feed: feed,
                                           options: ConversationControls(conversation, model: model).options, fail: fail)
                        .padding(Space.card)
                        .presentationDetents([.medium])
                }
        } else {
            content
        }
    }
}

private struct PhoneInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    let feed: ConversationFeed

    var body: some View {
        NavigationStack {
            ScrollView {
                ConversationInspector(conversation: conversation, feed: feed)
                    .padding(Space.card)
            }
            .navigationTitle("状態")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}
#endif

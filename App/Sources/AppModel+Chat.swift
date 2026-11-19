import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import TaskboardKit

extension AppModel {
    func chatImages(for key: ConversationKey) -> [ChatDraftImage] {
        chatImageDrafts[key] ?? []
    }

    func setChatImages(_ images: [ChatDraftImage], for key: ConversationKey) {
        chatImageDrafts[key] = images.isEmpty ? nil : images
    }

    /// 貼った・落とした画像を下書きの後ろに足す。縮めている間に外した画像を戻さないよう、終わった時点の下書きに足す。
    /// 足せなかった分（枚数の上限・読めない画像）があれば、その失敗を返す
    func addChatImages(_ incoming: [Data], for key: ConversationKey) async -> UserFacingError? {
        let outcome = await ChatImageIntake.append(incoming, to: [])
        let added = ChatImageIntake.images(of: outcome)
        let current = chatImages(for: key)
        let room = max(0, ChatAttachment.maxCount - current.count)
        setChatImages(current + added.prefix(room), for: key)
        return added.count > room ? ChatImageIntake.failure(.tooMany([])) : ChatImageIntake.failure(outcome)
    }

    func chatFiles(for key: ConversationKey) -> [ChatDraftFile] {
        chatFileDrafts[key] ?? []
    }

    func setChatFiles(_ files: [ChatDraftFile], for key: ConversationKey) {
        chatFileDrafts[key] = files.isEmpty ? nil : files
    }

    /// ［ファイルを添付］で選んだファイルを会話の下書きに足す。画像は画像の下書きに回す。足せなかった分があれば、その失敗を返す
    func addChatFiles(_ urls: [URL], for key: ConversationKey) async -> UserFacingError? {
        let outcome = ChatFileIntake.take(urls, local: isThisMac(key.machine), room: max(0, ChatAttachment.maxFiles - chatFiles(for: key).count))
        setChatFiles(chatFiles(for: key) + outcome.files, for: key)
        let imageProblem = outcome.images.isEmpty ? nil : await addChatImages(outcome.images, for: key)
        return outcome.problem.map(ChatFileIntake.failure) ?? imageProblem
    }
}

/// 会話の入力欄の書きかけの文とカーソル。入力欄を作り直しても（開き方を替えた・別の会話へ移って戻った）残し、送ったら消す。
/// 打鍵ごとに書くので観測しない（観測すると、書くたびに読んでいる画面が描き直される）。入力欄は開くときに読み、変わるたびに書き戻す。
/// 文はアプリの外（`AppDefaults.store`）にも残す。
/// 外へは、打つのが止まってから（`saveDelay`）と、アプリが終わる・裏に回るときにまとめて書く。打鍵ごとに書くと、同じ保存先を `@AppStorage` で読む
/// 画面（会話の画面・発言の一覧）が書くたびに描き直された
@MainActor
final class ChatDraftTexts {
    private struct Entry {
        var text: String
        var selection: TextSelection?
    }

    static let storeKey = "chat.conversationDrafts"
    static let saveDelay = Duration.milliseconds(1500)
    private var entries: [ConversationKey: Entry] = [:]
    private let store: UserDefaults
    private var pendingSave: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    init(store: UserDefaults) {
        self.store = store
        for (key, text) in store.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:] {
            guard let conversation = Self.conversation(key) else { continue }
            entries[conversation] = Entry(text: text)
        }
        #if os(macOS)
        let leaving = [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification]
        #else
        let leaving = [UIApplication.willTerminateNotification, UIApplication.didEnterBackgroundNotification]
        #endif
        observers = leaving.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    func text(for key: ConversationKey) -> String { entries[key]?.text ?? "" }

    func selection(for key: ConversationKey) -> TextSelection? { entries[key]?.selection }

    func set(_ text: String, selection: TextSelection?, for key: ConversationKey) {
        let previous = entries[key]?.text ?? ""
        entries[key] = text.isEmpty ? nil : Entry(text: text, selection: selection)
        guard previous != text else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 書きかけをアプリの外へ書く
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        var saved: [String: String] = [:]
        for (key, entry) in entries { saved[Self.storeKey(key)] = entry.text }
        guard (store.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]) != saved else { return }
        store.set(saved, forKey: Self.storeKey)
    }

    private static func storeKey(_ key: ConversationKey) -> String { "\(key.machine.rawValue)\n\(key.id)" }

    private static func conversation(_ key: String) -> ConversationKey? {
        let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return ConversationKey(machine: MachineID(rawValue: parts[0]), id: parts[1])
    }
}

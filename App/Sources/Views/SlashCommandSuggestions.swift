import SwiftUI
import TaskboardKit

/// 候補の 1 行の中身。チャットの `SlashCommand` と会話の `ConversationSlashItem` の両方から作る
struct SlashSuggestion: Identifiable, Hashable {
    var name: String
    var description: String
    /// 説明の前に添える種類（「組み込み」「Taskboard」）
    var badge: String?
    /// 打った語が合った別名
    var alias: String?
    /// 名前の前に付ける印（`/` のコマンドは `/`、`@` のファイルは無し）
    var prefix: String
    let id: String

    init(name: String, description: String, badge: String? = nil, alias: String? = nil, prefix: String = "/", id: String? = nil) {
        self.name = name
        self.description = description
        self.badge = badge
        self.alias = alias
        self.prefix = prefix
        self.id = id ?? name
    }

    init(_ command: SlashCommand) {
        self.init(name: command.name, description: command.description, badge: command.kind == .builtin ? String(localized: "組み込み") : nil)
    }
}

/// チャットの入力欄の上に出す、`/` で始まる skill と command と組み込みのコマンドの候補と、`@` のファイルの候補。↑↓ とホバーで選び、押すか ↩・Tab で入れる（キーは入力欄が受ける）
struct SlashCommandSuggestions: View {
    let commands: [SlashSuggestion]
    let selection: Int
    let fonts: ChatFonts
    let pick: (SlashSuggestion) -> Void
    let hover: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button {
                    pick(command)
                } label: {
                    SlashCommandRow(command: command, selected: index == selection, fonts: fonts)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onHover { inside in if inside { hover(index) } }
                #endif
            }
        }
        .padding(.vertical, Space.inline)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

/// 1 行。名前と説明を 1 行ずつ。Claude Code の組み込みは説明の前に「組み込み」を、アプリの操作は「Taskboard」を添える。選んでいる行は背景で示し、読み上げにも伝える
private struct SlashCommandRow: View {
    let command: SlashSuggestion
    let selected: Bool
    let fonts: ChatFonts

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.block) {
            Text(verbatim: "\(command.prefix)\(command.name)").font(fonts.body.monospaced()).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            if let alias = command.alias {
                Text(verbatim: "/\(alias)").font(fonts.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            }
            if let badge = command.badge {
                Text(badge).font(fonts.caption2).foregroundStyle(.secondary).chipStyle().lineLimit(1).layoutPriority(1)
            }
            if !command.description.isEmpty {
                Text(command.description).font(fonts.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.inline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension SlashTyping {
    /// 入力欄のカーソルの手前で探す。カーソルが分からなければ文の終わりで探し、範囲を選んでいるときは出さない
    static func find(in draft: String, selection: TextSelection?) -> SlashTyping? {
        guard let selection else { return find(in: draft) }
        guard case .selection(let range) = selection.indices, range.isEmpty, let cursor = cursor(range.lowerBound, in: draft) else { return nil }
        return find(in: draft, cursor: cursor)
    }
}

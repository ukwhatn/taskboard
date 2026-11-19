import Foundation
import TaskboardKit

/// タスク画面の右側の欄。Mac と iPad は開いた欄を格子に並べ（`TaskSideArea`）、iPhone は切り替えて 1 つを出す（`TaskSidePane`）。
/// 会話のシェルは欄にせず、会話と右側の下に全幅で出す（`TaskTerminalArea`）
enum SidePanel: String, CaseIterable, Identifiable, Codable {
    case status, docs, work, changes
    /// 会話が右の欄に置いた部品（`PanelPlace.side`）。部品のあるタスクだけで出し、人が開くまで閉じている
    case part

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: String(localized: "状態")
        case .docs: String(localized: "文書")
        case .work: String(localized: "作業項目")
        case .changes: String(localized: "差分")
        case .part: String(localized: "部品")
        }
    }

    var symbol: String {
        switch self {
        case .status: "info.circle"
        case .docs: "doc.text"
        case .work: "checklist"
        case .changes: "plusminus"
        case .part: "rectangle.on.rectangle"
        }
    }

    /// 上の帯にいつも並べる欄（部品の欄は、部品のあるタスクだけで区切りの後ろに出す）
    static let fixed: [SidePanel] = [.status, .docs, .work, .changes]

    /// iPhone の切り替えに並べる欄（端末は会話の画面からシートで開く）。部品のあるタスクは最後に部品の欄を加える
    static func phoneTabs(hasPart: Bool) -> [SidePanel] { [.docs, .work, .status, .changes] + (hasPart ? [.part] : []) }

    /// iPhone で出す欄。このタスクで選んだ欄があればそれ、無ければこの端末で前に選んだ欄。前に選んだ欄の中身がこのタスクで空なら、文書 → 作業項目 → 状態の順で中身のあるものに戻す
    static func shown(picked: SidePanel?, preferred: SidePanel, filled: (SidePanel) -> Bool) -> SidePanel {
        if let picked { return picked }
        if filled(preferred) { return preferred }
        return [.docs, .work].first(where: filled) ?? .status
    }
}

/// Mac と iPad の右側に開いている欄の組と大きさ。この端末に JSON で残す（`AppPreferences.taskSidePanelsKey`）
struct SidePanelSet: Codable, Equatable {
    /// 開いている欄。nil なら人がまだ選んでいない（`shown` が中身で決める）
    var open: [SidePanel]?
    /// 欄の高さの重み。同じ列の欄どうしで比べ、無ければ 1
    var weights: [SidePanel: Double] = [:]
    /// 2 列のときの左の列の幅の割合
    var column: Double = 0.5

    init(open: [SidePanel]? = nil) {
        self.open = open
    }

    /// 読めない値（前の版の欄の名前など）は初めの組にする
    init(json: String) {
        self = (try? JSONDecoder().decode(Self.self, from: Data(json.utf8))) ?? Self()
    }

    var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// 出す欄（`SidePanel.allCases` の順）。人が選んでいなければ差分だけ
    var shown: [SidePanel] {
        let chosen = open ?? [.changes]
        return SidePanel.allCases.filter(chosen.contains)
    }

    func weight(_ panel: SidePanel) -> Double { weights[panel] ?? 1 }

    /// 上の帯のボタン。開いていれば閉じ、閉じていれば開く
    mutating func toggle(_ panel: SidePanel, current: [SidePanel]) {
        open = current.contains(panel) ? current.filter { $0 != panel } : current + [panel]
    }

    /// 会話の帯の［状態］［差分］などの知らせ。閉じていれば開き、開いていればそのまま
    mutating func reveal(_ panel: SidePanel, current: [SidePanel]) {
        open = current.contains(panel) ? current : current + [panel]
    }

    /// 同じ列の隣どうしの欄（上が `upper`）の境目を `delta` だけ下げる。`panels` を `size` の格子に並べたときの、この組での高さから動かす
    /// （ドラッグでは、動かし始めの組に始めからの移動量を当てる。動かしている最中の高さに当てると、動くたびに動いた分を足し直して境目がカーソルより先へ走る）。
    /// 高さは最小の高さで止め、2 つの重みの和は変えない
    mutating func resize(_ upper: SidePanel, _ lower: SidePanel, panels: [SidePanel], in size: CGSize, by delta: CGFloat) {
        let frames = Dictionary(uniqueKeysWithValues: zip(panels, SidePanelArrangement.frames(of: panels, in: size, set: self)))
        guard let upperFrame = frames[upper], let lowerFrame = frames[lower] else { return }
        let sum = upperFrame.height + lowerFrame.height
        let minimum = min(SidePanelMetrics.minHeight, sum / 2)
        let top = min(max(upperFrame.height + delta, minimum), sum - minimum)
        let total = weight(upper) + weight(lower)
        weights[upper] = total * Double(top) / Double(sum)
        weights[lower] = total * Double(sum - top) / Double(sum)
    }

    /// 2 列の境目を `delta` だけ右へ動かす。`resize` と同じく、`panels` を `size` の格子に並べたときの、この組での左の列の幅から動かす
    mutating func resizeColumn(panels: [SidePanel], in size: CGSize, by delta: CGFloat) {
        let columns = SidePanelArrangement.columns(of: panels, width: size.width)
        guard columns.count == 2, let first = columns[0].first, let index = panels.firstIndex(of: first) else { return }
        let left = SidePanelArrangement.frames(of: panels, in: size, set: self)[index].width
        let available = size.width - SidePanelMetrics.divider
        column = Double(SidePanelArrangement.clampColumn(left + delta, available: available) / available)
    }
}

/// 開いている欄の枠を決める。1 つなら全部、2 つなら上下、3 つ以上は幅があれば 2 列（左に多い方）で、狭ければ 1 列で縦に積む。
/// 欄どうしの間は境目の線の幅だけ空ける
enum SidePanelArrangement {
    static func columns(of panels: [SidePanel], width: CGFloat) -> [[SidePanel]] {
        guard panels.count >= 3, width >= SidePanelMetrics.minColumnWidth * 2 + SidePanelMetrics.divider else { return [panels] }
        let left = (panels.count + 1) / 2
        return [Array(panels.prefix(left)), Array(panels.dropFirst(left))]
    }

    static func clampColumn(_ width: CGFloat, available: CGFloat) -> CGFloat {
        min(max(width, SidePanelMetrics.minColumnWidth), available - SidePanelMetrics.minColumnWidth)
    }

    /// `panels` の順の枠
    static func frames(of panels: [SidePanel], in size: CGSize, set: SidePanelSet) -> [CGRect] {
        let gap = SidePanelMetrics.divider
        let columns = columns(of: panels, width: size.width)
        var widths = [size.width]
        if columns.count == 2 {
            let available = size.width - gap
            let left = clampColumn(available * CGFloat(set.column), available: available)
            widths = [left, available - left]
        }
        var frames: [SidePanel: CGRect] = [:]
        var x: CGFloat = 0
        for (column, width) in zip(columns, widths) {
            let available = size.height - gap * CGFloat(column.count - 1)
            let total = column.reduce(0) { $0 + set.weight($1) }
            var y: CGFloat = 0
            for panel in column {
                let height = available * CGFloat(set.weight(panel) / total)
                frames[panel] = CGRect(x: x, y: y, width: width, height: height)
                y += height + gap
            }
            x += width + gap
        }
        return panels.compactMap { frames[$0] }
    }
}

/// 右側の欄を開く知らせ。会話の画面の［状態］［差分］が送り、その会話を出している画面が受ける（`conversation` が nil ならどの画面も受ける）
struct SidePaneRequest: Equatable {
    let panel: SidePanel
    let conversation: ConversationKey?
    /// 開いた欄で上に送る節の id（無ければ送らない）
    var section: String?
    let serial: Int
}

/// 端末の欄の様子。欄は様子があるときだけ出す
enum TerminalDockState: Equatable {
    /// シェルを起こしている。`attempt` は開いた回（閉じてから届いた結果を捨てる）
    case starting(attempt: UUID)
    case shown(TerminalKey)
    /// 起こせなかった。欄にわけと［やり直す］を出す
    case failed(UserFacingError)
}

/// 右の欄と端末の欄。会話の部品（`ConversationView`・`ConversationTopBar`）はここを通して開き、画面（`TaskPanel` など）が欄を出す。
/// 端末の欄は会話ごとに開いている間だけ様子を持ち、タスクの画面は会話と右側の下に、ほかの画面は会話の下に出す
extension AppModel {
    func showSidePane(_ panel: SidePanel, for conversation: ConversationKey? = nil, section: String? = nil) {
        sidePaneRequest = SidePaneRequest(panel: panel, conversation: conversation, section: section, serial: (sidePaneRequest?.serial ?? 0) + 1)
    }

    /// 会話の端末の欄に出すもの
    func terminalDock(for key: ConversationKey) -> TerminalDockState? {
        terminalDocks[key]
    }

    /// 上の帯の［ターミナル］。開いていれば閉じ、閉じていれば開く
    func toggleTerminal(for key: ConversationKey) {
        if terminalDocks[key] == nil { openTerminal(for: key) } else { closeTerminal(of: key) }
    }

    /// 端末の欄を開き、会話の作業フォルダのシェル（生きていれば前と同じシェル）に繋ぐ。開いていればその欄を前に出すだけ
    func openTerminal(for key: ConversationKey) {
        switch terminalDocks[key] {
        case .starting, .shown: return
        case .failed, nil: break
        }
        let attempt = UUID()
        terminalDocks[key] = .starting(attempt: attempt)
        Task {
            let result: TerminalDockState?
            do {
                result = .shown(TerminalKey(machine: key.machine, pane: try await conversationFeed(for: key).shell()))
            } catch {
                result = UserFacingError("シェルを起動できませんでした", error: error).map(TerminalDockState.failed)
            }
            guard terminalDocks[key] == .starting(attempt: attempt) else { return }
            terminalDocks[key] = result
        }
    }

    /// シェルが終わった（exit した）欄を外す。シェルはもう無いので止めない（次に開くと新しいシェル）
    func dropEndedTerminal(_ pane: TerminalKey) {
        for (key, state) in terminalDocks where state == .shown(pane) { terminalDocks[key] = nil }
    }

    /// 端末の欄を閉じ、会話のシェルを止める（次に開くと新しいシェル）
    func closeTerminal(of key: ConversationKey) {
        guard terminalDocks.removeValue(forKey: key) != nil else { return }
        let window = beginAction()
        Task {
            do {
                try await conversationFeed(for: key).stopShell()
            } catch {
                fail("シェルを停止できませんでした", error, in: window)
            }
        }
    }
}

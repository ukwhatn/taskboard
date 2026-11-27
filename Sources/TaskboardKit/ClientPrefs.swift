import Foundation

/// 端末（アプリ）の設定画面の項目のうち、daemon に写して MCP から読み書きできるもの。
/// キーはアプリの UserDefaults のキー（`AppPreferences`）と同じ文字で、変えると保存した値が読めなくなる。
/// 値の意味（既定・知らない値の扱い）はアプリが決め、daemon と MCP は型と範囲だけを確かめる
public enum ClientPref: String, CaseIterable, Codable, Hashable, Sendable {
    case appearance
    case taskPresentation = "task.presentation"
    case onlyMachineEnabled = "onlyMachine.enabled"
    case usageWindows = "usage.windows"
    case docEditorURL = "doc.editorURL"
    case notifyKinds = "notify.kinds"
    case notifyTurns = "notify.turns"
    case notifySound = "notify.sound"
    case chatFontSize = "chat.fontSize"
    case chatCollapseTools = "chat.collapseTools"
    case chatVoiceInput = "chat.voiceInput"
    case chatPreferBuiltInMicrophone = "chat.preferBuiltInMicrophone"
    case terminalFontFamilies = "terminal.fontFamilies"
    case terminalFontSize = "terminal.fontSize"
    case terminalLightTheme = "terminal.theme.light"
    case terminalDarkTheme = "terminal.theme.dark"
    case terminalOptionAsMeta = "terminal.optionAsMeta"
    case terminalBell = "terminal.bell"

    public enum Kind: Hashable, Sendable {
        case bool
        case number(ClosedRange<Double>)
        /// `choices` が空なら任意の文字
        case string(choices: [String])
        /// `choices` が空なら任意の文字の並び
        case strings(choices: [String])
    }

    public static let fontSizeRange = 9.0...28.0

    public var kind: Kind {
        switch self {
        case .appearance: .string(choices: ["system", "light", "dark"])
        case .taskPresentation: .string(choices: ["side", "full", "modal"])
        case .usageWindows: .strings(choices: ["Claude/5h", "Claude/1w", "Codex"])
        case .docEditorURL, .terminalLightTheme, .terminalDarkTheme: .string(choices: [])
        case .notifyKinds: .strings(choices: NotifyKind.allCases.map(\.rawValue))
        case .notifyTurns: .string(choices: TurnNotify.allCases.map(\.rawValue))
        case .chatFontSize, .terminalFontSize: .number(Self.fontSizeRange)
        case .terminalFontFamilies: .strings(choices: [])
        case .onlyMachineEnabled, .notifySound, .chatCollapseTools, .chatVoiceInput, .chatPreferBuiltInMicrophone, .terminalOptionAsMeta, .terminalBell: .bool
        }
    }

    /// 値がこの項目の型と範囲に合うか。合わなければ利用者に見せる理由
    public func problem(_ value: ClientPrefValue) -> String? {
        switch (kind, value) {
        case (.bool, .bool): return nil
        case (.number(let range), .number(let number)):
            return range.contains(number) ? nil : Copy.text("agent.prefs.range", ["key": rawValue, "lower": "\(Int(range.lowerBound))", "upper": "\(Int(range.upperBound))"])
        case (.string(let choices), .string(let text)):
            return choices.isEmpty || choices.contains(text) ? nil : Copy.text("agent.prefs.choices", ["key": rawValue, "choices": choices.joined(separator: " / ")])
        case (.strings(let choices), .strings(let items)):
            let unknown = items.filter { !choices.isEmpty && !choices.contains($0) }
            return unknown.isEmpty ? nil : Copy.text("agent.prefs.choices", ["key": rawValue, "choices": choices.joined(separator: " / ")])
        default:
            return Copy.text("agent.prefs.type", ["key": rawValue])
        }
    }
}

/// 設定の値。JSON はそのままの型（true・14・"dark"・["a","b"]）
public enum ClientPrefValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case strings([String])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else {
            self = .strings(try c.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .strings(let value): try c.encode(value)
        }
    }

    /// 応答に出す形
    public var display: String {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .string(let value): value.isEmpty ? "\"\"" : value
        case .strings(let value): "[" + value.joined(separator: ", ") + "]"
        }
    }
}

/// 1 項目の値と、書いた側（端末か MCP）の時刻。受け取る側は自分の値より新しいときだけ採る
public struct ClientPrefEntry: Codable, Hashable, Sendable {
    public var value: ClientPrefValue
    public var at: Date

    public init(value: ClientPrefValue, at: Date) {
        self.value = value
        self.at = at
    }
}

/// 1 台の端末（アプリ）の設定の写し。`clientID` はアプリが作る id で、ペアリングの `DeviceInfo.id` とは別（この Mac のアプリは daemon の token で接続し、端末の行を持たない）
public struct ClientPrefs: Codable, Hashable, Sendable, Identifiable {
    public var clientID: String
    public var name: String
    public var platform: DevicePlatform
    public var values: [String: ClientPrefEntry]
    /// 端末が最後に報告した時刻
    public var reportedAt: Date

    public var id: String { clientID }

    public init(clientID: String, name: String, platform: DevicePlatform, values: [String: ClientPrefEntry], reportedAt: Date) {
        self.clientID = clientID
        self.name = name
        self.platform = platform
        self.values = values
        self.reportedAt = reportedAt
    }

    /// 項目ごとに新しい方を採る
    public func merging(_ values: [String: ClientPrefEntry]) -> ClientPrefs {
        var merged = self
        for (key, entry) in values where (merged.values[key]?.at ?? .distantPast) < entry.at {
            merged.values[key] = entry
        }
        return merged
    }
}

/// `PUT /v1/clients/{id}/prefs`。端末の報告は名前と種類を付け、MCP の書き込みは省く（今の値を残す）。
/// 応答は重ねた後の `ClientPrefs`（端末はそこから自分より新しい値を採る）
public struct ClientPrefsReport: Codable, Hashable, Sendable {
    public var name: String?
    public var platform: DevicePlatform?
    public var values: [String: ClientPrefEntry]

    public init(name: String? = nil, platform: DevicePlatform? = nil, values: [String: ClientPrefEntry]) {
        self.name = name
        self.platform = platform
        self.values = values
    }
}

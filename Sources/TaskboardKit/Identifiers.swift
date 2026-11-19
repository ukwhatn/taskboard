import Foundation

/// daemon が初回起動時に生成する UUID。会話の id・シェルの id はマシンごとに独立なので、アプリ側は常にこれと組にして扱う。
public struct MachineID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
}

/// 端末の口の id（会話のシェルは `shell-<会話の id>`）。マシンごとに独立で、単独では一意にならない。
public struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// 会話の作業フォルダのシェル（agent host の擬似端末）。端末の口に生の出力が流れる
    public var isConversationShell: Bool { rawValue.hasPrefix("shell-") }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
}

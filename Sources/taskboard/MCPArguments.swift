import MCP

/// tool の引数を型で読む。型が違う値は無いものとして読む
extension [String: Value] {
    func string(_ name: String) -> String? { self[name]?.stringValue }
    func int(_ name: String) -> Int? { self[name]?.intValue }
    func bool(_ name: String) -> Bool? { self[name]?.boolValue }
    func array(_ name: String) -> [Value]? { self[name]?.arrayValue }
    /// 文字列の配列。文字列でない要素は落とす
    func strings(_ name: String) -> [String]? { array(name)?.compactMap(\.stringValue) }
    /// 数か、数字だけの文字列（`"12"`）の id
    func int64(_ name: String) -> Int64? { int(name).map(Int64.init) ?? string(name).flatMap(Int64.init) }
}

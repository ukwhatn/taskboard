import Foundation

/// `JSONSerialization` は object の鍵の順を残さないので、JSON の文から順のある所を読む
public enum JSONKeyOrder {
    /// 上の段の object の `properties` の鍵を書いた順に。読めなければ空
    static func propertyKeys(_ data: Data) -> [String] {
        var scanner = Scanner(bytes: Array(data))
        return (try? scanner.topLevelPropertyKeys()) ?? []
    }

    /// object を `path` の鍵でたどった値の、書いたままの JSON の文（engine の行から `requestedSchema` を順を保って取り出す）。無ければ nil
    public static func value(at path: [String], in data: Data) -> Data? {
        guard !path.isEmpty else { return nil }
        var scanner = Scanner(bytes: Array(data))
        guard let range = try? scanner.range(at: path[...]) else { return nil }
        return Data(scanner.bytes[range])
    }

    private struct Malformed: Error {}

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func range(at path: ArraySlice<String>) throws -> Range<Int>? {
            var found: Range<Int>?
            try object { key, scanner in
                guard found == nil, key == path.first else {
                    try scanner.skipValue()
                    return
                }
                if path.count == 1 {
                    scanner.skipSpace()
                    let start = scanner.index
                    try scanner.skipValue()
                    found = start..<scanner.index
                } else if scanner.peek() == UInt8(ascii: "{") {
                    found = try scanner.range(at: path.dropFirst())
                } else {
                    try scanner.skipValue()
                }
            }
            return found
        }

        mutating func topLevelPropertyKeys() throws -> [String] {
            var keys: [String] = []
            try object { key, scanner in
                if key == "properties" {
                    try scanner.object { inner, scanner in
                        keys.append(inner)
                        try scanner.skipValue()
                    }
                } else {
                    try scanner.skipValue()
                }
            }
            return keys
        }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private mutating func expect(_ byte: UInt8) throws {
            skipSpace()
            guard index < bytes.count, bytes[index] == byte else { throw Malformed() }
            index += 1
        }

        mutating func peek() -> UInt8? {
            skipSpace()
            return index < bytes.count ? bytes[index] : nil
        }

        mutating func object(_ member: (String, inout Scanner) throws -> Void) throws {
            try expect(UInt8(ascii: "{"))
            if peek() == UInt8(ascii: "}") {
                index += 1
                return
            }
            while true {
                let key = try string()
                try expect(UInt8(ascii: ":"))
                try member(key, &self)
                guard let next = peek() else { throw Malformed() }
                index += 1
                if next == UInt8(ascii: "}") { return }
                guard next == UInt8(ascii: ",") else { throw Malformed() }
            }
        }

        private mutating func string() throws -> String {
            skipSpace()
            let start = index
            try expect(UInt8(ascii: "\""))
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw Malformed() }
            index += 1
            // 逃がし（\u など）は JSONSerialization に解かせる
            guard let decoded = try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String else {
                throw Malformed()
            }
            return decoded
        }

        mutating func skipValue() throws {
            switch peek() {
            case UInt8(ascii: "{"):
                try object { _, scanner in try scanner.skipValue() }
            case UInt8(ascii: "["):
                index += 1
                if peek() == UInt8(ascii: "]") {
                    index += 1
                    return
                }
                while true {
                    try skipValue()
                    guard let next = peek() else { throw Malformed() }
                    index += 1
                    if next == UInt8(ascii: "]") { return }
                    guard next == UInt8(ascii: ",") else { throw Malformed() }
                }
            case UInt8(ascii: "\""):
                _ = try string()
            case .some:
                // 数・true・false・null は区切りまで読み飛ばす
                while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                    index += 1
                }
            case nil:
                throw Malformed()
            }
        }
    }
}

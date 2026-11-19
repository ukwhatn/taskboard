import Foundation
import TaskboardKit

/// CLI の起動の引数（定期起動・オーケストレーターの設定・紐づけの記録の `launchArgs`・案件の起動の既定）を会話の項目に読み替える。
/// 会話に渡せない引数が 1 つでもあれば nil（呼ぶ側が TUI で起こす）
public enum ConversationArguments {
    public struct Converted: Equatable, Sendable {
        public var model: String?
        public var effort: String?
        public var permissionMode: String
        /// そのまま CLI に渡す引数（`--settings` など）
        public var extraArgs: [String]
    }

    /// 値を 1 つ取る引数のうち、会話の CLI にそのまま渡すもの
    static let passedWithValue: Set<String> = ["--settings", "--add-dir"]
    /// 続く tool 名を取る引数（次の `-` で始まる引数まで）
    static let passedWithList: Set<String> = ["--disallowedTools", "--disallowed-tools", "--allowedTools", "--allowed-tools"]
    static let maxExtraArgs = 32
    static let maxArgBytes = 4_096

    /// `models` はモデルの名前を確かめる一覧。名前はそのまま返す（そろえるのは起こすときの `ConversationService.validated`）
    public static func convert(_ args: [String], models: ClaudeModels) -> Converted? {
        var model: String?
        var effort: String?
        var mode: String?
        var skip = false
        var extra: [String] = []
        var index = 0
        while index < args.count {
            let (name, inline) = split(args[index])
            index += 1
            func value() -> String? {
                if let inline { return inline }
                guard index < args.count, !args[index].hasPrefix("-") else { return nil }
                defer { index += 1 }
                return args[index]
            }
            switch name {
            case "--dangerously-skip-permissions":
                guard inline == nil else { return nil }
                skip = true
            case "--model":
                guard model == nil, let given = value(), models.argument(for: given) != nil else { return nil }
                model = given
            case "--effort":
                guard effort == nil, let given = value(), Effort(rawValue: given) != nil else { return nil }
                effort = given
            case "--permission-mode":
                guard mode == nil, let given = value(), ConversationInput.acceptedPermissionModes.contains(given) else { return nil }
                mode = given
            case _ where passedWithValue.contains(name):
                guard let given = value(), given.hasPrefix("/") else { return nil }
                if name == "--settings", !FileManager.default.fileExists(atPath: given) { return nil }
                extra += [name, given]
            case _ where passedWithList.contains(name):
                var names: [String] = inline.map { [$0] } ?? []
                while index < args.count, !args[index].hasPrefix("-") {
                    names.append(args[index])
                    index += 1
                }
                guard !names.isEmpty else { return nil }
                extra += [name] + names
            default:
                return nil
            }
        }
        guard extra.count <= maxExtraArgs, extra.allSatisfy({ $0.utf8.count <= maxArgBytes }) else { return nil }
        // `--dangerously-skip-permissions` は `--permission-mode` より強い（2.1.302 で、順に関わらず bypassPermissions になった）
        return Converted(model: model, effort: effort, permissionMode: skip ? "bypassPermissions" : mode ?? "default", extraArgs: extra)
    }

    /// 記録の `extraArgs` が、`convert` が作れる形か（API と記録の読み直しで確かめる）。`--model` は extraArgs に残らないので、控えの一覧で読む
    static func acceptsExtra(_ args: [String]) -> Bool {
        guard let converted = convert(args, models: ClaudeModels(nil)) else { return false }
        return converted.extraArgs == args
    }

    private static func split(_ arg: String) -> (String, String?) {
        guard arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") else { return (arg, nil) }
        return (String(arg[..<equals]), String(arg[arg.index(after: equals)...]))
    }
}

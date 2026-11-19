import Foundation

/// 部品の中身の量の予算。超えた登録は daemon が誤りで返す（黙って切らない）。値は docs/daemon.md「概況の部品」と同じ。場所ごとの数は `PanelPlace.limit`
public enum PanelBudget {
    public static let columns = 5
    public static let cellChars = 20
    public static let rows = 50
    /// 画面に出す行。超えた分は「ほか N 件」に折りたたむ
    public static let shownRows = 8
    public static let labelChars = 40
    public static let valueChars = 20
    public static let titleChars = 60
    public static let noteChars = 120
    public static let series = 4
    public static let points = 50
    public static let nodes = 12
    public static let edges = 20
    public static let draftToChars = 200
    public static let draftBodyChars = 4_000
    public static let checks = 8
    public static let htmlChars = 20_000
    public static let idChars = 40
    /// 会話が更新しないまま、このターン数を過ぎた部品は時刻を補足の色で出す
    public static let staleTurns = 2
}

/// 予算と書式から外れた登録。`message` は会話へ返す文
public struct PanelInvalid: Error, Hashable, Sendable {
    public var message: String

    init(_ message: String) {
        self.message = message
    }
}

/// 概況の登録の検証。daemon の書き込みの入口（`Store.setPanel`・`Store.updatePanelPart`）が、置き換えた後の部品の全部に 1 回だけ当てる
public enum PanelValidation {
    /// 守られていなければ `PanelInvalid` を投げる。受け付けたうえで返す注意を返す
    public static func check(_ parts: [PanelPartSpec]) throws -> [String] {
        var seen = Set<String>()
        for part in parts {
            guard isValidID(part.id) else { throw PanelInvalid(Copy.text("agent.panel.invalid.id", ["id": part.id, "limit": "\(PanelBudget.idChars)"])) }
            guard seen.insert(part.id).inserted else { throw PanelInvalid(Copy.text("agent.panel.invalid.duplicate", ["id": part.id])) }
            try place(part)
        }
        for place in PanelPlace.allCases {
            let count = parts.filter { $0.place == place }.count
            guard count <= place.limit else {
                throw PanelInvalid(Copy.text("agent.panel.invalid.place.count", ["place": place.rawValue, "count": "\(count)", "limit": "\(place.limit)"]))
            }
        }
        var warnings: [String] = []
        for part in parts { warnings += try check(part) }
        return warnings
    }

    /// 場所が受ける種類か。外れたら、その種類を受ける場所を添えて返す（place を省いた登録は head になるため）
    private static func place(_ part: PanelPartSpec) throws {
        let kind = part.content.kind
        guard !part.place.kinds.contains(kind) else { return }
        let fits = PanelPlace.allCases.filter { $0.kinds.contains(kind) }.map(\.rawValue).joined(separator: "・")
        throw PanelInvalid(
            Copy.text(
                "agent.panel.invalid.place.kind",
                ["id": part.id, "place": part.place.rawValue, "kinds": part.place.kinds.map(\.rawValue).joined(separator: "・"), "kind": kind.rawValue, "fits": fits]))
    }

    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= PanelBudget.idChars
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    private static func check(_ part: PanelPartSpec) throws -> [String] {
        let id = part.id
        if let bind = part.bind {
            let allowed: [PanelContent.Kind] = [.gauge, .table, .plan]
            guard allowed.contains(part.content.kind) else {
                throw PanelInvalid(Copy.text("agent.panel.invalid.bind", ["id": id, "kind": part.content.kind.rawValue]))
            }
            if case .plan = part.content, bind.source != .work {
                throw PanelInvalid(Copy.text("agent.panel.invalid.bind.plan", ["id": id, "source": bind.source.rawValue]))
            }
        }
        var warnings: [String] = []
        switch part.content {
        case .gauge(let gauge):
            try text(gauge.label, "label", id, limit: PanelBudget.labelChars, required: true)
            try text(gauge.value, "value", id, limit: PanelBudget.valueChars, required: part.bind == nil)
            try text(gauge.note, "note", id, limit: PanelBudget.noteChars)
            if let basis = gauge.basis { try text(basis.value, "basis.value", id, limit: PanelBudget.valueChars, required: true) }
            if part.bind != nil, !gauge.value.isEmpty { warnings.append(Copy.text("agent.panel.warning.bindValue", ["id": id])) }
        case .table(let table):
            try text(table.title, "title", id, limit: PanelBudget.titleChars, required: true)
            guard table.columns.count <= PanelBudget.columns else {
                throw PanelInvalid(Copy.text("agent.panel.invalid.columns", ["id": id, "count": "\(table.columns.count)", "limit": "\(PanelBudget.columns)"]))
            }
            for column in table.columns { try cell(column, id) }
            guard table.rows.count <= PanelBudget.rows else {
                throw PanelInvalid(Copy.text("agent.panel.invalid.rows", ["id": id, "count": "\(table.rows.count)", "limit": "\(PanelBudget.rows)"]))
            }
            if part.bind == nil {
                guard !table.columns.isEmpty else { throw PanelInvalid(Copy.text("agent.panel.invalid.empty", ["id": id, "field": "columns"])) }
            } else if !table.rows.isEmpty {
                warnings.append(Copy.text("agent.panel.warning.bindRows", ["id": id]))
            }
            for row in table.rows {
                guard row.cells.count <= max(table.columns.count, 1) else {
                    throw PanelInvalid(Copy.text("agent.panel.invalid.cells", ["id": id, "count": "\(row.cells.count)", "columns": "\(table.columns.count)"]))
                }
                for value in row.cells { try cell(value, id) }
                try target(row.open, id)
            }
        case .plan(let plan):
            try text(plan.title, "title", id, limit: PanelBudget.titleChars)
            for group in plan.groups { try text(group, "groups", id, limit: PanelBudget.cellChars, required: true) }
        case .diagram(let diagram):
            try text(diagram.title, "title", id, limit: PanelBudget.titleChars)
            guard !diagram.nodes.isEmpty else { throw PanelInvalid(Copy.text("agent.panel.invalid.empty", ["id": id, "field": "nodes"])) }
            guard diagram.nodes.count <= PanelBudget.nodes else {
                throw PanelInvalid(Copy.text("agent.panel.invalid.nodes", ["id": id, "count": "\(diagram.nodes.count)", "limit": "\(PanelBudget.nodes)"]))
            }
            for node in diagram.nodes {
                try text(node.label, "nodes.label", id, limit: PanelBudget.labelChars, required: true)
                try text(node.note, "nodes.note", id, limit: PanelBudget.noteChars)
                try text(node.at, "nodes.at", id, limit: PanelBudget.cellChars)
                try target(node.open, id)
            }
            switch diagram.style {
            case .compare:
                guard !diagram.columns.isEmpty, diagram.columns.count <= PanelBudget.columns else {
                    throw PanelInvalid(Copy.text("agent.panel.invalid.columns", ["id": id, "count": "\(diagram.columns.count)", "limit": "\(PanelBudget.columns)"]))
                }
                for column in diagram.columns { try cell(column, id) }
                for node in diagram.nodes {
                    guard node.values.count == diagram.columns.count else {
                        throw PanelInvalid(Copy.text("agent.panel.invalid.values", ["id": id, "label": node.label, "columns": "\(diagram.columns.count)"]))
                    }
                    for value in node.values { try cell(value, id) }
                }
            case .relation:
                guard diagram.edges.count <= PanelBudget.edges else {
                    throw PanelInvalid(Copy.text("agent.panel.invalid.edges", ["id": id, "count": "\(diagram.edges.count)", "limit": "\(PanelBudget.edges)"]))
                }
                let names = Set(diagram.nodes.map { $0.id.isEmpty ? $0.label : $0.id })
                for edge in diagram.edges {
                    for name in [edge.from, edge.to] where !names.contains(name) {
                        throw PanelInvalid(Copy.text("agent.panel.invalid.edge", ["id": id, "name": name]))
                    }
                    try text(edge.label, "edges.label", id, limit: PanelBudget.cellChars)
                }
            case .flow, .timeline:
                break
            }
        case .chart(let chart):
            try text(chart.title, "title", id, limit: PanelBudget.titleChars, required: true)
            try text(chart.unit, "unit", id, limit: PanelBudget.cellChars)
            try text(chart.targetLabel, "target_label", id, limit: PanelBudget.cellChars)
            guard !chart.series.isEmpty else { throw PanelInvalid(Copy.text("agent.panel.invalid.empty", ["id": id, "field": "series"])) }
            guard chart.series.count <= PanelBudget.series else {
                throw PanelInvalid(Copy.text("agent.panel.invalid.series", ["id": id, "count": "\(chart.series.count)", "limit": "\(PanelBudget.series)"]))
            }
            let points = chart.series.map(\.points.count).reduce(0, +)
            guard points <= PanelBudget.points else {
                throw PanelInvalid(Copy.text("agent.panel.invalid.points", ["id": id, "count": "\(points)", "limit": "\(PanelBudget.points)"]))
            }
            for series in chart.series {
                try text(series.name, "series.name", id, limit: PanelBudget.cellChars)
                for point in series.points {
                    try cell(point.x, id)
                    guard point.y.isFinite else { throw PanelInvalid(Copy.text("agent.panel.invalid.number", ["id": id, "x": point.x])) }
                }
            }
        case .draft(let draft):
            try check(draft, id: id)
        case .html(let html):
            try text(html.title, "title", id, limit: PanelBudget.titleChars)
            try text(html.html, "html", id, limit: PanelBudget.htmlChars, required: true)
            warnings += try PanelHTMLCheck.check(html.html, id: id)
        }
        return warnings
    }

    /// 送る文面の欄の予算（概況の部品と文書の `drafts` で同じ）
    public static func check(_ draft: PanelDraft, id: String) throws {
        try text(draft.title, "title", id, limit: PanelBudget.titleChars)
        try text(draft.to, "to", id, limit: PanelBudget.draftToChars, required: true)
        try text(draft.body, "body", id, limit: PanelBudget.draftBodyChars, required: true)
        guard draft.checks.count <= PanelBudget.checks else {
            throw PanelInvalid(Copy.text("agent.panel.invalid.checks", ["id": id, "count": "\(draft.checks.count)", "limit": "\(PanelBudget.checks)"]))
        }
        for check in draft.checks {
            try text(check.label, "checks.label", id, limit: PanelBudget.cellChars, required: true)
            try text(check.note, "checks.note", id, limit: PanelBudget.noteChars)
        }
    }

    private static func text(_ value: String, _ field: String, _ id: String, limit: Int, required: Bool = false) throws {
        if required, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PanelInvalid(Copy.text("agent.panel.invalid.empty", ["id": id, "field": field]))
        }
        guard value.count <= limit else {
            throw PanelInvalid(Copy.text("agent.panel.invalid.text", ["id": id, "field": field, "count": "\(value.count)", "limit": "\(limit)"]))
        }
    }

    private static func cell(_ value: String, _ id: String) throws {
        guard value.count <= PanelBudget.cellChars, !value.contains("\n") else {
            throw PanelInvalid(Copy.text("agent.panel.invalid.cell", ["id": id, "text": String(value.prefix(30)), "limit": "\(PanelBudget.cellChars)"]))
        }
    }

    private static func target(_ target: PanelTarget?, _ id: String) throws {
        guard let target else { return }
        let given = [target.task != nil, target.doc != nil, target.url != nil].filter { $0 }.count
        let urlOK = target.url.map { $0.hasPrefix("https://") || $0.hasPrefix("http://") || $0.hasPrefix("taskboard://") } ?? true
        guard given == 1, urlOK else { throw PanelInvalid(Copy.text("agent.panel.invalid.target", ["id": id])) }
    }
}

/// 自由の部品の HTML の検査。script と外部の読み込みは誤り、色と余白を直接書いた箇所は注意
public enum PanelHTMLCheck {
    static func check(_ html: String, id: String) throws -> [String] {
        if let found = first(html, scriptPatterns) { throw PanelInvalid(Copy.text("agent.panel.invalid.html.script", ["id": id, "found": found])) }
        if let found = first(html, externalPatterns) { throw PanelInvalid(Copy.text("agent.panel.invalid.html.external", ["id": id, "found": found])) }
        var warnings: [String] = []
        // 本文の「#172」を色と読まないよう、style の属性と要素、色の属性の中だけを見る
        let styles = all(html, stylePatterns).joined(separator: "\n")
        let colors = all(styles, colorPatterns)
        if !colors.isEmpty { warnings.append(Copy.text("agent.panel.warning.html.color", ["id": id, "found": colors.prefix(3).joined(separator: "、")])) }
        let spacing = all(styles, spacingPatterns)
        if !spacing.isEmpty { warnings.append(Copy.text("agent.panel.warning.html.spacing", ["id": id, "found": spacing.prefix(3).joined(separator: "、")])) }
        return warnings
    }

    private static let scriptPatterns = [#"<\s*script\b"#, #"\son[a-z]+\s*="#, #"javascript\s*:"#]
    private static let externalPatterns = [
        #"<\s*(link|iframe|frame|object|embed|base|portal)\b"#, #"<\s*meta[^>]+http-equiv"#, #"@import\b"#,
        #"\b(src|srcset|poster|background|data|action|formaction)\s*=\s*["']?\s*(https?:|//)"#, #"url\(\s*["']?\s*(https?:|//)"#,
    ]
    private static let stylePatterns = [#"\bstyle\s*=\s*"[^"]*""#, #"\bstyle\s*=\s*'[^']*'"#, #"<\s*style[^>]*>[\s\S]*?<\s*/\s*style\s*>"#, #"\b(bg)?color\s*=\s*["']?[^"'\s>]+"#]
    private static let colorPatterns = [#"#[0-9a-fA-F]{3,8}\b"#, #"\b(rgba?|hsla?)\s*\("#]
    private static let spacingPatterns = [#"\b(margin|padding|gap)[a-z-]*\s*:\s*[^;"'}]*\d+(\.\d+)?(px|pt|rem|em)"#]

    private static func first(_ html: String, _ patterns: [String]) -> String? {
        for pattern in patterns {
            if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { return String(html[range]) }
        }
        return nil
    }

    private static func all(_ html: String, _ patterns: [String]) -> [String] {
        var found: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                if let range = Range(match.range, in: html) { found.append(String(html[range])) }
            }
        }
        return Array(NSOrderedSet(array: found).array as? [String] ?? found)
    }
}

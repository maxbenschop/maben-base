import Foundation

/// A SQL token. Strings, quoted names, comments and dollar-quoted bodies are kept whole.
public struct SQLToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case word, quoted, string, number, comment, op, open, close, comma, semicolon, dot, param, space }
    public var kind: Kind
    public var text: String
    /// UTF-16 offset in the source.
    public var offset: Int
}

public enum SQLLexer {
    public static func tokens(_ sql: String) -> [SQLToken] {
        let u = Array(sql.utf16)
        let n = u.count
        var out: [SQLToken] = []
        var i = 0
        func text(_ a: Int, _ b: Int) -> String { String(utf16CodeUnits: Array(u[a..<b]), count: b - a) }
        func isWordChar(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c >= 128
        }
        while i < n {
            let c = u[i]
            let start = i
            func emit(_ k: SQLToken.Kind) { out.append(SQLToken(kind: k, text: text(start, i), offset: start)) }
            switch c {
            case 32, 9, 10, 13:
                while i < n, [32, 9, 10, 13].contains(u[i]) { i += 1 }
                emit(.space)
            case 39:  // 'string'
                i += 1
                while i < n {
                    if u[i] == 39 { if i + 1 < n && u[i + 1] == 39 { i += 2; continue }; i += 1; break }
                    if u[i] == 92 && i + 1 < n { i += 2; continue }
                    i += 1
                }
                emit(.string)
            case 34, 96:  // "name" `name`
                i += 1
                while i < n { if u[i] == c { if i + 1 < n && u[i + 1] == c { i += 2; continue }; i += 1; break }; i += 1 }
                emit(.quoted)
            case 45 where i + 1 < n && u[i + 1] == 45, 35:  // -- comment, # comment
                while i < n && u[i] != 10 { i += 1 }
                emit(.comment)
            case 47 where i + 1 < n && u[i + 1] == 42:  // /* */
                i += 2
                while i + 1 < n && !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
                i = min(n, i + 2)
                emit(.comment)
            case 36:  // $tag$ … $tag$ or $1
                var j = i + 1
                while j < n && isWordChar(u[j]) && u[j] != 36 { j += 1 }
                if j < n && u[j] == 36 {
                    let tag = Array(u[i...j])
                    var k = j + 1
                    while k + tag.count <= n && Array(u[k..<k + tag.count]) != tag { k += 1 }
                    i = min(n, k + tag.count)
                    emit(.string)
                } else {
                    i = j
                    emit(.param)
                }
            case 58:  // :name parameter, :: cast, := assignment
                if i + 1 < n && (u[i + 1] == 58 || u[i + 1] == 61) {
                    i += 2
                    emit(.op)
                } else if i + 1 < n && isWordChar(u[i + 1]) && !(u[i + 1] >= 48 && u[i + 1] <= 57) {
                    i += 1
                    while i < n && isWordChar(u[i]) { i += 1 }
                    emit(.param)
                } else {
                    i += 1
                    emit(.op)
                }
            case 40: i += 1; emit(.open)
            case 41: i += 1; emit(.close)
            case 44: i += 1; emit(.comma)
            case 59: i += 1; emit(.semicolon)
            case 46 where !(i + 1 < n && u[i + 1] >= 48 && u[i + 1] <= 57): i += 1; emit(.dot)
            case 48...57, 46:
                while i < n && ((u[i] >= 48 && u[i] <= 57) || u[i] == 46 || u[i] == 101 || u[i] == 69
                                || ((u[i] == 43 || u[i] == 45) && (u[i - 1] == 101 || u[i - 1] == 69))) { i += 1 }
                emit(.number)
            default:
                if isWordChar(c) {
                    while i < n && isWordChar(u[i]) { i += 1 }
                    emit(.word)
                } else {
                    i += 1
                    // Two-character operators.
                    if i < n, let pair = String(utf16CodeUnits: [c, u[i]], count: 2) as String?,
                       ["<=", ">=", "<>", "!=", "||", "->", "#>", "@>", "<@", "&&"].contains(pair) {
                        i += 1
                        if pair == "->" || pair == "#>", i < n, u[i] == 62 { i += 1 }  // ->> #>>
                    }
                    emit(.op)
                }
            }
        }
        return out
    }
}

// MARK: - Formatting

public enum SQLFormatter {
    static let clauses: [[String]] = [
        ["select"], ["from"], ["where"], ["group", "by"], ["order", "by"], ["having"], ["limit"], ["offset"],
        ["union", "all"], ["union"], ["except"], ["intersect"], ["values"], ["set"], ["returning"], ["window"],
        ["insert", "into"], ["update"], ["delete", "from"], ["with"], ["on", "conflict"], ["fetch"], ["for", "update"],
    ]
    static let joinWords: Set<String> = ["join", "left", "right", "full", "inner", "outer", "cross", "natural", "lateral"]
    static let breakingList: Set<String> = ["select", "set", "returning"]
    static let spaceBeforeParen: Set<String> = ["in", "values", "as", "on", "using", "and", "or", "not", "exists", "from", "join",
                                                "into", "where", "any", "all", "some", "then", "else", "when", "over", "filter"]

    /// Reformats SQL: keywords in capitals, one clause per line, select lists and AND/OR conditions on their own lines,
    /// subqueries indented. Strings, names and comments stay exactly as they were.
    public static func format(_ sql: String) -> String {
        let keywords = Set(SQLText.keywords.map { $0.lowercased() }).union(joinWords)
            .union(["into", "conflict", "do", "nothing", "by", "is", "between", "like", "ilike", "asc", "desc", "nulls", "last", "first"])
        let tokens = SQLLexer.tokens(sql).filter { $0.kind != .space }
        struct Frame { var indent: Int; var openedAt: Int; var subquery: Bool; var clause = ""; var breakList = false }
        var stack = [Frame(indent: 0, openedAt: 0, subquery: false)]
        var lines: [String] = []
        var line = ""
        var lineIndent = 0
        var prev: SQLToken?
        let pad = "  "

        func newline(_ level: Int) {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
            lineIndent = max(0, level)
            line = String(repeating: pad, count: lineIndent)
        }
        func append(_ s: String, space: Bool) {
            let atStart = line.trimmingCharacters(in: .whitespaces).isEmpty
            if space && !atStart { line += " " }
            line += s
        }
        func lower(_ t: SQLToken) -> String { t.kind == .word ? t.text.lowercased() : "" }
        func clauseAt(_ i: Int) -> [String]? {
            for c in clauses where i + c.count <= tokens.count {
                if zip(c, tokens[i..<i + c.count]).allSatisfy({ $0 == lower($1) }) { return c }
            }
            return nil
        }
        /// Whether the list starting at i has commas at its own depth before the clause ends.
        func listHasCommas(from i: Int) -> Bool {
            var depth = 0
            var j = i
            while j < tokens.count {
                let t = tokens[j]
                if t.kind == .open { depth += 1 }
                else if t.kind == .close { if depth == 0 { return false }; depth -= 1 }
                else if t.kind == .semicolon { return false }
                else if depth == 0 && t.kind == .comma { return true }
                else if depth == 0 && clauseAt(j) != nil { return false }
                j += 1
            }
            return false
        }
        func spaceBefore(_ t: SQLToken) -> Bool {
            guard let p = prev else { return false }
            if p.kind == .dot || p.kind == .open || p.text == "::" { return false }
            if [.comma, .semicolon, .close, .dot].contains(t.kind) || t.text == "::" { return false }
            if t.kind == .open, stack.last?.clause == "insert into", p.kind == .word || p.kind == .quoted { return true }
            if t.kind == .open, p.kind == .word {
                let w = p.text.lowercased()
                return spaceBeforeParen.contains(w) || clauses.contains { $0.last == w }
            }
            return true
        }

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            let top = stack.count - 1
            let base = stack[top].indent
            if let c = clauseAt(i) {
                let name = c.joined(separator: " ")
                newline(base)
                append(c.map { $0.uppercased() }.joined(separator: " "), space: false)
                stack[top].clause = name
                stack[top].breakList = false
                i += c.count
                prev = tokens[i - 1]
                if breakingList.contains(name) {
                    if i < tokens.count, ["distinct", "all"].contains(lower(tokens[i])) {
                        append(tokens[i].text.uppercased(), space: true)
                        prev = tokens[i]
                        i += 1
                    }
                    if listHasCommas(from: i) {
                        stack[top].breakList = true
                        newline(base + 1)
                        prev = nil
                    }
                }
                continue
            }
            let w = lower(t)
            let clause = stack[top].clause
            switch t.kind {
            case .word where joinWords.contains(w) && !(prev.map { joinWords.contains(lower($0)) } ?? false) && w != "lateral":
                newline(base)
                append(t.text.uppercased(), space: false)
            case .word where (w == "and" || w == "or") && ["where", "having"].contains(clause) && !inBetween(tokens, i):
                newline(base + 1)
                append(t.text.uppercased(), space: false)
            case .comma:
                append(",", space: false)
                if stack[top].breakList { newline(base + 1); prev = nil; i += 1; continue }
            case .open:
                let isSub = i + 1 < tokens.count && ["select", "with"].contains(lower(tokens[i + 1]))
                append("(", space: spaceBefore(t))
                stack.append(Frame(indent: isSub ? lineIndent + 1 : base, openedAt: lineIndent, subquery: isSub))
            case .close:
                let frame = stack.count > 1 ? stack.removeLast() : stack[0]
                if frame.subquery { newline(frame.openedAt) }
                append(")", space: false)
            case .semicolon:
                append(";", space: false)
                lines.append(line)
                lines.append("")
                line = ""
                lineIndent = 0
                stack = [Frame(indent: 0, openedAt: 0, subquery: false)]
                prev = nil
                i += 1
                continue
            case .comment:
                append(t.text, space: spaceBefore(t))
                if t.text.hasPrefix("--") || t.text.hasPrefix("#") { newline(lineIndent); prev = nil; i += 1; continue }
            case .word:
                append(keywords.contains(w) ? t.text.uppercased() : t.text, space: spaceBefore(t))
            default:
                append(t.text, space: spaceBefore(t))
            }
            prev = t
            i += 1
        }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n") + "\n"
    }

    private static func inBetween(_ tokens: [SQLToken], _ i: Int) -> Bool {
        // `x BETWEEN a AND b`: the AND two or three tokens after BETWEEN belongs to it.
        var j = i - 1
        var steps = 0
        while j >= 0 && steps < 6 {
            let w = tokens[j].kind == .word ? tokens[j].text.lowercased() : ""
            if w == "between" { return true }
            if w == "and" || w == "or" { return false }
            j -= 1
            steps += 1
        }
        return false
    }
}

// MARK: - Parameters and aliases

extension SQLText {
    /// Named parameters like :customer_id, in order of first use. Casts (::int) and strings are skipped.
    public static func parameters(in sql: String) -> [String] {
        var seen = Set<String>()
        return SQLLexer.tokens(sql).filter { $0.kind == .param && $0.text.hasPrefix(":") }
            .map { String($0.text.dropFirst()) }
            .filter { seen.insert($0).inserted }
    }

    /// Puts values in for :name parameters. Numbers and NULL go in as they are, anything else as a quoted string.
    /// A value starting with = is used as raw SQL (=now()).
    public static func bind(_ sql: String, values: [String: String], dialect: Dialect) -> String {
        var out = ""
        for t in SQLLexer.tokens(sql) {
            if t.kind == .param, t.text.hasPrefix(":"), let v = values[String(t.text.dropFirst())] {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if trimmed.uppercased() == "NULL" { out += "NULL" }
                else if trimmed.hasPrefix("=") { out += String(trimmed.dropFirst()) }
                else if Double(trimmed) != nil, !trimmed.isEmpty, !trimmed.hasPrefix("0") || trimmed == "0" || trimmed.hasPrefix("0.") { out += trimmed }
                else { out += dialect.literal(v) }
            } else {
                out += t.text
            }
        }
        return out
    }

    /// Tables named in FROM, JOIN, UPDATE and INTO, by alias and by name (both lowercased) → table name.
    public static func tableAliases(in sql: String) -> [String: String] {
        let tokens = SQLLexer.tokens(sql).filter { $0.kind != .space && $0.kind != .comment }
        let reserved = Set(keywords.map { $0.lowercased() }).union(SQLFormatter.joinWords)
        var out: [String: String] = [:]
        func unquote(_ t: SQLToken) -> String {
            t.kind == .quoted ? String(t.text.dropFirst().dropLast()) : t.text
        }
        var i = 0
        var depth = 0
        var fromDepth: Int?   // paren depth of the FROM list we're in
        while i < tokens.count {
            let w = tokens[i].kind == .word ? tokens[i].text.lowercased() : ""
            if tokens[i].kind == .open { depth += 1 }
            if tokens[i].kind == .close { depth -= 1; if let f = fromDepth, depth < f { fromDepth = nil } }
            let starts = ["from", "join", "update", "into"].contains(w)
            let continues = fromDepth == depth && tokens[i].kind == .comma
            if w == "from" { fromDepth = depth }
            else if fromDepth == depth, ["where", "group", "order", "having", "limit", "union", "select", "returning"].contains(w) || tokens[i].kind == .semicolon { fromDepth = nil }
            if (starts || continues), i + 1 < tokens.count, [.word, .quoted].contains(tokens[i + 1].kind),
               !(tokens[i + 1].kind == .word && reserved.contains(tokens[i + 1].text.lowercased()) && tokens[i + 1].text.lowercased() != "lateral") {
                var j = i + 1
                var name = unquote(tokens[j])
                while j + 2 < tokens.count, tokens[j + 1].kind == .dot, [.word, .quoted].contains(tokens[j + 2].kind) {
                    name = unquote(tokens[j + 2])
                    j += 2
                }
                out[name.lowercased()] = name
                var k = j + 1
                if k < tokens.count, tokens[k].kind == .word, tokens[k].text.lowercased() == "as" { k += 1 }
                if k < tokens.count, [.word, .quoted].contains(tokens[k].kind),
                   !(tokens[k].kind == .word && reserved.contains(tokens[k].text.lowercased())) {
                    out[unquote(tokens[k]).lowercased()] = name
                }
                i = j
            }
            i += 1
        }
        return out
    }
}

// MARK: - Snippets

public enum SnippetText {
    public struct Expanded: Equatable {
        public var text: String
        /// Placeholder ranges (UTF-16, relative to the start) in the order Tab visits them; the last is $0 or the end.
        public var stops: [NSRange]
    }

    /// Expands `${1:default}`, `${2}`, `$1` and `$0`. Indentation of the first line is repeated on following lines.
    public static func expand(_ body: String, indent: String = "") -> Expanded {
        let source = body.replacingOccurrences(of: "\n", with: "\n" + indent)
        var out = ""
        var stops: [(Int, NSRange)] = []
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            if c == "$", let next = source.index(i, offsetBy: 1, limitedBy: source.endIndex), next < source.endIndex {
                if source[next] == "{", let close = source[next...].firstIndex(of: "}") {
                    let inner = source[source.index(after: next)..<close]
                    let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    if let n = Int(parts[0]) {
                        let text = parts.count > 1 ? String(parts[1]) : ""
                        let start = (out as NSString).length
                        out += text
                        stops.append((n, NSRange(location: start, length: (text as NSString).length)))
                        i = source.index(after: close)
                        continue
                    }
                } else if let digit = source[next].wholeNumberValue {
                    stops.append((digit, NSRange(location: (out as NSString).length, length: 0)))
                    i = source.index(after: next)
                    continue
                }
            }
            out.append(c)
            i = source.index(after: i)
        }
        var ordered = stops.filter { $0.0 > 0 }.sorted { $0.0 < $1.0 }.map(\.1)
        ordered.append(stops.first { $0.0 == 0 }?.1 ?? NSRange(location: (out as NSString).length, length: 0))
        return Expanded(text: out, stops: ordered)
    }

    public static let builtIn: [Store.Snippet] = [
        .init(trigger: "sel", name: "Select rows", body: "SELECT ${2:*}\nFROM ${1:table}\nWHERE ${3:true}\nLIMIT ${4:100};$0"),
        .init(trigger: "selc", name: "Count rows", body: "SELECT COUNT(*)\nFROM ${1:table}\nWHERE ${2:true};$0"),
        .init(trigger: "selg", name: "Group and count", body: "SELECT ${2:column}, COUNT(*)\nFROM ${1:table}\nGROUP BY 1\nORDER BY 2 DESC;$0"),
        .init(trigger: "join", name: "Join", body: "JOIN ${1:table} ON ${2:condition}$0"),
        .init(trigger: "ins", name: "Insert a row", body: "INSERT INTO ${1:table} (${2:columns})\nVALUES (${3:values});$0"),
        .init(trigger: "upd", name: "Update rows", body: "UPDATE ${1:table}\nSET ${2:column} = ${3:value}\nWHERE ${4:id = 1};$0"),
        .init(trigger: "del", name: "Delete rows", body: "DELETE FROM ${1:table}\nWHERE ${2:id = 1};$0"),
        .init(trigger: "cte", name: "WITH query", body: "WITH recent AS (\n  ${1:SELECT 1}\n)\nSELECT *\nFROM recent;$0"),
        .init(trigger: "ct", name: "Create table", body: "CREATE TABLE ${1:name} (\n  id ${2:bigint} PRIMARY KEY,\n  ${3:column} ${4:text}$0\n);"),
        .init(trigger: "idx", name: "Create index", body: "CREATE INDEX ${1:name} ON ${2:table} (${3:column});$0"),
        .init(trigger: "case", name: "CASE expression", body: "CASE WHEN ${1:condition} THEN ${2:value} ELSE ${3:other} END$0"),
    ]
}

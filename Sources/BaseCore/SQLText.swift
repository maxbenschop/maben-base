import Foundation

/// Reading SQL text: where statements start and end, and what kind they are.
public enum SQLText {
    /// The statements in a script with their ranges (UTF-16 offsets, for NSTextView), split on semicolons
    /// outside strings, quoted names, comments and Postgres dollar quotes.
    public static func statements(in text: String) -> [(range: NSRange, sql: String)] {
        let chars = Array(text.utf16)
        var out: [(NSRange, String)] = []
        var start = 0
        var i = 0
        let n = chars.count
        func emit(_ end: Int) {
            let range = NSRange(location: start, length: end - start)
            let sql = (text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sql.isEmpty && !isOnlyComments(sql) { out.append((range, sql)) }
        }
        while i < n {
            let c = chars[i]
            switch c {
            case 0x27, 0x22, 0x60:  // ' " `
                i += 1
                while i < n {
                    if chars[i] == c {
                        if i + 1 < n && chars[i + 1] == c { i += 2; continue }
                        break
                    }
                    if c == 0x27 && chars[i] == 0x5C && i + 1 < n { i += 2; continue }  // backslash escape (MySQL)
                    i += 1
                }
                i += 1
            case 0x2D where i + 1 < n && chars[i + 1] == 0x2D:  // --
                while i < n && chars[i] != 0x0A { i += 1 }
            case 0x23:  // # comment (MySQL)
                while i < n && chars[i] != 0x0A { i += 1 }
            case 0x2F where i + 1 < n && chars[i + 1] == 0x2A:  // /* */
                i += 2
                while i + 1 < n && !(chars[i] == 0x2A && chars[i + 1] == 0x2F) { i += 1 }
                i += 2
            case 0x24:  // $tag$ … $tag$
                var j = i + 1
                while j < n, let s = Unicode.Scalar(chars[j]), CharacterSet.alphanumerics.contains(s) || chars[j] == 0x5F { j += 1 }
                if j < n && chars[j] == 0x24 {
                    let tag = Array(chars[i...j])
                    var k = j + 1
                    while k + tag.count <= n && Array(chars[k..<k + tag.count]) != tag { k += 1 }
                    i = min(n, k + tag.count)
                } else {
                    i += 1
                }
            case 0x3B:  // ;
                emit(i)
                i += 1
                start = i
            default:
                i += 1
            }
        }
        emit(n)
        return out
    }

    /// The statement the cursor is in (or right after).
    public static func statement(at location: Int, in text: String) -> (range: NSRange, sql: String)? {
        let all = statements(in: text)
        if let hit = all.first(where: { location >= $0.range.location && location <= NSMaxRange($0.range) }) { return hit }
        return all.last(where: { $0.range.location <= location }) ?? all.first
    }

    static func isOnlyComments(_ sql: String) -> Bool {
        var rest = Substring(sql)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            if rest.isEmpty { return true }
            if rest.hasPrefix("--") || rest.hasPrefix("#") {
                rest = rest.drop(while: { $0 != "\n" })
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return true }
                rest = rest[end.upperBound...]
            } else {
                return false
            }
        }
    }

    // MARK: Reading or writing

    /// True unless everything in the text is known to only read. Read-only connections refuse what this
    /// calls a write, and the other safe modes ask first, so the answer leans one way on purpose: a
    /// statement the app doesn't recognise is a write. (The old check listed the writes it knew, and let
    /// through CALL, MERGE, COPY, SELECT … INTO, and every Redis and MongoDB command.)
    public static func isWrite(_ sql: String, kind: DatabaseKind) -> Bool { !isReadOnly(sql, kind: kind) }

    public static func isReadOnly(_ sql: String, kind: DatabaseKind) -> Bool {
        switch kind.family {
        case .redis: return RedisText.isReadOnly(sql)
        case .mongo: return MongoText.isReadOnly(sql)
        default:
            // Engines disagree on where a string ends (is a backslash an escape?). A statement reads only
            // when it does under both readings, so a quote can't hide a second statement from this check.
            return statements(in: sql).allSatisfy { statement in
                [true, false].allSatisfy { readsOnly(words(statement.sql, backslashEscapes: $0, family: kind.family), family: kind.family) }
            }
        }
    }

    /// The words and the few signs that matter (; = ( .) of a statement, lower case, without what is inside
    /// strings, quoted names and comments. What is left out is only what no engine could run: `--x`, `#`
    /// comments, `/*! … */` and dollar-quoted text stay in, since some engine runs or doesn't skip each.
    static func words(_ sql: String, backslashEscapes: Bool, family: DatabaseKind.Family) -> [String] {
        let chars = Array(sql)
        var out: [String] = []
        var word = ""
        var i = 0
        func flush() { if !word.isEmpty { out.append(word.lowercased()); word = "" } }
        let brackets = family == .tsql || family == .sqlite
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" || c == "`" {
                flush()
                i += 1
                while i < chars.count {
                    if chars[i] == c {
                        if i + 1 < chars.count, chars[i + 1] == c { i += 2; continue }
                        break
                    }
                    if backslashEscapes, c != "`", chars[i] == "\\", i + 1 < chars.count { i += 2; continue }
                    i += 1
                }
                i += 1
            } else if c == "[", brackets {
                flush()
                while i < chars.count, chars[i] != "]" { i += 1 }
                i += 1
            } else if c == "-", i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2].isWhitespace {
                flush()
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "-", i + 2 == chars.count, chars[i + 1] == "-" {
                flush()
                i += 2
            } else if c == "/", i + 2 < chars.count, chars[i + 1] == "*", chars[i + 2] != "!", !(chars[i + 2] == "M" && i + 3 < chars.count && chars[i + 3] == "!") {
                flush()
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if c.isLetter || c.isNumber || c == "_" {
                word.append(c)
                i += 1
            } else {
                flush()
                if ";=(.".contains(c) { out.append(String(c)) }
                i += 1
            }
        }
        flush()
        return out
    }

    /// Words that make a statement a write wherever they stand: inside a WITH, after a SELECT (SELECT … INTO,
    /// FOR UPDATE), or as a second statement.
    private static let writesAnywhere: Set<String> = ["insert", "update", "delete", "merge", "into", "upsert"]
    /// SQL Server needs no semicolon between statements, so any of its writing statements can follow a SELECT.
    private static let writesAnywhereTSQL: Set<String> = [
        "exec", "execute", "create", "drop", "alter", "truncate", "grant", "revoke", "deny", "backup", "restore", "dbcc", "kill",
        "shutdown", "bulk", "reconfigure", "sp_executesql",
    ]
    /// With EXPLAIN ANALYZE the statement really runs, so it must not be any kind of write.
    private static let writesWhenRun: Set<String> = [
        "create", "drop", "alter", "truncate", "call", "exec", "execute", "do", "copy", "refresh", "vacuum", "reindex", "cluster",
        "grant", "revoke", "replace", "load", "lock", "comment", "set",
    ]
    private static let transactionWords: Set<String> = [
        "transaction", "work", "isolation", "level", "read", "only", "committed", "uncommitted", "repeatable", "serializable",
        "snapshot", "deferrable", "not", "deferred", "and", "no", "chain",
    ]
    /// PRAGMAs that only report.
    private static let readingPragmas: Set<String> = [
        "table_info", "table_xinfo", "table_list", "index_list", "index_info", "index_xinfo", "foreign_key_list", "database_list",
        "collation_list", "function_list", "module_list", "pragma_list", "compile_options", "database_size", "show_tables",
        "show_tables_expanded", "version", "storage_info", "integrity_check", "quick_check", "foreign_key_check", "freelist_count",
        "page_count", "data_version",
    ]

    private static func readsOnly(_ all: [String], family: DatabaseKind.Family) -> Bool {
        var words = all
        while words.last == ";" { words.removeLast() }
        // A semicolon in the middle means this is more than one statement after all.
        if words.contains(";") { return false }
        let start = words.drop(while: { $0 == "(" })
        guard let first = start.first else { return true }
        let rest = start.dropFirst()
        // EXPLAIN without ANALYZE only plans: the statement it explains doesn't run, whatever it is.
        let runs = rest.contains("analyze") || rest.contains("analyse")
        if first == "explain", !runs { return true }
        if words.contains(where: writesAnywhere.contains) { return false }
        if family == .tsql, words.contains(where: writesAnywhereTSQL.contains) { return false }
        switch first {
        case "select", "with", "values", "table", "from", "show", "describe", "desc", "use", "summarize", "pivot", "unpivot", "exists", "list":
            return true
        case "explain":
            return !rest.contains(where: writesWhenRun.contains)
        case "pragma":
            guard family == .sqlite || family == .duckdb, !rest.contains("=") else { return false }
            let name = rest.prefix(while: { $0 != "(" }).last ?? ""
            return readingPragmas.contains(name)
        case "begin", "start", "commit", "end", "abort":
            // BEGIN … END blocks, and BEGIN READ WRITE, are not just transaction control.
            return rest.allSatisfy(transactionWords.contains)
        case "savepoint", "release":
            return rest.count <= 2
        case "rollback":
            return rest.filter { !transactionWords.contains($0) && $0 != "to" && $0 != "savepoint" }.count <= 1
        default:
            return false
        }
    }

    static func stripComments(_ sql: String) -> String {
        var out = ""
        var rest = Substring(sql)
        while !rest.isEmpty {
            if rest.hasPrefix("--") { rest = rest.drop(while: { $0 != "\n" }); continue }
            if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { break }
                rest = rest[end.upperBound...]
                continue
            }
            out.append(rest.removeFirst())
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 'a', 'b''c' → ["a", "b'c"]
    public static func quotedList(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inside = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if inside {
                if c == "'" {
                    if chars.first == "'" { current.append("'"); chars.removeFirst() } else { inside = false; out.append(current); current = "" }
                } else if c == "\\", let next = chars.first {
                    current.append(next); chars.removeFirst()
                } else { current.append(c) }
            } else if c == "'" { inside = true }
        }
        return out
    }

    /// The values of a `CHECK (col IN ('a', 'b'))` for a column in a CREATE TABLE statement.
    public static func checkInList(column: String, in create: String) -> [String]? {
        let name = NSRegularExpression.escapedPattern(for: column)
        let pattern = #"CHECK\s*\(\s*["`\[]?"# + name + #"["`\]]?\s+IN\s*\(([^)]*)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: create, range: NSRange(create.startIndex..., in: create)),
              let r = Range(m.range(at: 1), in: create) else { return nil }
        let values = quotedList(String(create[r]))
        return values.isEmpty ? nil : values
    }

    public static let keywords: [String] = """
        SELECT FROM WHERE AND OR NOT IN IS NULL LIKE ILIKE BETWEEN EXISTS AS ON JOIN LEFT RIGHT INNER OUTER FULL CROSS \
        NATURAL USING GROUP BY ORDER HAVING LIMIT OFFSET UNION ALL DISTINCT INSERT INTO VALUES UPDATE SET DELETE \
        CREATE TABLE VIEW INDEX UNIQUE PRIMARY KEY FOREIGN REFERENCES DROP ALTER ADD COLUMN RENAME TO TRUNCATE \
        BEGIN COMMIT ROLLBACK TRANSACTION CASE WHEN THEN ELSE END ASC DESC DEFAULT CHECK CONSTRAINT WITH RECURSIVE \
        RETURNING CAST TRUE FALSE IF REPLACE EXPLAIN ANALYZE SHOW USE GRANT REVOKE SCHEMA DATABASE TRIGGER FUNCTION \
        PROCEDURE RETURNS LANGUAGE CASCADE RESTRICT COUNT SUM AVG MIN MAX COALESCE NULLIF NOW INTERVAL OVER \
        PARTITION WINDOW FILTER LATERAL EXCEPT INTERSECT FETCH FIRST NEXT ROWS ONLY VACUUM
        """.split(whereSeparator: \.isWhitespace).map(String.init)
}

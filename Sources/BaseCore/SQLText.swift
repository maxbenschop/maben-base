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

    /// True for statements that change data or schema. Used to ask before running them on production.
    public static func isWrite(_ sql: String) -> Bool {
        let words = ["insert", "update", "delete", "drop", "alter", "truncate", "create", "replace", "grant", "revoke",
                     "merge", "rename", "comment", "vacuum", "reindex", "cluster", "refresh"]
        for statement in statements(in: sql) {
            let stripped = stripComments(statement.sql).lowercased()
            let first = stripped.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? ""
            if words.contains(first) { return true }
            if first == "with", words.dropLast(10).contains(where: { stripped.contains(" \($0) ") }) { return true }
        }
        return false
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

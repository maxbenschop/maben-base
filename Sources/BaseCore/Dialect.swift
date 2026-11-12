import Foundation

/// How an engine spells identifiers and values, and the SQL (or commands, for MongoDB and Redis) the app writes for it.
public struct Dialect: Sendable {
    public let kind: DatabaseKind
    public var family: DatabaseKind.Family { kind.family }

    public init(kind: DatabaseKind) { self.kind = kind }

    public func quote(_ identifier: String) -> String {
        switch family {
        case .mysql, .bigquery, .clickhouse: "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
        case .tsql: "[" + identifier.replacingOccurrences(of: "]", with: "]]") + "]"
        case .mongo, .redis: identifier
        default: "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    public func qualified(_ table: TableRef) -> String {
        if let schema = table.schema, !schema.isEmpty { return quote(schema) + "." + quote(table.name) }
        return quote(table.name)
    }

    /// Engines that won't compare a number column with a quoted string, so numbers go in bare.
    var strictTypes: Bool { [.bigquery, .clickhouse, .cql].contains(family) }

    /// A value as a literal. Text the user typed is sent as a quoted string, which most engines cast to the
    /// column's type (numbers, dates, JSON, UUIDs, booleans). Strict engines get numbers and booleans bare,
    /// when `type` says the column is one. Binary columns take 0x… hex.
    public func literal(_ value: String?, binary: Bool = false, type: String? = nil) -> String {
        guard let value else { return "NULL" }
        if binary, let hex = Self.hexDigits(value) {
            switch family {
            case .postgres: return "'\\x\(hex)'"
            case .tsql, .cql: return "0x\(hex)"
            case .oracle: return "HEXTORAW('\(hex)')"
            case .snowflake: return "TO_BINARY('\(hex)', 'HEX')"
            case .bigquery: return "FROM_HEX('\(hex)')"
            case .clickhouse: return "unhex('\(hex)')"
            case .duckdb: return "from_hex('\(hex)')"
            default: return "X'\(hex)'"
            }
        }
        if strictTypes || family == .tsql, let type {
            let t = type.lowercased()
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let kind = EditorKind(type: t)
            if kind == .number, Double(trimmed) != nil { return trimmed }
            if kind == .boolean, ["true", "false"].contains(trimmed.lowercased()) { return family == .tsql ? (trimmed.lowercased() == "true" ? "1" : "0") : trimmed.lowercased() }
            if family == .cql, t.contains("uuid"), UUID(uuidString: trimmed) != nil { return trimmed }
            // Collections, tuples and user types are written in CQL's own syntax, which is how the grid shows them.
            if family == .cql, ["list<", "set<", "map<", "tuple<", "frozen<", "udt"].contains(where: { t.hasPrefix($0) }),
               let first = trimmed.first, "[{(".contains(first) { return trimmed }
        }
        switch family {
        case .mysql, .clickhouse:
            // Backslash is an escape inside strings here.
            return "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
        case .bigquery:
            return "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n") + "'"
        case .tsql:
            return "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        case .mongo:
            return MongoText.literal(value)
        case .redis:
            return RedisText.quote(value)
        default:
            // Postgres (standard_conforming_strings), SQLite, Oracle, Snowflake, DuckDB, CQL: only quotes are doubled.
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    /// "0xABCD" or "\xabcd" → "ABCD", if the text is hex.
    static func hexDigits(_ value: String) -> String? {
        var s = Substring(value)
        if s.hasPrefix("0x") || s.hasPrefix("\\x") || s.hasPrefix("0X") { s = s.dropFirst(2) } else { return nil }
        guard s.count % 2 == 0, s.allSatisfy(\.isHexDigit) else { return nil }
        return String(s)
    }

    // MARK: Browsing

    public func selectPage(_ table: TableRef, filter: String?, order: [(column: String, ascending: Bool)],
                           limit: Int, offset: Int) -> String {
        if family == .mongo { return MongoText.page(table, filter: filter, order: order, limit: limit, offset: offset) }
        if family == .redis { return RedisText.page(filter: filter, limit: limit, offset: offset) }
        var sql = "SELECT * FROM \(qualified(table))"
        if let filter, !filter.isEmpty { sql += " WHERE \(filter)" }
        // CQL sorts only on clustering columns, so it's left to the server's order.
        if !order.isEmpty && family != .cql {
            sql += " ORDER BY " + order.map { quote($0.column) + ($0.ascending ? " ASC" : " DESC") }.joined(separator: ", ")
        }
        switch family {
        case .tsql:
            if order.isEmpty { sql += " ORDER BY (SELECT NULL)" }
            sql += " OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        case .oracle:
            sql += " OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        case .cql:
            // No OFFSET in CQL: the driver reads offset + limit rows and drops the first ones.
            sql = "/* skip \(offset) */ " + sql + " LIMIT \(offset + limit)"
            if filter?.isEmpty == false { sql += " ALLOW FILTERING" }  // after LIMIT, as CQL wants
        default:
            sql += " LIMIT \(limit)"
            if offset > 0 { sql += " OFFSET \(offset)" }
        }
        return sql
    }

    public func count(_ table: TableRef, filter: String?) -> String {
        if family == .mongo { return MongoText.count(table, filter: filter) }
        if family == .redis { return RedisText.count(filter: filter) }
        var sql = "SELECT COUNT(*) FROM \(qualified(table))"
        if let filter, !filter.isEmpty { sql += " WHERE \(filter)" + (family == .cql ? " ALLOW FILTERING" : "") }
        return sql
    }

    // MARK: Filters

    public func condition(_ filter: Filter, type: String? = nil) -> String? {
        guard !filter.column.isEmpty else { return nil }
        let column = filter.column == Filter.anyColumn ? nil : quote(filter.column)
        let value = filter.value
        func like(_ pattern: String) -> String {
            pattern.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        }
        func textOfRaw(_ col: String) -> String {
            switch family {
            case .postgres: "\(col)::text"
            case .mysql: "CAST(\(col) AS CHAR)"
            case .tsql: "CAST(\(col) AS NVARCHAR(MAX))"
            case .oracle: "TO_CHAR(\(col))"
            case .bigquery: "CAST(\(col) AS STRING)"
            case .clickhouse: "toString(\(col))"
            case .duckdb, .snowflake: "CAST(\(col) AS VARCHAR)"
            case .cql: col
            default: "CAST(\(col) AS TEXT)"
            }
        }
        let likeOp = [.postgres, .duckdb, .snowflake, .clickhouse].contains(family) ? "ILIKE" : "LIKE"
        let escapeClause = [.mysql, .bigquery, .clickhouse, .cql].contains(family) ? "" : " ESCAPE '\\'"
        guard let column else { return nil }
        let lit = { (v: String) in literal(v, type: type) }
        // "contains" ignores case everywhere: Oracle's and BigQuery's LIKE don't, so both sides go upper case.
        let caseFold = family == .oracle || family == .bigquery
        func textOf(_ col: String) -> String { caseFold ? "UPPER(\(textOfRaw(col)))" : textOfRaw(col) }
        func pattern(_ p: String) -> String { caseFold ? "UPPER(\(literal(p)))" : literal(p) }
        switch filter.op {
        case .equals: return "\(column) = \(lit(value))"
        case .notEquals: return "\(column) <> \(lit(value))"
        case .less: return "\(column) < \(lit(value))"
        case .greater: return "\(column) > \(lit(value))"
        case .lessOrEqual: return "\(column) <= \(lit(value))"
        case .greaterOrEqual: return "\(column) >= \(lit(value))"
        case .contains: return "\(textOf(column)) \(likeOp) \(pattern("%" + like(value) + "%"))\(escapeClause)"
        case .notContains: return "\(textOf(column)) NOT \(likeOp) \(pattern("%" + like(value) + "%"))\(escapeClause)"
        case .startsWith: return "\(textOf(column)) \(likeOp) \(pattern(like(value) + "%"))\(escapeClause)"
        case .endsWith: return "\(textOf(column)) \(likeOp) \(pattern("%" + like(value)))\(escapeClause)"
        case .isNull: return "\(column) IS NULL"
        case .isNotNull: return "\(column) IS NOT NULL"
        case .in:
            let items = value.split(separator: ",").map { lit($0.trimmingCharacters(in: .whitespaces)) }
            guard !items.isEmpty else { return nil }
            return "\(column) IN (\(items.joined(separator: ", ")))"
        case .sql: return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "(\(value))"
        }
    }

    /// All enabled filters joined with AND. Free SQL filters are used as they are. `types` (column → type)
    /// lets strict engines get bare numbers.
    public func whereClause(_ filters: [Filter], types: [String: String] = [:]) -> String? {
        if family == .mongo { return MongoText.filter(filters, types: types) }
        if family == .redis { return RedisText.pattern(filters) }
        let parts = filters.filter(\.enabled).compactMap { f -> String? in
            if f.op == .sql { return condition(Filter(column: "sql", op: .sql, value: f.value)) }
            return condition(f, type: types[f.column])
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    /// How staged edits are written as one unit.
    public enum Transactions: Sendable {
        /// BEGIN, the statements one by one (each checked), COMMIT.
        case statements(begin: String)
        /// One request with everything inside BEGIN … COMMIT (stateless HTTP engines).
        case script(begin: String, commit: String)
        /// No transactions: one by one.
        case none
    }

    public var transactions: Transactions {
        switch kind {
        case .postgres, .sqlite, .libsql, .duckdb: .statements(begin: "BEGIN")
        case .mysql: .statements(begin: "START TRANSACTION")
        case .sqlserver: .statements(begin: "BEGIN TRANSACTION")
        case .oracle: .statements(begin: "SET TRANSACTION READ WRITE")
        case .snowflake: .script(begin: "BEGIN", commit: "COMMIT")
        case .bigquery: .script(begin: "BEGIN TRANSACTION", commit: "COMMIT TRANSACTION")
        case .d1, .clickhouse, .cassandra, .mongodb, .redis: .none
        }
    }

    /// Whether the structure editor can change tables on this engine.
    public var supportsDesign: Bool { [.postgres, .mysql, .sqlite, .libsql, .duckdb].contains(kind) }

    // MARK: Edits

    /// The statements that write a set of staged changes, in order: deletes, updates, inserts.
    public func statements(for changes: ChangeSet, table: TableRef, columns: [ResultColumn],
                           primaryKey: [String]) throws -> [String] {
        if family == .mongo { return try MongoText.statements(for: changes, table: table, columns: columns) }
        if family == .redis { return try RedisText.statements(for: changes, columns: columns) }
        let pkIndexes = primaryKey.compactMap { key in columns.firstIndex(where: { $0.name == key }) }
        let needsKey = !changes.updates.isEmpty || !changes.deletes.isEmpty
        if needsKey && (primaryKey.isEmpty || pkIndexes.count != primaryKey.count) {
            throw DatabaseError("This table has no primary key in the result, so rows can't be changed safely.")
        }
        func whereKey(_ original: [String?]) -> String {
            pkIndexes.map { i in
                let col = quote(columns[i].name)
                guard let value = original[i] else { return "\(col) IS NULL" }
                return "\(col) = \(literal(value, binary: columns[i].isBinary, type: columns[i].typeName))"
            }.joined(separator: " AND ")
        }
        var sql: [String] = []
        for row in changes.deletes.sorted() {
            guard let original = changes.originals[row] else { continue }
            // ClickHouse changes rows through mutations; mutations_sync waits for them.
            sql.append(family == .clickhouse ? "ALTER TABLE \(qualified(table)) DELETE WHERE \(whereKey(original)) SETTINGS mutations_sync = 2"
                                             : "DELETE FROM \(qualified(table)) WHERE \(whereKey(original))")
        }
        for row in changes.updates.keys.sorted() where !changes.deletes.contains(row) {
            guard let original = changes.originals[row], let edits = changes.updates[row], !edits.isEmpty else { continue }
            let sets = edits.keys.sorted().map { i in
                "\(quote(columns[i].name)) = \(literal(edits[i]!, binary: columns[i].isBinary, type: columns[i].typeName))"
            }.joined(separator: ", ")
            sql.append(family == .clickhouse ? "ALTER TABLE \(qualified(table)) UPDATE \(sets) WHERE \(whereKey(original)) SETTINGS mutations_sync = 2"
                                             : "UPDATE \(qualified(table)) SET \(sets) WHERE \(whereKey(original))")
        }
        for insert in changes.inserts {
            let set = insert.values.keys.sorted()
            if set.isEmpty {
                sql.append(kind == .mysql ? "INSERT INTO \(qualified(table)) () VALUES ()"
                                          : "INSERT INTO \(qualified(table)) DEFAULT VALUES")
            } else {
                let cols = set.map { quote(columns[$0].name) }.joined(separator: ", ")
                let vals = set.map { literal(insert.values[$0]!, binary: columns[$0].isBinary, type: columns[$0].typeName) }.joined(separator: ", ")
                sql.append("INSERT INTO \(qualified(table)) (\(cols)) VALUES (\(vals))")
            }
        }
        return sql
    }

    /// The statement that starts a transaction, where the engine has one per connection.
    public var begin: String {
        switch transactions {
        case .statements(let b): b
        case .script(let b, _): b
        case .none: ""
        }
    }

    /// Rows as INSERT statements, for copying and SQL export.
    public func insertStatements(table: TableRef, columns: [ResultColumn], rows: [[String?]]) -> [String] {
        let cols = columns.map { quote($0.name) }.joined(separator: ", ")
        return rows.map { row in
            let vals = row.enumerated().map { literal($0.element, binary: columns[$0.offset].isBinary, type: columns[$0.offset].typeName) }.joined(separator: ", ")
            return "INSERT INTO \(qualified(table)) (\(cols)) VALUES (\(vals));"
        }
    }
}

/// One condition in the filter bar.
public struct Filter: Hashable, Identifiable, Sendable {
    public static let anyColumn = "\u{1}any"

    public enum Op: String, CaseIterable, Sendable {
        case equals = "="
        case notEquals = "≠"
        case less = "<"
        case greater = ">"
        case lessOrEqual = "≤"
        case greaterOrEqual = "≥"
        case contains = "contains"
        case notContains = "doesn't contain"
        case startsWith = "starts with"
        case endsWith = "ends with"
        case `in` = "in list"
        case isNull = "is NULL"
        case isNotNull = "is not NULL"
        case sql = "SQL"

        public var takesValue: Bool { self != .isNull && self != .isNotNull }
    }

    public var id = UUID()
    public var enabled = true
    public var column: String
    public var op: Op
    public var value: String

    public init(column: String, op: Op = .equals, value: String = "") {
        self.column = column
        self.op = op
        self.value = value
    }
}

/// Edits waiting to be written. Rows are indexes into the page that was loaded; `originals` keeps
/// each touched row as it came from the server, so the WHERE clause finds it by its primary key.
public struct ChangeSet: Sendable {
    public struct Insert: Sendable, Identifiable {
        public var id = UUID()
        /// Column index → value. Columns left out get their default.
        public var values: [Int: String?] = [:]
        public init(values: [Int: String?] = [:]) { self.values = values }
    }

    public var updates: [Int: [Int: String?]] = [:]
    public var deletes: Set<Int> = []
    public var inserts: [Insert] = []
    public var originals: [Int: [String?]] = [:]

    public init() {}

    public var isEmpty: Bool { updates.isEmpty && deletes.isEmpty && inserts.isEmpty }
    public var count: Int { updates.values.reduce(0) { $0 + $1.count } + deletes.count + inserts.count }

    public mutating func set(row: Int, column: Int, value: String?, original: [String?]) {
        if originals[row] == nil { originals[row] = original }
        if originals[row]![column] == value {
            updates[row]?[column] = nil
            if updates[row]?.isEmpty == true { updates[row] = nil }
        } else {
            updates[row, default: [:]][column] = .some(value)
        }
    }

    public mutating func delete(row: Int, original: [String?]) {
        if originals[row] == nil { originals[row] = original }
        deletes.insert(row)
    }

    public mutating func undelete(row: Int) { deletes.remove(row) }

    public func value(row: Int, column: Int) -> String?? { updates[row]?[column] }
}

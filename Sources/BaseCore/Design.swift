import Foundation

/// A table's structure as an editable draft: columns, primary key, indexes and foreign keys.
/// Compare a draft with the original to get the ALTER statements, or turn a new one into CREATE TABLE.
public struct TableDesign: Equatable, Sendable {
    public struct Column: Identifiable, Hashable, Sendable {
        public var id = UUID()
        /// The name in the database; nil for a column that's being added.
        public var original: String?
        public var name: String
        public var type: String
        public var nullable: Bool
        /// A SQL expression, as typed: 'text', 42, now(). Empty means no default.
        public var defaultValue: String
        public var comment: String
        public var primaryKey: Bool
        /// Kept as it is: auto_increment (MySQL) or identity (Postgres).
        public var extra: String

        public init(original: String? = nil, name: String, type: String, nullable: Bool = true, defaultValue: String = "",
                    comment: String = "", primaryKey: Bool = false, extra: String = "") {
            self.original = original
            self.name = name
            self.type = type
            self.nullable = nullable
            self.defaultValue = defaultValue
            self.comment = comment
            self.primaryKey = primaryKey
            self.extra = extra
        }
    }

    public struct Index: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var original: String?
        public var name: String
        public var columns: [String]
        public var unique: Bool
        /// Postgres: the index belongs to a UNIQUE constraint and is dropped through it.
        public var isConstraint: Bool

        public init(original: String? = nil, name: String, columns: [String], unique: Bool = false, isConstraint: Bool = false) {
            self.original = original
            self.name = name
            self.columns = columns
            self.unique = unique
            self.isConstraint = isConstraint
        }
    }

    public struct ForeignKey: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var original: String?
        public var name: String
        public var columns: [String]
        public var refTable: String
        public var refSchema: String?
        public var refColumns: [String]
        public var onUpdate: String
        public var onDelete: String

        public init(original: String? = nil, name: String, columns: [String], refTable: String, refSchema: String? = nil,
                    refColumns: [String], onUpdate: String = "NO ACTION", onDelete: String = "NO ACTION") {
            self.original = original
            self.name = name
            self.columns = columns
            self.refTable = refTable
            self.refSchema = refSchema
            self.refColumns = refColumns
            self.onUpdate = onUpdate
            self.onDelete = onDelete
        }
    }

    public var table: TableRef
    public var columns: [Column]
    public var indexes: [Index]
    public var foreignKeys: [ForeignKey]
    /// The primary key constraint's name (Postgres needs it to drop the key).
    public var primaryKeyName: String?

    public init(table: TableRef, columns: [Column], indexes: [Index] = [], foreignKeys: [ForeignKey] = [], primaryKeyName: String? = nil) {
        self.table = table
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.primaryKeyName = primaryKeyName
    }

    /// The design of an existing table, as the driver describes it.
    public init(table: TableRef, kind: DatabaseKind, columns: [ColumnInfo], indexes: [IndexInfo], foreignKeys: [ForeignKeyInfo]) {
        self.table = table
        self.columns = columns.map { c in
            Column(original: c.name, name: c.name, type: c.type, nullable: c.nullable,
                   defaultValue: Self.defaultExpression(c.defaultValue, kind: kind, extra: c.extra), comment: c.comment ?? "",
                   primaryKey: c.isPrimaryKey, extra: c.extra ?? "")
        }
        self.indexes = indexes.filter { !$0.primary }.map {
            Index(original: $0.name, name: $0.name, columns: $0.columns, unique: $0.unique, isConstraint: $0.isConstraint)
        }
        self.foreignKeys = foreignKeys.map {
            ForeignKey(original: $0.name, name: $0.name, columns: $0.columns, refTable: $0.refTable, refSchema: $0.refSchema,
                       refColumns: $0.refColumns, onUpdate: $0.onUpdate, onDelete: $0.onDelete)
        }
        primaryKeyName = indexes.first(where: \.primary)?.name
    }

    /// A new table with an id column, ready to fill in.
    public static func new(table: TableRef, kind: DatabaseKind) -> TableDesign {
        let id: Column = switch kind.family {
        case .postgres: Column(name: "id", type: "bigserial", nullable: false, primaryKey: true)
        case .duckdb: Column(name: "id", type: "bigint", nullable: false, primaryKey: true)
        case .mysql: Column(name: "id", type: "bigint", nullable: false, primaryKey: true, extra: "auto_increment")
        default: Column(name: "id", type: "integer", nullable: false, primaryKey: true)
        }
        return TableDesign(table: table, columns: [id])
    }

    /// MySQL lists defaults as bare values ("abc", CURRENT_TIMESTAMP); the others as expressions.
    static func defaultExpression(_ value: String?, kind: DatabaseKind, extra: String?) -> String {
        guard let value else { return "" }
        guard kind == .mysql else { return value }
        if Double(value) != nil { return value }
        let upper = value.uppercased()
        if upper.hasPrefix("CURRENT_TIMESTAMP") || upper == "NULL" || upper.hasPrefix("NOW(") { return value }
        if extra?.uppercased().contains("DEFAULT_GENERATED") == true { return value.hasPrefix("(") ? value : "(\(value))" }
        return Dialect(kind: .mysql).literal(value)
    }

    public var primaryKey: [String] { columns.filter(\.primaryKey).map(\.name) }

    /// Renames a column and every index and foreign key that uses it.
    public mutating func renameColumn(_ id: UUID, to newName: String) {
        guard let i = columns.firstIndex(where: { $0.id == id }) else { return }
        let old = columns[i].name
        columns[i].name = newName
        for k in indexes.indices { indexes[k].columns = indexes[k].columns.map { $0 == old ? newName : $0 } }
        for k in foreignKeys.indices { foreignKeys[k].columns = foreignKeys[k].columns.map { $0 == old ? newName : $0 } }
    }

    /// Problems that stop the statements from being built.
    public func problems() -> [String] {
        var out: [String] = []
        if table.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("The table needs a name.") }
        if columns.isEmpty { out.append("A table needs at least one column.") }
        var seen = Set<String>()
        for c in columns {
            if c.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Every column needs a name."); break }
            if c.type.trimmingCharacters(in: .whitespaces).isEmpty { out.append("\(c.name) needs a type.") }
            if !seen.insert(c.name.lowercased()).inserted { out.append("There are two columns called \(c.name).") }
        }
        let names = Set(columns.map(\.name))
        for i in indexes {
            if i.name.isEmpty { out.append("Every index needs a name.") }
            if i.columns.isEmpty { out.append("Index \(i.name) has no columns.") }
            for c in i.columns where !names.contains(c) { out.append("Index \(i.name) uses \(c), which isn't a column.") }
        }
        for f in foreignKeys {
            if f.name.isEmpty { out.append("Every foreign key needs a name.") }
            if f.columns.isEmpty || f.refTable.isEmpty || f.refColumns.isEmpty { out.append("Foreign key \(f.name) isn't complete.") }
            if f.columns.count != f.refColumns.count { out.append("Foreign key \(f.name) needs as many columns on both sides.") }
            for c in f.columns where !names.contains(c) { out.append("Foreign key \(f.name) uses \(c), which isn't a column.") }
        }
        return out
    }
}

extension Dialect {
    /// The engines the structure editor writes for, by the SQL they share: libSQL and D1 are SQLite; DuckDB follows Postgres.
    var designKind: DatabaseKind {
        switch family {
        case .sqlite: .sqlite
        case .duckdb: .postgres
        case .mysql: .mysql
        default: .postgres
        }
    }

    /// The statements that turn `original` into `draft`, or create `draft` when there's no original.
    /// Postgres and SQLite run them in one transaction; MySQL commits each DDL statement itself.
    public func designStatements(original: TableDesign?, draft: TableDesign) throws -> [String] {
        guard supportsDesign else { throw DatabaseError("Changing structure isn't available for \(kind.title) here; use SQL in a query tab.") }
        let problems = draft.problems()
        if !problems.isEmpty { throw DatabaseError(problems.joined(separator: "\n")) }
        guard let original else { return createStatements(draft) }
        if designKind == .sqlite && sqliteNeedsRebuild(original, draft) { return sqliteRebuild(original, draft) }

        let t = qualified(draft.table)
        var out: [String] = []
        let originalColumns = Dictionary(uniqueKeysWithValues: original.columns.compactMap { c in c.original.map { ($0, c) } })
        let draftOriginals = Set(draft.columns.compactMap(\.original))
        // Renamed columns: the database carries renames into indexes and keys itself.
        var renamed: [String: String] = [:]
        for c in draft.columns { if let o = c.original { renamed[o] = c.name } }
        func mapped(_ cols: [String]) -> [String] { cols.map { renamed[$0] ?? $0 } }
        let pkChanged = mapped(original.primaryKey) != draft.primaryKey

        // 1. Drop foreign keys and indexes that went away or changed.
        let fkByOriginal = Dictionary(uniqueKeysWithValues: draft.foreignKeys.compactMap { f in f.original.map { ($0, f) } })
        for f in original.foreignKeys {
            guard let name = f.original else { continue }
            if let now = fkByOriginal[name], sameForeignKey(now, f, mapping: mapped) { continue }
            switch designKind {
            case .postgres: out.append("ALTER TABLE \(t) DROP CONSTRAINT \(quote(name))")
            case .mysql: out.append("ALTER TABLE \(t) DROP FOREIGN KEY \(quote(name))")
            default: break
            }
        }
        let indexByOriginal = Dictionary(uniqueKeysWithValues: draft.indexes.compactMap { i in i.original.map { ($0, i) } })
        var renamedIndexes: [(String, String)] = []
        for i in original.indexes {
            guard let name = i.original else { continue }
            if let now = indexByOriginal[name], now.columns == mapped(i.columns), now.unique == i.unique {
                if now.name != name { renamedIndexes.append((name, now.name)) }
                continue
            }
            out.append(dropIndex(i, table: draft.table))
        }
        if pkChanged && !original.primaryKey.isEmpty {
            switch designKind {
            case .postgres: out.append("ALTER TABLE \(t) DROP CONSTRAINT \(quote(original.primaryKeyName ?? "\(original.table.name)_pkey"))")
            case .mysql: out.append("ALTER TABLE \(t) DROP PRIMARY KEY")
            default: break
            }
        }

        // 2. Columns: drops, then renames and changes, then additions.
        for c in original.columns where !draftOriginals.contains(c.original ?? "") {
            out.append("ALTER TABLE \(t) DROP COLUMN \(quote(c.original ?? c.name))")
        }
        for c in draft.columns {
            guard let name = c.original, let was = originalColumns[name] else { continue }
            out += alterColumn(table: t, from: was, to: c)
        }
        for c in draft.columns where c.original == nil {
            out.append("ALTER TABLE \(t) ADD COLUMN \(columnDefinition(c, inCreate: false))")
            if designKind == .postgres, !c.comment.isEmpty {
                out.append("COMMENT ON COLUMN \(t).\(quote(c.name)) IS \(literal(c.comment))")
            }
        }

        // 3. Primary key, indexes, foreign keys.
        if pkChanged && !draft.primaryKey.isEmpty && designKind != .sqlite {
            out.append("ALTER TABLE \(t) ADD PRIMARY KEY (\(draft.primaryKey.map(quote).joined(separator: ", ")))")
        }
        for (old, new) in renamedIndexes {
            switch designKind {
            case .postgres:
                let schema = draft.table.schema.map { quote($0) + "." } ?? ""
                out.append("ALTER INDEX \(schema)\(quote(old)) RENAME TO \(quote(new))")
            case .mysql: out.append("ALTER TABLE \(t) RENAME INDEX \(quote(old)) TO \(quote(new))")
            default:
                if let i = draft.indexes.first(where: { $0.original == old }) {
                    out.append("DROP INDEX \(quote(old))")
                    out.append(createIndex(i, table: draft.table))
                }
            }
        }
        for i in draft.indexes {
            if let name = i.original, let was = original.indexes.first(where: { $0.original == name }),
               mapped(was.columns) == i.columns, was.unique == i.unique { continue }
            out.append(createIndex(i, table: draft.table))
        }
        let originalFKs = Dictionary(uniqueKeysWithValues: original.foreignKeys.compactMap { f in f.original.map { ($0, f) } })
        for f in draft.foreignKeys {
            if let name = f.original, let was = originalFKs[name], sameForeignKey(f, was, mapping: mapped) { continue }
            out.append("ALTER TABLE \(t) ADD \(foreignKeyClause(f))")
        }
        return out
    }

    /// `now` against `was`, with `was`'s columns passed through the renames.
    private func sameForeignKey(_ now: TableDesign.ForeignKey, _ was: TableDesign.ForeignKey, mapping: ([String]) -> [String]) -> Bool {
        let a = now, b = was
        return a.name == b.name && a.columns == mapping(b.columns) && a.refTable == b.refTable && a.refSchema == b.refSchema
            && a.refColumns == b.refColumns && a.onUpdate == b.onUpdate && a.onDelete == b.onDelete
    }

    private func alterColumn(table t: String, from was: TableDesign.Column, to c: TableDesign.Column) -> [String] {
        var out: [String] = []
        switch designKind {
        case .mysql:
            // CHANGE COLUMN restates the whole column, which covers rename, type, null, default and comment.
            if was.name != c.name || was.type != c.type || was.nullable != c.nullable || was.defaultValue != c.defaultValue
                || was.comment != c.comment || was.extra != c.extra {
                out.append("ALTER TABLE \(t) CHANGE COLUMN \(quote(was.name)) \(columnDefinition(c, inCreate: false))")
            }
        case .postgres:
            if was.name != c.name { out.append("ALTER TABLE \(t) RENAME COLUMN \(quote(was.name)) TO \(quote(c.name))") }
            let col = quote(c.name)
            if was.type != c.type { out.append("ALTER TABLE \(t) ALTER COLUMN \(col) TYPE \(c.type) USING \(col)::\(c.type)") }
            if was.nullable != c.nullable { out.append("ALTER TABLE \(t) ALTER COLUMN \(col) \(c.nullable ? "DROP" : "SET") NOT NULL") }
            if was.defaultValue != c.defaultValue {
                out.append(c.defaultValue.isEmpty ? "ALTER TABLE \(t) ALTER COLUMN \(col) DROP DEFAULT"
                                                  : "ALTER TABLE \(t) ALTER COLUMN \(col) SET DEFAULT \(c.defaultValue)")
            }
            if was.comment != c.comment {
                out.append("COMMENT ON COLUMN \(t).\(col) IS \(c.comment.isEmpty ? "NULL" : literal(c.comment))")
            }
        default:
            if was.name != c.name { out.append("ALTER TABLE \(t) RENAME COLUMN \(quote(was.name)) TO \(quote(c.name))") }
        }
        return out
    }

    func columnDefinition(_ c: TableDesign.Column, inCreate: Bool, inlinePK: Bool = false) -> String {
        var s = "\(quote(c.name)) \(c.type)"
        // SQLite: INTEGER PRIMARY KEY makes the column the rowid, which fills itself in.
        if inlinePK { s += " PRIMARY KEY" }
        if !c.nullable { s += " NOT NULL" }
        if !c.defaultValue.isEmpty { s += " DEFAULT \(c.defaultValue)" }
        if designKind == .mysql {
            if c.extra.lowercased().contains("auto_increment") { s += " AUTO_INCREMENT" }
            if !c.comment.isEmpty { s += " COMMENT \(literal(c.comment))" }
        }
        if designKind == .postgres && c.extra == "identity" && inCreate { s += " GENERATED BY DEFAULT AS IDENTITY" }
        return s
    }

    private func foreignKeyClause(_ f: TableDesign.ForeignKey) -> String {
        var target = quote(f.refTable)
        if let s = f.refSchema, !s.isEmpty, designKind != .sqlite { target = quote(s) + "." + target }
        var s = "CONSTRAINT \(quote(f.name)) FOREIGN KEY (\(f.columns.map(quote).joined(separator: ", "))) REFERENCES \(target) (\(f.refColumns.map(quote).joined(separator: ", ")))"
        if f.onUpdate != "NO ACTION" { s += " ON UPDATE \(f.onUpdate)" }
        if f.onDelete != "NO ACTION" { s += " ON DELETE \(f.onDelete)" }
        return s
    }

    private func createIndex(_ i: TableDesign.Index, table: TableRef) -> String {
        "CREATE \(i.unique ? "UNIQUE " : "")INDEX \(quote(i.name)) ON \(qualified(table)) (\(i.columns.map(quote).joined(separator: ", ")))"
    }

    private func dropIndex(_ i: TableDesign.Index, table: TableRef) -> String {
        let name = i.original ?? i.name
        switch designKind {
        case .postgres:
            if i.isConstraint { return "ALTER TABLE \(qualified(table)) DROP CONSTRAINT \(quote(name))" }
            let schema = table.schema.map { quote($0) + "." } ?? ""
            return "DROP INDEX \(schema)\(quote(name))"
        case .mysql: return "DROP INDEX \(quote(name)) ON \(qualified(table))"
        default: return "DROP INDEX \(quote(name))"
        }
    }

    func createTable(_ d: TableDesign, as table: TableRef) -> String {
        let pk = d.primaryKey
        let inlinePK = designKind == .sqlite && pk.count == 1 && d.columns.first(where: \.primaryKey)?.type.lowercased() == "integer"
        var lines = d.columns.map { "  " + columnDefinition($0, inCreate: true, inlinePK: inlinePK && $0.primaryKey) }
        if !pk.isEmpty && !inlinePK { lines.append("  PRIMARY KEY (\(pk.map(quote).joined(separator: ", ")))") }
        for f in d.foreignKeys { lines.append("  " + foreignKeyClause(f)) }
        return "CREATE TABLE \(qualified(table)) (\n\(lines.joined(separator: ",\n"))\n)"
    }

    private func createStatements(_ d: TableDesign) -> [String] {
        var out = [createTable(d, as: d.table)]
        for i in d.indexes { out.append(createIndex(i, table: d.table)) }
        if designKind == .postgres {
            for c in d.columns where !c.comment.isEmpty {
                out.append("COMMENT ON COLUMN \(qualified(d.table)).\(quote(c.name)) IS \(literal(c.comment))")
            }
        }
        return out
    }

    // MARK: SQLite rebuild

    /// SQLite's ALTER TABLE can only rename, add (nullable or with a default) and drop plain columns.
    private func sqliteNeedsRebuild(_ o: TableDesign, _ d: TableDesign) -> Bool {
        var renamed: [String: String] = [:]
        for c in d.columns { if let o = c.original { renamed[o] = c.name } }
        if o.primaryKey.map({ renamed[$0] ?? $0 }) != d.primaryKey { return true }
        let originals = Dictionary(uniqueKeysWithValues: o.columns.compactMap { c in c.original.map { ($0, c) } })
        for c in d.columns {
            if let name = c.original, let was = originals[name] {
                if was.type != c.type || was.nullable != c.nullable || was.defaultValue != c.defaultValue { return true }
            } else if c.primaryKey || (!c.nullable && c.defaultValue.isEmpty) {
                return true
            }
        }
        let keep = Set(d.columns.compactMap(\.original))
        let indexed = Set(o.indexes.flatMap(\.columns) + o.foreignKeys.flatMap(\.columns))
        for c in o.columns where !keep.contains(c.original ?? "") && (c.primaryKey || indexed.contains(c.name)) { return true }
        let fk = { (f: TableDesign.ForeignKey) in "\(f.name)|\(f.columns.map { renamed[$0] ?? $0 })|\(f.refTable)|\(f.refColumns)|\(f.onUpdate)|\(f.onDelete)" }
        let fkNow = { (f: TableDesign.ForeignKey) in "\(f.name)|\(f.columns)|\(f.refTable)|\(f.refColumns)|\(f.onUpdate)|\(f.onDelete)" }
        if o.foreignKeys.map(fk) != d.foreignKeys.map(fkNow) { return true }
        return false
    }

    /// The documented way to change a SQLite table: build the new one, copy the rows, swap, recreate indexes.
    private func sqliteRebuild(_ o: TableDesign, _ d: TableDesign) -> [String] {
        let temp = TableRef(schema: nil, name: "_mb_new_\(d.table.name)")
        var out = ["PRAGMA defer_foreign_keys = ON", createTable(d, as: temp)]
        let copied = d.columns.filter { $0.original != nil }
        if !copied.isEmpty {
            out.append("INSERT INTO \(quote(temp.name)) (\(copied.map { quote($0.name) }.joined(separator: ", "))) SELECT \(copied.map { quote($0.original!) }.joined(separator: ", ")) FROM \(quote(o.table.name))")
        }
        out.append("DROP TABLE \(quote(o.table.name))")
        out.append("ALTER TABLE \(quote(temp.name)) RENAME TO \(quote(d.table.name))")
        for i in d.indexes { out.append(createIndex(i, table: d.table)) }
        return out
    }

    public func createView(_ table: TableRef, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        return "CREATE VIEW \(qualified(table)) AS\n\(trimmed)"
    }
}

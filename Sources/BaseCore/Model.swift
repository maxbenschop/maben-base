import Foundation

/// The database engines Maben Base speaks.
public enum DatabaseKind: String, Codable, CaseIterable, Sendable {
    case postgres, mysql, sqlite, sqlserver, oracle, clickhouse, duckdb, libsql, d1, snowflake, bigquery, cassandra, mongodb, redis

    /// How an engine's SQL (or commands) look: quoting, literals, paging.
    public enum Family: Sendable { case postgres, mysql, sqlite, tsql, oracle, clickhouse, duckdb, snowflake, bigquery, cql, mongo, redis }

    public var family: Family {
        switch self {
        case .postgres: .postgres
        case .mysql: .mysql
        case .sqlite, .libsql, .d1: .sqlite
        case .sqlserver: .tsql
        case .oracle: .oracle
        case .clickhouse: .clickhouse
        case .duckdb: .duckdb
        case .snowflake: .snowflake
        case .bigquery: .bigquery
        case .cassandra: .cql
        case .mongodb: .mongo
        case .redis: .redis
        }
    }

    public var title: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL / MariaDB"
        case .sqlite: "SQLite"
        case .sqlserver: "SQL Server"
        case .oracle: "Oracle"
        case .clickhouse: "ClickHouse"
        case .duckdb: "DuckDB"
        case .libsql: "libSQL / Turso"
        case .d1: "Cloudflare D1"
        case .snowflake: "Snowflake"
        case .bigquery: "BigQuery"
        case .cassandra: "Cassandra / ScyllaDB"
        case .mongodb: "MongoDB"
        case .redis: "Redis / Valkey"
        }
    }

    public var shortTitle: String {
        switch self {
        case .postgres: "Postgres"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        case .sqlserver: "SQL Server"
        case .oracle: "Oracle"
        case .clickhouse: "ClickHouse"
        case .duckdb: "DuckDB"
        case .libsql: "libSQL"
        case .d1: "D1"
        case .snowflake: "Snowflake"
        case .bigquery: "BigQuery"
        case .cassandra: "Cassandra"
        case .mongodb: "MongoDB"
        case .redis: "Redis"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .sqlserver: 1433
        case .oracle: 1521
        case .clickhouse: 8123
        case .libsql: 8080
        case .cassandra: 9042
        case .mongodb: 27017
        case .redis: 6379
        case .sqlite, .duckdb, .d1, .snowflake, .bigquery: 0
        }
    }

    /// URL schemes that fill in a connection of this kind.
    public var schemes: [String] {
        switch self {
        case .postgres: ["postgres", "postgresql"]
        case .mysql: ["mysql", "mariadb"]
        case .sqlite: ["sqlite", "file"]
        case .sqlserver: ["sqlserver", "mssql"]
        case .oracle: ["oracle"]
        case .clickhouse: ["clickhouse", "clickhouses"]
        case .duckdb: ["duckdb"]
        case .libsql: ["libsql", "turso"]
        case .d1: ["d1"]
        case .snowflake: ["snowflake"]
        case .bigquery: ["bigquery"]
        case .cassandra: ["cassandra", "cql", "scylla"]
        case .mongodb: ["mongodb", "mongodb+srv"]
        case .redis: ["redis", "rediss", "valkey"]
        }
    }

    /// Postgres-style schemas inside a database.
    public var hasSchemas: Bool { [.postgres, .sqlserver, .duckdb, .snowflake].contains(self) }

    /// A file on this Mac rather than a server.
    public var isFile: Bool { self == .sqlite || self == .duckdb }

    /// Reached over HTTPS with a token; no host/port/TLS settings and no SSH tunnel.
    public var isCloudAPI: Bool { [.d1, .snowflake, .bigquery].contains(self) }

    public var supportsSSH: Bool { !isFile && !isCloudAPI }

    /// Edits, filters and structure use SQL.
    public var isSQL: Bool { self != .mongodb && self != .redis }

    /// The engine's own command-line tool, which these drivers run (Oracle: sqlplus; DuckDB: duckdb).
    public var tool: String? {
        switch self {
        case .oracle: "sqlplus"
        case .duckdb: "duckdb"
        default: nil
        }
    }
}

/// One column of a result.
public struct ResultColumn: Hashable, Sendable {
    public var name: String
    public var typeName: String
    /// Binary data: shown as 0x… hex, written back as a hex literal.
    public var isBinary: Bool

    public init(name: String, typeName: String, isBinary: Bool = false) {
        self.name = name
        self.typeName = typeName
        self.isBinary = isBinary
    }
}

/// What one statement returned. Values are text as the server sends them; nil is NULL.
public struct QueryResult: Sendable {
    public var columns: [ResultColumn]
    public var rows: [[String?]]
    /// Rows changed by INSERT/UPDATE/DELETE, when the server says.
    public var affectedRows: Int?
    /// The server's tag or message, like "UPDATE 3".
    public var message: String?
    /// True when more rows came back than the row limit and the rest were dropped.
    public var truncated: Bool

    public init(columns: [ResultColumn] = [], rows: [[String?]] = [], affectedRows: Int? = nil,
                message: String? = nil, truncated: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.message = message
        self.truncated = truncated
    }

    public var hasRows: Bool { !columns.isEmpty }
}

public struct DatabaseError: Error, LocalizedError, Sendable {
    public var message: String
    public var detail: String?
    /// The SQLSTATE or error code, when the server sends one.
    public var code: String?
    /// Results of the statements that ran before the one that failed (MySQL and SQLite keep those).
    public var completed: [QueryResult] = []

    public init(_ message: String, detail: String? = nil, code: String? = nil) {
        self.message = message
        self.detail = detail
        self.code = code
    }

    public var errorDescription: String? {
        [message, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A table, view or function in the sidebar.
public struct DBObject: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case table, view, materializedView, foreignTable, function

        public var title: String {
            switch self {
            case .table: "Tables"
            case .view: "Views"
            case .materializedView: "Materialized views"
            case .foreignTable: "Foreign tables"
            case .function: "Functions"
            }
        }

        public var symbol: String {
            switch self {
            case .table: "tablecells"
            case .view, .materializedView: "eye"
            case .foreignTable: "link"
            case .function: "function"
            }
        }

        /// Can be opened as rows.
        public var isRelation: Bool { self != .function }
    }

    public var schema: String?
    public var name: String
    public var kind: Kind

    public init(schema: String?, name: String, kind: Kind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }

    public var id: String { "\(schema ?? "")\u{1}\(name)\u{1}\(kind.rawValue)" }
    public var table: TableRef { TableRef(schema: schema, name: name) }
}

public struct TableRef: Hashable, Sendable {
    public var schema: String?
    public var name: String

    public init(schema: String?, name: String) {
        self.schema = schema
        self.name = name
    }
}

public struct ColumnInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var nullable: Bool
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var comment: String?
    public var extra: String?
    /// The allowed values, for enum types and CHECK (col IN (…)) constraints.
    public var enumValues: [String]?

    public init(name: String, type: String, nullable: Bool, defaultValue: String?, isPrimaryKey: Bool,
                comment: String? = nil, extra: String? = nil, enumValues: [String]? = nil) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.comment = comment
        self.extra = extra
        self.enumValues = enumValues
    }

    /// What kind of editor suits the column.
    public var editorKind: EditorKind { EditorKind(type: type, enumValues: enumValues) }

    public var id: String { name }
}

public struct IndexInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var columns: [String]
    public var unique: Bool
    public var primary: Bool
    public var definition: String?
    /// Postgres: the index belongs to a constraint (UNIQUE), so it's dropped through the constraint.
    public var isConstraint: Bool

    public init(name: String, columns: [String], unique: Bool, primary: Bool, definition: String? = nil, isConstraint: Bool = false) {
        self.name = name
        self.columns = columns
        self.unique = unique
        self.primary = primary
        self.definition = definition
        self.isConstraint = isConstraint
    }

    public var id: String { name }
}

/// A foreign key: `columns` of this table point at `refColumns` of `refTable`.
public struct ForeignKeyInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var columns: [String]
    public var refSchema: String?
    public var refTable: String
    public var refColumns: [String]
    public var onUpdate: String
    public var onDelete: String

    public init(name: String, columns: [String], refSchema: String?, refTable: String, refColumns: [String],
                onUpdate: String = "NO ACTION", onDelete: String = "NO ACTION") {
        self.name = name
        self.columns = columns
        self.refSchema = refSchema
        self.refTable = refTable
        self.refColumns = refColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    public var id: String { name + columns.joined(separator: ",") }
    public var target: TableRef { TableRef(schema: refSchema, name: refTable) }

    public static let actions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]
}

/// The editor a value gets in the row details.
public enum EditorKind: Equatable, Sendable {
    case text, json, date, dateTime, time, boolean, number, binary
    case choice([String])

    public init(type rawType: String, enumValues: [String]? = nil) {
        let t = rawType.lowercased()
        if let enumValues, !enumValues.isEmpty { self = .choice(enumValues); return }
        if t.hasPrefix("json") { self = .json }
        else if t == "date" { self = .date }
        else if t.hasPrefix("timestamp") || t.hasPrefix("datetime") { self = .dateTime }
        else if t.hasPrefix("time") { self = .time }
        else if t.hasPrefix("bool") || t == "tinyint(1)" { self = .boolean }
        else if t.contains("blob") || t.contains("binary") || t == "bytea" { self = .binary }
        else if ["int", "integer", "int2", "int4", "int8", "smallint", "bigint", "mediumint", "tinyint", "numeric", "decimal",
                 "real", "double", "float", "float4", "float8", "money", "double precision"].contains(where: { t == $0 || t.hasPrefix($0 + "(") || t.hasPrefix($0 + " ") }) {
            self = .number
        } else { self = .text }
    }
}

/// Everything the app needs from a database engine. One instance is one open connection and is
/// used from one thread at a time (the app's session queue); only `cancel()` may be called from another.
public protocol Driver: AnyObject {
    var kind: DatabaseKind { get }
    var serverVersion: String { get }
    var dialect: Dialect { get }

    /// Runs one or more statements. Results past `rowLimit` rows are read and dropped.
    func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult]
    /// Asks the server to stop the running statement. Safe to call from any thread.
    func cancel()
    func close()

    func databases() throws -> [String]
    var currentDatabase: String? { get }
    func use(database: String) throws
    /// Schemas (Postgres); empty for engines without them.
    func schemas() throws -> [String]
    func objects(schema: String?) throws -> [DBObject]
    func columns(of table: TableRef) throws -> [ColumnInfo]
    func indexes(of table: TableRef) throws -> [IndexInfo]
    /// The CREATE statement, when the engine can give it.
    func definition(of object: DBObject) throws -> String?
    func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo]
    /// A fast row count from the statistics, if the engine keeps one. May be stale.
    func estimatedCount(of table: TableRef) throws -> Int?
}

public extension Driver {
    func execute(_ sql: String) throws -> [QueryResult] { try execute(sql, rowLimit: .max) }

    /// The first result of a statement that returns rows.
    func rows(_ sql: String) throws -> [[String?]] {
        try execute(sql).first(where: \.hasRows)?.rows ?? []
    }
}

public extension Driver {
    /// Runs statements as one unit where the engine can: a transaction (rolled back on any error), one
    /// BEGIN … COMMIT script (Snowflake, BigQuery), or one by one (engines without transactions).
    /// With `checkFound`, an UPDATE or DELETE that matched no row stops it (and rolls back where possible).
    func runAsUnit(_ statements: [String], checkFound: Bool = false) throws {
        func run(_ s: String) throws {
            let r = try execute(s)
            if checkFound, let n = r.last?.affectedRows, n == 0, !s.uppercased().hasPrefix("INSERT"), !s.contains(".insertOne(") {
                throw DatabaseError("A row wasn't found any more, so nothing was saved.",
                                    detail: "Someone may have changed or removed it. Refresh and try again.\n\n\(s)")
            }
        }
        switch dialect.transactions {
        case .statements(let begin):
            _ = try execute(begin)
            do {
                for s in statements { try run(s) }
                _ = try execute("COMMIT")
            } catch {
                _ = try? execute("ROLLBACK")
                throw error
            }
        case .script(let begin, let commit):
            _ = try execute(([begin] + statements + [commit]).joined(separator: ";\n"))
        case .none:
            for s in statements { try run(s) }
        }
    }
}

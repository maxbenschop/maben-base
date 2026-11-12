import Foundation

/// A database's own command-line tool kept running, fed one statement at a time. After each statement the
/// tool is asked to print a marker line, so we know where its output ends.
final class ToolProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()
    private let arrived = DispatchSemaphore(value: 0)
    private(set) var exited = false

    init(executable: String, arguments: [String], environment: [String: String] = [:]) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw DatabaseError("\((executable as NSString).lastPathComponent) wasn't found at \(executable).")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "AI_AGENT")
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.append(h.availableData, error: false) }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in self?.append(h.availableData, error: true) }
        process.terminationHandler = { [weak self] _ in
            self?.lock.lock(); self?.exited = true; self?.lock.unlock()
            self?.arrived.signal()
        }
        try process.run()
    }

    private func append(_ data: Data, error: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if error { errBuffer.append(data) } else { outBuffer.append(data) }
        lock.unlock()
        arrived.signal()
    }

    func send(_ text: String) throws {
        guard !exited else { throw DatabaseError("The database tool stopped.", detail: drainError()) }
        try stdin.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    /// Output up to the marker line (exclusive), and whatever the tool wrote to stderr meanwhile.
    func read(until marker: String) throws -> (output: String, errors: String) {
        let needle = Data((marker + "\n").utf8)
        while true {
            lock.lock()
            if let r = outBuffer.range(of: needle) {
                let out = outBuffer.subdata(in: 0..<r.lowerBound)
                outBuffer.removeSubrange(0..<r.upperBound)
                lock.unlock()
                // stderr is a separate pipe: give what was written before the marker a moment to arrive.
                usleep(15_000)
                return (String(decoding: out, as: UTF8.self), drainError())
            }
            let dead = exited
            lock.unlock()
            if dead { throw DatabaseError("The database tool stopped.", detail: drainError() + String(decoding: outBuffer, as: UTF8.self)) }
            arrived.wait()
        }
    }

    func drainError() -> String {
        lock.lock(); defer { lock.unlock() }
        let s = String(decoding: errBuffer, as: UTF8.self)
        errBuffer.removeAll()
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func interrupt() { if process.isRunning { process.interrupt() } }

    func close() {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    static func find(_ name: String, configured: String?) -> String? {
        if let configured, !configured.isEmpty { return (configured as NSString).expandingTildeInPath }
        return BackupTool.find(name) ?? ["/opt/homebrew/bin", "/usr/local/bin", "/opt/oracle/instantclient", NSHomeDirectory() + "/instantclient"]
            .map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// CSV that keeps track of which fields were quoted (Oracle prints NULL as an empty unquoted field).
enum ToolCSV {
    static func parse(_ text: String) -> [[(value: String, quoted: Bool)]] {
        var rows: [[(String, Bool)]] = []
        var row: [(String, Bool)] = []
        var field = ""
        var quoted = false
        var inQuotes = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))[...]
        while let c = chars.popFirst() {
            if inQuotes {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true; quoted = true
            } else if c == "," {
                row.append((field, quoted)); field = ""; quoted = false
            } else if c == "\n" {
                row.append((field, quoted)); field = ""; quoted = false
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append((field, quoted)); rows.append(row) }
        return rows
    }
}

// MARK: - DuckDB

/// DuckDB through its own command-line tool (brew install duckdb), on a .duckdb file or in memory.
public final class DuckDBDriver: Driver {
    public let kind = DatabaseKind.duckdb
    public let dialect = Dialect(kind: .duckdb)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?
    private let tool: ToolProcess
    static let null = "\u{1}MB_NULL\u{1}"

    public init(path: String, readOnly: Bool, toolPath: String?) throws {
        guard let exe = ToolProcess.find("duckdb", configured: toolPath) else {
            throw DatabaseError("The duckdb tool isn't installed.", detail: "Install it with Homebrew: brew install duckdb")
        }
        var args = ["-no-agent", "-csv", "-header", "-nullvalue", Self.null]
        if readOnly { args.append("-readonly") }
        if !path.isEmpty { args.append(path) }
        tool = try ToolProcess(executable: exe, arguments: args)
        try tool.send(".changes on\n")
        serverVersion = "DuckDB " + (try rows("SELECT version()").first?[0] ?? "")
        currentDatabase = try rows("SELECT current_database()").first?[0] ?? nil
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        var out: [QueryResult] = []
        for statement in SQLText.statements(in: sql).map(\.sql) {
            let marker = "__MB_END_\(UUID().uuidString)__"
            try tool.send(statement + ";\n.print \(marker)\n")
            let (output, errors) = try tool.read(until: marker)
            if !errors.isEmpty {
                var e = DatabaseError(errors.components(separatedBy: "\n").first ?? errors, detail: errors.contains("\n") ? errors : nil)
                e.completed = out
                throw e
            }
            out.append(Self.result(output, rowLimit: rowLimit))
            if statement.lowercased().hasPrefix("use ") { currentDatabase = try rows("SELECT current_database()").first?[0] ?? currentDatabase }
        }
        return out
    }

    static func result(_ output: String, rowLimit: Int) -> QueryResult {
        let trimmed = output.trimmingCharacters(in: .newlines)
        if trimmed.isEmpty { return QueryResult(message: "Done") }
        if trimmed.hasPrefix("changes:") {
            let n = trimmed.split(separator: " ").dropFirst().first.flatMap { Int($0) }
            return QueryResult(affectedRows: n, message: "\(n ?? 0) rows affected")
        }
        var lines = ToolCSV.parse(output)
        // A statement that returns rows and also counts changes ends with a changes line.
        if let last = lines.last, last.count == 1, last[0].value.hasPrefix("changes:") { lines.removeLast() }
        guard let header = lines.first else { return QueryResult() }
        let rows = lines.dropFirst().prefix(rowLimit).map { $0.map { $0.value == null ? nil : $0.value } }
        return QueryResult(columns: header.map { ResultColumn(name: $0.value, typeName: "") }, rows: Array(rows),
                           message: "\(rows.count) rows", truncated: lines.count - 1 > rowLimit)
    }

    public func cancel() { tool.interrupt() }
    public func close() { tool.close() }

    public func databases() throws -> [String] { try rows("SELECT database_name FROM duckdb_databases() WHERE NOT internal ORDER BY 1").compactMap { $0[0] } }
    public func use(database: String) throws {
        _ = try execute("USE \(dialect.quote(database))")
        currentDatabase = database
    }
    public func schemas() throws -> [String] {
        try rows("SELECT schema_name FROM duckdb_schemas() WHERE database_name = current_database() AND schema_name NOT IN ('pg_catalog', 'information_schema') ORDER BY schema_name = 'main' DESC, 1").compactMap { $0[0] }
    }

    public func objects(schema: String?) throws -> [DBObject] {
        let s = dialect.literal(schema ?? "main")
        var out: [DBObject] = try rows("""
            SELECT table_name, table_type FROM information_schema.tables WHERE table_catalog = current_database() AND table_schema = \(s) ORDER BY 1
            """).compactMap { r in r[0].map { DBObject(schema: schema ?? "main", name: $0, kind: r[1] == "VIEW" ? .view : .table) } }
        out += try rows("SELECT DISTINCT function_name FROM duckdb_functions() WHERE schema_name = \(s) AND NOT internal ORDER BY 1")
            .compactMap { $0[0].map { DBObject(schema: schema ?? "main", name: $0, kind: .function) } }
        return out
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        let s = dialect.literal(table.schema ?? "main"), t = dialect.literal(table.name)
        let pk = Set(try rows("""
            SELECT unnest(constraint_column_names) FROM duckdb_constraints() WHERE schema_name = \(s) AND table_name = \(t) AND constraint_type = 'PRIMARY KEY'
            """).compactMap { $0[0] })
        return try rows("""
            SELECT column_name, data_type, is_nullable, column_default, comment FROM duckdb_columns()
            WHERE schema_name = \(s) AND table_name = \(t) ORDER BY column_index
            """).map { r in
            let type = r[1] ?? ""
            return ColumnInfo(name: r[0] ?? "", type: type, nullable: r[2] == "true", defaultValue: r[3], isPrimaryKey: pk.contains(r[0] ?? ""),
                              comment: (r[4] ?? "").isEmpty ? nil : r[4], enumValues: type.hasPrefix("ENUM(") ? SQLText.quotedList(type) : nil)
        }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        try rows("""
            SELECT index_name, is_unique, is_primary, sql, expressions FROM duckdb_indexes()
            WHERE schema_name = \(dialect.literal(table.schema ?? "main")) AND table_name = \(dialect.literal(table.name))
            """).map { r in
            IndexInfo(name: r[0] ?? "", columns: SQLText.quotedList((r[4] ?? "").replacingOccurrences(of: "\"", with: "'")).isEmpty
                        ? [r[4] ?? ""] : SQLText.quotedList((r[4] ?? "").replacingOccurrences(of: "\"", with: "'")),
                      unique: r[1] == "true", primary: r[2] == "true", definition: r[3])
        }
    }

    public func definition(of object: DBObject) throws -> String? {
        let s = dialect.literal(object.schema ?? "main"), n = dialect.literal(object.name)
        switch object.kind {
        case .view: return try rows("SELECT sql FROM duckdb_views() WHERE schema_name = \(s) AND view_name = \(n)").first?[0] ?? nil
        case .function: return try rows("SELECT macro_definition FROM duckdb_functions() WHERE schema_name = \(s) AND function_name = \(n) LIMIT 1").first?[0] ?? nil
        default: return try rows("SELECT sql FROM duckdb_tables() WHERE schema_name = \(s) AND table_name = \(n)").first?[0] ?? nil
        }
    }

    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] {
        try rows("""
            SELECT constraint_text FROM duckdb_constraints() WHERE schema_name = \(dialect.literal(table.schema ?? "main"))
              AND table_name = \(dialect.literal(table.name)) AND constraint_type = 'FOREIGN KEY'
            """).enumerated().compactMap { i, r -> ForeignKeyInfo? in
            // FOREIGN KEY (a, b) REFERENCES other(x, y)
            guard let text = r[0], let refRange = text.range(of: "REFERENCES ") else { return nil }
            let cols = text[..<refRange.lowerBound].components(separatedBy: CharacterSet(charactersIn: "()"))[safe: 1]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            let rest = text[refRange.upperBound...]
            let refTable = rest.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
            let refCols = rest.components(separatedBy: CharacterSet(charactersIn: "()"))[safe: 1]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            return ForeignKeyInfo(name: "fk_\(table.name)_\(i)", columns: cols, refSchema: table.schema, refTable: refTable, refColumns: refCols)
        }
    }

    public func estimatedCount(of table: TableRef) throws -> Int? {
        try rows("SELECT estimated_size FROM duckdb_tables() WHERE schema_name = \(dialect.literal(table.schema ?? "main")) AND table_name = \(dialect.literal(table.name))")
            .first?[0].flatMap { $0 }.flatMap { Int($0) }
    }
}

// MARK: - Oracle

/// Oracle through SQL*Plus (Oracle Instant Client's sqlplus, 12.2 or later for CSV output). The password is
/// sent on standard input, never on the command line.
public final class OracleDriver: Driver {
    public let kind = DatabaseKind.oracle
    public let dialect = Dialect(kind: .oracle)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?
    private let tool: ToolProcess
    private let user: String

    public init(host: String, port: Int, user: String, password: String, service: String, toolPath: String?) throws {
        guard let exe = ToolProcess.find("sqlplus", configured: toolPath) else {
            throw DatabaseError("sqlplus isn't installed.", detail: "Maben Base talks to Oracle through Oracle Instant Client's sqlplus. Install Instant Client (Basic and SQL*Plus) and set its path in the connection's Tool field.")
        }
        self.user = user
        tool = try ToolProcess(executable: exe, arguments: ["-S", "-L", "/nolog"])
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "") + "\"" }
        let target = "//\(host):\(port)/\(service.isEmpty ? "FREEPDB1" : service)"
        let settings = """
            WHENEVER SQLERROR CONTINUE
            SET MARKUP CSV ON QUOTE ON
            SET PAGESIZE 50000
            SET FEEDBACK ON
            SET TERMOUT ON
            SET ECHO OFF
            SET VERIFY OFF
            SET SQLBLANKLINES ON
            SET DEFINE OFF
            SET LONG 10000000
            SET LONGCHUNKSIZE 10000000
            SET NUMWIDTH 40
            ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
            ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF';
            ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
            """
        let marker = "__MB_END_\(UUID().uuidString)__"
        // A plain user name stays unquoted (Oracle upper-cases it); the password is quoted (it's case-sensitive).
        let plainUser = user.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "#" }
        try tool.send("CONNECT \(plainUser ? user : q(user))/\(q(password))@\(target)\n\(settings)\nPROMPT \(marker)\n")
        let (output, errors) = try tool.read(until: marker)
        if let e = Self.error(output + "\n" + errors) { throw DatabaseError("Oracle refused the connection.", detail: e) }
        serverVersion = "Oracle " + (try rows("SELECT version_full FROM product_component_version WHERE ROWNUM = 1").first?[0] ?? "")
        currentDatabase = try rows("SELECT sys_context('USERENV', 'CON_NAME') FROM dual").first?[0] ?? service
    }

    static func error(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let errs = lines.filter { $0.hasPrefix("ORA-") || $0.hasPrefix("SP2-") || $0.hasPrefix("PLS-") || $0.hasPrefix("ERROR:") }
        guard !errs.isEmpty else { return nil }
        return errs.filter { $0 != "ERROR:" }.joined(separator: "\n")
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        var out: [QueryResult] = []
        for raw in SQLText.statements(in: sql).map(\.sql) {
            let isBlock = raw.range(of: #"^\s*(BEGIN|DECLARE|CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION|PACKAGE|TRIGGER|TYPE))"#, options: [.regularExpression, .caseInsensitive]) != nil
            let statement = isBlock ? raw + ";" : raw
            let marker = "__MB_END_\(UUID().uuidString)__"
            try tool.send("\(statement)\n/\nPROMPT \(marker)\n")
            let (output, errors) = try tool.read(until: marker)
            if let e = Self.error(output + "\n" + errors) {
                var err = DatabaseError(e.components(separatedBy: "\n").first ?? e, detail: e.contains("\n") ? e : nil)
                err.completed = out
                throw err
            }
            out.append(Self.result(output, rowLimit: rowLimit))
        }
        return out
    }

    /// CSV with a header, then a feedback line ("3 rows selected.", "1 row created.", "Table created.").
    static func result(_ output: String, rowLimit: Int) -> QueryResult {
        var lines = output.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        var feedback = ""
        if let last = lines.last, !last.hasPrefix("\"") && (last.hasSuffix(".") || last == "no rows selected") {
            feedback = last
            lines.removeLast()
        }
        let n = feedback.split(separator: " ").first.flatMap { Int($0) }
        let csv = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if csv.isEmpty {
            if feedback.hasPrefix("no rows") { return QueryResult(columns: [], rows: [], message: feedback) }
            return QueryResult(affectedRows: feedback.contains("row") ? n : nil, message: feedback.isEmpty ? "Done" : feedback)
        }
        let parsed = ToolCSV.parse(csv)
        guard let header = parsed.first else { return QueryResult() }
        let rows = parsed.dropFirst().prefix(rowLimit).map { $0.map { $0.value.isEmpty && !$0.quoted ? nil : $0.value } }
        return QueryResult(columns: header.map { ResultColumn(name: $0.value, typeName: "") }, rows: Array(rows),
                           message: feedback, truncated: parsed.count - 1 > rowLimit)
    }

    public func cancel() { tool.interrupt() }

    public func close() {
        try? tool.send("EXIT\n")
        tool.close()
    }

    public func databases() throws -> [String] { [currentDatabase].compactMap { $0 } }
    public func use(database: String) throws {}

    /// Schemas are users that own something.
    public func schemas() throws -> [String] { [] }

    public func objects(schema: String?) throws -> [DBObject] {
        var out: [DBObject] = try rows("SELECT table_name FROM user_tables ORDER BY 1").compactMap { $0[0].map { DBObject(schema: nil, name: $0, kind: .table) } }
        out += try rows("SELECT view_name FROM user_views ORDER BY 1").compactMap { $0[0].map { DBObject(schema: nil, name: $0, kind: .view) } }
        out += try rows("SELECT mview_name FROM user_mviews ORDER BY 1").compactMap { $0[0].map { DBObject(schema: nil, name: $0, kind: .materializedView) } }
        out += try rows("SELECT object_name FROM user_objects WHERE object_type IN ('FUNCTION', 'PROCEDURE', 'PACKAGE') ORDER BY 1")
            .compactMap { $0[0].map { DBObject(schema: nil, name: $0, kind: .function) } }
        return out
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        let t = dialect.literal(table.name)
        let pk = Set(try rows("""
            SELECT cc.column_name FROM user_constraints c JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name
            WHERE c.table_name = \(t) AND c.constraint_type = 'P'
            """).compactMap { $0[0] })
        return try rows("""
            SELECT c.column_name,
                   c.data_type || CASE WHEN c.data_type IN ('VARCHAR2', 'NVARCHAR2', 'CHAR', 'NCHAR', 'RAW') THEN '(' || c.char_length || ')'
                                       WHEN c.data_type = 'NUMBER' AND c.data_precision IS NOT NULL THEN '(' || c.data_precision || ',' || c.data_scale || ')' END,
                   c.nullable, c.data_default, m.comments, c.identity_column
            FROM user_tab_columns c LEFT JOIN user_col_comments m ON m.table_name = c.table_name AND m.column_name = c.column_name
            WHERE c.table_name = \(t) ORDER BY c.column_id
            """).map { r in
            ColumnInfo(name: r[0] ?? "", type: (r[1] ?? "").lowercased(), nullable: r[2] == "Y", defaultValue: r[3]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       isPrimaryKey: pk.contains(r[0] ?? ""), comment: r[4], extra: r[5] == "YES" ? "identity" : nil)
        }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        var byName: [String: IndexInfo] = [:]
        var order: [String] = []
        for r in try rows("""
            SELECT i.index_name, ic.column_name, i.uniqueness, CASE WHEN c.constraint_type = 'P' THEN 'Y' END
            FROM user_indexes i JOIN user_ind_columns ic ON ic.index_name = i.index_name
            LEFT JOIN user_constraints c ON c.index_name = i.index_name AND c.constraint_type = 'P'
            WHERE i.table_name = \(dialect.literal(table.name)) ORDER BY i.index_name, ic.column_position
            """) {
            guard let name = r[0], let col = r[1] else { continue }
            if byName[name] == nil { order.append(name); byName[name] = IndexInfo(name: name, columns: [], unique: r[2] == "UNIQUE", primary: r[3] == "Y") }
            byName[name]!.columns.append(col)
        }
        return order.compactMap { byName[$0] }
    }

    public func definition(of object: DBObject) throws -> String? {
        let type = switch object.kind {
        case .view: "VIEW"
        case .materializedView: "MATERIALIZED_VIEW"
        case .function: (try rows("SELECT object_type FROM user_objects WHERE object_name = \(dialect.literal(object.name)) AND ROWNUM = 1").first?[0] ?? nil) ?? "FUNCTION"
        default: "TABLE"
        }
        return try rows("SELECT DBMS_METADATA.GET_DDL(\(dialect.literal(type)), \(dialect.literal(object.name))) FROM dual").first?[0] ?? nil
    }

    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] {
        var byName: [String: ForeignKeyInfo] = [:]
        var order: [String] = []
        for r in try rows("""
            SELECT c.constraint_name, cc.column_name, rc.table_name, rcc.column_name, c.delete_rule
            FROM user_constraints c
            JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name
            JOIN user_constraints rc ON rc.constraint_name = c.r_constraint_name
            JOIN user_cons_columns rcc ON rcc.constraint_name = rc.constraint_name AND rcc.position = cc.position
            WHERE c.table_name = \(dialect.literal(table.name)) AND c.constraint_type = 'R' ORDER BY c.constraint_name, cc.position
            """) {
            guard let name = r[0], let col = r[1], let refTable = r[2], let refCol = r[3] else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = ForeignKeyInfo(name: name, columns: [], refSchema: nil, refTable: refTable, refColumns: [], onDelete: r[4] ?? "NO ACTION")
            }
            byName[name]!.columns.append(col)
            byName[name]!.refColumns.append(refCol)
        }
        return order.compactMap { byName[$0] }
    }

    public func estimatedCount(of table: TableRef) throws -> Int? {
        try rows("SELECT num_rows FROM user_tables WHERE table_name = \(dialect.literal(table.name))").first?[0].flatMap { $0 }.flatMap { Int($0) }
    }
}

/// Where a database's command-line tool is (a configured path, or the usual install places).
public enum ToolFinder {
    public static func find(_ name: String, configured: String?) -> String? { ToolProcess.find(name, configured: configured) }
}

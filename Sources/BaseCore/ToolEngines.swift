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

    /// `configured` is the path typed in the connection's editor on this Mac (`ConnectionConfig.localToolPath`):
    /// it is the one setting that names a program to run, so it never comes from a URL, a file or sync.
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
        // As a full path, so a file name can never be read as one of the tool's options.
        if !path.isEmpty { args.append(URL(fileURLWithPath: path).path) }
        tool = try ToolProcess(executable: exe, arguments: args)
        try tool.send(".changes on\n")
        serverVersion = "DuckDB " + (try rows("SELECT version()").first?[0] ?? "")
        currentDatabase = try rows("SELECT current_database()").first?[0] ?? nil
    }

    /// Runs SQL from anywhere but the editor: a file being imported, or statements the app wrote. The duckdb
    /// tool reads a line that starts with a dot as one of its own commands, and those reach this Mac
    /// (.shell runs a program, .output and .read open files), so here such a line is refused.
    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] { try run(sql, rowLimit: rowLimit, typed: false) }

    /// What you typed in the query editor: the tool's dot commands work, as they do in a terminal.
    public func executeTyped(_ sql: String, rowLimit: Int) throws -> [QueryResult] { try run(sql, rowLimit: rowLimit, typed: true) }

    private func run(_ sql: String, rowLimit: Int, typed: Bool) throws -> [QueryResult] {
        var out: [QueryResult] = []
        for statement in SQLText.statements(in: sql).map(\.sql) {
            if !typed, let line = DuckDBText.dotCommand(in: statement) {
                var e = DatabaseError("A line would run a command of the duckdb tool, not SQL: \(line.prefix(60))",
                                      detail: "Lines that start with a dot (.shell, .read, .output, …) can run programs and open files on this Mac. They only run when you type them in the query editor.")
                e.completed = out
                throw e
            }
            let marker = "__MB_END_\(UUID().uuidString)__"
            // A typed dot command on a line of its own goes as it is: with a semicolon after it, the tool
            // would hand the semicolon to the command as one more argument.
            let isCommand = typed && !statement.contains(where: \.isNewline) && DuckDBText.dotCommand(in: statement) != nil
            try tool.send(statement + (isCommand ? "" : ";") + "\n.print \(marker)\n")
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
        var result = QueryResult(columns: header.map { ResultColumn(name: $0.value, typeName: "") }, rows: Array(rows),
                                 message: "\(rows.count) rows", truncated: lines.count - 1 > rowLimit)
        result.squareUp()
        return result
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

/// Reading SQL the way the duckdb tool does, to tell which lines it would take as its own commands.
enum DuckDBText {
    /// The first line the tool would read as a dot command: one that starts with a dot while no statement is
    /// under way. Lines inside a string, a quoted name or a dollar-quoted string are part of that value and
    /// are never commands, so data with such lines is fine. Comments don't count as a statement under way.
    static func dotCommand(in sql: String) -> String? {
        let chars = Array(sql)
        var i = 0
        var pending = false  // SQL seen since the last ; that ended a statement
        var lineStart = true
        func line(from start: Int) -> String { String(chars[start...].prefix(while: { $0 != "\n" && $0 != "\r\n" && $0 != "\r" })) }
        func isBreak(_ c: Character) -> Bool { c == "\n" || c == "\r\n" || c == "\r" }
        while i < chars.count {
            let c = chars[i]
            if lineStart {
                if c == " " || c == "\t" { i += 1; continue }
                if c == "." && !pending { return line(from: i) }
                lineStart = false
            }
            if isBreak(c) { lineStart = true; i += 1; continue }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                while i < chars.count, !isBreak(chars[i]) { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                // Checked line by line, as if it weren't a comment: refusing too much here costs a clearer file, too little a command.
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") {
                    if isBreak(chars[i]) {
                        var j = i + 1
                        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                        if j < chars.count, chars[j] == ".", !pending { return line(from: j) }
                    }
                    i += 1
                }
                i += 2
                continue
            }
            if c == "'" || c == "\"" {
                pending = true
                i += 1
                while i < chars.count {
                    if chars[i] == c {
                        if i + 1 < chars.count, chars[i + 1] == c { i += 2; continue }
                        break
                    }
                    i += 1
                }
                i += 1
                continue
            }
            if c == "$" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                if j < chars.count, chars[j] == "$" {
                    let tag = Array(chars[i...j])
                    var k = j + 1
                    while k + tag.count <= chars.count, Array(chars[k..<k + tag.count]) != tag { k += 1 }
                    pending = true
                    i = min(chars.count, k + tag.count)
                    continue
                }
            }
            if c == ";" { pending = false } else if !c.isWhitespace { pending = true }
            i += 1
        }
        return nil
    }
}

// MARK: - Oracle

/// What goes to SQL*Plus on its standard input. SQL*Plus reads a line at a time and has commands of its own
/// (HOST runs a program), so nothing that came from a database or a settings field may start or end a line.
enum OracleText {
    /// The settings that go in before signing in. DEFINE, ESCAPE and CMDSEP are off so that &, \ and ; in a
    /// value, or in the password on the CONNECT line, are only characters.
    static let settings = """
        WHENEVER SQLERROR CONTINUE
        SET DEFINE OFF
        SET ESCAPE OFF
        SET CMDSEP OFF
        SET MARKUP CSV ON QUOTE ON
        SET PAGESIZE 50000
        SET FEEDBACK ON
        SET TERMOUT ON
        SET ECHO OFF
        SET VERIFY OFF
        SET SQLBLANKLINES ON
        SET LONG 10000000
        SET LONGCHUNKSIZE 10000000
        SET NUMWIDTH 40
        """

    static let session = """
        ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
        ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF';
        ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
        """

    /// -R 3 is SQL*Plus's restricted mode: HOST, !, @, START, SPOOL, EDIT, GET, SAVE and STORE are off, so
    /// even a line that did get through couldn't run a program or touch a file.
    static let arguments = ["-S", "-L", "-R", "3", "/nolog"]

    /// The CONNECT line. Each part is one field of the connection; a line break in any of them would start
    /// a new line for SQL*Plus to read as a command, so control characters are refused, and so is anything
    /// that would end the part it is in.
    static func connectLine(user: String, password: String, host: String, port: Int, service: String) throws -> String {
        func refuse(_ what: String) -> DatabaseError {
            DatabaseError("The \(what) has a character that can't be used with sqlplus.", detail: "Line breaks, control characters and double quotes can't be sent to it.")
        }
        for (what, value) in [("user name", user), ("password", password), ("host", host), ("service", service)] {
            if ConnectionConfig.hasControl(value) || value.contains("\"") { throw refuse(what) }
        }
        if host.isEmpty || host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) { throw refuse("host") }
        if service.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) { throw refuse("service") }
        guard (1...65535).contains(port) else { throw DatabaseError("\(port) isn't a port number.") }
        // A plain user name stays unquoted (Oracle upper-cases it); the password is quoted (it's case-sensitive).
        let plainUser = user.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "#" }
        return "CONNECT \(plainUser ? user : "\"\(user)\"")/\"\(password)\"@//\(host):\(port)/\(service.isEmpty ? "FREEPDB1" : service)"
    }

    /// Refuses a statement in which a quoted name holds a line break or another control character. A table
    /// or column can be named that way, and its name would then put a line of its own in front of SQL*Plus.
    /// (Values never do: the app writes their control characters as CHR(n), see `Dialect.literal`.)
    static func check(_ statement: String) throws {
        let chars = Array(statement)
        var i = 0
        func skipString(_ quote: Character) {
            i += 1
            while i < chars.count {
                if chars[i] == quote {
                    if i + 1 < chars.count, chars[i + 1] == quote { i += 2; continue }
                    break
                }
                i += 1
            }
            i += 1
        }
        while i < chars.count {
            let c = chars[i]
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if (c == "q" || c == "Q"), i + 2 < chars.count, chars[i + 1] == "'", i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_") || "nN".contains(chars[i - 1]) {
                // q'[ … ]': ends at the closing delimiter followed by a quote.
                let open = chars[i + 2]
                let close: Character = ["[": "]", "{": "}", "(": ")", "<": ">"][open] ?? open
                i += 3
                while i < chars.count, !(chars[i] == close && i + 1 < chars.count && chars[i + 1] == "'") { i += 1 }
                i += 2
            } else if c == "'" {
                skipString("'")
            } else if c == "\"" {
                let start = i
                skipString("\"")
                let name = String(chars[start..<min(i, chars.count)])
                if ConnectionConfig.hasControl(name) {
                    throw DatabaseError("A quoted name in this statement has a line break or another control character in it.",
                                        detail: "sqlplus reads a line at a time, so a name like that can't be sent to it safely. Nothing was run.")
                }
            } else {
                i += 1
            }
        }
    }
}

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
        let connect = try OracleText.connectLine(user: user, password: password, host: host, port: port, service: service)
        tool = try ToolProcess(executable: exe, arguments: OracleText.arguments)
        let marker = "__MB_END_\(UUID().uuidString)__"
        try tool.send("\(OracleText.settings)\n\(connect)\n\(OracleText.session)\nPROMPT \(marker)\n")
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
            do { try OracleText.check(raw) } catch var e as DatabaseError {
                e.completed = out
                throw e
            }
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
        var result = QueryResult(columns: header.map { ResultColumn(name: $0.value, typeName: "") }, rows: Array(rows),
                                 message: feedback, truncated: parsed.count - 1 > rowLimit)
        result.squareUp()
        return result
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

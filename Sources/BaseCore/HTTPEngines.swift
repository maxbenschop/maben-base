import Foundation

// MARK: - ClickHouse

/// ClickHouse over its HTTP interface (8123, or 8443 with TLS). Each statement is one request; results come
/// back as TabSeparatedWithNamesAndTypes. Rows are changed with ALTER TABLE … UPDATE/DELETE (mutations).
public final class ClickHouseDriver: Driver {
    public let kind = DatabaseKind.clickhouse
    public let dialect = Dialect(kind: .clickhouse)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?
    private let http: HTTPClient
    private let base: URL
    private let headers: [String: String]
    private var queryID: String?

    public init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        http = HTTPClient(tls: tls, host: host)
        guard let base = HTTPClient.baseURL(host: host, port: port, secure: tls.mode != .off) else { throw DatabaseError("\(host) isn't a valid address.") }
        self.base = base
        headers = ["X-ClickHouse-User": user.isEmpty ? "default" : user, "X-ClickHouse-Key": password]
        currentDatabase = database.isEmpty ? "default" : database
        serverVersion = try rows("SELECT version()").first?[0] ?? ""
    }

    private func request(_ sql: String) throws -> (QueryResult, HTTPClient.Response) {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let id = UUID().uuidString
        queryID = id
        c.queryItems = [URLQueryItem(name: "database", value: currentDatabase), URLQueryItem(name: "query_id", value: id),
                        URLQueryItem(name: "default_format", value: "TabSeparatedWithNamesAndTypes"),
                        URLQueryItem(name: "send_progress_in_http_headers", value: "0")]
        let r = try http.send(c.url!, headers: headers, body: Data(sql.utf8))
        guard r.status == 200 else {
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = text.range(of: #"Code: (\d+)"#, options: .regularExpression).map { String(text[$0].dropFirst(6)) }
            let message = text.replacingOccurrences(of: #"^Code: \d+\. DB::Exception: "#, with: "", options: .regularExpression)
                .components(separatedBy: " (version ").first ?? text
            throw DatabaseError(message, code: code)
        }
        return (Self.parseTSV(r.text), r)
    }

    /// TabSeparatedWithNamesAndTypes: names, types, then rows; \N is NULL and \t \n \\ are escaped.
    static func parseTSV(_ text: String) -> QueryResult {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 2 else { return QueryResult() }
        func unescape(_ s: Substring) -> String? {
            if s == "\\N" { return nil }
            guard s.contains("\\") else { return String(s) }
            var out = ""
            var it = s.makeIterator()
            while let c = it.next() {
                if c == "\\", let n = it.next() {
                    switch n { case "t": out.append("\t"); case "n": out.append("\n"); case "r": out.append("\r"); case "0": out.append("\0"); default: out.append(n) }
                } else { out.append(c) }
            }
            return out
        }
        let names = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map { unescape($0) ?? "" }
        let types = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let columns = zip(names, types).map { ResultColumn(name: $0, typeName: $1) }
        let rows = lines.dropFirst(2).map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(unescape) }
        return QueryResult(columns: columns, rows: Array(rows), message: "\(rows.count) row\(rows.count == 1 ? "" : "s")")
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        var out: [QueryResult] = []
        for s in SQLText.statements(in: sql).map(\.sql) {
            do {
                var (result, response) = try request(s)
                if result.rows.count > rowLimit { result.rows = Array(result.rows.prefix(rowLimit)); result.truncated = true }
                if !result.hasRows {
                    let summary = response.headers["x-clickhouse-summary"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                    result.affectedRows = (summary?["written_rows"] as? String).flatMap(Int.init)
                    result.message = result.affectedRows.map { "\($0) rows written" } ?? "Done"
                    if s.lowercased().hasPrefix("use ") { currentDatabase = s.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " ;`\"")) }
                }
                out.append(result)
            } catch var e as DatabaseError {
                e.completed = out
                throw e
            }
        }
        return out
    }

    public func cancel() {
        http.cancel()
        guard let id = queryID else { return }
        DispatchQueue.global().async { [base, headers, http] in
            var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "query", value: "KILL QUERY WHERE query_id = '\(id)'")]
            _ = try? http.send(c.url!, headers: headers)
        }
    }

    public func close() { http.close() }

    public func databases() throws -> [String] { try rows("SELECT name FROM system.databases ORDER BY name").compactMap { $0[0] } }
    public func use(database: String) throws {
        currentDatabase = database
        _ = try rows("SELECT 1")
    }
    public func schemas() throws -> [String] { [] }

    public func objects(schema: String?) throws -> [DBObject] {
        try rows("SELECT name, engine FROM system.tables WHERE database = currentDatabase() AND NOT is_temporary ORDER BY name").compactMap { r in
            guard let name = r[0] else { return nil }
            let kind: DBObject.Kind = r[1] == "View" ? .view : r[1] == "MaterializedView" ? .materializedView : .table
            return DBObject(schema: nil, name: name, kind: kind)
        }
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        try rows("""
            SELECT name, type, default_kind, default_expression, is_in_primary_key, comment FROM system.columns
            WHERE database = currentDatabase() AND table = \(dialect.literal(table.name)) ORDER BY position
            """).map { r in
            let type = r[1] ?? ""
            // Enum8('a' = 1, 'b' = 2): the quoted names.
            let enumValues: [String]? = type.hasPrefix("Enum") || type.hasPrefix("Nullable(Enum") ? SQLText.quotedList(type) : nil
            return ColumnInfo(name: r[0] ?? "", type: type, nullable: type.hasPrefix("Nullable"), defaultValue: (r[3] ?? "").isEmpty ? nil : r[3],
                              isPrimaryKey: r[4] == "1", comment: (r[5] ?? "").isEmpty ? nil : r[5],
                              extra: (r[2] ?? "").isEmpty ? nil : r[2]?.lowercased(), enumValues: enumValues)
        }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        var out: [IndexInfo] = []
        if let r = try rows("SELECT primary_key, sorting_key FROM system.tables WHERE database = currentDatabase() AND name = \(dialect.literal(table.name))").first {
            if let pk = r[0], !pk.isEmpty { out.append(IndexInfo(name: "primary key", columns: pk.components(separatedBy: ", "), unique: false, primary: true)) }
            if let sk = r[1], !sk.isEmpty, sk != r[0] { out.append(IndexInfo(name: "sorting key", columns: sk.components(separatedBy: ", "), unique: false, primary: false)) }
        }
        out += (try? rows("SELECT name, expr, type FROM system.data_skipping_indices WHERE database = currentDatabase() AND table = \(dialect.literal(table.name))"))?
            .map { IndexInfo(name: $0[0] ?? "", columns: [$0[1] ?? ""], unique: false, primary: false, definition: $0[2]) } ?? []
        return out
    }

    public func definition(of object: DBObject) throws -> String? { try rows("SHOW CREATE TABLE \(dialect.quote(object.name))").first?[0] ?? nil }
    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] { [] }
    public func estimatedCount(of table: TableRef) throws -> Int? {
        try rows("SELECT total_rows FROM system.tables WHERE database = currentDatabase() AND name = \(dialect.literal(table.name))").first?[0].flatMap { $0 }.flatMap { Int($0) }
    }
}

// MARK: - libSQL / Turso

/// libSQL (Turso, sqld) over the Hrana-over-HTTP pipeline API. A stream (baton) is kept between requests,
/// so transactions work. The schema is SQLite's.
public final class LibSQLDriver: Driver, SQLiteSchema {
    public let kind = DatabaseKind.libsql
    public let dialect = Dialect(kind: .libsql)
    public private(set) var serverVersion = "libSQL"
    public let currentDatabase: String? = "main"
    private let http: HTTPClient
    private var base: URL
    private let token: String
    private var baton: String?

    public init(host: String, port: Int, token: String, tls: TLSOptions) throws {
        http = HTTPClient(tls: tls, host: host)
        var h = host
        if h.hasPrefix("libsql://") { h = "https://" + h.dropFirst(9) }
        guard let base = HTTPClient.baseURL(host: h, port: port, secure: tls.mode != .off || h.hasPrefix("https")) else {
            throw DatabaseError("\(host) isn't a valid address.")
        }
        self.base = base
        self.token = token
        serverVersion = "libSQL " + (try rows("SELECT sqlite_version()").first?[0] ?? "")
    }

    private func pipeline(_ requests: [[String: Any]]) throws -> [Any] {
        var body: [String: Any] = ["requests": requests]
        if let baton { body["baton"] = baton }
        let (status, json) = try http.json(base.appendingPathComponent("v2/pipeline"), headers: token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"], body: body)
        guard let object = json as? [String: Any] else { throw DatabaseError("libSQL answered with HTTP \(status).") }
        if status == 401 || status == 403 { throw DatabaseError("libSQL refused the token.", detail: object["error"] as? String) }
        guard status == 200 else { throw DatabaseError((object["error"] as? String) ?? (object["message"] as? String) ?? "HTTP \(status)") }
        baton = object["baton"] as? String
        if let b = object["base_url"] as? String, let u = URL(string: b) { base = u }
        return object["results"] as? [Any] ?? []
    }

    static func value(_ v: Any) -> String? {
        guard let d = v as? [String: Any] else { return nil }
        switch d["type"] as? String {
        case "null": return nil
        case "integer", "text": return d["value"] as? String ?? (d["value"]).map { "\($0)" }
        case "float":
            if let n = d["value"] as? Double { return n == n.rounded() && abs(n) < 1e15 ? String(format: "%.1f", n) : String(n) }
            return (d["value"]).map { "\($0)" }
        case "blob": return (d["base64"] as? String).flatMap { Data(base64Encoded: $0) }.map { "0x" + $0.map { String(format: "%02X", $0) }.joined() }
        default: return (d["value"]).map { "\($0)" }
        }
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        var out: [QueryResult] = []
        for s in SQLText.statements(in: sql).map(\.sql) {
            let results = try pipeline([["type": "execute", "stmt": ["sql": s, "want_rows": true]]])
            guard let first = results.first as? [String: Any] else { continue }
            if first["type"] as? String == "error" {
                let e = first["error"] as? [String: Any]
                var err = DatabaseError(e?["message"] as? String ?? "The statement failed.", code: e?["code"] as? String)
                err.completed = out
                throw err
            }
            let result = ((first["response"] as? [String: Any])?["result"] as? [String: Any]) ?? [:]
            let cols = (result["cols"] as? [[String: Any]] ?? []).map {
                ResultColumn(name: $0["name"] as? String ?? "", typeName: ($0["decltype"] as? String ?? "any").lowercased())
            }
            var columns = cols
            var rows = (result["rows"] as? [[Any]] ?? []).prefix(rowLimit == .max ? .max : rowLimit + 1).map { $0.map(Self.value) }
            for (i, c) in columns.enumerated() where rows.contains(where: { $0[i]?.hasPrefix("0x") == true }) && c.typeName.contains("blob") {
                columns[i].isBinary = true
            }
            let truncated = rows.count > rowLimit
            if truncated { rows.removeLast() }
            let affected = result["affected_row_count"] as? Int
            out.append(QueryResult(columns: columns, rows: Array(rows), affectedRows: columns.isEmpty ? affected : nil,
                                   message: columns.isEmpty ? "\(affected ?? 0) rows affected" : "\(rows.count) rows", truncated: truncated))
        }
        return out
    }

    public func cancel() { http.cancel() }

    public func close() {
        if baton != nil { _ = try? pipeline([["type": "close"]]) }
        http.close()
    }

    public func databases() throws -> [String] { ["main"] }
    public func use(database: String) throws {}
    public func schemas() throws -> [String] { [] }
    public func objects(schema: String?) throws -> [DBObject] { try sqliteObjects() }
    public func columns(of table: TableRef) throws -> [ColumnInfo] { try sqliteColumns(table) }
    public func indexes(of table: TableRef) throws -> [IndexInfo] { try sqliteIndexes(table) }
    public func definition(of object: DBObject) throws -> String? { try sqliteDefinition(object) }
    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] { try sqliteForeignKeys(table) }
    public func estimatedCount(of table: TableRef) throws -> Int? { nil }
}

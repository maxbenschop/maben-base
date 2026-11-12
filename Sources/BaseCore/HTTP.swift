import Foundation

/// A blocking HTTPS client for the engines reached over HTTP (ClickHouse, libSQL, D1, Snowflake, BigQuery),
/// with the same TLS choices as the socket drivers, and a cancel that stops the request in flight.
final class HTTPClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let tls: TLSOptions
    private let host: String
    private let lock = NSLock()
    private var current: URLSessionTask?
    var timeout: TimeInterval = 600

    init(tls: TLSOptions, host: String) {
        self.tls = tls
        self.host = host
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    func send(_ url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) throws -> Response {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        let done = DispatchSemaphore(value: 0)
        var result: Result<Response, Error> = .failure(DatabaseError("No response."))
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                let ns = error as NSError
                result = .failure(ns.code == NSURLErrorCancelled ? DatabaseError("Stopped.") :
                                    DatabaseError("Couldn't reach \(url.host ?? "the server").", detail: error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                var h: [String: String] = [:]
                for (k, v) in http.allHeaderFields { h[String(describing: k).lowercased()] = String(describing: v) }
                result = .success(Response(status: http.statusCode, headers: h, body: data ?? Data()))
            }
            done.signal()
        }
        lock.lock(); current = task; lock.unlock()
        task.resume()
        done.wait()
        lock.lock(); current = nil; lock.unlock()
        return try result.get()
    }

    func json(_ url: URL, method: String = "POST", headers: [String: String] = [:], body: Any? = nil) throws -> (Int, Any?) {
        var h = headers
        var data: Data?
        if let body {
            data = try JSONSerialization.data(withJSONObject: body)
            h["Content-Type"] = "application/json"
        }
        h["Accept"] = "application/json"
        let r = try send(url, method: method, headers: h, body: data)
        return (r.status, try? JSONSerialization.jsonObject(with: r.body, options: [.fragmentsAllowed]))
    }

    func cancel() {
        lock.lock(); current?.cancel(); lock.unlock()
    }

    func close() { session.invalidateAndCancel() }

    // TLS: Require accepts any certificate; Verify checks it (against your CA when one is set); a client
    // certificate is offered when the server asks for one.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust {
            if tls.mode == .require || tls.mode == .prefer { return completionHandler(.useCredential, URLCredential(trust: trust)) }
            if !tls.anchors.isEmpty {
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, space.host as CFString))
                SecTrustSetAnchorCertificates(trust, tls.anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                return SecTrustEvaluateWithError(trust, nil) ? completionHandler(.useCredential, URLCredential(trust: trust))
                                                             : completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return completionHandler(.performDefaultHandling, nil)
        }
        if space.authenticationMethod == NSURLAuthenticationMethodClientCertificate, let identity = tls.identity {
            return completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        }
        completionHandler(.performDefaultHandling, nil)
    }

    /// http(s)://host[:port] from a host field that may already be a URL.
    static func baseURL(host: String, port: Int, secure: Bool) -> URL? {
        if host.hasPrefix("http://") || host.hasPrefix("https://") { return URL(string: host) }
        let defaultPort = secure ? 443 : 80
        let portPart = port == 0 || port == defaultPort ? "" : ":\(port)"
        return URL(string: "\(secure ? "https" : "http")://\(host)\(portPart)")
    }
}

// MARK: - SQLite-style schema, shared by SQLite, libSQL and D1

/// Engines that answer SQLite's schema queries (sqlite_master and the pragma functions).
protocol SQLiteSchema: Driver {}

extension SQLiteSchema {
    func sqliteObjects() throws -> [DBObject] {
        try rows("""
            SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
              AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' AND name NOT LIKE 'libsql\\_%' ESCAPE '\\'
            ORDER BY name
            """).compactMap { row in
            guard let name = row[0] else { return nil }
            return DBObject(schema: nil, name: name, kind: row[1] == "view" ? .view : .table)
        }
    }

    func sqliteColumns(_ table: TableRef) throws -> [ColumnInfo] {
        let create = try rows("SELECT sql FROM sqlite_master WHERE name = \(dialect.literal(table.name))").first?[0] ?? nil
        return try rows("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(\(dialect.literal(table.name)))").map { row in
            let name = row[0] ?? ""
            return ColumnInfo(name: name, type: (row[1] ?? "").lowercased(), nullable: row[2] == "0", defaultValue: row[3],
                              isPrimaryKey: (Int(row[4] ?? "0") ?? 0) > 0,
                              enumValues: create.flatMap { SQLText.checkInList(column: name, in: $0) })
        }
    }

    func sqliteIndexes(_ table: TableRef) throws -> [IndexInfo] {
        try rows("SELECT name, \"unique\", origin FROM pragma_index_list(\(dialect.literal(table.name)))").compactMap { row in
            guard let name = row[0] else { return nil }
            let cols = try rows("SELECT name FROM pragma_index_info(\(dialect.literal(name))) ORDER BY seqno").compactMap { $0[0] }
            let sql = try rows("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = \(dialect.literal(name))").first?[0] ?? nil
            return IndexInfo(name: name, columns: cols, unique: row[1] == "1", primary: row[2] == "pk", definition: sql)
        }
    }

    func sqliteDefinition(_ object: DBObject) throws -> String? {
        let sql = try rows("SELECT sql FROM sqlite_master WHERE name = \(dialect.literal(object.name))").compactMap { $0[0] }
        return sql.isEmpty ? nil : sql.map { $0 + ";" }.joined(separator: "\n")
    }

    func sqliteForeignKeys(_ table: TableRef) throws -> [ForeignKeyInfo] {
        var order: [String] = []
        var byID: [String: ForeignKeyInfo] = [:]
        for r in try rows("SELECT id, seq, \"table\", \"from\", \"to\", on_update, on_delete FROM pragma_foreign_key_list(\(dialect.literal(table.name))) ORDER BY id, seq") {
            guard let id = r[0], let refTable = r[2], let from = r[3] else { continue }
            if byID[id] == nil {
                order.append(id)
                byID[id] = ForeignKeyInfo(name: "fk_\(table.name)_\(id)", columns: [], refSchema: nil, refTable: refTable, refColumns: [],
                                          onUpdate: r[5] ?? "NO ACTION", onDelete: r[6] ?? "NO ACTION")
            }
            byID[id]!.columns.append(from)
            byID[id]!.refColumns.append(r[4] ?? "")
        }
        return try order.compactMap { id -> ForeignKeyInfo? in
            guard var fk = byID[id] else { return nil }
            if fk.refColumns.allSatisfy(\.isEmpty) { fk.refColumns = try sqliteColumns(fk.target).filter(\.isPrimaryKey).map(\.name) }
            return fk
        }
    }
}

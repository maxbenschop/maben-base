import Foundation

/// A blocking HTTPS client for the engines reached over HTTP (ClickHouse, libSQL, D1, Snowflake, BigQuery),
/// with a cancel that stops the request in flight. The server's certificate is always checked, against this
/// Mac's trusted roots or your own CA, unless the connection is set to TLS Require: a token or password
/// never goes to a server that could be anyone by default.
final class HTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The largest answer kept. A server can't make the app hold more than this.
    static let maxBody = Socket.maxMessage

    private var session: URLSession!
    private let tls: TLSOptions
    private let host: String
    private let lock = NSLock()
    private var current: URLSessionTask?
    private var pending: [Int: Pending] = [:]
    var timeout: TimeInterval = 600

    private struct Pending {
        var body = Data()
        var error: Error?
        var response: URLResponse?
        var tooLarge = false
        /// Why the server's certificate was refused, when it was.
        var distrust: String?
        let done = DispatchSemaphore(value: 0)
    }

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
        let task = session.dataTask(with: request)
        let waiting = Pending()
        lock.lock(); pending[task.taskIdentifier] = waiting; current = task; lock.unlock()
        task.resume()
        waiting.done.wait()
        lock.lock()
        let result = pending.removeValue(forKey: task.taskIdentifier) ?? waiting
        current = nil
        lock.unlock()
        let name = url.host ?? "the server"
        if result.tooLarge { throw DatabaseError.malformedReply("An answer of more than \(Self.maxBody) bytes.") }
        if let reason = result.distrust { throw TLSTrust.error(host: tls.peerName ?? name, reason: reason) }
        if let error = result.error {
            let code = (error as NSError).code
            if code == NSURLErrorCancelled { throw DatabaseError("Stopped.") }
            if (NSURLErrorClientCertificateRejected...NSURLErrorServerCertificateUntrusted).contains(code) || code == NSURLErrorSecureConnectionFailed {
                throw TLSTrust.error(host: name, reason: error.localizedDescription)
            }
            throw DatabaseError("Couldn't reach \(name).", detail: error.localizedDescription)
        }
        guard let http = result.response as? HTTPURLResponse else { throw DatabaseError("No response.") }
        var h: [String: String] = [:]
        for (k, v) in http.allHeaderFields { h[String(describing: k).lowercased()] = String(describing: v) }
        return Response(status: http.statusCode, headers: h, body: result.body)
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard var p = pending[dataTask.taskIdentifier] else { return }
        if p.body.count + data.count > Self.maxBody {
            p.tooLarge = true
            dataTask.cancel()
        } else {
            p.body.append(data)
        }
        pending[dataTask.taskIdentifier] = p
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        pending[task.taskIdentifier]?.error = error
        pending[task.taskIdentifier]?.response = task.response
        let done = pending[task.taskIdentifier]?.done
        lock.unlock()
        done?.signal()
    }

    /// A redirect is followed only to the same server over HTTPS (or within this Mac and private networks):
    /// the request carries the password or token in its headers, and they must not follow a redirect elsewhere.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.originalRequest?.url, to = request.url
        let sameServer = from?.host?.lowercased() == to?.host?.lowercased() && from?.port == to?.port
        let stillSafe = to?.scheme == "https" || from?.scheme == "http"
        completionHandler(sameServer && stillSafe ? request : nil)
    }

    // TLS: the certificate is checked (against your CA when one is set) in every mode but Require, which
    // accepts any certificate because you chose that; a client certificate is offered when the server asks.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust {
            if tls.mode == .require { return completionHandler(.useCredential, URLCredential(trust: trust)) }
            // Through a tunnel the request goes to 127.0.0.1, but the certificate is still the server's.
            let name = tls.peerName ?? space.host
            if tls.anchors.isEmpty && name == space.host { return completionHandler(.performDefaultHandling, nil) }
            if let reason = TLSTrust.problem(trust, host: name, anchors: tls.anchors) {
                lock.lock(); pending[task.taskIdentifier]?.distrust = reason; lock.unlock()
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        if space.authenticationMethod == NSURLAuthenticationMethodClientCertificate, let identity = tls.identity {
            return completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        }
        completionHandler(.performDefaultHandling, nil)
    }

    /// http(s)://host[:port] from a host field that may already be a URL.
    static func baseURL(host: String, port: Int, secure: Bool) -> URL? {
        let lower = host.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: host) }
        let defaultPort = secure ? 443 : 80
        let portPart = port == 0 || port == defaultPort ? "" : ":\(port)"
        return URL(string: "\(secure ? "https" : "http")://\(host)\(portPart)")
    }

    /// Where an engine reached over HTTP is: `baseURL`, refused when it would send the password or token as
    /// plain text to a server out on the internet without you having chosen TLS Off. An http:// address in
    /// the host field doesn't count as that choice: it can come from a pasted URL or an imported file.
    static func endpoint(host: String, port: Int, tls: ConnectionConfig.TLS) throws -> URL {
        let field = host.lowercased().hasPrefix("libsql://") ? "https://" + host.dropFirst(9) : host
        let lower = field.lowercased()
        // A field with another scheme in it is no address for HTTP.
        guard !lower.contains("://") || lower.hasPrefix("http://") || lower.hasPrefix("https://") else { throw DatabaseError("\(host) isn't a valid address.") }
        guard let url = baseURL(host: field, port: port, secure: tls != .off), let name = url.host, !name.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw DatabaseError("\(host) isn't a valid address.")
        }
        if url.scheme?.lowercased() == "http", tls != .off, !HostScope.isLocal(name) {
            throw DatabaseError("\(host) is a plain HTTP address, so the sign-in would cross the network as plain text.",
                                detail: "Nothing was sent. Use an https:// address, or set TLS to Off if you really want a plain connection to this server.")
        }
        return url
    }

    /// Whether a server may move the rest of a session to `next` (libSQL's base_url): only to HTTPS on the
    /// same server or one in the same domain, since every request carries the token. Without that, whoever
    /// answers once could send the token anywhere.
    static func mayMove(from current: URL, to next: URL) -> Bool {
        guard let a = current.host?.lowercased(), let b = next.host?.lowercased(), next.user == nil else { return false }
        if a == b { return next.scheme?.lowercased() == current.scheme?.lowercased() && next.port == current.port }
        return next.scheme?.lowercased() == "https" && !HostScope.isAddress(a) && MongoDriver.srvTargetAllowed(b, for: a)
    }

    /// An address a token may be sent to: HTTPS, or plain HTTP only on this Mac or a private network
    /// (an emulator). Used where there's no TLS setting to turn off by hand.
    static func tokenEndpoint(_ text: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw DatabaseError("\(text) isn't a valid address.")
        }
        guard scheme == "https" || (scheme == "http" && HostScope.isLocal(host)) else {
            throw DatabaseError("\(text) isn't an HTTPS address.", detail: "The sign-in would cross the network as plain text. Plain HTTP is only used on this Mac or a private network.")
        }
        return url
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

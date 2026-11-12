import CryptoKit
import Foundation
import Security

/// RS256 JSON Web Tokens from a PEM private key (PKCS#8 or PKCS#1), for Google service accounts and
/// Snowflake key-pair sign-in.
enum JWT {
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func der(_ pem: String) -> Data? {
        Data(base64Encoded: pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined())
    }

    /// A PKCS#8 PrivateKeyInfo's inner RSAPrivateKey (Security wants PKCS#1).
    static func pkcs1(_ der: [UInt8]) -> [UInt8] {
        var i = 0
        func length() -> Int {
            var len = Int(der[i]); i += 1
            if len & 0x80 != 0 { let n = len & 0x7F; len = 0; for _ in 0..<n { len = len << 8 | Int(der[i]); i += 1 } }
            return len
        }
        guard der.count > 26, der[0] == 0x30 else { return der }
        i = 1; _ = length()
        guard der[i] == 0x02 else { return der }  // version
        i += 1; i += length()
        guard i < der.count, der[i] == 0x30 else { return der }  // PKCS#1 starts with the modulus INTEGER, not a SEQUENCE
        i += 1; i += length()
        guard i < der.count, der[i] == 0x04 else { return der }
        i += 1
        let n = length()
        return Array(der[i..<min(der.count, i + n)])
    }

    static func privateKey(_ pem: String) throws -> SecKey {
        guard !pem.contains("ENCRYPTED"), let der = der(pem) else { throw DatabaseError("The private key can't be read.", detail: "It must be an unencrypted PEM key (BEGIN PRIVATE KEY).") }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1(Array(der))) as CFData, attrs as CFDictionary, &error) else {
            throw DatabaseError("The private key can't be used.", detail: error?.takeRetainedValue().localizedDescription)
        }
        return key
    }

    static func sign(_ claims: [String: Any], key: SecKey) throws -> String {
        let header = base64url(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"]))
        let body = base64url(try JSONSerialization.data(withJSONObject: claims))
        let input = Data("\(header).\(body)".utf8)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, &error) else {
            throw DatabaseError("Signing in failed.", detail: error?.takeRetainedValue().localizedDescription)
        }
        return "\(header).\(body).\(base64url(signature as Data))"
    }

    /// SHA256:base64 of the public key's DER (Snowflake's key fingerprint).
    static func fingerprint(_ key: SecKey) throws -> String {
        guard let pub = SecKeyCopyPublicKey(key), let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw DatabaseError("The public key can't be made from the private key.")
        }
        // SubjectPublicKeyInfo = SEQUENCE { rsaEncryption AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
        func len(_ n: Int) -> [UInt8] {
            n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
        }
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString: [UInt8] = [0x03] + len(pkcs1.count + 1) + [0x00] + Array(pkcs1)
        let spki: [UInt8] = [0x30] + len(algorithm.count + bitString.count) + algorithm + bitString
        return "SHA256:" + Data(SHA256.hash(data: spki)).base64EncodedString()
    }
}

// MARK: - BigQuery

/// BigQuery through its REST API. Sign-in: a service account key file, or your gcloud login when there's none.
/// Datasets show as databases. The `endpoint` option points at an emulator.
public final class BigQueryDriver: Driver {
    public let kind = DatabaseKind.bigquery
    public let dialect = Dialect(kind: .bigquery)
    public let serverVersion = "BigQuery"
    public private(set) var currentDatabase: String?
    private let http = HTTPClient(tls: TLSOptions(.verify), host: "bigquery.googleapis.com")
    private let project: String
    private let base: URL
    private let keyFile: String
    private var token: (value: String, expires: Date)?
    private let emulator: Bool
    private var jobID: String?

    public init(project: String, dataset: String, keyFile: String, endpoint: String?) throws {
        guard !project.isEmpty else { throw DatabaseError("BigQuery needs a project ID.") }
        self.project = project
        self.keyFile = (keyFile as NSString).expandingTildeInPath
        emulator = !(endpoint ?? "").isEmpty
        base = URL(string: (endpoint?.isEmpty == false ? endpoint! : "https://bigquery.googleapis.com") + "/bigquery/v2/projects/\(project)")!
        currentDatabase = dataset.isEmpty ? nil : dataset
        _ = try execute("SELECT 1")
    }

    private func accessToken() throws -> String? {
        if emulator && keyFile.isEmpty { return nil }
        if let token, token.expires > Date().addingTimeInterval(60) { return token.value }
        if keyFile.isEmpty {
            // gcloud's own login, as in a terminal.
            let gcloud = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", NSHomeDirectory() + "/google-cloud-sdk/bin/gcloud"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let gcloud else { throw DatabaseError("Choose a service account key file, or sign in with the gcloud tool (gcloud auth login).") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gcloud)
            p.arguments = ["auth", "print-access-token"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0, !value.isEmpty else { throw DatabaseError("gcloud didn't give a token; run gcloud auth login.") }
            token = (value, Date().addingTimeInterval(45 * 60))
            return value
        }
        guard let data = FileManager.default.contents(atPath: keyFile),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["client_email"] as? String, let pem = json["private_key"] as? String else {
            throw DatabaseError("The key file isn't a Google service account key.", detail: keyFile)
        }
        let tokenURI = json["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
        let now = Int(Date().timeIntervalSince1970)
        let jwt = try JWT.sign(["iss": email, "scope": "https://www.googleapis.com/auth/bigquery", "aud": tokenURI, "iat": now, "exp": now + 3600],
                               key: try JWT.privateKey(pem))
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)"
        let r = try http.send(URL(string: tokenURI)!, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8))
        guard let reply = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let value = reply["access_token"] as? String else {
            throw DatabaseError("Google refused the service account key.", detail: r.text)
        }
        token = (value, Date().addingTimeInterval(Double(reply["expires_in"] as? Int ?? 3600)))
        return value
    }

    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) throws -> [String: Any] {
        var c = URLComponents(url: path.isEmpty ? base : base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var headers: [String: String] = [:]
        if let t = try accessToken() { headers["Authorization"] = "Bearer \(t)" }
        let (status, json) = try http.json(c.url!, method: method, headers: headers, body: body)
        let object = json as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let e = object["error"] as? [String: Any]
            throw DatabaseError(e?["message"] as? String ?? "BigQuery answered with HTTP \(status).", code: (e?["status"] as? String) ?? String(status))
        }
        return object
    }

    /// A REST value as cell text: nested records and arrays as JSON, timestamps as dates.
    private func cell(_ v: Any?, _ field: [String: Any]) -> String? {
        guard let v, !(v is NSNull) else { return nil }
        let type = field["type"] as? String ?? ""
        let repeated = field["mode"] as? String == "REPEATED"
        func plain(_ x: Any) -> Any {
            if let d = x as? [String: Any], let f = d["f"] as? [Any], let sub = field["fields"] as? [[String: Any]] {
                var o: [String: Any] = [:]
                for (i, s) in sub.enumerated() where i < f.count { o[s["name"] as? String ?? "\(i)"] = plain((f[i] as? [String: Any])?["v"] ?? NSNull()) }
                return o
            }
            if let d = x as? [String: Any], let inner = d["v"] { return plain(inner) }
            if let a = x as? [Any] { return a.map(plain) }
            return x
        }
        if repeated || type == "RECORD" || type == "STRUCT" || type == "JSON" && !(v is String) {
            let data = (try? JSONSerialization.data(withJSONObject: plain(v), options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let s = v as? String ?? "\(v)"
        if type == "TIMESTAMP", let secs = Double(s) {
            return BSON.isoFormatter.string(from: Date(timeIntervalSince1970: secs)).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
        }
        if type == "BYTES", let d = Data(base64Encoded: s) { return "0x" + d.map { String(format: "%02X", $0) }.joined() }
        return s
    }

    private func result(_ reply: [String: Any], rowLimit: Int) throws -> QueryResult {
        var reply = reply
        let job = reply["jobReference"] as? [String: Any]
        let jobID = job?["jobId"] as? String
        self.jobID = jobID
        let location = job?["location"] as? String
        while reply["jobComplete"] as? Bool == false, let jobID {
            reply = try call("queries/\(jobID)", query: [URLQueryItem(name: "timeoutMs", value: "10000")] + (location.map { [URLQueryItem(name: "location", value: $0)] } ?? []))
        }
        guard let schema = (reply["schema"] as? [String: Any])?["fields"] as? [[String: Any]] else {
            let n = Int(reply["numDmlAffectedRows"] as? String ?? "") ?? 0
            return QueryResult(affectedRows: n, message: "\(n) rows affected")
        }
        let columns = schema.map { ResultColumn(name: $0["name"] as? String ?? "", typeName: ($0["mode"] as? String == "REPEATED" ? "ARRAY<" : "") + ($0["type"] as? String ?? "") + ($0["mode"] as? String == "REPEATED" ? ">" : ""), isBinary: $0["type"] as? String == "BYTES") }
        var rows: [[String?]] = []
        func add(_ r: [String: Any]) {
            for row in r["rows"] as? [[String: Any]] ?? [] where rows.count < rowLimit {
                let f = row["f"] as? [[String: Any]] ?? []
                rows.append(schema.enumerated().map { i, field in i < f.count ? cell(f[i]["v"], field) : nil })
            }
        }
        add(reply)
        var pageToken = reply["pageToken"] as? String
        while let token = pageToken, rows.count < rowLimit, let jobID {
            let more = try call("queries/\(jobID)", query: [URLQueryItem(name: "pageToken", value: token)] + (location.map { [URLQueryItem(name: "location", value: $0)] } ?? []))
            add(more)
            pageToken = more["pageToken"] as? String
        }
        let total = Int(reply["totalRows"] as? String ?? "") ?? rows.count
        return QueryResult(columns: columns, rows: rows, message: "\(rows.count) rows", truncated: total > rows.count)
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        // A script that starts with BEGIN (staged edits) runs as one request; otherwise one statement at a time.
        let statements = SQLText.statements(in: sql).map(\.sql)
        let parts = statements.first?.uppercased().hasPrefix("BEGIN") == true ? [sql] : statements
        var out: [QueryResult] = []
        for s in parts {
            var body: [String: Any] = ["query": s, "useLegacySql": false, "timeoutMs": 20000, "maxResults": min(rowLimit, 10000)]
            if let ds = currentDatabase { body["defaultDataset"] = ["projectId": project, "datasetId": ds] }
            do { out.append(try result(try call("queries", method: "POST", body: body), rowLimit: rowLimit)) } catch var e as DatabaseError {
                e.completed = out
                throw e
            }
        }
        return out
    }

    public func cancel() {
        http.cancel()
        if let jobID { _ = try? call("jobs/\(jobID)/cancel", method: "POST", body: [:]) }
    }
    public func close() { http.close() }

    public func databases() throws -> [String] {
        ((try call("datasets", query: [URLQueryItem(name: "maxResults", value: "1000")]))["datasets"] as? [[String: Any]] ?? [])
            .compactMap { ($0["datasetReference"] as? [String: Any])?["datasetId"] as? String }.sorted()
    }

    public func use(database: String) throws { currentDatabase = database }
    public func schemas() throws -> [String] { [] }

    public func objects(schema: String?) throws -> [DBObject] {
        guard let ds = currentDatabase else { return [] }
        return ((try call("datasets/\(ds)/tables", query: [URLQueryItem(name: "maxResults", value: "1000")]))["tables"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = (t["tableReference"] as? [String: Any])?["tableId"] as? String else { return nil }
            let type = t["type"] as? String ?? "TABLE"
            return DBObject(schema: nil, name: name, kind: type == "VIEW" ? .view : type == "MATERIALIZED_VIEW" ? .materializedView : type == "EXTERNAL" ? .foreignTable : .table)
        }.sorted { $0.name < $1.name }
    }

    private func table(_ t: TableRef) throws -> [String: Any] {
        guard let ds = currentDatabase else { throw DatabaseError("Choose a dataset first.") }
        return try call("datasets/\(ds)/tables/\(t.name)")
    }

    public func columns(of t: TableRef) throws -> [ColumnInfo] {
        let info = try table(t)
        let pk = Set((((info["tableConstraints"] as? [String: Any])?["primaryKey"] as? [String: Any])?["columns"] as? [String]) ?? [])
        return ((info["schema"] as? [String: Any])?["fields"] as? [[String: Any]] ?? []).map { f in
            let name = f["name"] as? String ?? ""
            let mode = f["mode"] as? String ?? "NULLABLE"
            let type = (mode == "REPEATED" ? "ARRAY<" : "") + (f["type"] as? String ?? "") + (mode == "REPEATED" ? ">" : "")
            return ColumnInfo(name: name, type: type, nullable: mode != "REQUIRED", defaultValue: f["defaultValueExpression"] as? String,
                              isPrimaryKey: pk.contains(name), comment: f["description"] as? String)
        }
    }

    public func indexes(of t: TableRef) throws -> [IndexInfo] { [] }

    public func definition(of object: DBObject) throws -> String? {
        let info = try table(object.table)
        if let view = info["view"] as? [String: Any], let q = view["query"] as? String { return "CREATE VIEW \(dialect.quote(object.name)) AS\n\(q)" }
        if let mv = info["materializedView"] as? [String: Any], let q = mv["query"] as? String { return "CREATE MATERIALIZED VIEW \(dialect.quote(object.name)) AS\n\(q)" }
        let cols = try columns(of: object.table).map { "  \(dialect.quote($0.name)) \($0.type)\($0.nullable ? "" : " NOT NULL")" }
        return "CREATE TABLE \(dialect.quote(object.name)) (\n\(cols.joined(separator: ",\n"))\n);"
    }

    public func foreignKeys(of t: TableRef) throws -> [ForeignKeyInfo] { [] }
    public func estimatedCount(of t: TableRef) throws -> Int? { Int(try table(t)["numRows"] as? String ?? "") }
}

// MARK: - Snowflake

/// Snowflake through its SQL API v2. Sign-in: a programmatic access token as the password, or key-pair
/// authentication with an unencrypted .p8 private key file.
public final class SnowflakeDriver: Driver {
    public let kind = DatabaseKind.snowflake
    public let dialect = Dialect(kind: .snowflake)
    public private(set) var serverVersion = "Snowflake"
    public private(set) var currentDatabase: String?
    private let http: HTTPClient
    private let base: URL
    private let account: String
    private let user: String
    private let token: String
    private let keyFile: String
    private var schema: String?
    private let warehouse: String?
    private let role: String?
    private var handle: String?

    public init(account: String, user: String, token: String, keyFile: String, database: String, options: [String: String]) throws {
        let host = account.contains(".snowflakecomputing.com") ? account : "\(account).snowflakecomputing.com"
        guard !account.isEmpty, let base = URL(string: "https://\(host)/api/v2/statements") else { throw DatabaseError("Snowflake needs an account identifier.") }
        self.base = base
        http = HTTPClient(tls: TLSOptions(.verify), host: host)
        self.account = account.components(separatedBy: ".snowflakecomputing.com")[0]
        self.user = user
        self.token = token
        self.keyFile = (keyFile as NSString).expandingTildeInPath
        currentDatabase = database.isEmpty ? nil : database
        schema = options["schema"]
        warehouse = options["warehouse"]
        role = options["role"]
        serverVersion = "Snowflake " + (try rows("SELECT CURRENT_VERSION()").first?[0] ?? "")
    }

    private func authorization() throws -> [String: String] {
        if !keyFile.isEmpty {
            guard let pem = try? String(contentsOfFile: keyFile, encoding: .utf8) else { throw DatabaseError("The private key file can't be read.", detail: keyFile) }
            let key = try JWT.privateKey(pem)
            // The account part before any region, upper case; dots become dashes.
            let acct = account.split(separator: ".").first.map { String($0).uppercased() } ?? account.uppercased()
            let now = Int(Date().timeIntervalSince1970)
            let jwt = try JWT.sign(["iss": "\(acct).\(user.uppercased()).\(try JWT.fingerprint(key))", "sub": "\(acct).\(user.uppercased())",
                                    "iat": now, "exp": now + 3000], key: key)
            return ["Authorization": "Bearer \(jwt)", "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT"]
        }
        guard !token.isEmpty else { throw DatabaseError("Snowflake needs a programmatic access token (as the password) or a private key file.") }
        return ["Authorization": "Bearer \(token)", "X-Snowflake-Authorization-Token-Type": "PROGRAMMATIC_ACCESS_TOKEN"]
    }

    private func call(_ url: URL, method: String = "GET", body: [String: Any]? = nil) throws -> (Int, [String: Any]) {
        let (status, json) = try http.json(url, method: method, headers: try authorization().merging(["User-Agent": "MabenBase/1.0"]) { $1 }, body: body)
        let object = json as? [String: Any] ?? [:]
        if status == 401 || status == 403 { throw DatabaseError("Snowflake refused the sign-in.", detail: object["message"] as? String) }
        if status >= 400 && status != 422 { throw DatabaseError(object["message"] as? String ?? "Snowflake answered with HTTP \(status).", code: object["code"] as? String) }
        if status == 422 { throw DatabaseError(object["message"] as? String ?? "The statement failed.", code: object["sqlState"] as? String ?? object["code"] as? String) }
        return (status, object)
    }

    private func run(_ statement: String, multi: Bool, rowLimit: Int) throws -> [QueryResult] {
        var body: [String: Any] = ["statement": statement, "timeout": 600]
        if let d = currentDatabase { body["database"] = d }
        if let s = schema { body["schema"] = s }
        if let w = warehouse { body["warehouse"] = w }
        if let r = role { body["role"] = r }
        if multi { body["parameters"] = ["MULTI_STATEMENT_COUNT": "0"] }
        var (status, reply) = try call(base, method: "POST", body: body)
        handle = reply["statementHandle"] as? String
        while status == 202, let h = handle {
            usleep(300_000)
            (status, reply) = try call(base.appendingPathComponent(h))
        }
        if let children = reply["statementHandles"] as? [String] {
            return try children.map { h in
                var (s, r) = try call(base.appendingPathComponent(h))
                while s == 202 { usleep(300_000); (s, r) = try call(base.appendingPathComponent(h)) }
                return try result(r, handle: h, rowLimit: rowLimit)
            }
        }
        return [try result(reply, handle: handle, rowLimit: rowLimit)]
    }

    private func result(_ reply: [String: Any], handle: String?, rowLimit: Int) throws -> QueryResult {
        let meta = reply["resultSetMetaData"] as? [String: Any] ?? [:]
        let rowType = meta["rowType"] as? [[String: Any]] ?? []
        let columns = rowType.map { ResultColumn(name: $0["name"] as? String ?? "", typeName: ($0["type"] as? String ?? "").lowercased(), isBinary: $0["type"] as? String == "binary") }
        var rows: [[String?]] = (reply["data"] as? [[Any]] ?? []).map { $0.map { $0 is NSNull ? nil : $0 as? String ?? "\($0)" } }
        let partitions = (meta["partitionInfo"] as? [Any])?.count ?? 1
        var p = 1
        while p < partitions && rows.count < rowLimit, let handle {
            var c = URLComponents(url: base.appendingPathComponent(handle), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "partition", value: String(p))]
            let (_, more) = try call(c.url!)
            rows += (more["data"] as? [[Any]] ?? []).map { $0.map { $0 is NSNull ? nil : $0 as? String ?? "\($0)" } }
            p += 1
        }
        let total = meta["numRows"] as? Int ?? rows.count
        let dml = columns.first?.name.lowercased().hasPrefix("number of rows") == true
        if dml {
            let n = rows.first?.compactMap { $0.flatMap(Int.init) }.reduce(0, +) ?? 0
            return QueryResult(affectedRows: n, message: "\(n) rows affected")
        }
        return QueryResult(columns: columns, rows: Array(rows.prefix(rowLimit)), message: "\(min(rows.count, rowLimit)) rows", truncated: total > rowLimit)
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        let statements = SQLText.statements(in: sql).map(\.sql)
        // Staged edits arrive as one BEGIN … COMMIT script: run it as one multi-statement request.
        if statements.count > 1, statements.first?.uppercased().hasPrefix("BEGIN") == true { return try run(sql, multi: true, rowLimit: rowLimit) }
        var out: [QueryResult] = []
        for s in statements {
            do {
                out += try run(s, multi: false, rowLimit: rowLimit)
                let lower = s.lowercased()
                if lower.hasPrefix("use database ") { currentDatabase = String(s.dropFirst(13)).trimmingCharacters(in: CharacterSet(charactersIn: " ;\"")) }
                if lower.hasPrefix("use schema ") { schema = String(s.dropFirst(11)).trimmingCharacters(in: CharacterSet(charactersIn: " ;\"")) }
            } catch var e as DatabaseError {
                e.completed = out
                throw e
            }
        }
        return out
    }

    public func cancel() {
        http.cancel()
        if let h = handle { _ = try? call(base.appendingPathComponent(h).appendingPathComponent("cancel"), method: "POST", body: [:]) }
    }
    public func close() { http.close() }

    private func show(_ sql: String, column: String) throws -> [String] {
        guard let r = try execute(sql).first, let i = r.columns.firstIndex(where: { $0.name.lowercased() == column }) else { return [] }
        return r.rows.compactMap { $0[i] }
    }

    public func databases() throws -> [String] { try show("SHOW TERSE DATABASES", column: "name").sorted() }
    public func use(database: String) throws { currentDatabase = database; schema = nil }

    public func schemas() throws -> [String] {
        guard currentDatabase != nil else { return [] }
        let list = try rows("SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME <> 'INFORMATION_SCHEMA' ORDER BY SCHEMA_NAME = 'PUBLIC' DESC, 1").compactMap { $0[0] }
        if schema == nil { schema = list.first }
        return list
    }

    public func objects(schema s: String?) throws -> [DBObject] {
        let sc = s ?? schema ?? "PUBLIC"
        schema = sc
        return try rows("SELECT TABLE_NAME, TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = \(dialect.literal(sc)) ORDER BY 1").compactMap { r in
            r[0].map { DBObject(schema: sc, name: $0, kind: r[1] == "VIEW" ? .view : r[1] == "MATERIALIZED VIEW" ? .materializedView : .table) }
        }
    }

    public func columns(of t: TableRef) throws -> [ColumnInfo] {
        let pk = Set((try? show("SHOW PRIMARY KEYS IN TABLE \(dialect.qualified(t))", column: "column_name")) ?? [])
        return try rows("""
            SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COMMENT FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = \(dialect.literal(t.schema ?? schema ?? "PUBLIC")) AND TABLE_NAME = \(dialect.literal(t.name)) ORDER BY ORDINAL_POSITION
            """).map { r in
            ColumnInfo(name: r[0] ?? "", type: (r[1] ?? "").lowercased(), nullable: r[2] == "YES", defaultValue: r[3], isPrimaryKey: pk.contains(r[0] ?? ""), comment: r[4])
        }
    }

    public func indexes(of t: TableRef) throws -> [IndexInfo] { [] }

    public func definition(of object: DBObject) throws -> String? {
        let kind = object.kind == .view ? "view" : "table"
        return try rows("SELECT GET_DDL('\(kind)', \(dialect.literal(dialect.qualified(object.table))))").first?[0] ?? nil
    }

    public func foreignKeys(of t: TableRef) throws -> [ForeignKeyInfo] { [] }

    public func estimatedCount(of t: TableRef) throws -> Int? {
        try rows("SELECT ROW_COUNT FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = \(dialect.literal(t.schema ?? schema ?? "PUBLIC")) AND TABLE_NAME = \(dialect.literal(t.name))")
            .first?[0].flatMap { $0 }.flatMap { Int($0) }
    }
}

// MARK: - Cloudflare D1

/// Cloudflare D1 through the REST API with an API token (D1 edit permission). The account ID goes in the
/// host field and the database ID in the database field. The schema is SQLite's.
public final class D1Driver: Driver, SQLiteSchema {
    public let kind = DatabaseKind.d1
    public let dialect = Dialect(kind: .d1)
    public private(set) var serverVersion = "Cloudflare D1"
    public let currentDatabase: String?
    private let http = HTTPClient(tls: TLSOptions(.verify), host: "api.cloudflare.com")
    private let account: String
    private let token: String
    private let base: URL

    public init(account: String, database: String, token: String, endpoint: String? = nil) throws {
        guard !account.isEmpty, !database.isEmpty else { throw DatabaseError("D1 needs the account ID (as host) and the database ID.") }
        self.account = account
        self.token = token
        currentDatabase = database
        base = URL(string: (endpoint ?? "https://api.cloudflare.com/client/v4") + "/accounts/\(account)/d1/database/\(database)")!
        serverVersion = "D1 · SQLite " + (try rows("SELECT sqlite_version()").first?[0] ?? "")
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        let (status, json) = try http.json(base.appendingPathComponent("raw"), headers: ["Authorization": "Bearer \(token)"], body: ["sql": sql])
        let reply = json as? [String: Any] ?? [:]
        if reply["success"] as? Bool != true {
            let e = (reply["errors"] as? [[String: Any]])?.first
            throw DatabaseError(e?["message"] as? String ?? "D1 answered with HTTP \(status).", code: (e?["code"]).map { "\($0)" })
        }
        return (reply["result"] as? [[String: Any]] ?? []).map { r in
            let results = r["results"] as? [String: Any] ?? [:]
            let cols = results["columns"] as? [String] ?? []
            let rows = (results["rows"] as? [[Any]] ?? []).prefix(rowLimit).map { $0.map { v -> String? in
                if v is NSNull { return nil }
                if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
                return v as? String ?? "\(v)"
            } }
            let changes = (r["meta"] as? [String: Any])?["changes"] as? Int
            return QueryResult(columns: cols.map { ResultColumn(name: $0, typeName: "") }, rows: Array(rows),
                               affectedRows: cols.isEmpty ? changes : nil, message: cols.isEmpty ? "\(changes ?? 0) rows affected" : "\(rows.count) rows")
        }
    }

    public func cancel() { http.cancel() }
    public func close() { http.close() }
    public func databases() throws -> [String] { [currentDatabase].compactMap { $0 } }
    public func use(database: String) throws {}
    public func schemas() throws -> [String] { [] }
    public func objects(schema: String?) throws -> [DBObject] { try sqliteObjects() }
    public func columns(of table: TableRef) throws -> [ColumnInfo] { try sqliteColumns(table) }
    public func indexes(of table: TableRef) throws -> [IndexInfo] { try sqliteIndexes(table) }
    public func definition(of object: DBObject) throws -> String? { try sqliteDefinition(object) }
    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] { try sqliteForeignKeys(table) }
    public func estimatedCount(of table: TableRef) throws -> Int? { nil }
}

import Foundation

/// PostgreSQL over its wire protocol (version 3), using the simple query protocol so every value
/// arrives as text in the server's own format. Auth: trust, password, MD5 and SCRAM-SHA-256.
public final class PostgresDriver: Driver {
    public let kind = DatabaseKind.postgres
    public let dialect = Dialect(kind: .postgres)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?

    private var socket: Socket
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let tls: TLSOptions
    private var processID: Int32 = 0
    private var secretKey: Int32 = 0
    private var typeNames: [Int32: String] = PostgresDriver.builtinTypes
    private let cancelLock = NSLock()

    public init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.tls = tls
        socket = try Self.connect(host: host, port: port, tls: tls)
        try startup(database: database)
        currentDatabase = database
        loadTypeNames()
    }

    /// A host starting with / is a Unix socket: a directory (Postgres puts .s.PGSQL.<port> in it) or the socket itself.
    static func socketPath(_ host: String, port: Int) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: host, isDirectory: &isDir), isDir.boolValue { return host + "/.s.PGSQL.\(port)" }
        return host
    }

    private static func connect(host: String, port: Int, tls: TLSOptions) throws -> Socket {
        let unix = host.hasPrefix("/")
        let socket = try Socket(host: unix ? socketPath(host, port: port) : host, port: port)
        // Postgres has no TLS on Unix sockets.
        if tls.mode != .off && !unix {
            var request = [UInt8]()
            request.appendInt32BE(8)
            request.appendInt32BE(80877103)
            try socket.write(request)
            let answer = try socket.readByte()
            if answer == UInt8(ascii: "S") {
                socket.startTLS(tls)
            } else if tls.mode != .prefer {
                socket.close()
                throw DatabaseError("The server doesn't accept TLS connections.", detail: "Set TLS to Prefer or Off for this connection.")
            }
        }
        return socket
    }

    // MARK: Messages

    private func send(_ type: UInt8?, _ body: [UInt8]) throws {
        var msg = [UInt8]()
        if let type { msg.append(type) }
        msg.appendInt32BE(Int32(body.count + 4))
        msg.append(contentsOf: body)
        try socket.write(msg)
    }

    private func receive() throws -> (UInt8, [UInt8]) {
        let type = try socket.readByte()
        var r = ByteReader(try socket.read(4))
        let length = Int(r.int32BE()) - 4
        guard length >= 0, length < 1 << 30 else { throw DatabaseError("The server sent a message this app doesn't understand.") }
        return (type, try socket.read(length))
    }

    private func errorFrom(_ body: [UInt8]) -> DatabaseError {
        var r = ByteReader(body)
        var fields: [UInt8: String] = [:]
        while !r.atEnd {
            let code = r.byte()
            if code == 0 { break }
            fields[code] = r.cString()
        }
        var detail = [fields[UInt8(ascii: "D")], fields[UInt8(ascii: "H")].map { "Hint: \($0)" }].compactMap { $0 }
        if let position = fields[UInt8(ascii: "P")] { detail.append("At character \(position)") }
        return DatabaseError(fields[UInt8(ascii: "M")] ?? "Unknown error", detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
                             code: fields[UInt8(ascii: "C")])
    }

    // MARK: Startup and auth

    private func startup(database: String) throws {
        var body = [UInt8]()
        body.appendInt32BE(196608)
        for (k, v) in [("user", user), ("database", database), ("application_name", "Maben Base"), ("client_encoding", "UTF8"),
                       ("DateStyle", "ISO, MDY")] {
            body.appendCString(k)
            body.appendCString(v)
        }
        body.append(0)
        try send(nil, body)

        var scram: SCRAM?
        while true {
            let (type, msg) = try receive()
            switch type {
            case UInt8(ascii: "R"):
                var r = ByteReader(msg)
                let code = r.int32BE()
                switch code {
                case 0: break
                case 3:
                    try send(UInt8(ascii: "p"), { var b = [UInt8](); b.appendCString(password); return b }())
                case 5:
                    let salt = Array(r.take(4))
                    let inner = Crypto.md5Hex(Array((password + user).utf8))
                    let outer = "md5" + Crypto.md5Hex(Array(inner.utf8) + salt)
                    try send(UInt8(ascii: "p"), { var b = [UInt8](); b.appendCString(outer); return b }())
                case 10:
                    var mechanisms: [String] = []
                    while !r.atEnd { let m = r.cString(); if m.isEmpty { break }; mechanisms.append(m) }
                    guard mechanisms.contains("SCRAM-SHA-256") else {
                        throw DatabaseError("The server asks for a sign-in method this app doesn't support.", detail: mechanisms.joined(separator: ", "))
                    }
                    let s = SCRAM(password: password)
                    scram = s
                    let first = Array(s.clientFirst.utf8)
                    var b = [UInt8]()
                    b.appendCString("SCRAM-SHA-256")
                    b.appendInt32BE(Int32(first.count))
                    b.append(contentsOf: first)
                    try send(UInt8(ascii: "p"), b)
                case 11:
                    guard let s = scram else { throw DatabaseError("Unexpected SCRAM message.") }
                    let final = try s.clientFinal(serverFirst: String(decoding: r.rest(), as: UTF8.self))
                    try send(UInt8(ascii: "p"), Array(final.utf8))
                case 12:
                    guard let s = scram, s.verify(serverFinal: String(decoding: r.rest(), as: UTF8.self)) else {
                        throw DatabaseError("The server's SCRAM signature didn't match.")
                    }
                default:
                    throw DatabaseError("The server asks for a sign-in method this app doesn't support (code \(code)).",
                                        detail: "Supported: password, MD5 and SCRAM-SHA-256.")
                }
            case UInt8(ascii: "S"):
                var r = ByteReader(msg)
                let name = r.cString(), value = r.cString()
                if name == "server_version" { serverVersion = value }
            case UInt8(ascii: "K"):
                var r = ByteReader(msg)
                processID = r.int32BE()
                secretKey = r.int32BE()
            case UInt8(ascii: "Z"):
                return
            case UInt8(ascii: "E"):
                throw errorFrom(msg)
            default:
                continue
            }
        }
    }

    // MARK: Queries

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        var body = [UInt8]()
        body.appendCString(sql)
        try send(UInt8(ascii: "Q"), body)

        var results: [QueryResult] = []
        var current: QueryResult?
        var error: DatabaseError?
        while true {
            let (type, msg) = try receive()
            switch type {
            case UInt8(ascii: "T"):
                var r = ByteReader(msg)
                let count = Int(r.int16BE())
                var columns: [ResultColumn] = []
                for _ in 0..<count {
                    let name = r.cString()
                    _ = r.int32BE(); _ = r.int16BE()
                    let oid = r.int32BE()
                    _ = r.int16BE(); _ = r.int32BE(); _ = r.int16BE()
                    let typeName = typeNames[oid] ?? "oid \(oid)"
                    columns.append(ResultColumn(name: name, typeName: typeName, isBinary: oid == 17))
                }
                current = QueryResult(columns: columns)
            case UInt8(ascii: "D"):
                guard current != nil else { continue }
                if current!.rows.count >= rowLimit { current!.truncated = true; continue }
                var r = ByteReader(msg)
                let count = Int(r.int16BE())
                var row: [String?] = []
                row.reserveCapacity(count)
                for _ in 0..<count {
                    let len = Int(r.int32BE())
                    if len < 0 { row.append(nil) } else { row.append(String(decoding: r.take(len), as: UTF8.self)) }
                }
                current!.rows.append(row)
            case UInt8(ascii: "C"):
                var r = ByteReader(msg)
                let tag = r.cString()
                var result = current ?? QueryResult()
                result.message = tag
                let parts = tag.split(separator: " ")
                if let first = parts.first, ["INSERT", "UPDATE", "DELETE", "MERGE", "COPY"].contains(String(first)), let n = parts.last.flatMap({ Int($0) }) {
                    result.affectedRows = n
                }
                results.append(result)
                current = nil
            case UInt8(ascii: "I"):
                break
            case UInt8(ascii: "E"):
                error = errorFrom(msg)
            case UInt8(ascii: "G"):
                // COPY FROM STDIN: not supported here.
                var b = [UInt8]()
                b.appendCString("COPY FROM STDIN isn't supported in Maben Base")
                try send(UInt8(ascii: "f"), b)
            case UInt8(ascii: "Z"):
                if let error { throw error }
                return results
            default:
                continue  // notices, parameter status, COPY OUT data
            }
        }
    }

    public func cancel() {
        cancelLock.lock(); defer { cancelLock.unlock() }
        guard processID != 0, let s = try? Socket(host: host.hasPrefix("/") ? Self.socketPath(host, port: port) : host, port: port, timeout: 5) else { return }
        var b = [UInt8]()
        b.appendInt32BE(16)
        b.appendInt32BE(80877102)
        b.appendInt32BE(processID)
        b.appendInt32BE(secretKey)
        try? s.write(b)
        s.close()
    }

    public func close() {
        if !socket.isClosed { try? send(UInt8(ascii: "X"), []) }
        socket.close()
    }

    deinit { close() }

    private func loadTypeNames() {
        guard let rows = try? rows("SELECT oid, typname FROM pg_type") else { return }
        for row in rows {
            if let oid = row[0].flatMap({ Int32($0) }), let name = row[1] {
                typeNames[oid] = Self.builtinTypes[oid] ?? name
            }
        }
    }

    // MARK: Schema

    public func databases() throws -> [String] {
        try rows("SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY 1").compactMap { $0[0] }
    }

    public func use(database: String) throws {
        let newSocket = try Self.connect(host: host, port: port, tls: tls)
        let old = socket
        socket = newSocket
        do {
            try startup(database: database)
        } catch {
            socket = old
            throw error
        }
        // Say goodbye on the old connection (send() would write to the new one).
        var terminate: [UInt8] = [UInt8(ascii: "X")]
        terminate.appendInt32BE(4)
        try? old.write(terminate)
        old.close()
        currentDatabase = database
        typeNames = Self.builtinTypes
        loadTypeNames()
    }

    public func schemas() throws -> [String] {
        try rows("""
            SELECT nspname FROM pg_namespace
            WHERE nspname NOT LIKE 'pg\\_%' ESCAPE '\\' AND nspname <> 'information_schema'
            ORDER BY nspname = 'public' DESC, nspname
            """).compactMap { $0[0] }
    }

    public func objects(schema: String?) throws -> [DBObject] {
        let s = dialect.literal(schema ?? "public")
        var objects: [DBObject] = try rows("""
            SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(s) AND c.relkind IN ('r','p','v','m','f') ORDER BY c.relname
            """).compactMap { row in
            guard let name = row[0], let kind = row[1] else { return nil }
            let k: DBObject.Kind = switch kind {
            case "v": .view
            case "m": .materializedView
            case "f": .foreignTable
            default: .table
            }
            return DBObject(schema: schema ?? "public", name: name, kind: k)
        }
        objects += try rows("""
            SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = \(s) AND p.prokind IN ('f','p') ORDER BY 1
            """).compactMap { $0[0].map { DBObject(schema: schema ?? "public", name: $0, kind: .function) } }
        return objects
    }

    private func regclass(_ table: TableRef) -> String {
        dialect.literal(dialect.qualified(table)) + "::regclass"
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        let pk = Set(try rows("""
            SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = \(regclass(table)) AND i.indisprimary
            """).compactMap { $0[0] })
        return try rows("""
            SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid), col_description(a.attrelid, a.attnum),
                   CASE WHEN a.attidentity <> '' THEN 'identity' WHEN a.attgenerated <> '' THEN 'generated' END,
                   (SELECT string_agg(e.enumlabel, chr(31) ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = a.atttypid)
            FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = \(regclass(table)) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """).map { row in
            ColumnInfo(name: row[0] ?? "", type: row[1] ?? "", nullable: row[2] == "t", defaultValue: row[3],
                       isPrimaryKey: pk.contains(row[0] ?? ""), comment: row[4], extra: row[5],
                       enumValues: row[6].map { $0.components(separatedBy: "\u{1f}") })
        }
    }

    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] {
        let rows = try rows("""
            SELECT c.conname, a.attname, nf.nspname, cf.relname, af.attname, c.confupdtype, c.confdeltype
            FROM pg_constraint c
            CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS k(col, fcol, ord)
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.col
            JOIN pg_class cf ON cf.oid = c.confrelid JOIN pg_namespace nf ON nf.oid = cf.relnamespace
            JOIN pg_attribute af ON af.attrelid = c.confrelid AND af.attnum = k.fcol
            WHERE c.conrelid = \(regclass(table)) AND c.contype = 'f'
            ORDER BY c.conname, k.ord
            """)
        func action(_ code: String?) -> String {
            switch code {
            case "r": "RESTRICT"
            case "c": "CASCADE"
            case "n": "SET NULL"
            case "d": "SET DEFAULT"
            default: "NO ACTION"
            }
        }
        var order: [String] = []
        var byName: [String: ForeignKeyInfo] = [:]
        for r in rows {
            guard let name = r[0], let col = r[1], let refTable = r[3], let refCol = r[4] else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = ForeignKeyInfo(name: name, columns: [], refSchema: r[2], refTable: refTable, refColumns: [],
                                              onUpdate: action(r[5]), onDelete: action(r[6]))
            }
            byName[name]!.columns.append(col)
            byName[name]!.refColumns.append(refCol)
        }
        return order.compactMap { byName[$0] }
    }

    public func estimatedCount(of table: TableRef) throws -> Int? {
        guard let v = try rows("SELECT reltuples::bigint FROM pg_class WHERE oid = \(regclass(table))").first?[0], let n = Int(v) else { return nil }
        return n < 0 ? nil : n  // -1: never analyzed
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        try rows("""
            SELECT ic.relname, i.indisunique, i.indisprimary, pg_get_indexdef(i.indexrelid),
                   array_to_string(ARRAY(SELECT pg_get_indexdef(i.indexrelid, k + 1, true) FROM generate_subscripts(i.indkey, 1) k ORDER BY k), ','),
                   EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid AND c.contype IN ('u', 'x'))
            FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = \(regclass(table)) ORDER BY i.indisprimary DESC, ic.relname
            """).map { row in
            IndexInfo(name: row[0] ?? "", columns: (row[4] ?? "").split(separator: ",").map(String.init),
                      unique: row[1] == "t", primary: row[2] == "t", definition: row[3], isConstraint: row[5] == "t")
        }
    }

    public func definition(of object: DBObject) throws -> String? {
        switch object.kind {
        case .view, .materializedView:
            guard let body = try rows("SELECT pg_get_viewdef(\(regclass(object.table)), true)").first?[0] else { return nil }
            let what = object.kind == .view ? "VIEW" : "MATERIALIZED VIEW"
            return "CREATE \(what) \(dialect.qualified(object.table)) AS\n\(body)"
        case .function:
            let s = dialect.literal(object.schema ?? "public")
            let name = dialect.literal(object.name)
            return try rows("""
                SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = \(s) AND p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' = \(name)
                """).first?[0]
        case .table, .foreignTable:
            let cols = try columns(of: object.table)
            let idx = try indexes(of: object.table)
            var lines = cols.map { c -> String in
                var l = "  \(dialect.quote(c.name)) \(c.type)"
                if !c.nullable { l += " NOT NULL" }
                if let d = c.defaultValue { l += " DEFAULT \(d)" }
                return l
            }
            let pk = cols.filter(\.isPrimaryKey).map { dialect.quote($0.name) }
            if !pk.isEmpty { lines.append("  PRIMARY KEY (\(pk.joined(separator: ", ")))") }
            var sql = "CREATE TABLE \(dialect.qualified(object.table)) (\n\(lines.joined(separator: ",\n"))\n);"
            for i in idx where !i.primary { if let d = i.definition { sql += "\n\(d);" } }
            return sql
        }
    }

    static let builtinTypes: [Int32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 25: "text", 26: "oid",
        114: "json", 142: "xml", 700: "float4", 701: "float8", 790: "money", 1042: "bpchar", 1043: "varchar",
        1082: "date", 1083: "time", 1114: "timestamp", 1184: "timestamptz", 1186: "interval", 1266: "timetz",
        1700: "numeric", 2950: "uuid", 3802: "jsonb", 869: "inet", 650: "cidr", 829: "macaddr", 1560: "bit",
        1562: "varbit", 3614: "tsvector", 1000: "bool[]", 1005: "int2[]", 1007: "int4[]", 1016: "int8[]",
        1009: "text[]", 1015: "varchar[]", 2951: "uuid[]", 3807: "jsonb[]", 199: "json[]",
    ]
}

/// SCRAM-SHA-256 as Postgres uses it (no channel binding).
private struct SCRAM {
    let password: String
    let nonce: String
    var clientFirstBare: String { "n=,r=\(nonce)" }
    var clientFirst: String { "n,," + clientFirstBare }
    private final class Box { var serverSignature: [UInt8] = [] }
    private let box = Box()

    init(password: String) {
        self.password = password
        nonce = Data(Crypto.randomBytes(18)).base64EncodedString()
    }

    func clientFinal(serverFirst: String) throws -> String {
        var fields: [Character: String] = [:]
        for part in serverFirst.split(separator: ",") where part.count > 2 {
            fields[part.first!] = String(part.dropFirst(2))
        }
        guard let r = fields["r"], r.hasPrefix(nonce), let s = fields["s"], let salt = Data(base64Encoded: s),
              let i = fields["i"].flatMap({ Int($0) }) else { throw DatabaseError("The server's SCRAM message was malformed.") }
        let salted = Crypto.pbkdf2SHA256(password: Array(SASLprep(password).utf8), salt: Array(salt), iterations: i)
        let clientKey = Crypto.hmacSHA256(key: salted, Array("Client Key".utf8))
        let storedKey = Crypto.sha256(clientKey)
        let withoutProof = "c=biws,r=\(r)"
        let authMessage = Array("\(clientFirstBare),\(serverFirst),\(withoutProof)".utf8)
        let signature = Crypto.hmacSHA256(key: storedKey, authMessage)
        let proof = Crypto.xor(clientKey, signature)
        let serverKey = Crypto.hmacSHA256(key: salted, Array("Server Key".utf8))
        box.serverSignature = Crypto.hmacSHA256(key: serverKey, authMessage)
        return "\(withoutProof),p=\(Data(proof).base64EncodedString())"
    }

    func verify(serverFinal: String) -> Bool {
        guard serverFinal.hasPrefix("v="), let v = Data(base64Encoded: String(serverFinal.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return Array(v) == box.serverSignature
    }

    /// Postgres normalises passwords with SASLprep; NFKC covers what matters in practice.
    private func SASLprep(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping }
}

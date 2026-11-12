import Foundation

/// Cassandra and ScyllaDB over the CQL native protocol, version 4. Keyspaces show as databases.
public final class CassandraDriver: Driver {
    public let kind = DatabaseKind.cassandra
    public let dialect = Dialect(kind: .cassandra)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?
    private let socket: Socket
    private var stream: Int16 = 0

    public init(host: String, port: Int, user: String, password: String, keyspace: String, tls: TLSOptions) throws {
        socket = try Socket(host: host, port: port)
        if tls.mode != .off { socket.startTLS(tls) }
        var startup: [UInt8] = []
        startup.appendInt16BE(1)
        startup += Self.string("CQL_VERSION") + Self.string("3.0.0")
        var (op, body) = try request(0x01, startup)
        if op == 0x03 {
            // PasswordAuthenticator: SASL PLAIN.
            let token = [0] + Array(user.utf8) + [0] + Array(password.utf8)
            var b: [UInt8] = []
            b.appendInt32BE(Int32(token.count))
            b += token
            (op, body) = try request(0x0F, b)
            if op == 0x00 { throw DatabaseError("Cassandra refused the user name or password.", detail: Self.errorMessage(body)) }
        }
        guard op == 0x02 || op == 0x10 else { throw DatabaseError("Cassandra didn't accept the connection.", detail: Self.errorMessage(body)) }
        serverVersion = (try? rows("SELECT release_version FROM system.local").first?[0] ?? nil) ?? ""
        if !keyspace.isEmpty { try use(database: keyspace) }
    }

    // MARK: Frames

    static func string(_ s: String) -> [UInt8] {
        var b: [UInt8] = []
        b.appendInt16BE(Int16(s.utf8.count))
        return b + Array(s.utf8)
    }

    private func request(_ opcode: UInt8, _ body: [UInt8]) throws -> (UInt8, [UInt8]) {
        stream = stream &+ 1
        if stream < 0 { stream = 1 }
        var frame: [UInt8] = [0x04, 0x00]
        frame.appendInt16BE(stream)
        frame.append(opcode)
        frame.appendInt32BE(Int32(body.count))
        try socket.write(frame + body)
        while true {
            var h = ByteReader(try socket.read(9))
            _ = h.byte()
            let flags = h.byte()
            let id = h.int16BE()
            let op = h.byte()
            let length = Int(h.int32BE())
            var payload = try socket.read(length)
            // Tracing id, warnings and custom payloads come before the body when their flags are set.
            var r = ByteReader(payload)
            if flags & 0x02 != 0 { _ = r.take(16) }
            if flags & 0x08 != 0 { let n = Int(r.int16BE()); for _ in 0..<n { _ = readString(&r) } }
            if flags & 0x04 != 0 { let n = Int(r.int16BE()); for _ in 0..<n { _ = readString(&r); _ = r.take(Int(r.int32BE())) } }
            if r.pos > 0 { payload = Array(payload[r.pos...]) }
            if id == stream { return (op, payload) }  // events (stream -1) are skipped
        }
    }

    static func errorMessage(_ body: [UInt8]) -> String {
        var r = ByteReader(body)
        _ = r.int32BE()
        let n = Int(r.int16BE())
        return String(decoding: r.take(n), as: UTF8.self)
    }

    // MARK: Types

    indirect enum CQLType {
        case simple(Int16), list(CQLType), set(CQLType), map(CQLType, CQLType), udt([(String, CQLType)]), tuple([CQLType]), custom(String)

        var name: String {
            switch self {
            case .simple(let id):
                return [1: "ascii", 2: "bigint", 3: "blob", 4: "boolean", 5: "counter", 6: "decimal", 7: "double", 8: "float", 9: "int",
                        0x0B: "timestamp", 0x0C: "uuid", 0x0D: "text", 0x0E: "varint", 0x0F: "timeuuid", 0x10: "inet", 0x11: "date",
                        0x12: "time", 0x13: "smallint", 0x14: "tinyint", 0x15: "duration"][Int(id)] ?? "type \(id)"
            case .list(let t): return "list<\(t.name)>"
            case .set(let t): return "set<\(t.name)>"
            case .map(let k, let v): return "map<\(k.name), \(v.name)>"
            case .udt: return "udt"
            case .tuple(let ts): return "tuple<\(ts.map(\.name).joined(separator: ", "))>"
            case .custom(let c): return c
            }
        }
    }

    private func readString(_ r: inout ByteReader) -> String { String(decoding: r.take(Int(UInt16(bitPattern: r.int16BE()))), as: UTF8.self) }

    private func readType(_ r: inout ByteReader) -> CQLType {
        let id = r.int16BE()
        switch id {
        case 0x0000: return .custom(readString(&r))
        case 0x20: return .list(readType(&r))
        case 0x22: return .set(readType(&r))
        case 0x21: let k = readType(&r); return .map(k, readType(&r))
        case 0x30:
            _ = readString(&r); _ = readString(&r)
            let n = Int(r.int16BE())
            return .udt((0..<n).map { _ in (readString(&r), readType(&r)) })
        case 0x31:
            let n = Int(r.int16BE())
            return .tuple((0..<n).map { _ in readType(&r) })
        default: return .simple(id)
        }
    }

    private func value(_ b: ArraySlice<UInt8>, _ type: CQLType, nested: Bool = false) -> String {
        let bytes = Array(b)
        func be() -> Int64 { bytes.reduce(Int64(0)) { $0 << 8 | Int64($1) } }
        func signedBE() -> Int64 { bytes.isEmpty ? 0 : (bytes[0] & 0x80 != 0 ? bytes.reduce(Int64(-1)) { $0 << 8 | Int64($1) } : be()) }
        func quoteIfNested(_ s: String) -> String { nested ? "'" + s.replacingOccurrences(of: "'", with: "''") + "'" : s }
        func children(_ r: inout ByteReader) -> ArraySlice<UInt8>? { let n = Int(r.int32BE()); return n < 0 ? nil : r.take(n) }
        switch type {
        case .simple(let id):
            switch id {
            case 1, 0x0D: return quoteIfNested(String(decoding: bytes, as: UTF8.self))
            case 2, 5, 9, 0x13, 0x14: return String(signedBE())
            case 3: return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
            case 4: return bytes.first == 0 ? "false" : "true"
            case 7: return String(Double(bitPattern: UInt64(bitPattern: be())))
            case 8: return String(Float(bitPattern: UInt32(truncatingIfNeeded: be())))
            case 0x0B:
                let d = Date(timeIntervalSince1970: Double(signedBE()) / 1000)
                return quoteIfNested(BSON.isoFormatter.string(from: d).replacingOccurrences(of: "T", with: " "))
            case 0x0C, 0x0F:
                guard bytes.count == 16 else { return "" }
                let h = bytes.map { String(format: "%02x", $0) }.joined()
                let a = Array(h)
                return "\(String(a[0..<8]))-\(String(a[8..<12]))-\(String(a[12..<16]))-\(String(a[16..<20]))-\(String(a[20..<32]))"
            case 0x0E: return String(signedBE())
            case 6:
                var r = ByteReader(bytes)
                let scale = Int(r.int32BE())
                let unscaled = Array(r.rest()).reduce(Int64(Array(r.bytes.dropFirst(4)).first.map { $0 & 0x80 != 0 ? -1 : 0 } ?? 0)) { $0 << 8 | Int64($1) }
                var s = String(unscaled.magnitude)
                if scale > 0 {
                    if s.count <= scale { s = String(repeating: "0", count: scale - s.count + 1) + s }
                    s.insert(".", at: s.index(s.endIndex, offsetBy: -scale))
                }
                return (unscaled < 0 ? "-" : "") + s
            case 0x10:
                if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
                return stride(from: 0, to: bytes.count, by: 2).map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }.joined(separator: ":")
            case 0x11:
                let days = Int64(UInt32(truncatingIfNeeded: be())) - (1 << 31)
                return quoteIfNested(String(BSON.isoFormatter.string(from: Date(timeIntervalSince1970: Double(days) * 86400)).prefix(10)))
            case 0x12:
                let ns = be()
                return quoteIfNested(String(format: "%02d:%02d:%02d.%09d", ns / 3_600_000_000_000, ns / 60_000_000_000 % 60, ns / 1_000_000_000 % 60, ns % 1_000_000_000))
            default: return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
            }
        case .list(let t), .set(let t):
            var r = ByteReader(bytes)
            let n = Int(r.int32BE())
            let items = (0..<max(0, n)).map { _ in children(&r).map { value($0, t, nested: true) } ?? "null" }
            return type.name.hasPrefix("set") ? "{" + items.joined(separator: ", ") + "}" : "[" + items.joined(separator: ", ") + "]"
        case .map(let k, let v):
            var r = ByteReader(bytes)
            let n = Int(r.int32BE())
            return "{" + (0..<max(0, n)).map { _ in
                let key = children(&r).map { value($0, k, nested: true) } ?? "null"
                return "\(key): \(children(&r).map { value($0, v, nested: true) } ?? "null")"
            }.joined(separator: ", ") + "}"
        case .udt(let fields):
            var r = ByteReader(bytes)
            return "{" + fields.compactMap { name, t in
                r.atEnd ? nil : "\(name): \(children(&r).map { value($0, t, nested: true) } ?? "null")"
            }.joined(separator: ", ") + "}"
        case .tuple(let ts):
            var r = ByteReader(bytes)
            return "(" + ts.map { t in children(&r).map { value($0, t, nested: true) } ?? "null" }.joined(separator: ", ") + ")"
        case .custom:
            return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: Queries

    private func query(_ cql: String, pagingState: [UInt8]?, pageSize: Int32) throws -> (QueryResult, [UInt8]?) {
        var body: [UInt8] = []
        let text = Array(cql.utf8)
        body.appendInt32BE(Int32(text.count))
        body += text
        body.appendInt16BE(0x000A)  // LOCAL_ONE
        var flags: UInt8 = 0x04
        if pagingState != nil { flags |= 0x08 }
        body.append(flags)
        body.appendInt32BE(pageSize)
        if let pagingState { body.appendInt32BE(Int32(pagingState.count)); body += pagingState }
        let (op, payload) = try request(0x07, body)
        if op == 0x00 {
            var r = ByteReader(payload)
            let code = r.int32BE()
            throw DatabaseError(readString(&r), code: String(format: "0x%04X", code))
        }
        guard op == 0x08 else { throw DatabaseError("Cassandra sent an unexpected reply (\(op)).") }
        var r = ByteReader(payload)
        let kind = r.int32BE()
        switch kind {
        case 2:
            let flags = r.int32BE()
            let count = Int(r.int32BE())
            var next: [UInt8]?
            if flags & 0x02 != 0 { let n = Int(r.int32BE()); if n >= 0 { next = Array(r.take(n)) } }
            let global = flags & 0x01 != 0
            if global { _ = readString(&r); _ = readString(&r) }
            var cols: [(String, CQLType)] = []
            if flags & 0x04 == 0 {
                for _ in 0..<count {
                    if !global { _ = readString(&r); _ = readString(&r) }
                    let name = readString(&r)
                    cols.append((name, readType(&r)))
                }
            }
            let rowCount = Int(r.int32BE())
            var rows: [[String?]] = []
            rows.reserveCapacity(rowCount)
            for _ in 0..<rowCount {
                rows.append(cols.map { c in
                    let n = Int(r.int32BE())
                    return n < 0 ? nil : value(r.take(n), c.1)
                })
            }
            let columns = cols.map { ResultColumn(name: $0.0, typeName: $0.1.name, isBinary: $0.1.name == "blob") }
            return (QueryResult(columns: columns, rows: rows), next)
        case 3:
            currentDatabase = readString(&r)
            return (QueryResult(message: "Using \(currentDatabase ?? "")"), nil)
        case 5:
            let change = readString(&r)
            return (QueryResult(message: change.capitalized), nil)
        default:
            return (QueryResult(message: "Done"), nil)
        }
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        var out: [QueryResult] = []
        for statement in SQLText.statements(in: sql).map(\.sql) {
            // The app's pages start with /* skip N */: CQL has no OFFSET.
            var skip = 0
            if let m = statement.range(of: #"^/\* skip (\d+) \*/"#, options: .regularExpression) {
                skip = Int(statement[m].filter(\.isNumber)) ?? 0
            }
            do {
                var (result, next) = try query(statement, pagingState: nil, pageSize: 5000)
                while let state = next, result.rows.count < skip + rowLimit {
                    let (more, after) = try query(statement, pagingState: state, pageSize: 5000)
                    result.rows += more.rows
                    next = after
                }
                if skip > 0 { result.rows = Array(result.rows.dropFirst(skip)) }
                if result.rows.count > rowLimit || next != nil && result.hasRows {
                    result.truncated = result.rows.count > rowLimit
                    result.rows = Array(result.rows.prefix(rowLimit))
                }
                if result.hasRows { result.message = "\(result.rows.count) rows" }
                out.append(result)
            } catch var e as DatabaseError {
                e.completed = out
                throw e
            }
        }
        return out
    }

    public func cancel() {}
    public func close() { socket.close() }
    deinit { close() }

    // MARK: Schema

    public func databases() throws -> [String] {
        try rows("SELECT keyspace_name FROM system_schema.keyspaces").compactMap { $0[0] }
            .filter { !$0.hasPrefix("system") }.sorted()
    }

    public func use(database: String) throws { _ = try execute("USE \(dialect.quote(database))") }
    public func schemas() throws -> [String] { [] }

    public func objects(schema: String?) throws -> [DBObject] {
        guard let ks = currentDatabase else { return [] }
        let k = dialect.literal(ks)
        var out = try rows("SELECT table_name FROM system_schema.tables WHERE keyspace_name = \(k)").compactMap { $0[0].map { DBObject(schema: nil, name: $0, kind: .table) } }
        out += try rows("SELECT view_name FROM system_schema.views WHERE keyspace_name = \(k)").compactMap { $0[0].map { DBObject(schema: nil, name: $0, kind: .materializedView) } }
        return out.sorted { $0.name < $1.name }
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        guard let ks = currentDatabase else { return [] }
        let all = try rows("""
            SELECT column_name, type, kind, position FROM system_schema.columns WHERE keyspace_name = \(dialect.literal(ks)) AND table_name = \(dialect.literal(table.name))
            """)
        func rank(_ r: [String?]) -> (Int, Int) {
            let k = r[2] ?? ""
            return (k == "partition_key" ? 0 : k == "clustering" ? 1 : k == "static" ? 2 : 3, Int(r[3] ?? "") ?? 0)
        }
        return all.sorted { rank($0) < rank($1) }.map { r in
            let key = ["partition_key", "clustering"].contains(r[2] ?? "")
            return ColumnInfo(name: r[0] ?? "", type: r[1] ?? "", nullable: !key, defaultValue: nil, isPrimaryKey: key,
                              extra: r[2] == "partition_key" ? "partition key" : r[2] == "clustering" ? "clustering" : r[2] == "static" ? "static" : nil)
        }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        guard let ks = currentDatabase else { return [] }
        return try rows("SELECT index_name, kind, options FROM system_schema.indexes WHERE keyspace_name = \(dialect.literal(ks)) AND table_name = \(dialect.literal(table.name))")
            .map { IndexInfo(name: $0[0] ?? "", columns: [$0[2] ?? ""], unique: false, primary: false, definition: $0[1]) }
    }

    public func definition(of object: DBObject) throws -> String? {
        let cols = try columns(of: object.table)
        let partition = cols.filter { $0.extra == "partition key" }.map { dialect.quote($0.name) }
        let clustering = cols.filter { $0.extra == "clustering" }.map { dialect.quote($0.name) }
        var lines = cols.map { "  \(dialect.quote($0.name)) \($0.type)\($0.extra == "static" ? " STATIC" : "")" }
        let pk = (partition.count > 1 ? "(\(partition.joined(separator: ", ")))" : partition.first ?? "") + (clustering.isEmpty ? "" : ", " + clustering.joined(separator: ", "))
        lines.append("  PRIMARY KEY (\(pk))")
        return "CREATE TABLE \(dialect.quote(object.name)) (\n\(lines.joined(separator: ",\n"))\n);"
    }

    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] { [] }
    public func estimatedCount(of table: TableRef) throws -> Int? { nil }
}

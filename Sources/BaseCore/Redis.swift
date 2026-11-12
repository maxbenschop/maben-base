import Foundation

/// Redis and Valkey over RESP2. Each database's keys show as one table (key, type, ttl, value); the query
/// editor takes Redis commands, one per line.
public final class RedisDriver: Driver {
    public let kind = DatabaseKind.redis
    public let dialect = Dialect(kind: .redis)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?
    private let socket: Socket
    private var databaseCount = 16

    indirect enum Reply: Equatable {
        case simple(String), error(String), integer(Int), bulk(Data?), array([Reply]?)

        var text: String? {
            switch self {
            case .simple(let s): s
            case .integer(let i): String(i)
            case .bulk(let d): d.map { String(data: $0, encoding: .utf8) ?? "0x" + $0.map { String(format: "%02X", $0) }.joined() }
            case .error(let e): e
            case .array: nil
            }
        }

        var items: [Reply] { if case .array(let a) = self { return a ?? [] }; return [] }
    }

    public init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        socket = try Socket(host: host, port: port)
        if tls.mode != .off && !host.hasPrefix("/") { socket.startTLS(tls) }
        if !password.isEmpty {
            let reply = try command(user.isEmpty || user == "default" ? ["AUTH", password] : ["AUTH", user, password])
            if case .error(let e) = reply { throw DatabaseError("Redis refused the password.", detail: e) }
        }
        if case .error(let e) = try command(["PING"]) { throw DatabaseError(e) }
        let info = try command(["INFO", "server"]).text ?? ""
        serverVersion = info.split(whereSeparator: \.isNewline).first { $0.hasPrefix("redis_version:") || $0.hasPrefix("valkey_version:") }
            .map { String($0.split(separator: ":")[1]) } ?? ""
        if let n = try? command(["CONFIG", "GET", "databases"]).items.last?.text.flatMap(Int.init) { databaseCount = n }
        let db = Int(database) ?? 0
        try use(database: String(db))
    }

    // MARK: RESP

    private func encode(_ args: [String]) -> [UInt8] {
        var out = Array("*\(args.count)\r\n".utf8)
        for a in args {
            let bytes = Array(a.utf8)
            out += Array("$\(bytes.count)\r\n".utf8) + bytes + [13, 10]
        }
        return out
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        while true {
            let b = try socket.readByte()
            if b == 13 { _ = try socket.readByte(); break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readReply() throws -> Reply {
        let type = try socket.readByte()
        let line = try readLine()
        switch type {
        case UInt8(ascii: "+"): return .simple(line)
        case UInt8(ascii: "-"): return .error(line)
        case UInt8(ascii: ":"): return .integer(Int(line) ?? 0)
        case UInt8(ascii: "$"):
            let n = Int(line) ?? -1
            if n < 0 { return .bulk(nil) }
            let data = Data(try socket.read(n))
            _ = try socket.read(2)
            return .bulk(data)
        case UInt8(ascii: "*"):
            let n = Int(line) ?? -1
            if n < 0 { return .array(nil) }
            return .array(try (0..<n).map { _ in try readReply() })
        default:
            throw DatabaseError("Redis sent a reply this app doesn't understand.")
        }
    }

    func command(_ args: [String]) throws -> Reply {
        try socket.write(encode(args))
        return try readReply()
    }

    /// Several commands in one round trip.
    func pipeline(_ commands: [[String]]) throws -> [Reply] {
        guard !commands.isEmpty else { return [] }
        try socket.write(commands.flatMap(encode))
        return try commands.map { _ in try readReply() }
    }

    // MARK: Running

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        var results: [QueryResult] = []
        let lines = sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
        for line in lines {
            let args = RedisText.split(line)
            guard let name = args.first?.uppercased() else { continue }
            do {
                switch name {
                case "MB.PAGE": results.append(try page(pattern: args[safe: 1] ?? "*", offset: Int(args[safe: 2] ?? "") ?? 0, limit: Int(args[safe: 3] ?? "") ?? 300))
                case "MB.COUNT": results.append(QueryResult(columns: [ResultColumn(name: "count", typeName: "integer")], rows: [[String(try count(args[safe: 1] ?? "*"))]]))
                default:
                    let reply = try command(args)
                    if case .error(let e) = reply { throw DatabaseError(e) }
                    // An error inside MULTI … EXEC comes back as one of EXEC's replies.
                    if name == "EXEC", let failed = reply.items.first(where: { if case .error = $0 { true } else { false } }) {
                        throw DatabaseError(failed.text ?? "A command in the transaction failed.")
                    }
                    if name == "SELECT", let db = args[safe: 1] { currentDatabase = db }
                    results.append(Self.result(reply, rowLimit: rowLimit))
                }
            } catch var e as DatabaseError {
                e.completed = results
                throw e
            }
        }
        return results
    }

    /// A reply as rows: lists one value per row, maps (HGETALL, CONFIG GET) as field/value pairs.
    static func result(_ reply: Reply, rowLimit: Int) -> QueryResult {
        switch reply {
        case .array(let items):
            let list = items ?? []
            if list.contains(where: { if case .array = $0 { true } else { false } }) {
                let rows = list.prefix(rowLimit).map { item -> [String?] in
                    if case .array = item { return [RedisText.json(item)] }
                    return [item.text]
                }
                return QueryResult(columns: [ResultColumn(name: "value", typeName: "")], rows: rows, message: "\(list.count) items")
            }
            let rows = list.prefix(rowLimit).enumerated().map { [String($0.offset), $0.element.text] as [String?] }
            return QueryResult(columns: [ResultColumn(name: "#", typeName: "integer"), ResultColumn(name: "value", typeName: "")], rows: rows,
                               message: "\(list.count) items", truncated: list.count > rowLimit)
        case .integer(let i):
            return QueryResult(columns: [ResultColumn(name: "result", typeName: "integer")], rows: [[String(i)]], message: "(integer) \(i)")
        default:
            return QueryResult(columns: [ResultColumn(name: "result", typeName: "")], rows: [[reply.text]], message: reply.text ?? "(nil)")
        }
    }

    private func scanAll(_ pattern: String, cap: Int = 200_000) throws -> [String] {
        var keys: [String] = []
        var cursor = "0"
        repeat {
            let reply = try command(["SCAN", cursor, "MATCH", pattern, "COUNT", "1000"])
            let parts = reply.items
            cursor = parts.first?.text ?? "0"
            keys += parts.last?.items.compactMap(\.text) ?? []
        } while cursor != "0" && keys.count < cap
        return keys
    }

    private func count(_ pattern: String) throws -> Int {
        let (glob, type) = RedisText.unpack(pattern)
        if glob == "*" && type == nil, case .integer(let n) = try command(["DBSIZE"]) { return n }
        let keys = try scanAll(glob)
        guard let type else { return keys.count }
        return try pipeline(keys.map { ["TYPE", $0] }).filter { $0.text == type }.count
    }

    /// The keys of a page with their type, time to live and value. Keys are sorted so pages stay put.
    private func page(pattern: String, offset: Int, limit: Int) throws -> QueryResult {
        let (glob, type) = RedisText.unpack(pattern)
        var keys = try scanAll(glob).sorted()
        var types = try pipeline(keys.map { ["TYPE", $0] }).map { $0.text ?? "" }
        if let type {
            let kept = zip(keys, types).filter { $0.1 == type }
            keys = kept.map(\.0); types = kept.map(\.1)
        }
        let range = min(offset, keys.count)..<min(offset + limit, keys.count)
        let pageKeys = Array(keys[range]), pageTypes = Array(types[range])
        let ttls = try pipeline(pageKeys.map { ["PTTL", $0] })
        let values = try pipeline(zip(pageKeys, pageTypes).map { key, type -> [String] in
            switch type {
            case "string": ["GET", key]
            case "hash": ["HGETALL", key]
            case "list": ["LRANGE", key, "0", "199"]
            case "set": ["SRANDMEMBER", key, "200"]
            case "zset": ["ZRANGE", key, "0", "199", "WITHSCORES"]
            case "stream": ["XLEN", key]
            case "ReJSON-RL": ["JSON.GET", key]
            default: ["TYPE", key]
            }
        })
        var rows: [[String?]] = []
        for (i, key) in pageKeys.enumerated() {
            let ttl: String? = { if case .integer(let ms) = ttls[i] { return ms < 0 ? nil : String(ms / 1000) }; return nil }()
            let value: String?
            switch pageTypes[i] {
            case "string", "ReJSON-RL": value = values[i].text
            case "hash": value = RedisText.json(values[i], asMap: true)
            case "zset": value = RedisText.json(values[i], asPairs: true)
            case "stream": value = "(stream of \(values[i].text ?? "?") entries)"
            default: value = RedisText.json(values[i])
            }
            rows.append([key, pageTypes[i], ttl, value])
        }
        return QueryResult(columns: [ResultColumn(name: "key", typeName: "key"), ResultColumn(name: "type", typeName: "type"),
                                     ResultColumn(name: "ttl", typeName: "seconds"), ResultColumn(name: "value", typeName: "value")],
                           rows: rows, message: "\(rows.count) keys")
    }

    public func cancel() {}
    public func close() { socket.close() }
    deinit { close() }

    // MARK: Schema

    public func databases() throws -> [String] { (0..<databaseCount).map(String.init) }

    public func use(database: String) throws {
        guard let n = Int(database) else { throw DatabaseError("Redis databases are numbers (0–\(databaseCount - 1)).") }
        if case .error(let e) = try command(["SELECT", String(n)]) { throw DatabaseError(e) }
        currentDatabase = String(n)
    }

    public func schemas() throws -> [String] { [] }
    public func objects(schema: String?) throws -> [DBObject] { [DBObject(schema: nil, name: "keys", kind: .table)] }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        [ColumnInfo(name: "key", type: "key", nullable: false, defaultValue: nil, isPrimaryKey: true),
         ColumnInfo(name: "type", type: "type", nullable: false, defaultValue: nil, isPrimaryKey: false,
                    enumValues: ["string", "hash", "list", "set", "zset"]),
         ColumnInfo(name: "ttl", type: "integer", nullable: true, defaultValue: nil, isPrimaryKey: false, comment: "Seconds until it expires; empty keeps it"),
         ColumnInfo(name: "value", type: "text", nullable: true, defaultValue: nil, isPrimaryKey: false,
                    comment: "Hashes, lists and sets as JSON")]
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] { [] }
    public func definition(of object: DBObject) throws -> String? { nil }
    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] { [] }
    public func estimatedCount(of table: TableRef) throws -> Int? {
        if case .integer(let n) = try command(["DBSIZE"]) { return n }
        return nil
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The text the app writes for Redis: page and count pseudo-commands, key patterns from filters, and
/// the commands that save edits.
public enum RedisText {
    /// Splits a command line into arguments: spaces separate; "double" or 'single' quotes keep spaces.
    public static func split(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var inToken = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if let q = quote {
                if c == "\\", q == "\"", let next = chars.popFirst() {
                    switch next { case "n": current.append("\n"); case "t": current.append("\t"); default: current.append(next) }
                } else if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; inToken = true
            } else if c.isWhitespace {
                if inToken { out.append(current); current = ""; inToken = false }
            } else {
                current.append(c); inToken = true
            }
        }
        if inToken { out.append(current) }
        return out
    }

    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func glob(_ s: String) -> String {
        var out = ""
        for c in s { if "*?[]\\".contains(c) { out.append("\\") }; out.append(c) }
        return out
    }

    /// Filters on key (equals, contains, starts/ends with, SQL = a raw pattern) and type (equals).
    public static func pattern(_ filters: [Filter]) -> String? {
        var pattern = "*"
        var type: String?
        for f in filters where f.enabled {
            if f.column == "type", f.op == .equals { type = f.value; continue }
            switch f.op {
            case .equals: pattern = glob(f.value)
            case .contains: pattern = "*\(glob(f.value))*"
            case .startsWith: pattern = "\(glob(f.value))*"
            case .endsWith: pattern = "*\(glob(f.value))"
            case .sql: pattern = f.value
            default: break
            }
        }
        if pattern == "*" && type == nil { return nil }
        return pattern + (type.map { "\u{1}" + $0 } ?? "")
    }

    static func unpack(_ packed: String) -> (glob: String, type: String?) {
        let parts = packed.split(separator: "\u{1}", maxSplits: 1).map(String.init)
        return (parts.first ?? "*", parts.count > 1 ? parts[1] : nil)
    }

    static func page(filter: String?, limit: Int, offset: Int) -> String { "MB.PAGE \(quote(filter ?? "*")) \(offset) \(limit)" }
    static func count(filter: String?) -> String { "MB.COUNT \(quote(filter ?? "*"))" }

    static func json(_ reply: RedisDriver.Reply, asMap: Bool = false, asPairs: Bool = false) -> String {
        let items = reply.items
        var object: Any
        if asMap {
            var d: [String: String] = [:]
            stride(from: 0, to: items.count - 1, by: 2).forEach { d[items[$0].text ?? ""] = items[$0 + 1].text ?? "" }
            object = d
        } else if asPairs {
            object = stride(from: 0, to: items.count - 1, by: 2).map { [items[$0].text ?? "", Double(items[$0 + 1].text ?? "") ?? 0] as [Any] }
        } else {
            object = items.map { item -> Any in
                if case .array = item { return (try? JSONSerialization.jsonObject(with: Data(json(item).utf8))) ?? NSNull() }
                return item.text ?? NSNull()
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Edits as commands. Columns: key, type, ttl, value. Collections are replaced whole, inside MULTI/EXEC.
    public static func statements(for changes: ChangeSet, columns: [ResultColumn]) throws -> [String] {
        func col(_ name: String) -> Int? { columns.firstIndex { $0.name == name } }
        guard let k = col("key"), let t = col("type"), let ttl = col("ttl"), let v = col("value") else {
            throw DatabaseError("Redis keys are edited in the keys table.")
        }
        func write(_ key: String, type: String, value: String?) throws -> [String] {
            let q = quote(key)
            guard let value else { return ["DEL \(q)"] }
            func parse() throws -> Any {
                guard let o = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) else {
                    throw DatabaseError("The value of \(key) must be JSON for a \(type).")
                }
                return o
            }
            func s(_ x: Any) -> String { x is NSNull ? "\"\"" : quote("\(x)") }
            switch type {
            case "hash":
                guard let d = try parse() as? [String: Any], !d.isEmpty else { throw DatabaseError("A hash needs a JSON object with at least one field.") }
                return ["DEL \(q)", "HSET \(q) " + d.keys.sorted().map { "\(quote($0)) \(s(d[$0]!))" }.joined(separator: " ")]
            case "list", "set":
                guard let a = try parse() as? [Any], !a.isEmpty else { throw DatabaseError("A \(type) needs a JSON array with at least one item.") }
                return ["DEL \(q)", "\(type == "list" ? "RPUSH" : "SADD") \(q) " + a.map(s).joined(separator: " ")]
            case "zset":
                guard let a = try parse() as? [[Any]], !a.isEmpty else { throw DatabaseError("A sorted set needs [[\"member\", score], …].") }
                return ["DEL \(q)", "ZADD \(q) " + a.map { "\($0.count > 1 ? "\($0[1])" : "0") \(s($0[0]))" }.joined(separator: " ")]
            default:
                return ["SET \(q) \(quote(value)) KEEPTTL"]
            }
        }
        func expire(_ key: String, _ value: String?) -> String {
            guard let value, let n = Int(value.trimmingCharacters(in: .whitespaces)), n >= 0 else { return "PERSIST \(quote(key))" }
            return "EXPIRE \(quote(key)) \(n)"
        }
        func transaction(_ lines: [String]) -> String { lines.count > 1 ? (["MULTI"] + lines + ["EXEC"]).joined(separator: "\n") : lines.joined() }

        var out: [String] = []
        for row in changes.deletes.sorted() {
            guard let original = changes.originals[row], let key = original[k] else { continue }
            out.append("DEL \(quote(key))")
        }
        for row in changes.updates.keys.sorted() where !changes.deletes.contains(row) {
            guard let original = changes.originals[row], let key = original[k], let edits = changes.updates[row] else { continue }
            if let newType = edits[t] ?? nil, newType != original[t] { throw DatabaseError("A key's type can't be changed here; delete it and add it again.") }
            var lines: [String] = []
            if let value = edits[v] { lines += try write(key, type: original[t] ?? "string", value: value) }
            if let newTTL = edits[ttl] { lines.append(expire(key, newTTL)) }
            else if edits[v] != nil, let oldTTL = original[ttl], original[t] != "string" { lines.append(expire(key, oldTTL)) }
            if let newKey = edits[k] ?? nil, newKey != key { lines.append("RENAME \(quote(key)) \(quote(newKey))") }
            if !lines.isEmpty { out.append(transaction(lines)) }
        }
        for insert in changes.inserts {
            guard let key = insert.values[k] ?? nil, !key.isEmpty else { throw DatabaseError("A new key needs a name.") }
            let type = (insert.values[t] ?? nil) ?? "string"
            var lines = try write(key, type: type, value: (insert.values[v] ?? nil) ?? "")
            if type == "string" { lines = ["SET \(quote(key)) \(quote((insert.values[v] ?? nil) ?? ""))"] } else { lines.removeFirst() }
            if let t = insert.values[ttl] ?? nil, !t.isEmpty { lines.append(expire(key, t)) }
            out.append(transaction(lines))
        }
        return out
    }
}

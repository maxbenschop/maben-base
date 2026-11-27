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
        var isError: Bool { if case .error = self { return true }; return false }
    }

    public init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        socket = try Socket(host: host, port: port)
        // The handshake runs here, and with TLS Verify the certificate is checked here: before AUTH goes out.
        if tls.mode != .off && !host.hasPrefix("/") { try socket.startTLS(tls) }
        if !password.isEmpty {
            let reply = try command(user.isEmpty || user == "default" ? ["AUTH", password] : ["AUTH", user, password])
            if case .error(let e) = reply { throw DatabaseError("Redis refused the password.", detail: e) }
        }
        if case .error(let e) = try command(["PING"]) { throw DatabaseError(e) }
        let info = try command(["INFO", "server"]).text ?? ""
        serverVersion = info.split(whereSeparator: \.isNewline).first { $0.hasPrefix("redis_version:") || $0.hasPrefix("valkey_version:") }
            .flatMap { $0.split(separator: ":").dropFirst().first.map(String.init) } ?? ""
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

    /// Limits on what a reply may ask the app to hold: Redis itself stops a value at 512 MB.
    private static let maxLine = 1 << 20, maxBulk = 512 << 20, maxItems = 1 << 26, maxDepth = 64

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        while true {
            let b = try socket.readByte()
            if b == 13 { _ = try socket.readByte(); break }
            guard bytes.count < Self.maxLine else { throw DatabaseError.malformedReply("A reply line of more than \(Self.maxLine) bytes.") }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readReply(depth: Int = 0) throws -> Reply {
        // Arrays nest; a reply nested without end would otherwise run the app out of stack.
        guard depth <= Self.maxDepth else { throw DatabaseError.malformedReply("A reply nested more than \(Self.maxDepth) deep.") }
        let type = try socket.readByte()
        let line = try readLine()
        switch type {
        case UInt8(ascii: "+"): return .simple(line)
        case UInt8(ascii: "-"): return .error(line)
        case UInt8(ascii: ":"): return .integer(Int(line) ?? 0)
        case UInt8(ascii: "$"):
            let n = Int(line) ?? -1
            if n < 0 { return .bulk(nil) }
            guard n <= Self.maxBulk else { throw DatabaseError.malformedReply("A value of \(n) bytes.") }
            let data = Data(try socket.read(n))
            _ = try socket.read(2)
            return .bulk(data)
        case UInt8(ascii: "*"):
            let n = Int(line) ?? -1
            if n < 0 { return .array(nil) }
            guard n <= Self.maxItems else { throw DatabaseError.malformedReply("A list of \(n) items.") }
            // No room is set aside up front: the list grows only as items really arrive.
            var items: [Reply] = []
            for _ in 0..<n { items.append(try readReply(depth: depth + 1)) }
            return .array(items)
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
                    if name == "EXEC", let failed = reply.items.first(where: \.isError) {
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

    /// Saves edits as commands built from the values themselves, each argument sent whole (a RESP array).
    /// A key or value never passes through the editor's line parser, so a line break or a quote in one
    /// can't end the command and start another.
    public func apply(_ changes: ChangeSet, table: TableRef, columns: [ResultColumn], primaryKey: [String]) throws {
        for unit in try RedisText.commands(for: changes, columns: columns) {
            let commands = unit.map { $0.map(\.value) }
            let replies = commands.count == 1 ? [try command(commands[0])] : try pipeline([["MULTI"]] + commands + [["EXEC"]])
            // An error inside MULTI … EXEC comes back as one of EXEC's replies, or stops EXEC itself.
            let failed = replies.first(where: \.isError) ?? replies.last?.items.first(where: \.isError)
            if let failed { throw DatabaseError(failed.text ?? "A command failed.") }
        }
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
        // Offset and limit come from text (MB.PAGE): keep them inside the keys there are.
        let lower = min(max(0, offset), keys.count)
        let range = lower..<(lower + min(max(0, limit), keys.count - lower))
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
    /// In double quotes, \n \r \t, \xHH and \uHHHH stand for the characters `quote` writes that way.
    public static func split(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var inToken = false
        let chars = Array(line)
        var i = 0
        /// The character with this code, from `digits` hex digits after the cursor.
        func hex(_ digits: Int) -> Character? {
            guard i + digits < chars.count, let v = UInt32(String(chars[(i + 1)...(i + digits)]), radix: 16), let scalar = Unicode.Scalar(v) else { return nil }
            i += digits
            return Character(scalar)
        }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\", q == "\"", i + 1 < chars.count {
                    i += 1
                    switch chars[i] {
                    case "n": current.append("\n")
                    case "r": current.append("\r")
                    case "t": current.append("\t")
                    case "x": current.append(hex(2) ?? "x")
                    case "u": current.append(hex(4) ?? "u")
                    default: current.append(chars[i])
                    }
                } else if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; inToken = true
            } else if c.isWhitespace {
                if inToken { out.append(current); current = ""; inToken = false }
            } else {
                current.append(c); inToken = true
            }
            i += 1
        }
        if inToken { out.append(current) }
        return out
    }

    /// An argument in double quotes that `split` reads back exactly. Every line break and control character
    /// is written as an escape, so the text is always one line, whatever the argument holds.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ConnectionConfig.isControl(scalar) {
                    out += scalar.value < 0x100 ? String(format: "\\x%02x", scalar.value) : String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Commands that only read. A connection in read-only mode runs these and nothing else: a command that
    /// isn't here counts as a write, whatever it does.
    private static let readingCommands: Set<String> = [
        "GET", "MGET", "EXISTS", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME", "TYPE", "KEYS", "SCAN", "STRLEN", "GETRANGE", "SUBSTR", "LCS",
        "RANDOMKEY", "DUMP", "DBSIZE", "INFO", "PING", "ECHO", "TIME", "SELECT", "COMMAND", "LOLWUT",
        "HGET", "HGETALL", "HMGET", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSCAN", "HSTRLEN", "HRANDFIELD",
        "LRANGE", "LLEN", "LINDEX", "LPOS",
        "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SSCAN", "SRANDMEMBER", "SINTER", "SUNION", "SDIFF", "SINTERCARD",
        "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE", "ZREVRANGEBYLEX", "ZCARD", "ZCOUNT", "ZLEXCOUNT",
        "ZSCORE", "ZMSCORE", "ZRANK", "ZREVRANK", "ZSCAN", "ZRANDMEMBER", "ZINTER", "ZUNION", "ZDIFF", "ZINTERCARD",
        "XLEN", "XRANGE", "XREVRANGE", "XPENDING",
        "BITCOUNT", "BITPOS", "GETBIT", "BITFIELD_RO", "GEOPOS", "GEODIST", "GEOHASH", "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO",
        "SORT_RO", "EVAL_RO", "EVALSHA_RO", "FCALL_RO",
        "JSON.GET", "JSON.MGET", "JSON.TYPE", "JSON.STRLEN", "JSON.ARRLEN", "JSON.OBJKEYS", "JSON.OBJLEN",
        "MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH",
        "MB.PAGE", "MB.COUNT",
    ]
    /// Commands that read only with one of these as their first argument (CONFIG GET reads, CONFIG SET doesn't).
    private static let readingSubcommands: [String: Set<String>] = [
        "CONFIG": ["GET"], "OBJECT": ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT", "HELP"], "MEMORY": ["USAGE", "STATS", "DOCTOR", "MALLOC-STATS"],
        "CLIENT": ["ID", "INFO", "LIST", "GETNAME"], "SLOWLOG": ["GET", "LEN"], "LATENCY": ["LATEST", "HISTORY", "DOCTOR"],
        "CLUSTER": ["INFO", "NODES", "SLOTS", "SHARDS", "KEYSLOT", "COUNTKEYSINSLOT", "MYID"], "PUBSUB": ["CHANNELS", "NUMSUB", "NUMPAT"],
        "XINFO": ["STREAM", "GROUPS", "CONSUMERS", "HELP"], "ACL": ["WHOAMI", "LIST", "USERS", "CAT", "GETUSER"],
        "FUNCTION": ["LIST", "STATS"], "SCRIPT": ["EXISTS"],
    ]

    /// True when every command in the text only reads. The lines are read as the driver reads them.
    static func isReadOnly(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
            .allSatisfy { line in
                let args = split(line)
                guard let name = args.first?.uppercased() else { return true }
                if let allowed = readingSubcommands[name] { return args.count > 1 && allowed.contains(args[1].uppercased()) }
                return readingCommands.contains(name)
            }
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
            // Scores can be inf, which JSON has no number for: those stay text.
            object = stride(from: 0, to: items.count - 1, by: 2).map { i -> [Any] in
                let text = items[i + 1].text ?? ""
                let score = Double(text) ?? 0
                return [items[i].text ?? "", score.isFinite ? score : text]
            }
        } else {
            object = items.map { item -> Any in
                if case .array = item { return (try? JSONSerialization.jsonObject(with: Data(json(item).utf8))) ?? NSNull() }
                return item.text ?? NSNull()
            }
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One argument of a command the app writes: a word of the command itself, or a key, field or value.
    public enum Arg: Equatable, Sendable {
        case word(String), data(String)

        public var value: String {
            switch self {
            case .word(let s), .data(let s): s
            }
        }

        /// As shown before saving: data in quotes, so it reads as one argument.
        var shown: String {
            switch self {
            case .word(let s): s
            case .data(let s): RedisText.quote(s)
            }
        }
    }

    /// Edits as text, to show before saving and to keep in the history. What runs is `commands(for:)`.
    public static func statements(for changes: ChangeSet, columns: [ResultColumn]) throws -> [String] {
        try commands(for: changes, columns: columns).map { unit in
            let lines = unit.map { $0.map(\.shown).joined(separator: " ") }
            return lines.count > 1 ? (["MULTI"] + lines + ["EXEC"]).joined(separator: "\n") : lines.joined()
        }
    }

    /// Edits as commands, each a list of arguments. Columns: key, type, ttl, value. Collections are replaced
    /// whole; an edit that takes several commands is one unit, run inside MULTI/EXEC.
    public static func commands(for changes: ChangeSet, columns: [ResultColumn]) throws -> [[[Arg]]] {
        func col(_ name: String) -> Int? { columns.firstIndex { $0.name == name } }
        guard let k = col("key"), let t = col("type"), let ttl = col("ttl"), let v = col("value") else {
            throw DatabaseError("Redis keys are edited in the keys table.")
        }
        func write(_ key: String, type: String, value: String?) throws -> [[Arg]] {
            guard let value else { return [[.word("DEL"), .data(key)]] }
            func parse() throws -> Any {
                guard let o = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) else {
                    throw DatabaseError("The value of \(key) must be JSON for a \(type).")
                }
                return o
            }
            func s(_ x: Any) -> Arg { .data(x is NSNull ? "" : "\(x)") }
            switch type {
            case "hash":
                guard let d = try parse() as? [String: Any], !d.isEmpty else { throw DatabaseError("A hash needs a JSON object with at least one field.") }
                return [[.word("DEL"), .data(key)], [.word("HSET"), .data(key)] + d.keys.sorted().flatMap { [.data($0), s(d[$0]!)] }]
            case "list", "set":
                guard let a = try parse() as? [Any], !a.isEmpty else { throw DatabaseError("A \(type) needs a JSON array with at least one item.") }
                return [[.word("DEL"), .data(key)], [.word(type == "list" ? "RPUSH" : "SADD"), .data(key)] + a.map(s)]
            case "zset":
                guard let a = try parse() as? [[Any]], !a.isEmpty, a.allSatisfy({ !$0.isEmpty }) else { throw DatabaseError("A sorted set needs [[\"member\", score], …].") }
                return [[.word("DEL"), .data(key)], [.word("ZADD"), .data(key)] + a.flatMap { [.word($0.count > 1 ? "\($0[1])" : "0"), s($0[0])] }]
            default:
                return [[.word("SET"), .data(key), .data(value), .word("KEEPTTL")]]
            }
        }
        func expire(_ key: String, _ value: String?) -> [Arg] {
            guard let value, let n = Int(value.trimmingCharacters(in: .whitespaces)), n >= 0 else { return [.word("PERSIST"), .data(key)] }
            return [.word("EXPIRE"), .data(key), .word(String(n))]
        }

        var out: [[[Arg]]] = []
        for row in changes.deletes.sorted() {
            guard let original = changes.originals[row], let key = original[safe: k] ?? nil else { continue }
            out.append([[.word("DEL"), .data(key)]])
        }
        for row in changes.updates.keys.sorted() where !changes.deletes.contains(row) {
            guard let original = changes.originals[row], let key = original[safe: k] ?? nil, let edits = changes.updates[row] else { continue }
            let oldType = original[safe: t] ?? nil
            if let newType = edits[t] ?? nil, newType != oldType { throw DatabaseError("A key's type can't be changed here; delete it and add it again.") }
            var lines: [[Arg]] = []
            if let value = edits[v] { lines += try write(key, type: oldType ?? "string", value: value) }
            if let newTTL = edits[ttl] { lines.append(expire(key, newTTL)) }
            else if edits[v] != nil, let oldTTL = original[safe: ttl] ?? nil, oldType != "string" { lines.append(expire(key, oldTTL)) }
            if let newKey = edits[k] ?? nil, newKey != key { lines.append([.word("RENAME"), .data(key), .data(newKey)]) }
            if !lines.isEmpty { out.append(lines) }
        }
        for insert in changes.inserts {
            guard let key = insert.values[k] ?? nil, !key.isEmpty else { throw DatabaseError("A new key needs a name.") }
            let type = (insert.values[t] ?? nil) ?? "string"
            var lines = try write(key, type: type, value: (insert.values[v] ?? nil) ?? "")
            if type == "string" { lines = [[.word("SET"), .data(key), .data((insert.values[v] ?? nil) ?? "")]] } else { lines.removeFirst() }
            if let t = insert.values[ttl] ?? nil, !t.isEmpty { lines.append(expire(key, t)) }
            out.append(lines)
        }
        return out
    }
}

import Foundation

/// A saved connection. The password lives in the Keychain, not here.
public struct ConnectionConfig: Codable, Hashable, Identifiable, Sendable {
    public enum TLS: String, Codable, CaseIterable, Sendable {
        /// Plain connection.
        case off
        /// TLS if the server offers it, without checking the certificate. Falls back to a plain connection
        /// only for this Mac and private networks. Engines reached over HTTPS check the certificate.
        case prefer
        /// TLS required, certificate not checked (self-signed servers).
        case require
        /// TLS required and the certificate must be valid for the host.
        case verify

        public var title: String {
            switch self {
            case .off: "Off"
            case .prefer: "Prefer"
            case .require: "Require"
            case .verify: "Verify"
            }
        }

        /// What the mode does, in one sentence, for the connection editor.
        public func help(for kind: DatabaseKind) -> String {
            switch self {
            case .off:
                return "No encryption: the password and your data cross the network as plain text."
            case .prefer:
                if kind.usesHTTP { return "Encrypts, and checks the server's certificate." }
                if kind.startsWithTLS { return "Encrypts, without checking the server's certificate." }
                return "Encrypts when the server can, without checking its certificate. Stays plain only on this Mac or a private network."
            case .require:
                return "Always encrypts, but accepts any certificate, so nothing proves the server is yours."
            case .verify:
                return "Always encrypts, and connects only when the server's certificate is valid for its name."
            }
        }
    }

    /// The colour tag that says what you're connected to. Production asks before writing.
    public enum Environment: String, Codable, CaseIterable, Sendable {
        case local, development, staging, production

        public var title: String { rawValue.capitalized }
    }

    /// How careful the app is with this connection.
    public enum SafeMode: String, Codable, CaseIterable, Sendable {
        /// Runs everything right away.
        case off
        /// Asks before anything that changes data or structure.
        case confirmWrites
        /// Asks before every query, reads included.
        case confirmAll
        /// Asks for Touch ID or your Mac password before anything that changes data or structure.
        case authenticate
        /// Never writes.
        case readOnly

        public var title: String {
            switch self {
            case .off: "Off"
            case .confirmWrites: "Ask before writes"
            case .confirmAll: "Ask before every query"
            case .authenticate: "Touch ID before writes"
            case .readOnly: "Read-only"
            }
        }
    }

    public var id = UUID()
    public var name = ""
    public var group = ""
    public var kind: DatabaseKind = .postgres
    public var environment: Environment = .local
    public var host = "127.0.0.1"
    public var port: Int = 5432
    public var user = ""
    public var database = ""
    public var tls: TLS = .prefer
    /// SQLite: the database file.
    public var filePath = ""
    public var safeMode: SafeMode = .off
    public var readOnly: Bool {
        get { safeMode == .readOnly }
        set { safeMode = newValue ? .readOnly : (safeMode == .readOnly ? .off : safeMode) }
    }
    /// Optional CA certificate (PEM or DER) the server's certificate must chain to, for TLS Verify.
    public var caFile = ""
    /// Optional client certificate and key as a .p12 file (its password is in the Keychain).
    public var clientCertFile = ""

    public var sshEnabled = false
    public var sshHost = ""
    public var sshPort: Int = 22
    public var sshUser = ""
    /// Optional private key; without it, ssh uses your agent and ~/.ssh/config.
    public var sshKeyPath = ""
    /// Sign in to the SSH server with a password (kept in the Keychain) instead of a key.
    public var sshUsePassword = false
    /// The last time this connection was changed, for syncing between Macs.
    public var modified = Date(timeIntervalSince1970: 0)
    /// Engine-specific settings: warehouse and role (Snowflake), endpoint (BigQuery emulator), authSource and
    /// replicaSet (MongoDB), srv (mongodb+srv).
    public var options: [String: String] = [:]
    /// Where sqlplus or duckdb is, when it isn't in one of the usual places. This names a program the app
    /// runs, so it is set only in the editor on this Mac and kept in this Mac's own settings (`Store`):
    /// it is never read from a URL, a connections file or the synced list, and never written to them.
    public var localToolPath = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, group, kind, environment, host, port, user, database, tls, filePath, safeMode, caFile, clientCertFile
        case sshEnabled, sshHost, sshPort, sshUser, sshKeyPath, sshUsePassword, modified, options
    }
    private enum LegacyKeys: String, CodingKey { case readOnly }

    /// Missing fields keep their defaults, so connections saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(UUID.self, forKey: .id) { id = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .name) { name = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .group) { group = v }
        if let v = try c.decodeIfPresent(DatabaseKind.self, forKey: .kind) { kind = v }
        if let v = try c.decodeIfPresent(Environment.self, forKey: .environment) { environment = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .host) { host = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .port) { port = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .user) { user = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .database) { database = v }
        if let v = try c.decodeIfPresent(TLS.self, forKey: .tls) { tls = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .filePath) { filePath = v }
        if let v = try c.decodeIfPresent(SafeMode.self, forKey: .safeMode) {
            safeMode = v
        } else {
            // Before safe modes: a read-only switch, and production always asked before writes.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if try legacy.decodeIfPresent(Bool.self, forKey: .readOnly) == true { safeMode = .readOnly }
            else if environment == .production { safeMode = .confirmWrites }
        }
        if let v = try c.decodeIfPresent(String.self, forKey: .caFile) { caFile = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .clientCertFile) { clientCertFile = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .sshUsePassword) { sshUsePassword = v }
        if let v = try c.decodeIfPresent(Date.self, forKey: .modified) { modified = v }
        if let v = try c.decodeIfPresent([String: String].self, forKey: .options) { options = v }
        // Older versions kept the tool's path here, where a file from someone else could set it.
        options["tool"] = nil
        if let v = try c.decodeIfPresent(Bool.self, forKey: .sshEnabled) { sshEnabled = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .sshHost) { sshHost = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .sshPort) { sshPort = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .sshUser) { sshUser = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .sshKeyPath) { sshKeyPath = v }
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .sqlite: return (filePath as NSString).lastPathComponent.isEmpty ? "SQLite" : (filePath as NSString).lastPathComponent
        default: return database.isEmpty ? host : "\(database) on \(host)"
        }
    }

    public var summary: String {
        switch kind {
        case .sqlite: return (filePath as NSString).abbreviatingWithTildeInPath
        default:
            var s = user.isEmpty ? "" : "\(user)@"
            s += "\(host):\(port)"
            if !database.isEmpty { s += "/\(database)" }
            if sshEnabled { s += " via \(sshHost)" }
            return s
        }
    }

    // MARK: Checks

    /// Line breaks, NULs, escapes and the other control characters. No field needs one, and fields end up
    /// in command lines and in tools that read their input a line at a time.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    static func hasControl(_ text: String) -> Bool { text.unicodeScalars.contains(where: isControl) }

    private var textFields: [String] {
        [name, group, host, user, database, filePath, caFile, clientCertFile, sshHost, sshUser, sshKeyPath, localToolPath]
            + options.keys + options.values
    }

    /// False when a field holds a control character. Connections from a URL, a file or the synced list are
    /// refused when it is false, and nothing connects with one.
    public var isWellFormed: Bool { !textFields.contains(where: Self.hasControl) }

    /// Takes control characters out of every field (what was pasted into the editor, or saved by an older version).
    public mutating func stripControlCharacters() {
        func clean(_ text: String) -> String {
            Self.hasControl(text) ? String(String.UnicodeScalarView(text.unicodeScalars.filter { !Self.isControl($0) })) : text
        }
        name = clean(name); group = clean(group); host = clean(host); user = clean(user); database = clean(database)
        filePath = clean(filePath); caFile = clean(caFile); clientCertFile = clean(clientCertFile)
        sshHost = clean(sshHost); sshUser = clean(sshUser); sshKeyPath = clean(sshKeyPath); localToolPath = clean(localToolPath)
        if options.contains(where: { Self.hasControl($0.key) || Self.hasControl($0.value) }) {
            options = Dictionary(options.map { (clean($0.key), clean($0.value)) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The TLS mode a new connection starts with: Verify for a server out on the internet, Prefer for this
    /// Mac and private networks, where certificates are rarely set up.
    public static func defaultTLS(kind: DatabaseKind, host: String) -> TLS {
        if kind.isFile { return .off }
        guard HostScope.isLocal(host) else { return .verify }
        // Postgres, MySQL and SQL Server are asked first and go on plain when they have no TLS. The others
        // can't be asked (HTTP, or TLS from the first byte), and nearby they are nearly always plain: a
        // local Redis, ClickHouse or sqld. An https:// address is still HTTPS, checked, whatever the mode.
        return kind.usesHTTP || kind.startsWithTLS ? .off : .prefer
    }

    /// Fills the fields from a URL like postgres://user:pass@host:5432/db?sslmode=require.
    /// Returns the password, if the URL has one. A URL never chooses a program to run: `tool=` is ignored.
    @discardableResult
    public mutating func apply(url string: String) -> (ok: Bool, password: String?) {
        var filled = self
        let result = filled.fill(url: string)
        // A URL with a line break or another control character in a field is refused whole.
        guard result.ok, filled.isWellFormed else { return (false, nil) }
        self = filled
        return result
    }

    private mutating func fill(url string: String) -> (ok: Bool, password: String?) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // MongoDB lists replica set members as host1:port,host2:port, which URLComponents can't read.
        var hostList: String?
        if let m = trimmed.range(of: #"^mongodb(\+srv)?://([^@/]*@)?([^/?]+,[^/?]+)"#, options: .regularExpression) {
            let authority = String(trimmed[m])
            if let hosts = authority.split(separator: "@").last.map(String.init)?.replacingOccurrences(of: #"^mongodb(\+srv)?://"#, with: "", options: .regularExpression) {
                hostList = hosts
                trimmed = trimmed.replacingOccurrences(of: hosts, with: "placeholder")
            }
        }
        guard let url = URLComponents(string: trimmed), let scheme = url.scheme?.lowercased(),
              let k = DatabaseKind.allCases.first(where: { $0.schemes.contains(scheme) }) else { return (false, nil) }
        if let p = url.port, !(1...65535).contains(p) { return (false, nil) }
        kind = k
        let query = Dictionary(url.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        if k.isFile {
            filePath = url.path.removingPercentEncoding ?? url.path
            tls = .off
            if name.isEmpty { name = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension }
            return (true, nil)
        }
        host = hostList ?? url.host?.removingPercentEncoding ?? "127.0.0.1"
        port = url.port ?? kind.defaultPort
        user = url.user?.removingPercentEncoding ?? ""
        database = String(url.path.drop(while: { $0 == "/" })).removingPercentEncoding ?? ""
        /// true/false for a yes-or-no parameter, nil when the URL doesn't have it.
        func flag(_ names: String...) -> Bool? {
            for n in names { if let v = query[n]?.lowercased() { return ["true", "1", "yes", "on", "require", "required"].contains(v) } }
            return nil
        }
        // What the URL says about TLS. A scheme or parameter that means "TLS" means it the way that engine's
        // own clients do, which is with the certificate checked, unless the URL itself says otherwise.
        var chosen: TLS?
        switch k {
        case .redis:
            chosen = scheme == "rediss" ? .verify : flag("ssl", "tls").map { $0 ? .verify : .off } ?? .off
        case .clickhouse:
            chosen = scheme == "clickhouses" || flag("secure") == true ? .verify : .off
            if chosen == .verify, url.port == nil { port = 8443 }
        case .mongodb:
            if scheme == "mongodb+srv" { options["srv"] = "1" }
            chosen = flag("tls", "ssl").map { $0 ? .verify : .off } ?? (scheme == "mongodb+srv" ? .verify : .off)
            if chosen == .verify, flag("tlsInsecure", "tlsAllowInvalidCertificates") == true { chosen = .require }
            for key in ["authSource", "replicaSet", "authMechanism"] { if let v = query[key] { options[key] = v } }
        case .snowflake:
            // snowflake://user@account/database/schema?warehouse=…&role=…
            let parts = database.split(separator: "/").map(String.init)
            database = parts.first ?? ""
            if parts.count > 1 { options["schema"] = parts[1] }
            for key in ["warehouse", "role"] { if let v = query[key] { options[key] = v } }
        case .bigquery:
            // bigquery://project/dataset
            if let v = query["endpoint"] { options["endpoint"] = v }
        case .libsql:
            // turso:// and libsql:// are Turso's schemes: HTTPS on 443, as its own clients use them. A sqld on
            // this Mac or a private network is plain HTTP on its own port.
            chosen = flag("tls", "ssl").map { $0 ? .verify : .off } ?? (HostScope.isLocal(host) ? nil : .verify)
            if chosen == .verify, url.port == nil { port = 443 }
        case .sqlserver:
            switch query["encrypt"]?.lowercased() {
            case "strict": options["strict"] = "1"; chosen = .verify
            case "true", "yes", "mandatory", "1": chosen = flag("trustServerCertificate") == true ? .require : .verify
            case "false", "no", "optional", "0": chosen = .off
            default: break
            }
        case .cassandra, .oracle:
            chosen = flag("ssl").map { $0 ? .verify : .off }
        default: break
        }
        if let mode = (query["sslmode"] ?? query["ssl-mode"])?.lowercased() {
            switch mode {
            case "disable", "disabled": chosen = .off
            case "prefer", "preferred", "allow": chosen = .prefer
            // As in libpq: encrypted, certificate not checked.
            case "require", "required": chosen = .require
            case "verify", "verify-ca", "verify-full", "verify_identity", "verify_ca": chosen = .verify
            default: break
            }
        }
        tls = chosen ?? Self.defaultTLS(kind: k, host: host)
        // libpq's names: sslrootcert is the CA file, sslcert here is a .p12 with the client key.
        if let v = query["sslrootcert"] { caFile = v }
        if let v = query["sslcert"] { clientCertFile = v }
        if name.isEmpty { name = database.isEmpty || k == .redis ? host : database }
        return (true, url.password?.removingPercentEncoding)
    }
}

/// Which hosts count as near: this Mac and private networks. A plain connection there is ordinary;
/// anywhere else it puts the password on the open internet.
public enum HostScope {
    /// The host out of a field that may hold a URL (libSQL, ClickHouse) or a bracketed IPv6 address.
    static func name(_ field: String) -> String {
        var h = field.trimmingCharacters(in: .whitespaces).lowercased()
        if h.contains("://"), let host = URLComponents(string: h)?.host { h = host }
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") { h = String(h[h.index(after: h.startIndex)..<close]) }
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }
        return h
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        var a = in_addr()
        guard inet_pton(AF_INET, host, &a) == 1 else { return nil }
        return withUnsafeBytes(of: a.s_addr) { Array($0) }
    }

    private static func ipv6(_ host: String) -> [UInt8]? {
        var a = in6_addr()
        guard inet_pton(AF_INET6, host, &a) == 1 else { return nil }
        return withUnsafeBytes(of: a) { Array($0) }
    }

    /// An IP address rather than a name.
    static func isAddress(_ host: String) -> Bool { ipv4(name(host)) != nil || ipv6(name(host)) != nil }

    private static func isLocal(v4 b: [UInt8]) -> Bool {
        b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }

    /// localhost, 127.0.0.0/8, ::1, a .local name, a private address (10/8, 172.16/12, 192.168/16, fc00::/7),
    /// a link-local address, or a Unix socket. A list of hosts (MongoDB) is local when every one is.
    public static func isLocal(_ field: String) -> Bool {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("/") { return true }
        if trimmed.contains(","), !trimmed.contains("://") {
            return trimmed.split(separator: ",").allSatisfy { part in
                // host:port, but not a bare IPv6 address.
                let p = String(part)
                let host = p.filter({ $0 == ":" }).count == 1 ? String(p[..<p.firstIndex(of: ":")!]) : p
                return isLocal(host)
            }
        }
        let h = name(trimmed)
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        if let b = ipv4(h) { return isLocal(v4: b) }
        if let b = ipv6(h) {
            if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }  // ::1
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }  // fe80::/10
            if b[0] & 0xFE == 0xFC { return true }  // fc00::/7
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isLocal(v4: Array(b[12...])) }  // ::ffff:a.b.c.d
        }
        return false
    }
}

/// When the app goes on without encryption, and when it sends a password the other end can read.
enum PlainText {
    /// TLS Prefer may fall back to a plain connection only to this Mac or a private network.
    static func mayFallBack(host: String, mode: ConnectionConfig.TLS) -> Bool { mode == .prefer && HostScope.isLocal(host) }

    static func noTLS(host: String, mode: ConnectionConfig.TLS) -> DatabaseError {
        if mode == .prefer {
            return DatabaseError("The server at \(host) doesn't offer TLS, so nothing was sent.",
                                 detail: "TLS Prefer only goes on without encryption on this Mac or a private network. If you really want a plain connection to this server, set TLS to Off.")
        }
        return DatabaseError("The server doesn't accept TLS connections.", detail: "If you really want a plain connection to this server, set TLS to Off.")
    }

    /// A password in a form the server (or anyone on the path) can read goes out only over TLS, to this Mac
    /// or a private network, or when you chose TLS Off yourself.
    static func maySendPassword(encrypted: Bool, host: String, mode: ConnectionConfig.TLS) -> Bool {
        encrypted || HostScope.isLocal(host) || mode == .off
    }

    static func passwordRefused(host: String) -> DatabaseError {
        DatabaseError("The server at \(host) asks for the password as plain text, and this connection isn't encrypted.",
                      detail: "Nothing was sent. Turn on TLS for this connection, or set TLS to Off if you really want to send it unencrypted.")
    }
}

public enum Connector {
    /// Opens a connection. SSH tunnels are set up by the caller and passed as host/port.
    public static func open(_ config: ConnectionConfig, password: String?, host: String? = nil, port: Int? = nil,
                            database: String? = nil, certificatePassword: String? = nil) throws -> Driver {
        guard config.isWellFormed else {
            throw DatabaseError("This connection's settings have characters that can't be used.",
                                detail: "A field holds a line break or another control character. Type the settings again in the connection's editor.")
        }
        let db = database ?? config.database
        var tls = config.kind.isFile ? TLSOptions(.off) : try TLSOptions.load(config, certificatePassword: certificatePassword)
        // Through a tunnel the connection goes to 127.0.0.1, but the certificate is still the server's.
        if let host, host != config.host, !config.host.contains(","), !config.host.hasPrefix("/") { tls.peerName = HostScope.name(config.host) }
        let h = host ?? config.host, p = port ?? config.port, pw = password ?? ""
        let toolPath = config.localToolPath.isEmpty ? nil : config.localToolPath
        switch config.kind {
        case .sqlite:
            return try SQLiteDriver(path: (config.filePath as NSString).expandingTildeInPath, readOnly: config.readOnly)
        case .postgres:
            return try PostgresDriver(host: h, port: p, user: config.user, password: pw,
                                      database: db.isEmpty ? (config.user.isEmpty ? "postgres" : config.user) : db, tls: tls,
                                      readOnly: config.readOnly)
        case .mysql:
            return try MySQLDriver(host: h, port: p, user: config.user, password: pw, database: db, tls: tls, readOnly: config.readOnly)
        case .redis:
            return try RedisDriver(host: h, port: p, user: config.user, password: pw, database: db, tls: tls)
        case .mongodb:
            return try MongoDriver(host: h, port: p, user: config.user, password: pw, database: db, tls: tls, options: config.options)
        case .clickhouse:
            return try ClickHouseDriver(host: h, port: p, user: config.user, password: pw, database: db, tls: tls)
        case .libsql:
            return try LibSQLDriver(host: h, port: p, token: pw, tls: tls)
        case .duckdb:
            return try DuckDBDriver(path: (config.filePath as NSString).expandingTildeInPath, readOnly: config.readOnly, toolPath: toolPath)
        case .oracle:
            return try OracleDriver(host: h, port: p, user: config.user, password: pw, service: db, toolPath: toolPath)
        case .sqlserver:
            return try SQLServerDriver(host: h, port: p, user: config.user, password: pw, database: db.isEmpty ? "master" : db, tls: tls,
                                       strict: config.options["strict"] == "1")
        case .cassandra:
            return try CassandraDriver(host: h, port: p, user: config.user, password: pw, keyspace: db, tls: tls)
        case .bigquery:
            return try BigQueryDriver(project: config.host, dataset: db, keyFile: config.filePath, endpoint: config.options["endpoint"])
        case .snowflake:
            return try SnowflakeDriver(account: config.host, user: config.user, token: pw, keyFile: config.filePath, database: db, options: config.options)
        case .d1:
            return try D1Driver(account: config.host, database: db, token: pw, endpoint: config.options["endpoint"])
        }
    }
}

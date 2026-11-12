import Foundation

/// A saved connection. The password lives in the Keychain, not here.
public struct ConnectionConfig: Codable, Hashable, Identifiable, Sendable {
    public enum TLS: String, Codable, CaseIterable, Sendable {
        /// Plain connection.
        case off
        /// TLS if the server offers it, without checking the certificate.
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
    /// replicaSet (MongoDB), tool (path to sqlplus or duckdb), srv (mongodb+srv).
    public var options: [String: String] = [:]

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

    /// Fills the fields from a URL like postgres://user:pass@host:5432/db?sslmode=require.
    /// Returns the password, if the URL has one.
    @discardableResult
    public mutating func apply(url string: String) -> (ok: Bool, password: String?) {
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
        kind = k
        let query = Dictionary(url.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        if k.isFile {
            if let tool = query["tool"] { options["tool"] = tool }
            filePath = url.path.removingPercentEncoding ?? url.path
            if name.isEmpty { name = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension }
            return (true, nil)
        }
        host = hostList ?? url.host?.removingPercentEncoding ?? "127.0.0.1"
        port = url.port ?? kind.defaultPort
        user = url.user?.removingPercentEncoding ?? ""
        database = String(url.path.drop(while: { $0 == "/" })).removingPercentEncoding ?? ""
        if let tool = query["tool"] { options["tool"] = tool }
        if k == .sqlserver, query["encrypt"]?.lowercased() == "strict" { options["strict"] = "1"; tls = .require }
        switch k {
        case .redis: if scheme == "rediss" { tls = .require } else if query["ssl"] == nil { tls = .off }
        case .clickhouse: if scheme == "clickhouses" || query["secure"] == "true" { tls = .require; if url.port == nil { port = 8443 } } else { tls = .off }
        case .mongodb:
            if scheme == "mongodb+srv" { options["srv"] = "1"; tls = .require }
            else if query["tls"] == nil && query["ssl"] == nil { tls = .off }
            if query["tls"] == "true" || query["ssl"] == "true" { tls = .require }
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
        case .cassandra, .libsql, .sqlserver, .oracle: if query["ssl"] == nil && query["encrypt"] == nil && query["sslmode"] == nil { tls = k == .libsql && scheme == "turso" ? .require : .off }
        default: break
        }
        if let mode = url.queryItems?.first(where: { $0.name == "sslmode" || $0.name == "ssl-mode" })?.value?.lowercased() {
            switch mode {
            case "disable", "disabled": tls = .off
            case "prefer", "preferred", "allow": tls = .prefer
            case "require", "required": tls = .require
            case "verify", "verify-ca", "verify-full", "verify_identity", "verify_ca": tls = .verify
            default: break
            }
        }
        // libpq's names: sslrootcert is the CA file, sslcert here is a .p12 with the client key.
        if let v = url.queryItems?.first(where: { $0.name == "sslrootcert" })?.value { caFile = v }
        if let v = url.queryItems?.first(where: { $0.name == "sslcert" })?.value { clientCertFile = v }
        if name.isEmpty { name = database.isEmpty || k == .redis ? host : database }
        return (true, url.password?.removingPercentEncoding)
    }
}

public enum Connector {
    /// Opens a connection. SSH tunnels are set up by the caller and passed as host/port.
    public static func open(_ config: ConnectionConfig, password: String?, host: String? = nil, port: Int? = nil,
                            database: String? = nil, certificatePassword: String? = nil) throws -> Driver {
        let db = database ?? config.database
        let tls = config.kind.isFile ? TLSOptions(.off) : try TLSOptions.load(config, certificatePassword: certificatePassword)
        let h = host ?? config.host, p = port ?? config.port, pw = password ?? ""
        switch config.kind {
        case .sqlite:
            return try SQLiteDriver(path: (config.filePath as NSString).expandingTildeInPath, readOnly: config.readOnly)
        case .postgres:
            return try PostgresDriver(host: h, port: p, user: config.user, password: pw,
                                      database: db.isEmpty ? (config.user.isEmpty ? "postgres" : config.user) : db, tls: tls)
        case .mysql:
            return try MySQLDriver(host: h, port: p, user: config.user, password: pw, database: db, tls: tls)
        case .redis:
            return try RedisDriver(host: h, port: p, user: config.user, password: pw, database: db, tls: tls)
        case .mongodb:
            return try MongoDriver(host: h, port: p, user: config.user, password: pw, database: db, tls: tls, options: config.options)
        case .clickhouse:
            return try ClickHouseDriver(host: h, port: p, user: config.user, password: pw, database: db, tls: tls)
        case .libsql:
            return try LibSQLDriver(host: h, port: p, token: pw, tls: tls)
        case .duckdb:
            return try DuckDBDriver(path: (config.filePath as NSString).expandingTildeInPath, readOnly: config.readOnly, toolPath: config.options["tool"])
        case .oracle:
            return try OracleDriver(host: h, port: p, user: config.user, password: pw, service: db, toolPath: config.options["tool"])
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

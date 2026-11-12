import Foundation

/// Server administration for Postgres and MySQL/MariaDB: running queries, users and permissions, and live numbers.
public enum Admin {
    public struct Process: Identifiable, Hashable, Sendable {
        public var id: String
        public var user: String
        public var database: String
        public var client: String
        public var state: String
        public var seconds: Double?
        public var query: String
    }

    public struct User: Identifiable, Hashable, Sendable {
        /// Postgres: the role name. MySQL: 'user'@'host'.
        public var id: String
        public var name: String
        public var host: String?
        public var canLogin: Bool
        public var superuser: Bool
        public var detail: String
    }

    public static func supported(_ kind: DatabaseKind) -> Bool { kind == .postgres || kind == .mysql }

    // MARK: Processes

    public static func processes(_ d: Driver) throws -> [Process] {
        switch d.kind {
        case .postgres:
            return try d.rows("""
                SELECT pid::text, coalesce(usename, ''), coalesce(datname, ''), coalesce(client_addr::text, 'local'),
                       coalesce(state, backend_type), extract(epoch FROM now() - query_start)::float8::text, left(coalesce(query, ''), 4000)
                FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'
                ORDER BY state = 'active' DESC, query_start NULLS LAST
                """).map { r in
                Process(id: r[0] ?? "", user: r[1] ?? "", database: r[2] ?? "", client: r[3] ?? "", state: r[4] ?? "",
                        seconds: r[5].flatMap { Double($0) }, query: r[6] ?? "")
            }
        case .mysql:
            return try d.rows("""
                SELECT ID, USER, HOST, coalesce(DB, ''), concat(COMMAND, if(STATE IS NULL OR STATE = '', '', concat(' · ', STATE))), TIME, coalesce(LEFT(INFO, 4000), '')
                FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() ORDER BY COMMAND = 'Sleep', TIME DESC
                """).map { r in
                Process(id: r[0] ?? "", user: r[1] ?? "", database: r[3] ?? "", client: r[2] ?? "", state: r[4] ?? "",
                        seconds: r[5].flatMap { Double($0) }, query: r[6] ?? "")
            }
        default:
            return []
        }
    }

    /// Stops the process's running query (the connection stays), or ends the connection.
    public static func stop(_ d: Driver, process id: String, endConnection: Bool) throws {
        guard let n = Int(id) else { throw DatabaseError("Not a process id: \(id)") }
        switch d.kind {
        case .postgres:
            let ok = try d.rows("SELECT \(endConnection ? "pg_terminate_backend" : "pg_cancel_backend")(\(n))").first?[0]
            if ok != "t" { throw DatabaseError("The server didn't stop process \(n).", detail: "It may have finished already, or you don't have the right to stop it.") }
        case .mysql:
            _ = try d.execute(endConnection ? "KILL \(n)" : "KILL QUERY \(n)")
        default:
            throw DatabaseError("Not available for \(d.kind.title).")
        }
    }

    // MARK: Users and permissions

    public static func users(_ d: Driver) throws -> [User] {
        switch d.kind {
        case .postgres:
            return try d.rows("""
                SELECT rolname, rolcanlogin, rolsuper,
                       concat_ws(', ', CASE WHEN rolcreatedb THEN 'create databases' END, CASE WHEN rolcreaterole THEN 'create roles' END,
                                 CASE WHEN rolreplication THEN 'replication' END, CASE WHEN rolvaliduntil IS NOT NULL THEN 'valid until ' || rolvaliduntil::date END)
                FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%' ESCAPE '\\' ORDER BY rolcanlogin DESC, rolname
                """).map { r in
                User(id: r[0] ?? "", name: r[0] ?? "", host: nil, canLogin: r[1] == "t", superuser: r[2] == "t", detail: r[3] ?? "")
            }
        case .mysql:
            return try d.rows("SELECT User, Host, Super_priv FROM mysql.user ORDER BY User, Host").map { r in
                let name = r[0] ?? "", host = r[1] ?? "%"
                return User(id: "'\(name)'@'\(host)'", name: name, host: host, canLogin: true, superuser: r[2] == "Y", detail: "")
            }
        default:
            return []
        }
    }

    /// What a user may do, one line per grant.
    public static func grants(_ d: Driver, user: User) throws -> [String] {
        switch d.kind {
        case .postgres:
            let u = d.dialect.literal(user.name)
            var lines = try d.rows("""
                SELECT table_schema || '.' || table_name || ': ' || string_agg(privilege_type, ', ' ORDER BY privilege_type)
                FROM information_schema.role_table_grants WHERE grantee = \(u) GROUP BY table_schema, table_name ORDER BY 1
                """).compactMap { $0[0] }
            lines += try d.rows("""
                SELECT 'member of ' || r.rolname FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid
                JOIN pg_roles u ON u.oid = m.member WHERE u.rolname = \(u)
                """).compactMap { $0[0] }
            return lines
        case .mysql:
            return try d.rows("SHOW GRANTS FOR \(user.id)").compactMap { $0[0] }
        default:
            return []
        }
    }

    public enum Privilege: String, CaseIterable, Sendable {
        case select = "SELECT", insert = "INSERT", update = "UPDATE", delete = "DELETE", all = "ALL PRIVILEGES"
    }

    /// The SQL to create a user who can sign in with a password.
    public static func createUser(_ kind: DatabaseKind, name: String, host: String, password: String, superuser: Bool) -> [String] {
        let d = Dialect(kind: kind)
        switch kind {
        case .postgres:
            return ["CREATE ROLE \(d.quote(name)) LOGIN PASSWORD \(d.literal(password))\(superuser ? " SUPERUSER" : "")"]
        default:
            let account = "\(d.literal(name))@\(d.literal(host.isEmpty ? "%" : host))"
            var out = ["CREATE USER \(account) IDENTIFIED BY \(d.literal(password))"]
            if superuser { out.append("GRANT ALL PRIVILEGES ON *.* TO \(account) WITH GRANT OPTION") }
            return out
        }
    }

    public static func setPassword(_ kind: DatabaseKind, user: User, password: String) -> String {
        let d = Dialect(kind: kind)
        return kind == .postgres ? "ALTER ROLE \(d.quote(user.name)) PASSWORD \(d.literal(password))"
                                 : "ALTER USER \(user.id) IDENTIFIED BY \(d.literal(password))"
    }

    /// Postgres won't drop a role that owns things or holds privileges, so whatever it owns in this database
    /// goes to you first and its privileges are removed; then the role goes. (Other databases need the same there.)
    public static func dropUser(_ kind: DatabaseKind, user: User) -> [String] {
        guard kind == .postgres else { return ["DROP USER \(user.id)"] }
        let name = Dialect(kind: kind).quote(user.name)
        return ["REASSIGN OWNED BY \(name) TO CURRENT_USER", "DROP OWNED BY \(name)", "DROP ROLE \(name)"]
    }

    /// GRANT or REVOKE on one table, or on every table of a schema (Postgres) or database (MySQL) when `table` is nil.
    public static func grant(_ kind: DatabaseKind, revoke: Bool, privileges: [Privilege], user: User, container: String, table: String?) -> String {
        let d = Dialect(kind: kind)
        let what = privileges.contains(.all) ? "ALL PRIVILEGES" : privileges.map(\.rawValue).joined(separator: ", ")
        let target: String
        if kind == .postgres {
            target = table.map { "TABLE \(d.quote(container)).\(d.quote($0))" } ?? "ALL TABLES IN SCHEMA \(d.quote(container))"
        } else {
            target = "\(d.quote(container)).\(table.map(d.quote) ?? "*")"
        }
        let who = kind == .postgres ? d.quote(user.name) : user.id
        return revoke ? "REVOKE \(what) ON \(target) FROM \(who)" : "GRANT \(what) ON \(target) TO \(who)"
    }

    // MARK: Metrics

    /// One reading of the server's counters. Rates come from the difference between two readings.
    public struct Reading: Sendable {
        public var date = Date()
        /// Gauges: shown as they are.
        public var gauges: [String: Double] = [:]
        /// Counters: always growing; shown as a rate per second.
        public var counters: [String: Double] = [:]
    }

    public static func read(_ d: Driver) throws -> Reading {
        var r = Reading()
        switch d.kind {
        case .postgres:
            if let row = try d.rows("""
                SELECT (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'),
                       (SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND backend_type = 'client backend'),
                       (SELECT setting::float8 FROM pg_settings WHERE name = 'max_connections'),
                       (SELECT count(*) FROM pg_locks WHERE NOT granted),
                       (SELECT coalesce(max(extract(epoch FROM now() - query_start)), 0) FROM pg_stat_activity WHERE state = 'active' AND backend_type = 'client backend'),
                       sum(xact_commit), sum(xact_rollback), sum(blks_hit), sum(blks_read), sum(tup_returned), sum(tup_inserted + tup_updated + tup_deleted),
                       pg_database_size(current_database())
                FROM pg_stat_database
                """).first {
                let v = row.map { $0.flatMap(Double.init) ?? 0 }
                r.gauges = ["connections": v[0], "active": v[1], "maxConnections": v[2], "waitingLocks": v[3], "longestQuery": v[4], "databaseSize": v[11]]
                r.counters = ["commits": v[5], "rollbacks": v[6], "cacheHits": v[7], "diskReads": v[8], "rowsRead": v[9], "rowsWritten": v[10]]
            }
        case .mysql:
            var status: [String: Double] = [:]
            for row in try d.rows("SHOW GLOBAL STATUS") { if let k = row[0], let v = row[1].flatMap(Double.init) { status[k] = v } }
            let maxConn = try d.rows("SELECT @@max_connections").first?[0].flatMap(Double.init) ?? 0
            r.gauges = ["connections": status["Threads_connected"] ?? 0, "active": status["Threads_running"] ?? 0, "maxConnections": maxConn,
                        "uptime": status["Uptime"] ?? 0]
            r.counters = ["queries": status["Questions"] ?? 0, "slowQueries": status["Slow_queries"] ?? 0,
                          "cacheHits": (status["Innodb_buffer_pool_read_requests"] ?? 0) - (status["Innodb_buffer_pool_reads"] ?? 0),
                          "diskReads": status["Innodb_buffer_pool_reads"] ?? 0, "bytesIn": status["Bytes_received"] ?? 0,
                          "bytesOut": status["Bytes_sent"] ?? 0, "rowsRead": status["Innodb_rows_read"] ?? 0,
                          "rowsWritten": (status["Innodb_rows_inserted"] ?? 0) + (status["Innodb_rows_updated"] ?? 0) + (status["Innodb_rows_deleted"] ?? 0)]
        default:
            break
        }
        return r
    }

    /// Per-second rates between two readings, plus the cache hit ratio over that time.
    public static func rates(from a: Reading, to b: Reading) -> [String: Double] {
        let dt = max(0.001, b.date.timeIntervalSince(a.date))
        var out: [String: Double] = [:]
        for (k, v) in b.counters { if let old = a.counters[k] { out[k] = max(0, v - old) / dt } }
        let hits = (b.counters["cacheHits"] ?? 0) - (a.counters["cacheHits"] ?? 0)
        let reads = (b.counters["diskReads"] ?? 0) - (a.counters["diskReads"] ?? 0)
        if hits + reads > 0 { out["cacheHitRatio"] = hits / (hits + reads) }
        if let c = out["commits"] { out["transactions"] = c + (out["rollbacks"] ?? 0) }
        return out
    }
}

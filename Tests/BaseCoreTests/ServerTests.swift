@testable import BaseCore
import XCTest

/// Round trips against real servers. Skipped unless a URL is set, e.g.
///   MB_TEST_POSTGRES=postgres://postgres:secret@127.0.0.1:55432/postgres?sslmode=disable
///   MB_TEST_MYSQL=mysql://root:secret@127.0.0.1:53306/shop
/// (see CONTRIBUTING.md for the Docker commands).
final class ServerTests: XCTestCase {
    func testPostgres() throws { try roundTrip(env: "MB_TEST_POSTGRES", ddl: """
        CREATE TABLE mb_rt (id serial PRIMARY KEY, name text NOT NULL, price numeric(10,2), meta jsonb, data bytea,
                            seen timestamptz, tags text[], flag boolean DEFAULT false)
        """) }

    func testMySQL() throws { try roundTrip(env: "MB_TEST_MYSQL", ddl: """
        CREATE TABLE mb_rt (id int AUTO_INCREMENT PRIMARY KEY, name varchar(100) NOT NULL, price decimal(10,2), meta json,
                            data varbinary(16), seen datetime, tags text, flag tinyint(1) DEFAULT 0)
        """) }

    private func roundTrip(env: String, ddl: String) throws {
        guard let url = ProcessInfo.processInfo.environment[env] else { throw XCTSkip("\(env) not set") }
        var config = ConnectionConfig()
        let parsed = config.apply(url: url)
        let db = try Connector.open(config, password: parsed.password)
        defer { db.close() }
        let d = db.dialect
        let table = TableRef(schema: db.kind == .postgres ? "public" : nil, name: "mb_rt")
        _ = try db.execute("DROP TABLE IF EXISTS \(d.qualified(table))")
        _ = try db.execute(ddl)
        defer { _ = try? db.execute("DROP TABLE IF EXISTS \(d.qualified(table))") }
        _ = try db.execute("INSERT INTO \(d.qualified(table)) (name, price) VALUES ('first', 1.50), ('second', NULL), ('third', 3)")

        XCTAssertEqual(try db.columns(of: table).filter(\.isPrimaryKey).map(\.name), ["id"])
        XCTAssertTrue(try db.objects(schema: table.schema).contains { $0.name == "mb_rt" && $0.kind == .table })

        let page = try db.execute(d.selectPage(table, filter: nil, order: [("id", true)], limit: 300, offset: 0))[0]
        XCTAssertEqual(page.rows.count, 3)
        let col = { (name: String) in page.columns.firstIndex { $0.name == name }! }

        // Edit like the app does: stage, build SQL, run in one transaction.
        let tricky = "Ünïcödé 'quotes' \\ back\\slash 😀"
        let hex = db.kind == .postgres ? "\\xcafe00" : "0xCAFE00"
        var changes = ChangeSet()
        changes.set(row: 0, column: col("name"), value: tricky, original: page.rows[0])
        changes.set(row: 0, column: col("meta"), value: "{\"a\": [1, 2]}", original: page.rows[0])
        changes.set(row: 0, column: col("data"), value: hex, original: page.rows[0])
        changes.set(row: 0, column: col("seen"), value: "2026-11-12 10:30:00", original: page.rows[0])
        changes.set(row: 0, column: col("price"), value: nil, original: page.rows[0])
        changes.set(row: 1, column: col("price"), value: "9.99", original: page.rows[1])
        // Saving a value unchanged must still count as found (MySQL reports changed rows otherwise).
        changes.set(row: 1, column: col("name"), value: "second", original: ["x"] + page.rows[1].dropFirst())
        changes.delete(row: 2, original: page.rows[2])
        changes.inserts.append(.init(values: [col("name"): "fourth", col("flag"): db.kind == .postgres ? "true" : "1"]))
        let statements = try d.statements(for: changes, table: table, columns: page.columns, primaryKey: ["id"])
        _ = try db.execute(d.begin)
        for s in statements {
            let r = try db.execute(s)
            if !s.hasPrefix("INSERT") { XCTAssertEqual(r.last?.affectedRows, 1, s) }
        }
        _ = try db.execute("COMMIT")

        let after = try db.execute(d.selectPage(table, filter: nil, order: [("id", true)], limit: 300, offset: 0))[0]
        XCTAssertEqual(after.rows.count, 3)
        XCTAssertEqual(after.rows[0][col("name")], tricky)
        XCTAssertNil(after.rows[0][col("price")])
        XCTAssertEqual(after.rows[0][col("data")]?.lowercased(), hex.lowercased())
        XCTAssertTrue(after.rows[0][col("meta")]?.contains("[1, 2]") == true, after.rows[0][col("meta")] ?? "nil")
        XCTAssertTrue(after.rows[0][col("seen")]?.hasPrefix("2026-11-12") == true)
        XCTAssertEqual(after.rows[1][col("price")], "9.99")
        XCTAssertEqual(after.rows[2][col("name")], "fourth")

        // Filters run on the server.
        let filtered = try db.execute(d.selectPage(table, filter: d.whereClause([Filter(column: "name", op: .contains, value: "QUOTES")]),
                                                   order: [], limit: 10, offset: 0))[0]
        XCTAssertEqual(filtered.rows.count, 1)

        // A failed transaction leaves nothing behind.
        _ = try db.execute(d.begin)
        _ = try db.execute("UPDATE \(d.qualified(table)) SET name = 'gone'")
        XCTAssertThrowsError(try db.execute("SELECT nope FROM \(d.qualified(table))"))
        _ = try? db.execute("ROLLBACK")
        XCTAssertEqual(try db.rows("SELECT COUNT(*) FROM \(d.qualified(table)) WHERE name = 'gone'").first?[0], "0")

        // The connection stays usable after an error, and cancel stops a long statement.
        let sleep = db.kind == .postgres ? "SELECT pg_sleep(10)" : "SELECT SLEEP(10)"
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { db.cancel() }
        _ = try? db.execute(sleep)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(try db.rows("SELECT 1").first?[0], "1")

        // Switching database (Postgres reconnects) keeps the connection working.
        let current = db.currentDatabase!
        XCTAssertTrue(try db.databases().contains(current))
        try db.use(database: current)
        XCTAssertEqual(db.currentDatabase, current)
        XCTAssertEqual(try db.rows("SELECT 2").first?[0], "2")
        XCTAssertThrowsError(try db.use(database: "mb_does_not_exist"))
        XCTAssertEqual(try db.rows("SELECT 3").first?[0], "3")
    }

    func testPostgresStructure() throws { try structure(env: "MB_TEST_POSTGRES") }
    func testMySQLStructure() throws { try structure(env: "MB_TEST_MYSQL") }

    /// Create two tables from designs, change them, and read everything back.
    private func structure(env: String) throws {
        guard let url = ProcessInfo.processInfo.environment[env] else { throw XCTSkip("\(env) not set") }
        var config = ConnectionConfig()
        let parsed = config.apply(url: url)
        let db = try Connector.open(config, password: parsed.password)
        defer { db.close() }
        let d = db.dialect
        let schema = db.kind == .postgres ? "public" : nil
        let teams = TableRef(schema: schema, name: "mb_teams"), people = TableRef(schema: schema, name: "mb_people")
        func run(_ statements: [String]) throws {
            if db.kind == .postgres { _ = try db.execute(([d.begin] + statements + ["COMMIT"]).joined(separator: ";\n")) }
            else { for s in statements { _ = try db.execute(s) } }
        }
        for t in [people, teams] { _ = try db.execute("DROP TABLE IF EXISTS \(d.qualified(t))") }
        defer { for t in [people, teams] { _ = try? db.execute("DROP TABLE IF EXISTS \(d.qualified(t))") } }
        if db.kind == .postgres { _ = try db.execute("DROP TYPE IF EXISTS mb_mood; CREATE TYPE mb_mood AS ENUM ('happy', 'sad')") }

        var t = TableDesign.new(table: teams, kind: db.kind)
        t.columns.append(.init(name: "name", type: "varchar(50)", nullable: false))
        try run(try d.designStatements(original: nil, draft: t))

        var p = TableDesign.new(table: people, kind: db.kind)
        p.columns.append(.init(name: "name", type: "varchar(80)", nullable: false, defaultValue: "'nobody'", comment: "Full name"))
        p.columns.append(.init(name: "team_id", type: "bigint"))
        p.columns.append(.init(name: "mood", type: db.kind == .postgres ? "mb_mood" : "enum('happy','sad')"))
        p.indexes.append(.init(name: "mb_people_name", columns: ["name"]))
        p.foreignKeys.append(.init(name: "mb_people_team", columns: ["team_id"], refTable: "mb_teams", refSchema: schema, refColumns: ["id"], onDelete: "CASCADE"))
        try run(try d.designStatements(original: nil, draft: p))
        _ = try db.execute("INSERT INTO \(d.qualified(teams)) (name) VALUES ('Core')")
        _ = try db.execute("INSERT INTO \(d.qualified(people)) (name, team_id, mood) VALUES ('Anne', 1, 'happy')")
        _ = try db.execute("INSERT INTO \(d.qualified(people)) (team_id) VALUES (1)")

        // Read it back as the app does.
        func load() throws -> TableDesign {
            TableDesign(table: people, kind: db.kind, columns: try db.columns(of: people), indexes: try db.indexes(of: people),
                        foreignKeys: try db.foreignKeys(of: people))
        }
        let original = try load()
        XCTAssertEqual(original.primaryKey, ["id"])
        XCTAssertEqual(original.foreignKeys.first?.refTable, "mb_teams")
        XCTAssertEqual(original.foreignKeys.first?.onDelete, "CASCADE")
        XCTAssertEqual(try db.columns(of: people).first { $0.name == "mood" }?.enumValues, ["happy", "sad"])
        XCTAssertEqual(original.columns.first { $0.name == "name" }?.comment, "Full name")
        XCTAssertEqual(try d.designStatements(original: original, draft: original), [], "reading back gives the same design")
        XCTAssertEqual(try db.rows("SELECT name FROM \(d.qualified(people)) WHERE id = 2").first?[0], "nobody")

        // Change it: rename, retype, default, unique index, drop the foreign key, add a column.
        var draft = original
        let nameID = draft.columns.first { $0.name == "name" }!.id
        draft.renameColumn(nameID, to: "full_name")
        if let i = draft.columns.firstIndex(where: { $0.name == "full_name" }) {
            draft.columns[i].type = "varchar(200)"
            draft.columns[i].defaultValue = ""
        }
        // (MySQL also lists the index it made for the foreign key.)
        draft.indexes[draft.indexes.firstIndex { $0.name == "mb_people_name" }!].unique = true
        draft.foreignKeys = []
        draft.columns.append(.init(name: "joined", type: db.kind == .postgres ? "timestamptz" : "datetime", defaultValue: "CURRENT_TIMESTAMP"))
        try run(try d.designStatements(original: original, draft: draft))

        let after = try load()
        XCTAssertEqual(after.columns.map(\.name), ["id", "full_name", "team_id", "mood", "joined"])
        XCTAssertEqual(after.columns[1].type.lowercased().replacingOccurrences(of: "character varying", with: "varchar"), "varchar(200)")
        XCTAssertEqual(after.columns[1].defaultValue, "")
        XCTAssertTrue(after.indexes.contains { $0.name == "mb_people_name" && $0.unique && $0.columns == ["full_name"] })
        XCTAssertTrue(after.foreignKeys.isEmpty)
        XCTAssertEqual(try db.rows("SELECT full_name FROM \(d.qualified(people)) WHERE id = 1").first?[0], "Anne")
        XCTAssertNotNil(try db.rows("SELECT joined FROM \(d.qualified(people)) WHERE id = 1").first?[0] ?? nil)
        XCTAssertEqual(try d.designStatements(original: after, draft: after), [])

        // Estimates come from statistics; after ANALYZE they're close.
        _ = try db.execute(db.kind == .postgres ? "ANALYZE \(d.qualified(people))" : "ANALYZE TABLE \(d.qualified(people))")
        XCTAssertNotNil(try db.estimatedCount(of: people))

        // The engine's own dump tool, when it's installed.
        let maria = db.serverVersion.localizedCaseInsensitiveContains("mariadb")
        if db.kind == .mysql, BackupTool.find(maria ? "mariadb-dump" : "mysqldump") != nil {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID()).sql").path
            defer { try? FileManager.default.removeItem(atPath: file) }
            let cmd = try BackupTool.backup(kind: .mysql, host: config.host, port: config.port, user: config.user, password: parsed.password ?? "",
                                            database: config.database, tls: .off, file: file, plainSQL: true, serverVersion: db.serverVersion)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd.executable)
            p.arguments = cmd.arguments
            p.environment = cmd.environment
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            XCTAssertTrue(try String(contentsOfFile: file, encoding: .utf8).contains("mb_people"))
        }
    }

    func testPostgresAdmin() throws { try admin(env: "MB_TEST_POSTGRES") }
    func testMySQLAdmin() throws { try admin(env: "MB_TEST_MYSQL") }

    private func admin(env: String) throws {
        guard let url = ProcessInfo.processInfo.environment[env] else { throw XCTSkip("\(env) not set") }
        var config = ConnectionConfig()
        let parsed = config.apply(url: url)
        let db = try Connector.open(config, password: parsed.password)
        let other = try Connector.open(config, password: parsed.password)
        defer { db.close(); other.close() }

        // A long query on another connection shows up, and stopping it ends that query only.
        let sleep = db.kind == .postgres ? "SELECT pg_sleep(30)" : "SELECT SLEEP(30)"
        let done = expectation(description: "sleep stopped")
        DispatchQueue.global().async { _ = try? other.execute(sleep); done.fulfill() }
        var found: Admin.Process?
        for _ in 0..<50 where found == nil {
            usleep(100_000)
            found = try Admin.processes(db).first { $0.query.lowercased().contains("sleep(") }
        }
        let process = try XCTUnwrap(found, "the sleeping query is listed")
        XCTAssertGreaterThanOrEqual(process.seconds ?? -1, 0)
        try Admin.stop(db, process: process.id, endConnection: false)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try other.rows("SELECT 7").first?[0], "7", "the connection survives a stopped query")

        // Users: create, grant, read the grants back, change the password, drop.
        let d = db.dialect
        let container = db.kind == .postgres ? "public" : (db.currentDatabase ?? "shop")
        _ = try? db.execute("DROP TABLE IF EXISTS \(d.qualified(TableRef(schema: db.kind == .postgres ? "public" : nil, name: "mb_admin_t")))")
        _ = try db.execute("CREATE TABLE \(d.qualified(TableRef(schema: db.kind == .postgres ? "public" : nil, name: "mb_admin_t"))) (id int primary key)")
        defer { _ = try? db.execute("DROP TABLE IF EXISTS \(d.qualified(TableRef(schema: db.kind == .postgres ? "public" : nil, name: "mb_admin_t")))") }
        if let old = try Admin.users(db).first(where: { $0.name == "mb_test_user" }) { for s in Admin.dropUser(db.kind, user: old) { _ = try? db.execute(s) } }
        for s in Admin.createUser(db.kind, name: "mb_test_user", host: "%", password: "pw 'one'", superuser: false) { _ = try db.execute(s) }
        let user = try XCTUnwrap(try Admin.users(db).first { $0.name == "mb_test_user" })
        XCTAssertTrue(user.canLogin)
        XCTAssertFalse(user.superuser)
        _ = try db.execute(Admin.grant(db.kind, revoke: false, privileges: [.select, .insert], user: user, container: container, table: "mb_admin_t"))
        let grants = try Admin.grants(db, user: user).joined(separator: "\n")
        XCTAssertTrue(grants.contains("SELECT") && grants.contains("INSERT") && grants.contains("mb_admin_t"), grants)
        _ = try db.execute(Admin.grant(db.kind, revoke: true, privileges: [.insert], user: user, container: container, table: "mb_admin_t"))
        XCTAssertFalse(try Admin.grants(db, user: user).joined().contains("INSERT"))
        _ = try db.execute(Admin.setPassword(db.kind, user: user, password: "two"))
        for s in Admin.dropUser(db.kind, user: user) { _ = try db.execute(s) }
        XCTAssertNil(try Admin.users(db).first { $0.name == "mb_test_user" })

        // Metrics: two readings give rates.
        let a = try Admin.read(db)
        _ = try db.execute("SELECT 1")
        usleep(200_000)
        let b = try Admin.read(db)
        XCTAssertGreaterThan(b.gauges["connections"] ?? 0, 0)
        XCTAssertGreaterThan(b.gauges["maxConnections"] ?? 0, 0)
        let rates = Admin.rates(from: a, to: b)
        XCTAssertNotNil(rates[db.kind == .postgres ? "transactions" : "queries"])
    }
}

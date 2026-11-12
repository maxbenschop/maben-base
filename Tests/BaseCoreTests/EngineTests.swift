@testable import BaseCore
import XCTest

/// Engines beyond Postgres/MySQL/SQLite, against real servers. Each is skipped unless its URL is set:
///   MB_TEST_REDIS=redis://:pw@127.0.0.1:56379/0      MB_TEST_MONGO=mongodb://root:pw@127.0.0.1:57017/shop?authSource=admin
/// and so on (see CONTRIBUTING.md).
final class EngineTests: XCTestCase {
    private func connect(_ env: String) throws -> Driver {
        guard let url = ProcessInfo.processInfo.environment[env] else { throw XCTSkip("\(env) not set") }
        var config = ConnectionConfig()
        let parsed = config.apply(url: url)
        return try Connector.open(config, password: parsed.password)
    }

    /// Browse, filter, edit, add and delete through the same text the app writes.
    private func page(_ db: Driver, _ table: TableRef, filters: [Filter] = [], order: [(String, Bool)] = []) throws -> QueryResult {
        let d = db.dialect
        // As the app does: filters know the column types.
        var types: [String: String] = [:]
        if !filters.isEmpty, db.kind != .redis { for c in try db.columns(of: table) { types[c.name] = c.type } }
        return try db.execute(d.selectPage(table, filter: d.whereClause(filters, types: types), order: order.map { ($0.0, $0.1) }, limit: 300, offset: 0))
            .first(where: \.hasRows) ?? QueryResult()
    }

    private func save(_ db: Driver, _ changes: ChangeSet, _ table: TableRef, _ result: QueryResult, key: [String]) throws {
        for s in try db.dialect.statements(for: changes, table: table, columns: result.columns, primaryKey: key) { _ = try db.execute(s) }
    }

    func testRedis() throws {
        let db = try connect("MB_TEST_REDIS")
        defer { db.close() }
        _ = try db.execute("FLUSHDB\nSET mb:a \"one\"\nHSET mb:h f1 v1\nRPUSH mb:l x y\nSET other 1")
        let keys = TableRef(schema: nil, name: "keys")
        var r = try page(db, keys, filters: [Filter(column: "key", op: .startsWith, value: "mb:")])
        XCTAssertEqual(r.rows.map { $0[0] }, ["mb:a", "mb:h", "mb:l"])
        XCTAssertEqual(try db.execute(db.dialect.count(keys, filter: db.dialect.whereClause([Filter(column: "type", op: .equals, value: "hash")])))[0].rows[0][0], "1")

        var changes = ChangeSet()
        changes.set(row: 0, column: 3, value: "uno \"quoted\"", original: r.rows[0])
        changes.set(row: 0, column: 2, value: "600", original: r.rows[0])
        changes.set(row: 1, column: 3, value: #"{"f1":"v2","f2":"new"}"#, original: r.rows[1])
        changes.set(row: 2, column: 0, value: "mb:list", original: r.rows[2])
        changes.inserts.append(.init(values: [0: "mb:new", 1: "set", 3: #"["p","q"]"#]))
        try save(db, changes, keys, r, key: ["key"])

        r = try page(db, keys, filters: [Filter(column: "key", op: .startsWith, value: "mb:")])
        let byKey = Dictionary(uniqueKeysWithValues: r.rows.map { ($0[0]!, $0) })
        XCTAssertEqual(byKey["mb:a"]?[3], "uno \"quoted\"")
        XCTAssertEqual(Int(byKey["mb:a"]?[2] ?? "") ?? 0, 600, accuracy: 2)
        XCTAssertEqual(byKey["mb:h"]?[3], #"{"f1":"v2","f2":"new"}"#)
        XCTAssertNotNil(byKey["mb:list"])
        XCTAssertNil(byKey["mb:l"])
        XCTAssertEqual(byKey["mb:new"]?[1], "set")

        var del = ChangeSet()
        del.delete(row: 0, original: r.rows[0])
        try save(db, del, keys, r, key: ["key"])
        XCTAssertEqual(try page(db, keys, filters: [Filter(column: "key", op: .equals, value: "mb:a")]).rows.count, 0)
        XCTAssertThrowsError(try db.execute("NOTACOMMAND"))
    }

    func testMongo() throws {
        let db = try connect("MB_TEST_MONGO")
        defer { db.close() }
        _ = try db.execute("""
            db.mb_people.drop()
            db.mb_people.insertMany([{ _id: 1, name: "Anne", age: 30, tags: ["a"] }, { _id: 2, name: "Bob", age: 25 }, { _id: 3, name: "Cy's", city: "Leiden" }])
            """)
        let t = TableRef(schema: nil, name: "mb_people")
        XCTAssertEqual(try db.columns(of: t).first?.name, "_id")
        var r = try page(db, t, order: [("_id", true)])
        XCTAssertEqual(r.rows.count, 3)
        XCTAssertEqual(r.columns.map(\.name), ["_id", "name", "age", "tags", "city"])
        XCTAssertEqual(try page(db, t, filters: [Filter(column: "name", op: .contains, value: "an")]).rows.map { $0[1] }, ["Anne"])
        XCTAssertEqual(try page(db, t, filters: [Filter(column: "age", op: .greater, value: "26")]).rows.count, 1)
        XCTAssertEqual(try db.execute(db.dialect.count(t, filter: nil))[0].rows[0][0], "3")

        var changes = ChangeSet()
        changes.set(row: 0, column: 1, value: "Anne-Marie", original: r.rows[0])
        changes.set(row: 0, column: 2, value: "31", original: r.rows[0])
        changes.set(row: 1, column: 3, value: #"["x", "y"]"#, original: r.rows[1])
        changes.set(row: 2, column: 1, value: "42", original: r.rows[2])  // a string column keeps "42" as text
        changes.delete(row: 1, original: r.rows[1])
        changes.inserts.append(.init(values: [1: "Dee", 4: "Gouda"]))
        try save(db, changes, t, r, key: ["_id"])

        r = try page(db, t, order: [("name", true)])
        XCTAssertEqual(r.rows.count, 3)
        let names = r.rows.map { $0[r.columns.firstIndex { $0.name == "name" }!] }
        XCTAssertEqual(names, ["42", "Anne-Marie", "Dee"])
        let typed = try db.execute("db.mb_people.find({ name: \"42\" })")[0]
        XCTAssertEqual(typed.rows.count, 1, "42 was saved as a string")
        XCTAssertEqual(try db.execute("db.mb_people.find({ age: 31 })")[0].rows.count, 1, "31 was saved as a number")
        _ = try db.execute("db.mb_people.drop()")
    }

    /// A SQL engine: create a table, browse, filter, edit through the app's statements, read back.
    private func sqlRoundTrip(_ env: String, create: String, table: TableRef, drop: String) throws {
        let db = try connect(env)
        defer { _ = try? db.execute(drop); db.close() }
        _ = try? db.execute(drop)
        for s in SQLText.statements(in: create).map(\.sql) { _ = try db.execute(s) }
        var r = try page(db, table, order: [("id", true)])
        XCTAssertEqual(r.rows.count, 3, "created rows are listed")
        XCTAssertEqual(try page(db, table, filters: [Filter(column: "name", op: .contains, value: "NN")]).rows.count, 1)
        XCTAssertEqual(try page(db, table, filters: [Filter(column: "id", op: .greater, value: "1")]).rows.count, 2)
        let nameCol = r.columns.firstIndex { $0.name == "name" }!
        var changes = ChangeSet()
        changes.set(row: 0, column: nameCol, value: "Ann 'quoted' \\ ü", original: r.rows[0])
        changes.delete(row: 2, original: r.rows[2])
        changes.inserts.append(.init(values: [r.columns.firstIndex { $0.name == "id" }!: "9", nameCol: "Nine"]))
        let statements = try db.dialect.statements(for: changes, table: table, columns: r.columns, primaryKey: ["id"])
        switch db.dialect.transactions {
        case .statements(let begin):
            _ = try db.execute(begin)
            for s in statements { _ = try db.execute(s) }
            _ = try db.execute("COMMIT")
        default:
            for s in statements { _ = try db.execute(s) }
        }
        r = try page(db, table, order: [("id", true)])
        XCTAssertEqual(r.rows.map { $0[nameCol] }, ["Ann 'quoted' \\ ü", "Bob", "Nine"])
        XCTAssertEqual(try db.execute(db.dialect.count(table, filter: nil))[0].rows[0][0], "3")
        XCTAssertFalse(try db.columns(of: table).isEmpty)
        XCTAssertTrue(try db.objects(schema: table.schema).contains { $0.name == table.name })
    }

    func testClickHouse() throws {
        try sqlRoundTrip("MB_TEST_CLICKHOUSE", create: """
            CREATE TABLE mb_rt (id UInt64, name String, amount Decimal(10,2)) ENGINE = MergeTree ORDER BY id;
            INSERT INTO mb_rt VALUES (1, 'Anne', 1.5), (2, 'Bob', 2), (3, 'Cy', 3)
            """, table: TableRef(schema: nil, name: "mb_rt"), drop: "DROP TABLE IF EXISTS mb_rt")
    }

    func testLibSQL() throws {
        try sqlRoundTrip("MB_TEST_LIBSQL", create: """
            CREATE TABLE mb_rt (id INTEGER PRIMARY KEY, name TEXT, amount REAL);
            INSERT INTO mb_rt VALUES (1, 'Anne', 1.5), (2, 'Bob', 2), (3, 'Cy', 3)
            """, table: TableRef(schema: nil, name: "mb_rt"), drop: "DROP TABLE IF EXISTS mb_rt")
    }

    func testDuckDB() throws {
        try sqlRoundTrip("MB_TEST_DUCKDB", create: """
            CREATE TABLE mb_rt (id INTEGER PRIMARY KEY, name VARCHAR, amount DECIMAL(10,2));
            INSERT INTO mb_rt VALUES (1, 'Anne', 1.5), (2, 'Bob', 2), (3, 'Cy', 3)
            """, table: TableRef(schema: "main", name: "mb_rt"), drop: "DROP TABLE IF EXISTS mb_rt")
    }

    func testOracle() throws {
        try sqlRoundTrip("MB_TEST_ORACLE", create: """
            CREATE TABLE "mb_rt" ("id" NUMBER(10) PRIMARY KEY, "name" VARCHAR2(100), "amount" NUMBER(10,2));
            INSERT INTO "mb_rt" VALUES (1, 'Anne', 1.5);
            INSERT INTO "mb_rt" VALUES (2, 'Bob', 2);
            INSERT INTO "mb_rt" VALUES (3, 'Cy', 3);
            COMMIT
            """, table: TableRef(schema: nil, name: "mb_rt"), drop: "DROP TABLE \"mb_rt\" PURGE")
    }

    func testSQLServer() throws {
        try sqlRoundTrip("MB_TEST_SQLSERVER", create: """
            CREATE TABLE dbo.mb_rt (id int PRIMARY KEY, name nvarchar(100), amount decimal(10,2));
            INSERT INTO dbo.mb_rt VALUES (1, N'Anne', 1.5), (2, N'Bob', 2), (3, N'Cy', 3)
            """, table: TableRef(schema: "dbo", name: "mb_rt"), drop: "DROP TABLE IF EXISTS dbo.mb_rt")
    }

    func testCassandra() throws {
        let db = try connect("MB_TEST_CASSANDRA")
        defer { _ = try? db.execute("DROP TABLE IF EXISTS mb_rt"); db.close() }
        _ = try db.execute("DROP TABLE IF EXISTS mb_rt; CREATE TABLE mb_rt (id int PRIMARY KEY, name text, tags list<text>)")
        for i in 1...12 { _ = try db.execute("INSERT INTO mb_rt (id, name, tags) VALUES (\(i), 'n\(i)', ['a'])") }
        let t = TableRef(schema: nil, name: "mb_rt")
        let d = db.dialect
        // Paging without OFFSET: page two of five rows.
        let all = try db.execute(d.selectPage(t, filter: nil, order: [], limit: 300, offset: 0))[0]
        let second = try db.execute(d.selectPage(t, filter: nil, order: [], limit: 5, offset: 5))[0]
        XCTAssertEqual(second.rows.map { $0[0] }, all.rows[5..<10].map { $0[0] })
        XCTAssertEqual(try db.execute(d.count(t, filter: nil))[0].rows[0][0], "12")
        let one = try db.execute(d.selectPage(t, filter: d.whereClause([Filter(column: "id", op: .equals, value: "3")], types: ["id": "int"]),
                                              order: [], limit: 300, offset: 0))[0]
        XCTAssertEqual(one.rows.count, 1)
        var changes = ChangeSet()
        changes.set(row: 0, column: 1, value: "Third 'one'", original: one.rows[0])
        changes.set(row: 0, column: 2, value: "['x', 'y']", original: one.rows[0])
        changes.inserts.append(.init(values: [0: "99", 1: "New"]))
        for s in try d.statements(for: changes, table: t, columns: one.columns, primaryKey: ["id"]) { _ = try db.execute(s) }
        var del = ChangeSet()
        del.delete(row: 0, original: all.rows[0])
        for s in try d.statements(for: del, table: t, columns: all.columns, primaryKey: ["id"]) { _ = try db.execute(s) }
        XCTAssertEqual(try db.rows("SELECT name, tags FROM mb_rt WHERE id = 3").first, ["Third 'one'", "['x', 'y']"])
        XCTAssertEqual(try db.rows("SELECT name FROM mb_rt WHERE id = 99").first?[0], "New")
        XCTAssertEqual(try db.execute(d.count(t, filter: nil))[0].rows[0][0], "12")
    }

    func testBigQuery() throws {
        try sqlRoundTrip("MB_TEST_BIGQUERY", create: """
            CREATE TABLE mb_rt (id INT64, name STRING, amount NUMERIC);
            INSERT INTO mb_rt (id, name, amount) VALUES (1, 'Anne', 1.5), (2, 'Bob', 2), (3, 'Cy', 3)
            """, table: TableRef(schema: nil, name: "mb_rt"), drop: "DROP TABLE IF EXISTS mb_rt")
    }
}

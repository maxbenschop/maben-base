@testable import BaseCore
import XCTest

final class SQLTextTests: XCTestCase {
    func testSplitsOnSemicolonsOutsideQuotesAndComments() {
        let sql = """
            select 'a;b' as x; -- comment; here
            select "c;d" from t /* ; */;
            create function f() returns int as $$ begin return 1; end $$ language plpgsql;
            select `e;f`
            """
        let parts = SQLText.statements(in: sql).map(\.sql)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "select 'a;b' as x")
        XCTAssertTrue(parts[1].hasPrefix("-- comment; here\nselect \"c;d\""))
        XCTAssertTrue(parts[2].contains("return 1; end $$"))
        XCTAssertEqual(parts[3], "select `e;f`")
    }

    func testDropsEmptyAndCommentOnlyStatements() {
        XCTAssertEqual(SQLText.statements(in: ";; -- nothing\n; select 1;").map(\.sql), ["select 1"])
    }

    func testStatementAtCursor() {
        let sql = "select 1;\nselect 2;\nselect 3"
        XCTAssertEqual(SQLText.statement(at: 12, in: sql)?.sql, "select 2")
        XCTAssertEqual(SQLText.statement(at: 0, in: sql)?.sql, "select 1")
        XCTAssertEqual(SQLText.statement(at: (sql as NSString).length, in: sql)?.sql, "select 3")
    }

    func testDetectsWrites() {
        XCTAssertTrue(SQLText.isWrite("update t set a = 1"))
        XCTAssertTrue(SQLText.isWrite("select 1; DROP TABLE x"))
        XCTAssertTrue(SQLText.isWrite("-- hi\n  delete from t"))
        XCTAssertTrue(SQLText.isWrite("with x as (select 1) delete from t using x"))
        XCTAssertFalse(SQLText.isWrite("select * from updates"))
        XCTAssertFalse(SQLText.isWrite("explain select 1"))
    }
}

final class DialectTests: XCTestCase {
    let pg = Dialect(kind: .postgres)
    let my = Dialect(kind: .mysql)

    func testQuotingAndLiterals() {
        XCTAssertEqual(pg.quote("we\"ird"), "\"we\"\"ird\"")
        XCTAssertEqual(my.quote("we`ird"), "`we``ird`")
        XCTAssertEqual(pg.literal("it's \\ fine"), "'it''s \\ fine'")
        XCTAssertEqual(my.literal("it's \\ fine"), "'it''s \\\\ fine'")
        XCTAssertEqual(pg.literal(nil), "NULL")
        XCTAssertEqual(pg.literal("\\xdeadbeef", binary: true), "'\\xdeadbeef'")
        XCTAssertEqual(my.literal("0xDEADBEEF", binary: true), "X'DEADBEEF'")
        XCTAssertEqual(my.literal("not hex", binary: true), "'not hex'")
        XCTAssertEqual(pg.qualified(TableRef(schema: "public", name: "users")), "\"public\".\"users\"")
    }

    func testChangeSetStatements() throws {
        let columns = [ResultColumn(name: "id", typeName: "int4"), ResultColumn(name: "name", typeName: "text")]
        var changes = ChangeSet()
        changes.set(row: 0, column: 1, value: "Ann", original: ["1", "Anne"])
        changes.set(row: 1, column: 1, value: nil, original: ["2", "Bob"])
        changes.delete(row: 2, original: ["3", "Cy"])
        changes.inserts.append(.init(values: [1: "Dee"]))
        changes.inserts.append(.init())
        let sql = try pg.statements(for: changes, table: TableRef(schema: "public", name: "people"), columns: columns, primaryKey: ["id"])
        XCTAssertEqual(sql, [
            "DELETE FROM \"public\".\"people\" WHERE \"id\" = '3'",
            "UPDATE \"public\".\"people\" SET \"name\" = 'Ann' WHERE \"id\" = '1'",
            "UPDATE \"public\".\"people\" SET \"name\" = NULL WHERE \"id\" = '2'",
            "INSERT INTO \"public\".\"people\" (\"name\") VALUES ('Dee')",
            "INSERT INTO \"public\".\"people\" DEFAULT VALUES",
        ])
    }

    func testEditingBackToOriginalClearsTheChange() {
        var changes = ChangeSet()
        changes.set(row: 0, column: 1, value: "x", original: ["1", "a"])
        changes.set(row: 0, column: 1, value: "a", original: ["1", "a"])
        XCTAssertTrue(changes.isEmpty)
    }

    func testRefusesUpdatesWithoutPrimaryKey() {
        var changes = ChangeSet()
        changes.set(row: 0, column: 0, value: "x", original: ["a"])
        XCTAssertThrowsError(try pg.statements(for: changes, table: TableRef(schema: nil, name: "t"),
                                               columns: [ResultColumn(name: "a", typeName: "text")], primaryKey: []))
    }

    func testFilters() {
        XCTAssertEqual(pg.whereClause([Filter(column: "name", op: .contains, value: "50%")]),
                       "\"name\"::text ILIKE '%50\\%%' ESCAPE '\\'")
        XCTAssertEqual(my.whereClause([Filter(column: "id", op: .in, value: "1, 2")]), "`id` IN ('1', '2')")
        var off = Filter(column: "x", op: .isNull)
        off.enabled = false
        XCTAssertNil(pg.whereClause([off]))
        XCTAssertEqual(pg.whereClause([Filter(column: "", op: .sql, value: "a > 1"), Filter(column: "b", op: .isNotNull)]),
                       "(a > 1) AND \"b\" IS NOT NULL")
    }

    func testPageQuery() {
        XCTAssertEqual(pg.selectPage(TableRef(schema: "s", name: "t"), filter: "\"a\" = '1'", order: [("a", false)], limit: 300, offset: 600),
                       "SELECT * FROM \"s\".\"t\" WHERE \"a\" = '1' ORDER BY \"a\" DESC LIMIT 300 OFFSET 600")
    }
}

final class ConnectionTests: XCTestCase {
    func testParsesURLs() {
        var c = ConnectionConfig()
        let r = c.apply(url: "postgresql://me:p%40ss@db.example.com:6543/shop?sslmode=verify-full")
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.password, "p@ss")
        XCTAssertEqual(c.kind, .postgres)
        XCTAssertEqual(c.host, "db.example.com")
        XCTAssertEqual(c.port, 6543)
        XCTAssertEqual(c.user, "me")
        XCTAssertEqual(c.database, "shop")
        XCTAssertEqual(c.tls, .verify)

        var m = ConnectionConfig()
        XCTAssertTrue(m.apply(url: "mysql://root@localhost/app").ok)
        XCTAssertEqual(m.kind, .mysql)
        XCTAssertEqual(m.port, 3306)
        XCTAssertFalse(ConnectionConfig().with { $0.apply(url: "http://x") }.ok)
    }

    func testOldSavedConnectionsStillLoad() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","kind":"mysql","host":"db","port":3307}]"#
        let list = try JSONDecoder().decode([ConnectionConfig].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.name, "Old")
        XCTAssertEqual(list.first?.kind, .mysql)
        XCTAssertEqual(list.first?.port, 3307)
        XCTAssertEqual(list.first?.tls, .prefer)
        XCTAssertFalse(list.first?.sshEnabled ?? true)
        let again = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(list[0]))
        XCTAssertEqual(again, list[0])
    }

    func testStoreRoundTripsConnections() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(folder: folder)
        var c = ConnectionConfig()
        c.name = "Saved"
        c.safeMode = .authenticate
        c.modified = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(connections: [c])
        XCTAssertEqual(store.connections(), [c])
    }

    func testLegacyReadOnlyAndProductionBecomeSafeModes() throws {
        let json = #"[{"name":"A","readOnly":true},{"name":"B","environment":"production"},{"name":"C"}]"#
        let list = try JSONDecoder().decode([ConnectionConfig].self, from: Data(json.utf8))
        XCTAssertEqual(list.map(\.safeMode), [.readOnly, .confirmWrites, .off])
    }

    func testSecretBox() throws {
        let sealed = try SecretBox.seal(Data("pässwörds".utf8), passphrase: "correct horse")
        XCTAssertEqual(String(decoding: try SecretBox.open(sealed, passphrase: "correct horse"), as: UTF8.self), "pässwörds")
        XCTAssertThrowsError(try SecretBox.open(sealed, passphrase: "wrong"))
        XCTAssertNotEqual(try SecretBox.seal(Data("x".utf8), passphrase: "p").salt, try SecretBox.seal(Data("x".utf8), passphrase: "p").salt)
    }

    func testMergeKeepsNewestAndHonoursDeletes() {
        func c(_ name: String, _ t: TimeInterval, id: UUID = UUID()) -> ConnectionConfig {
            var x = ConnectionConfig(); x.id = id; x.name = name; x.modified = Date(timeIntervalSince1970: t); return x
        }
        let shared = UUID(), gone = UUID(), revived = UUID()
        let local = [c("mine old", 10, id: shared), c("local only", 5), c("deleted elsewhere", 5, id: gone), c("edited after delete", 50, id: revived)]
        let remote = [c("theirs new", 20, id: shared), c("remote only", 5)]
        let merged = ConnectionMerge.merge(local: local, remote: remote, deleted: [gone: Date(timeIntervalSince1970: 30), revived: Date(timeIntervalSince1970: 30)])
        XCTAssertEqual(merged.map(\.name), ["theirs new", "local only", "edited after delete", "remote only"])
    }

    func testCSV() {
        let rows = Export.parseCSV("a,b\n1,\"x, \"\"y\"\"\"\n2,\"multi\nline\"\n")
        XCTAssertEqual(rows, [["a", "b"], ["1", "x, \"y\""], ["2", "multi\nline"]])
        XCTAssertEqual(Export.parseCSV("a;b\r\n1;2\r\n"), [["a", "b"], ["1", "2"]])
        let csv = Export.csv(columns: [ResultColumn(name: "a", typeName: ""), ResultColumn(name: "b", typeName: "")],
                             rows: [["1", nil], ["x,y", "q\"q"]])
        XCTAssertEqual(csv, "a,b\n1,\nx,y\n".replacingOccurrences(of: "x,y\n", with: "\"x,y\",\"q\"\"q\"\n"))
    }
}

final class SQLiteDriverTests: XCTestCase {
    func testRoundTripThroughStagedEdits() throws {
        let path = NSTemporaryDirectory() + "mb-test-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try SQLiteDriver(path: path, create: true)
        _ = try db.execute("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, photo BLOB);
            INSERT INTO people (name, score, photo) VALUES ('Anne', 1.5, X'CAFE'), ('Bob', NULL, NULL);
            """)
        XCTAssertEqual(try db.objects(schema: nil).map(\.name), ["people"])
        XCTAssertEqual(try db.columns(of: TableRef(schema: nil, name: "people")).filter(\.isPrimaryKey).map(\.name), ["id"])

        let page = try db.execute(db.dialect.selectPage(TableRef(schema: nil, name: "people"), filter: nil, order: [("id", true)], limit: 300, offset: 0))[0]
        XCTAssertEqual(page.rows[0], ["1", "Anne", "1.5", "0xCAFE"])
        XCTAssertTrue(page.columns[3].isBinary)

        var changes = ChangeSet()
        changes.set(row: 0, column: 1, value: "Ann", original: page.rows[0])
        changes.set(row: 0, column: 3, value: "0xBEEF", original: page.rows[0])
        changes.delete(row: 1, original: page.rows[1])
        changes.inserts.append(.init(values: [1: "Cy's", 2: "3"]))
        let sql = try db.dialect.statements(for: changes, table: TableRef(schema: nil, name: "people"), columns: page.columns, primaryKey: ["id"])
        _ = try db.execute(([db.dialect.begin] + sql + ["COMMIT"]).joined(separator: ";\n"))

        let after = try db.rows("SELECT id, name, score, photo, typeof(score) FROM people ORDER BY id")
        XCTAssertEqual(after, [["1", "Ann", "1.5", "0xBEEF", "real"], ["2", "Cy's", "3.0", nil, "real"]])
    }

    func testErrorKeepsEarlierResults() throws {
        let db = try SQLiteDriver(path: ":memory:", create: true)
        do {
            _ = try db.execute("CREATE TABLE t (a); INSERT INTO t VALUES (1); SELECT nope FROM t")
            XCTFail("expected an error")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.completed.count, 2)
            XCTAssertTrue(error.message.contains("nope"))
        }
    }

    func testRowLimit() throws {
        let db = try SQLiteDriver(path: ":memory:", create: true)
        let r = try db.execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50) SELECT i FROM n", rowLimit: 10)[0]
        XCTAssertEqual(r.rows.count, 10)
        XCTAssertTrue(r.truncated)
    }
}

private extension ConnectionConfig {
    func with(_ f: (inout ConnectionConfig) -> (ok: Bool, password: String?)) -> (ok: Bool, password: String?) {
        var copy = self
        return f(&copy)
    }
}

@testable import BaseCore
import XCTest

final class DesignTests: XCTestCase {
    private func sample(_ kind: DatabaseKind) -> TableDesign {
        TableDesign(table: TableRef(schema: kind == .postgres ? "public" : nil, name: "people"), columns: [
            .init(original: "id", name: "id", type: "integer", nullable: false, primaryKey: true),
            .init(original: "name", name: "name", type: "text", nullable: false),
            .init(original: "age", name: "age", type: "integer"),
        ], indexes: [.init(original: "people_name", name: "people_name", columns: ["name"])], primaryKeyName: "people_pkey")
    }

    func testPostgresAlter() throws {
        let d = Dialect(kind: .postgres)
        let original = sample(.postgres)
        var draft = original
        draft.renameColumn(draft.columns[1].id, to: "full_name")
        draft.columns[1].nullable = true
        draft.columns[2].type = "bigint"
        draft.columns[2].defaultValue = "0"
        draft.columns[2].comment = "Years"
        draft.columns.append(.init(name: "email", type: "text", nullable: false, defaultValue: "''"))
        draft.indexes[0].unique = true
        draft.foreignKeys.append(.init(name: "people_team", columns: ["age"], refTable: "teams", refSchema: "public", refColumns: ["id"], onDelete: "CASCADE"))
        XCTAssertEqual(try d.designStatements(original: original, draft: draft), [
            #"DROP INDEX "public"."people_name""#,
            #"ALTER TABLE "public"."people" RENAME COLUMN "name" TO "full_name""#,
            #"ALTER TABLE "public"."people" ALTER COLUMN "full_name" DROP NOT NULL"#,
            #"ALTER TABLE "public"."people" ALTER COLUMN "age" TYPE bigint USING "age"::bigint"#,
            #"ALTER TABLE "public"."people" ALTER COLUMN "age" SET DEFAULT 0"#,
            #"COMMENT ON COLUMN "public"."people"."age" IS 'Years'"#,
            #"ALTER TABLE "public"."people" ADD COLUMN "email" text NOT NULL DEFAULT ''"#,
            #"CREATE UNIQUE INDEX "people_name" ON "public"."people" ("full_name")"#,
            #"ALTER TABLE "public"."people" ADD CONSTRAINT "people_team" FOREIGN KEY ("age") REFERENCES "public"."teams" ("id") ON DELETE CASCADE"#,
        ])
    }

    func testMySQLAlterAndPrimaryKey() throws {
        let d = Dialect(kind: .mysql)
        let original = sample(.mysql)
        var draft = original
        draft.renameColumn(draft.columns[1].id, to: "full_name")
        draft.columns[1].primaryKey = true
        draft.columns.remove(at: 2)
        XCTAssertEqual(try d.designStatements(original: original, draft: draft), [
            "ALTER TABLE `people` DROP PRIMARY KEY",
            "ALTER TABLE `people` DROP COLUMN `age`",
            "ALTER TABLE `people` CHANGE COLUMN `name` `full_name` text NOT NULL",
            "ALTER TABLE `people` ADD PRIMARY KEY (`id`, `full_name`)",
        ])
    }

    func testNothingChangedMeansNoStatements() throws {
        for kind in DatabaseKind.allCases {
            let d = Dialect(kind: kind)
            if d.supportsDesign {
                XCTAssertEqual(try d.designStatements(original: sample(kind), draft: sample(kind)), [], kind.title)
            } else {
                XCTAssertThrowsError(try d.designStatements(original: sample(kind), draft: sample(kind)), kind.title)
            }
        }
    }

    func testCreateTable() throws {
        var design = TableDesign.new(table: TableRef(schema: nil, name: "notes"), kind: .sqlite)
        design.columns.append(.init(name: "body", type: "text", nullable: false, defaultValue: "''"))
        design.indexes.append(.init(name: "notes_body", columns: ["body"], unique: true))
        XCTAssertEqual(try Dialect(kind: .sqlite).designStatements(original: nil, draft: design), [
            "CREATE TABLE \"notes\" (\n  \"id\" integer PRIMARY KEY NOT NULL,\n  \"body\" text NOT NULL DEFAULT ''\n)",
            "CREATE UNIQUE INDEX \"notes_body\" ON \"notes\" (\"body\")",
        ])
        var mysql = TableDesign.new(table: TableRef(schema: nil, name: "notes"), kind: .mysql)
        mysql.columns.append(.init(name: "body", type: "varchar(200)", comment: "Text"))
        XCTAssertEqual(try Dialect(kind: .mysql).designStatements(original: nil, draft: mysql),
                       ["CREATE TABLE `notes` (\n  `id` bigint NOT NULL AUTO_INCREMENT,\n  `body` varchar(200) COMMENT 'Text',\n  PRIMARY KEY (`id`)\n)"])
    }

    func testProblemsStopTheBuild() {
        var design = sample(.postgres)
        design.columns.append(.init(name: "name", type: "text"))
        XCTAssertThrowsError(try Dialect(kind: .postgres).designStatements(original: sample(.postgres), draft: design))
    }

    /// The SQLite rebuild really runs and keeps the rows.
    func testSQLiteRebuildKeepsData() throws {
        let db = try SQLiteDriver(path: ":memory:", create: true)
        _ = try db.execute("""
            PRAGMA foreign_keys = ON;
            CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, team INTEGER);
            CREATE INDEX people_name ON people (name);
            INSERT INTO teams VALUES (1, 'Core');
            INSERT INTO people VALUES (1, 'Anne', 30, 1), (2, 'Bob', NULL, 1);
            """)
        let table = TableRef(schema: nil, name: "people")
        let original = TableDesign(table: table, kind: .sqlite, columns: try db.columns(of: table), indexes: try db.indexes(of: table),
                                   foreignKeys: try db.foreignKeys(of: table))
        var draft = original
        draft.columns[2].type = "real"            // needs a rebuild
        draft.columns[2].defaultValue = "18"
        draft.renameColumn(draft.columns[1].id, to: "full_name")
        draft.foreignKeys.append(.init(name: "people_team", columns: ["team"], refTable: "teams", refColumns: ["id"], onDelete: "CASCADE"))
        let statements = try db.dialect.designStatements(original: original, draft: draft)
        XCTAssertTrue(statements.contains { $0.hasPrefix("CREATE TABLE \"_mb_new_people\"") })
        _ = try db.execute((["BEGIN"] + statements + ["COMMIT"]).joined(separator: ";\n"))

        XCTAssertEqual(try db.rows("SELECT id, full_name, age, typeof(age) FROM people ORDER BY id"),
                       [["1", "Anne", "30.0", "real"], ["2", "Bob", nil, "null"]])
        XCTAssertEqual(try db.columns(of: table).first { $0.name == "age" }?.defaultValue, "18")
        XCTAssertEqual(try db.indexes(of: table).first { $0.name == "people_name" }?.columns, ["full_name"])
        let fks = try db.foreignKeys(of: table)
        XCTAssertEqual(fks.first?.refTable, "teams")
        XCTAssertEqual(fks.first?.onDelete, "CASCADE")
        // The foreign key works: deleting the team removes its people.
        _ = try db.execute("DELETE FROM teams")
        XCTAssertEqual(try db.rows("SELECT COUNT(*) FROM people").first?[0], "0")
    }

    func testSQLiteSimpleChangesDontRebuild() throws {
        let original = sample(.sqlite)
        var draft = original
        draft.renameColumn(draft.columns[1].id, to: "full_name")
        draft.columns.append(.init(name: "email", type: "text"))
        draft.columns.remove(at: 2)
        XCTAssertEqual(try Dialect(kind: .sqlite).designStatements(original: original, draft: draft), [
            "ALTER TABLE \"people\" DROP COLUMN \"age\"",
            "ALTER TABLE \"people\" RENAME COLUMN \"name\" TO \"full_name\"",
            "ALTER TABLE \"people\" ADD COLUMN \"email\" text",
        ])
    }

    func testEnumsFromChecks() throws {
        let db = try SQLiteDriver(path: ":memory:", create: true)
        _ = try db.execute("CREATE TABLE o (id INTEGER PRIMARY KEY, status TEXT CHECK (status IN ('new', 'it''s done')))")
        let status = try db.columns(of: TableRef(schema: nil, name: "o")).first { $0.name == "status" }
        XCTAssertEqual(status?.enumValues, ["new", "it's done"])
        XCTAssertEqual(status?.editorKind, .choice(["new", "it's done"]))
        XCTAssertEqual(MySQLDriver.enumValues("enum('a','b''c')"), ["a", "b'c"])
        XCTAssertEqual(EditorKind(type: "timestamp with time zone"), .dateTime)
        XCTAssertEqual(EditorKind(type: "jsonb"), .json)
        XCTAssertEqual(EditorKind(type: "numeric(10,2)"), .number)
        XCTAssertEqual(EditorKind(type: "bytea"), .binary)
    }
}

final class SQLToolsTests: XCTestCase {
    func testFormatter() {
        let out = SQLFormatter.format("select a, b from t join u on u.id = t.u_id where a = 1 and b in (select x from y) order by a; insert into t (a) values (1)")
        XCTAssertEqual(out, """
            SELECT
              a,
              b
            FROM t
            JOIN u ON u.id = t.u_id
            WHERE a = 1
              AND b IN (
                SELECT x
                FROM y
              )
            ORDER BY a;

            INSERT INTO t (a)
            VALUES (1)

            """)
        // Strings, quoted names, casts and comments survive untouched.
        let tricky = "select 'from x where' as \"Select\", a::int -- keep me\nfrom t"
        let formatted = SQLFormatter.format(tricky)
        XCTAssertTrue(formatted.contains("'from x where'"))
        XCTAssertTrue(formatted.contains("\"Select\""))
        XCTAssertTrue(formatted.contains("a::int"))
        XCTAssertTrue(formatted.contains("-- keep me"))
        XCTAssertEqual(SQLFormatter.format(formatted), formatted, "formatting twice changes nothing")
    }

    func testParameters() {
        let sql = "select * from t where id = :id and name = :name and x::int > 0 and y = :id and z = ':nope' and a[1:2] = 1"
        XCTAssertEqual(SQLText.parameters(in: sql), ["id", "name"])
        let bound = SQLText.bind(sql, values: ["id": "42", "name": "O'Brien"], dialect: Dialect(kind: .postgres))
        XCTAssertEqual(bound, "select * from t where id = 42 and name = 'O''Brien' and x::int > 0 and y = 42 and z = ':nope' and a[1:2] = 1")
        XCTAssertEqual(SQLText.bind("v = :v", values: ["v": "null"], dialect: Dialect(kind: .mysql)), "v = NULL")
        XCTAssertEqual(SQLText.bind("v = :v", values: ["v": "=now()"], dialect: Dialect(kind: .mysql)), "v = now()")
        XCTAssertEqual(SQLText.bind("v = :v", values: ["v": "007"], dialect: Dialect(kind: .mysql)), "v = '007'")
    }

    func testAliases() {
        let a = SQLText.tableAliases(in: "select o. from public.orders o join \"Customers\" as c on c.id = o.cid, items i where 1")
        XCTAssertEqual(a["o"], "orders")
        XCTAssertEqual(a["orders"], "orders")
        XCTAssertEqual(a["c"], "Customers")
        XCTAssertEqual(a["i"], "items")
        XCTAssertNil(a["where"])
        XCTAssertEqual(SQLText.tableAliases(in: "update accounts set x = 1")["accounts"], "accounts")
    }

    func testExcelFileOpens() throws {
        let data = Export.xlsx([
            .init(name: "Orders: 2026", columns: [ResultColumn(name: "id", typeName: "int4"), ResultColumn(name: "note", typeName: "text")],
                  rows: [["1", "a < b & \"c\""], ["2", nil]]),
            .init(name: "Orders: 2026", columns: [ResultColumn(name: "x", typeName: "text")], rows: [["\u{1}bad"]]),
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-xlsx-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.xlsx")
        try data.write(to: file)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", file.path, "-d", dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "the archive unpacks")
        let workbook = try String(contentsOf: dir.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)
        XCTAssertTrue(workbook.contains(#"name="Orders 2026""#))
        XCTAssertTrue(workbook.contains(#"name="Orders 2026 2""#))
        let sheet = try String(contentsOf: dir.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8)
        XCTAssertTrue(sheet.contains("<v>1</v>"), "numbers stay numbers")
        XCTAssertTrue(sheet.contains("a &lt; b &amp; &quot;c&quot;"))
        _ = try XMLDocument(contentsOf: dir.appendingPathComponent("xl/worksheets/sheet2.xml"))
    }

    func testMarkdown() {
        XCTAssertEqual(Export.markdown(columns: [ResultColumn(name: "a|b", typeName: "")], rows: [["x\ny"], [nil]]),
                       "| a\\|b |\n| --- |\n| x<br>y |\n| NULL |\n")
    }

    func testSQLDumpRestores() throws {
        let db = try SQLiteDriver(path: ":memory:", create: true)
        _ = try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT, b BLOB); INSERT INTO t VALUES (1, 'it''s', X'00FF'), (2, NULL, NULL); CREATE VIEW w AS SELECT v FROM t")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mb-dump-\(UUID()).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        try Dump.sql(driver: db, objects: try db.objects(schema: nil), to: file) { _, _ in }
        let copy = try SQLiteDriver(path: ":memory:", create: true)
        _ = try copy.execute(try String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(try copy.rows("SELECT id, v, b FROM t ORDER BY id"), [["1", "it's", "0x00FF"], ["2", nil, nil]])
        XCTAssertEqual(try copy.rows("SELECT COUNT(*) FROM w").first?[0], "2")
    }
}

final class JWTTests: XCTestCase {
    /// An RS256 token from an openssl PKCS#8 key verifies with the public key; the fingerprint has Snowflake's form.
    func testSignsWithPKCS8Key() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-jwt-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyFile = dir.appendingPathComponent("k.p8").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", keyFile]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let key = try JWT.privateKey(try String(contentsOfFile: keyFile, encoding: .utf8))
        let token = try JWT.sign(["iss": "me", "iat": 1], key: key)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func unurl(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let ok = SecKeyVerifySignature(SecKeyCopyPublicKey(key)!, .rsaSignatureMessagePKCS1v15SHA256,
                                       Data("\(parts[0]).\(parts[1])".utf8) as CFData, unurl(parts[2]) as CFData, nil)
        XCTAssertTrue(ok)
        let fp = try JWT.fingerprint(key)
        XCTAssertTrue(fp.hasPrefix("SHA256:"))
        // The same fingerprint openssl computes from the public key's DER.
        let o = Process()
        o.executableURL = URL(fileURLWithPath: "/bin/sh")
        o.arguments = ["-c", "openssl pkey -in '\(keyFile)' -pubout -outform DER | openssl dgst -sha256 -binary | openssl enc -base64"]
        let out = Pipe()
        o.standardOutput = out
        o.standardError = FileHandle.nullDevice
        try o.run(); o.waitUntilExit()
        XCTAssertEqual(fp, "SHA256:" + String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

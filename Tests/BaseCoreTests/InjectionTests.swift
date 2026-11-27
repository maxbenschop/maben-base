@testable import BaseCore
import XCTest

/// Values, names and files that come from a database (or from someone else) and must stay data.
final class LiteralTests: XCTestCase {
    func testABackslashCantTakeTheClosingQuoteWithIt() {
        // The value a hostile row would hold to break out of its string where a backslash is an escape.
        let hostile = #"x\'; DROP TABLE users; --"#
        for kind in [DatabaseKind.snowflake, .mysql, .clickhouse] {
            XCTAssertEqual(Dialect(kind: kind).literal(hostile), #"'x\\''; DROP TABLE users; --'"#, "\(kind)")
            XCTAssertEqual(Dialect(kind: kind).literal("ends in \\"), #"'ends in \\'"#, "\(kind)")
        }
        XCTAssertEqual(Dialect(kind: .bigquery).literal(hostile), #"'x\\\'; DROP TABLE users; --'"#)
        // Postgres: E'…' reads the same whether standard_conforming_strings is on or off.
        XCTAssertEqual(Dialect(kind: .postgres).literal(hostile), #"E'x\\''; DROP TABLE users; --'"#)
        XCTAssertEqual(Dialect(kind: .postgres).literal("plain 'text'"), "'plain ''text'''")
        XCTAssertEqual(Dialect(kind: .postgres).literal("deadbeef".isEmpty ? nil : "\\xdeadbeef", binary: true), #"E'\\xdeadbeef'"#)
        // Where a backslash is only a backslash, it stays one.
        for kind in [DatabaseKind.sqlite, .duckdb, .cassandra, .sqlserver] {
            XCTAssertTrue(Dialect(kind: kind).literal(hostile).hasSuffix(#"'x\''; DROP TABLE users; --'"#), "\(kind)")
        }
    }

    func testBacktickNamesCantEndEarly() {
        XCTAssertEqual(Dialect(kind: .clickhouse).quote("a\\"), "`a\\\\`")
        XCTAssertEqual(Dialect(kind: .clickhouse).quote("a`; DROP TABLE t; --"), "`a\\`; DROP TABLE t; --`")
        XCTAssertEqual(Dialect(kind: .bigquery).quote("a\\`b"), "`a\\\\\\`b`")
        XCTAssertEqual(Dialect(kind: .mysql).quote("a`b\\"), "`a``b\\`", "MySQL doubles the backtick and has no escapes in names")
    }

    func testTheLikeEscapeIsWrittenTheWayTheEngineReadsIt() {
        let f = [Filter(column: "name", op: .contains, value: "50%")]
        XCTAssertEqual(Dialect(kind: .postgres).whereClause(f), #""name"::text ILIKE E'%50\\%%' ESCAPE E'\\'"#)
        XCTAssertEqual(Dialect(kind: .snowflake).whereClause(f)?.hasSuffix(#"ESCAPE '\\'"#), true)
        XCTAssertEqual(Dialect(kind: .sqlite).whereClause(f)?.hasSuffix(#"ESCAPE '\'"#), true)
    }

    // MARK: Oracle and SQL*Plus

    func testOracleValuesNeverPutALineOfTheirOwnInFrontOfSQLPlus() {
        let d = Dialect(kind: .oracle)
        XCTAssertEqual(d.literal("it's"), "'it''s'")
        XCTAssertEqual(d.literal(""), "''")
        XCTAssertEqual(d.literal("a\nHOST touch /tmp/x\n"), "'a' || CHR(10) || 'HOST touch /tmp/x' || CHR(10)")
        XCTAssertEqual(d.literal("a\r\n!id"), "'a' || CHR(13) || CHR(10) || '!id'")
        XCTAssertEqual(d.literal("a\u{2028}@evil.sql"), "'a' || UNISTR('\\2028') || '@evil.sql'")
        for hostile in ["x\nHOST id", "x\r!id", "x\u{0B}@f", "x\u{0C}/", "x\u{85}.", "x\u{2029}#HOST id", "tab\tand\0nul"] {
            XCTAssertFalse(ConnectionConfig.hasControl(d.literal(hostile)), hostile)
        }
        // What reaches SQL*Plus for an edit and for an INSERT of a hostile row is one line each.
        var changes = ChangeSet()
        changes.set(row: 0, column: 1, value: "new\nHOST id", original: ["1", "old\n!id"])
        changes.inserts.append(.init(values: [1: "x\n/\nHOST id"]))
        let columns = [ResultColumn(name: "ID", typeName: "NUMBER"), ResultColumn(name: "NOTE", typeName: "VARCHAR2")]
        for s in try! d.statements(for: changes, table: TableRef(schema: nil, name: "T"), columns: columns, primaryKey: ["ID"]) {
            XCTAssertFalse(s.contains("\n"), s)
            XCTAssertNoThrow(try OracleText.check(s))
        }
        XCTAssertFalse(d.insertStatements(table: TableRef(schema: nil, name: "T"), columns: columns, rows: [["1", "a\nHOST id"]]).joined().contains("\n"))
    }

    func testOracleRefusesANameWithALineBreak() {
        XCTAssertNoThrow(try OracleText.check("SELECT \"a b\", 'text\nwith a break', q'[it's\nfine]' FROM \"T\" -- \"x\ny\""))
        XCTAssertThrowsError(try OracleText.check("SELECT * FROM \"T\nHOST id\""))
        XCTAssertThrowsError(try OracleText.check("SELECT \"a\rb\" FROM t"))
        XCTAssertThrowsError(try OracleText.check("UPDATE t SET \"c\u{2028}d\" = 1"))
        // The app's own statement for a table that is named that way.
        let hostile = Dialect(kind: .oracle).selectPage(TableRef(schema: nil, name: "T\nHOST id"), filter: nil, order: [], limit: 10, offset: 0)
        XCTAssertThrowsError(try OracleText.check(hostile))
    }

    func testSQLPlusStartsRestrictedWithItsSubstitutionsOff() {
        XCTAssertEqual(OracleText.arguments, ["-S", "-L", "-R", "3", "/nolog"])
        for line in ["SET DEFINE OFF", "SET ESCAPE OFF", "SET CMDSEP OFF", "SET SQLBLANKLINES ON"] {
            XCTAssertTrue(OracleText.settings.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.contains(line), line)
        }
    }

    func testTheConnectLineIsOneLine() throws {
        XCTAssertEqual(try OracleText.connectLine(user: "mb", password: "Secre t&1;", host: "db.example.com", port: 1521, service: ""),
                       "CONNECT mb/\"Secre t&1;\"@//db.example.com:1521/FREEPDB1")
        XCTAssertEqual(try OracleText.connectLine(user: "odd user", password: "p", host: "::1", port: 1521, service: "ORCL"), "CONNECT \"odd user\"/\"p\"@//::1:1521/ORCL")
        let bad: [(String, String, String, String)] = [
            ("mb\nHOST id", "p", "h", "s"), ("mb", "p\nHOST id", "h", "s"), ("mb", "p", "h\nHOST id", "s"), ("mb", "p", "h", "s\nHOST id"),
            ("mb", "p\r", "h", "s"), ("mb", "p\"x", "h", "s"), ("m\"b", "p", "h", "s"), ("mb", "p", "h x", "s"), ("mb", "p", "h/x", "s"),
            ("mb", "p", "", "s"), ("mb", "p", "h", "s@other"), ("mb", "p", "h", "s x"), ("mb", "p\u{2028}", "h", "s"),
        ]
        for (user, password, host, service) in bad {
            XCTAssertThrowsError(try OracleText.connectLine(user: user, password: password, host: host, port: 1521, service: service), "\(user)|\(password)|\(host)|\(service)")
        }
        XCTAssertThrowsError(try OracleText.connectLine(user: "mb", password: "p", host: "h", port: 0, service: "s"))
    }

    // MARK: DuckDB

    func testDuckDBDotCommandsAreFoundWhereTheToolWouldRunThem() {
        XCTAssertEqual(DuckDBText.dotCommand(in: ".shell touch /tmp/x"), ".shell touch /tmp/x")
        XCTAssertEqual(DuckDBText.dotCommand(in: "  \t.read /tmp/evil.sql"), ".read /tmp/evil.sql")
        XCTAssertEqual(DuckDBText.dotCommand(in: "-- a comment\n.shell id\nSELECT 1"), ".shell id")
        XCTAssertEqual(DuckDBText.dotCommand(in: "/* a\n.shell id\n*/ SELECT 1"), ".shell id", "refused inside a comment too")
        XCTAssertEqual(DuckDBText.dotCommand(in: "\r\n.output /tmp/x"), ".output /tmp/x")
        // Lines of a value, of a name, or of a statement under way are SQL, not commands.
        XCTAssertNil(DuckDBText.dotCommand(in: "INSERT INTO t VALUES ('a\n.shell id\n')"))
        XCTAssertNil(DuckDBText.dotCommand(in: "SELECT \"odd\n.name\" FROM t"))
        XCTAssertNil(DuckDBText.dotCommand(in: "SELECT $$a\n.shell id$$"))
        XCTAssertNil(DuckDBText.dotCommand(in: "SELECT 1\n  .5 + 1"))
        XCTAssertNil(DuckDBText.dotCommand(in: "SELECT t\n.c FROM t"))
        XCTAssertNil(DuckDBText.dotCommand(in: "SELECT 0.5, t.c FROM t"))
        // The app's own statements for a hostile value never hold one.
        let d = Dialect(kind: .duckdb)
        XCTAssertNil(DuckDBText.dotCommand(in: d.insertStatements(table: TableRef(schema: nil, name: "t\n.shell id"), columns: [ResultColumn(name: "a\n.shell id", typeName: "")],
                                                                  rows: [["x'\n.shell id\n"]]).joined(separator: ";\n")))
    }

    /// With the real duckdb tool, when it is installed: a line that would run a program is refused unless
    /// it was typed in the editor, and the same line inside a value is only a value.
    func testDuckDBRunsNoDotCommandFromAFileOrFromData() throws {
        guard ToolFinder.find("duckdb", configured: nil) != nil else { throw XCTSkip("duckdb isn't installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-duck-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let proof = folder.appendingPathComponent("ran").path
        let db = try DuckDBDriver(path: "", readOnly: false, toolPath: nil)
        defer { db.close() }
        XCTAssertThrowsError(try db.execute(".shell /usr/bin/touch '\(proof)'")) { XCTAssertTrue(($0 as? DatabaseError)?.message.contains("command of the duckdb tool") == true) }
        XCTAssertThrowsError(try db.execute("SELECT 1;\n.shell /usr/bin/touch '\(proof)'"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proof), "nothing ran")

        // A hostile value saved the way the app saves it stays a value.
        _ = try db.execute("CREATE TABLE t (id INTEGER, note VARCHAR)")
        let hostile = "x'\n.shell /usr/bin/touch '\(proof)'\n"
        for s in db.dialect.insertStatements(table: TableRef(schema: nil, name: "t"), columns: [ResultColumn(name: "id", typeName: "INTEGER"), ResultColumn(name: "note", typeName: "VARCHAR")],
                                             rows: [["1", hostile]]) { _ = try db.execute(s) }
        XCTAssertEqual(try db.rows("SELECT note FROM t").first?[0], hostile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proof))

        // Typed in the query editor, the tool's own commands work as they do in a terminal: this one makes
        // the file it names and nothing else (no file for a semicolon the app added).
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath)
        _ = try db.executeTyped(".shell /usr/bin/touch '\(proof)'", rowLimit: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: proof))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath), before)
        XCTAssertEqual(try db.executeTyped("SELECT 41 + 1 AS n", rowLimit: 10).first?.rows.first?.first ?? nil, "42", "the connection goes on after a command")
    }

    // MARK: MySQL accounts

    func testMySQLAccountsAreQuotedPartByPart() {
        XCTAssertEqual(Admin.mysqlAccount(name: "app", host: "%"), "'app'@'%'")
        XCTAssertEqual(Admin.mysqlAccount(name: "app", host: ""), "'app'@'%'")
        XCTAssertEqual(Admin.mysqlAccount(name: "a'@'%' IDENTIFIED BY 'x' -- ", host: "h\\"), #"'a''@''%'' IDENTIFIED BY ''x'' -- '@'h\\'"#)
        // Whatever the id says, the statements are made from the name and the host.
        let user = Admin.User(id: "'x'@'%'; DROP USER 'root'@'%'", name: "o'brien", host: "10.0.0.%", canLogin: true, superuser: false, detail: "")
        XCTAssertEqual(Admin.dropUser(.mysql, user: user), ["DROP USER 'o''brien'@'10.0.0.%'"])
        XCTAssertEqual(Admin.setPassword(.mysql, user: user, password: "p'w"), "ALTER USER 'o''brien'@'10.0.0.%' IDENTIFIED BY 'p''w'")
        XCTAssertTrue(Admin.grant(.mysql, revoke: false, privileges: [], user: user, container: "shop", table: nil).hasSuffix("TO 'o''brien'@'10.0.0.%'"))
        XCTAssertTrue(Admin.grant(.mysql, revoke: true, privileges: [], user: user, container: "shop", table: "t").hasSuffix("FROM 'o''brien'@'10.0.0.%'"))
        XCTAssertEqual(Admin.createUser(.mysql, name: "o'brien", host: "", password: "p", superuser: false), ["CREATE USER 'o''brien'@'%' IDENTIFIED BY 'p'"])
    }
}

final class RedisSafetyTests: XCTestCase {
    private let columns = ["key", "type", "ttl", "value"].map { ResultColumn(name: $0, typeName: "") }

    func testEditsAreArgumentListsSoAKeyCantStartACommand() throws {
        let hostile = "k\r\nFLUSHALL\r\n"
        var changes = ChangeSet()
        changes.delete(row: 0, original: [hostile, "string", "-1", "v"])
        changes.set(row: 1, column: 3, value: "new\u{2028}FLUSHALL", original: ["a\u{85}CONFIG SET dir /tmp", "string", "-1", "old"])
        changes.set(row: 2, column: 0, value: "renamed\nDEL x", original: ["b", "string", "-1", "v"])
        changes.inserts.append(.init(values: [0: "n\rEVAL x 0", 1: "hash", 3: #"{"f\nFLUSHDB":"v\rSHUTDOWN"}"#]))
        let units = try RedisText.commands(for: changes, columns: columns)
        let commands = units.flatMap { $0 }.map { $0.map(\.value) }
        XCTAssertEqual(commands, [
            ["DEL", hostile],
            ["SET", "a\u{85}CONFIG SET dir /tmp", "new\u{2028}FLUSHALL", "KEEPTTL"],
            ["RENAME", "b", "renamed\nDEL x"],
            ["HSET", "n\rEVAL x 0", "f\nFLUSHDB", "v\rSHUTDOWN"],
        ])
        // Only words the app wrote itself are command words.
        for arg in units.flatMap({ $0 }).flatMap({ $0 }) {
            if case .word(let w) = arg { XCTAssertTrue(["DEL", "SET", "KEEPTTL", "RENAME", "HSET"].contains(w), w) }
        }
    }

    func testTheTextShownForAnEditIsOneCommandPerLine() throws {
        var changes = ChangeSet()
        changes.delete(row: 0, original: ["k\r\nFLUSHALL\u{2028}x\u{85}y\u{0B}z", "string", "-1", "v"])
        let shown = try RedisText.statements(for: changes, columns: columns)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].split(whereSeparator: \.isNewline).count, 1, shown[0])
        // Read back the way the driver reads a typed line, it is still one DEL of that one key.
        XCTAssertEqual(RedisText.split(shown[0]), ["DEL", "k\r\nFLUSHALL\u{2028}x\u{85}y\u{0B}z"])
    }

    func testQuotedArgumentsReadBackExactly() {
        for value in ["plain", "with space", "q\"uote", "back\\slash", "a\nb", "a\rb", "a\r\nb", "tab\t", "nul\0", "\u{1B}[0m", "ls\u{2028}ps\u{2029}", "nel\u{85}", "ünï", ""] {
            let quoted = RedisText.quote(value)
            XCTAssertFalse(quoted.contains(where: \.isNewline), quoted)
            XCTAssertEqual(RedisText.split("GET \(quoted)"), ["GET", value], quoted)
        }
        XCTAssertEqual(RedisText.split(RedisText.page(filter: "a\nb*", limit: 10, offset: 0)), ["MB.PAGE", "a\nb*", "0", "10"])
    }

    func testReadOnlyKnowsRedisCommands() {
        for read in ["GET k", "get k", "HGETALL h", "SCAN 0 MATCH * COUNT 100", "CONFIG GET maxmemory", "OBJECT ENCODING k", "TTL k\nTYPE k", "# note\nPING", "MB.PAGE \"*\" 0 100", ""] {
            XCTAssertFalse(SQLText.isWrite(read, kind: .redis), read)
        }
        for write in ["SET k v", "DEL k", "FLUSHALL", "flushdb", "CONFIG SET dir /tmp", "CONFIG", "EVAL \"redis.call('del','k')\" 0", "RENAME a b", "EXPIRE k 1",
                      "GET k\nDEL k", "HSET h f v", "SOMETHING.NEW k", "DEBUG SLEEP 1", "SHUTDOWN", "SCRIPT FLUSH", "GETDEL k", "GETEX k EX 1", "SORT l STORE d",
                      "BITFIELD k SET u8 0 1", "\"SET\" k v", "MIGRATE h 1 k 0 1", "SLAVEOF h 1"] {
            XCTAssertTrue(SQLText.isWrite(write, kind: .redis), write)
        }
    }
}

final class MongoSafetyTests: XCTestCase {
    private let columns = [ResultColumn(name: "_id", typeName: "string"), ResultColumn(name: "name", typeName: "string")]

    func testAnIDCellStandsForExactlyTheValueItShows() throws {
        let ids: [BSON] = [.string("abc"), .string("{ $ne: null }"), .string("ObjectId(\"507f1f77bcf86cd799439011\")"), .string("5"), .string("true"),
                           .string("null"), .string("[1]"), .string(" padded "), .string(""), .string("/re/"), .int32(5), .int64(5_000_000_000), .double(1.5),
                           .objectId(Data(repeating: 0xAB, count: 12)), .bool(true), .document([("a", .int32(1)), ("$ne", .null)])]
        for id in ids {
            guard let cell = MongoText.idCell(id) else { XCTFail("no cell for \(id)"); continue }
            XCTAssertEqual(MongoText.idValue(cell), id, cell)
        }
    }

    func testAStringIDThatLooksLikeAQueryIsComparedAsAString() throws {
        // The document's _id is this string. Read as shell text it would match every document.
        let hostile = BSON.string("{ $ne: null }")
        let cell = try XCTUnwrap(MongoText.idCell(hostile))
        var changes = ChangeSet()
        changes.delete(row: 0, original: [cell, "x"])
        changes.set(row: 1, column: 1, value: "new", original: [cell, "old"])
        let edits = try MongoText.edits(for: changes, columns: columns)
        XCTAssertEqual(edits.count, 2)
        for edit in edits {
            switch edit {
            case .delete(let filter), .update(let filter, _): XCTAssertEqual(filter, .document([("_id", hostile)]))
            case .insert: XCTFail("no insert was staged")
            }
        }
    }

    func testADocumentIDIsComparedAsAValueNeverRunAsOperators() {
        let id = BSON.document([("$ne", .null)])
        XCTAssertEqual(MongoText.idFilter(id), .document([("_id", .document([("$eq", id)]))]))
        XCTAssertEqual(MongoText.idFilter(.regex(".*", "")), .document([("_id", .document([("$eq", .regex(".*", ""))]))]))
        XCTAssertEqual(MongoText.idFilter(.int32(7)), .document([("_id", .int32(7))]))
    }

    func testEditsAreValuesAndTheTextIsOnlyForShow() throws {
        var changes = ChangeSet()
        changes.set(row: 0, column: 1, value: "x\" }), db.dropDatabase(), ({ \"", original: ["7", "old"])
        let edits = try MongoText.edits(for: changes, columns: columns)
        guard case .update(let filter, let set)? = edits.first else { return XCTFail("expected an update") }
        XCTAssertEqual(filter, .document([("_id", .int32(7))]))
        XCTAssertEqual(set, .document([("$set", .document([("name", .string("x\" }), db.dropDatabase(), ({ \""))]))]))
        let shown = try MongoText.statements(for: changes, table: TableRef(schema: nil, name: "c\"); db.dropDatabase(); (\""), columns: columns)
        XCTAssertEqual(MongoText.commands(shown[0]).count, 1, "even as text it is one command")
    }

    func testReadOnlyKnowsMongoCommands() {
        for read in ["db.people.find({ age: { $gt: 5 } }).limit(10)", "db.getCollection(\"a b\").countDocuments({})", "show collections", "use shop",
                     "db.people.aggregate([{ $match: { a: 1 } }, { $group: { _id: \"$a\" } }])", "db.runCommand({ ping: 1 })", "db.people.getIndexes()", "db.getCollectionNames()"] {
            XCTAssertFalse(SQLText.isWrite(read, kind: .mongodb), read)
        }
        for write in ["db.people.insertOne({ a: 1 })", "db.people.updateMany({}, { $set: { a: 1 } })", "db.people.deleteMany({})", "db.people.drop()", "db.dropDatabase()",
                      "db.people.aggregate([{ $match: {} }, { $out: \"copy\" }])", "db.people.aggregate([{ $merge: { into: \"copy\" } }])",
                      "db.people.aggregate([{ $facet: { a: [{ $out: \"copy\" }] } }])", "db.runCommand({ drop: \"people\" })", "db.adminCommand({ shutdown: 1 })",
                      "db.people.findOneAndDelete({})", "db.people.createIndex({ a: 1 })", "db.people.find({}); db.people.drop()", "db.people.somethingNew()",
                      "db.runCommand({ aggregate: \"people\", pipeline: [{ $out: \"copy\" }], cursor: {} })", "not a command", "db.people.renameCollection(\"x\")"] {
            XCTAssertTrue(SQLText.isWrite(write, kind: .mongodb), write)
        }
    }

    func testSRVAnswersMustStayInTheDomainThatWasAsked() {
        XCTAssertTrue(MongoDriver.srvTargetAllowed("shard-00-00.abc.mongodb.net", for: "cluster0.abc.mongodb.net"))
        XCTAssertTrue(MongoDriver.srvTargetAllowed("Shard-00-00.ABC.mongodb.net.", for: "cluster0.abc.mongodb.net"))
        XCTAssertFalse(MongoDriver.srvTargetAllowed("evil.example.com", for: "cluster0.abc.mongodb.net"))
        XCTAssertFalse(MongoDriver.srvTargetAllowed("abc.mongodb.net.evil.example.com", for: "cluster0.abc.mongodb.net"))
        XCTAssertFalse(MongoDriver.srvTargetAllowed("evilabc.mongodb.net", for: "cluster0.abc.mongodb.net"), "a longer name that only ends the same")
        XCTAssertFalse(MongoDriver.srvTargetAllowed("other.mongodb.net", for: "cluster0.abc.mongodb.net"))
        XCTAssertTrue(MongoDriver.srvTargetAllowed("db1.example.com", for: "example.com"), "a short name must be the whole ending")
        XCTAssertFalse(MongoDriver.srvTargetAllowed("db1.other.com", for: "example.com"))
        XCTAssertFalse(MongoDriver.srvTargetAllowed("-x.abc.mongodb.net", for: "cluster0.abc.mongodb.net"))
        for name in ["@8.8.8.8", "+short", "-x", "a b", "a\nb", "", ".x", "ü.example.com"] { XCTAssertFalse(MongoDriver.isHostName(name), name) }
        XCTAssertTrue(MongoDriver.isHostName("cluster0.abc.mongodb.net"))
        XCTAssertThrowsError(try MongoDriver.lookupSRV("@8.8.8.8"), "never handed to dig")
    }
}

final class FileSafetyTests: XCTestCase {
    func testBackupToolsGetTheDatabaseAsANameOnly() throws {
        let pg = BackupTool.pgDumpArguments(host: "h", port: 5432, user: "u", database: "host=evil.example.com user=postgres", file: "/tmp/out.dump", plainSQL: false)
        XCTAssertTrue(pg.contains("--dbname=dbname='host=evil.example.com user=postgres'"), "\(pg)")
        XCTAssertTrue(pg.allSatisfy { $0.hasPrefix("--") }, "every argument is an option with its value attached: \(pg)")
        XCTAssertTrue(BackupTool.pgDumpArguments(host: "h", port: 1, user: "u", database: "postgres://evil/x", file: "f", plainSQL: true).contains("--dbname=dbname='postgres://evil/x'"))
        XCTAssertEqual(BackupTool.pgDatabase("o'br\\ien"), #"--dbname=dbname='o\'br\\ien'"#)
        XCTAssertTrue(BackupTool.psqlArguments(host: "h", port: 1, user: "u", database: "d", file: "f").contains("--dbname=dbname='d'"))
        let restore = BackupTool.pgRestoreArguments(host: "h", port: 1, user: "u", database: "d", file: "-f")
        XCTAssertEqual(Array(restore.suffix(2)), ["--", "-f"], "a file can't be read as an option")

        let dump = BackupTool.mysqlDumpArguments(host: "h", port: 3306, user: "u", database: "shop", file: "/tmp/out.sql", tls: .off)
        XCTAssertEqual(Array(dump.suffix(2)), ["--", "shop"], "the database comes last, after --")
        XCTAssertEqual(Array(BackupTool.mysqlArguments(host: "h", port: 3306, user: "u", database: "shop", tls: .verify).suffix(2)), ["--", "shop"])

        XCTAssertNoThrow(try BackupTool.checkNames(database: "shop", user: "app", host: "db.example.com"))
        XCTAssertThrowsError(try BackupTool.checkNames(database: "--result-file=/tmp/x", user: "app", host: "h"))
        XCTAssertThrowsError(try BackupTool.checkNames(database: "shop", user: "-u", host: "h"))
        XCTAssertThrowsError(try BackupTool.checkNames(database: "shop", user: "app", host: "-h"))
        XCTAssertThrowsError(try BackupTool.checkNames(database: "sh\nop", user: "app", host: "h"))
        for kind in [DatabaseKind.postgres, .mysql] {
            XCTAssertThrowsError(try BackupTool.backup(kind: kind, host: "h", port: 1, user: "u", password: "p", database: "-x", tls: .off, file: "/tmp/f", plainSQL: true)) {
                XCTAssertTrue(($0 as? DatabaseError)?.message.contains("can't be given to the backup tool") == true, "\(kind): refused for its name, before any tool is looked for")
            }
        }
    }

    func testTableNamesBecomeFileNamesThatStayInTheFolder() throws {
        XCTAssertEqual(Export.fileName("orders"), "orders")
        XCTAssertEqual(Export.fileName("../../.ssh/authorized_keys"), "-..-.ssh-authorized_keys")
        XCTAssertEqual(Export.fileName("/etc/passwd"), "-etc-passwd")
        XCTAssertEqual(Export.fileName(".."), "table")
        XCTAssertEqual(Export.fileName(".hidden"), "hidden")
        XCTAssertEqual(Export.fileName(""), "table")
        XCTAssertEqual(Export.fileName("a\nb\0c:d\\e"), "a-b-c-d-e")
        XCTAssertLessThanOrEqual(Export.fileName(String(repeating: "ü", count: 500)).utf8.count, 200)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-export-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.resolvingSymlinksInPath().path
        var taken = Set<String>()
        for table in ["orders", "../../../../tmp/evil", "/etc/cron.d/evil", "..", ".", "a/b", "Orders", "orders", "~/x", "...", "con\u{0}trol"] {
            let url = try Export.destination(in: folder, table: table, fileExtension: "csv", taken: &taken)
            XCTAssertEqual(url.deletingLastPathComponent().path, root, table)
            XCTAssertFalse(url.lastPathComponent.hasPrefix("."), table)
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".csv"), table)
        }
        XCTAssertEqual(taken.count, 11, "two tables never share a file, also when only the case differs")
        XCTAssertTrue(taken.contains("orders 2.csv") && taken.contains("orders 3.csv"))
    }

    func testDumpCommentsStayComments() {
        XCTAssertEqual(Dump.comment("shop\nDROP TABLE users;"), "shop DROP TABLE users;")
        XCTAssertEqual(Dump.comment("a\r\nb\u{2028}c\u{85}d"), "a  b c d")
        XCTAssertEqual(Dump.comment("plain name"), "plain name")
    }

    func testADumpOfATableWithALineBreakInItsNameRestoresOnlyThatTable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-dump-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try SQLiteDriver(path: folder.appendingPathComponent("a.sqlite").path, create: true)
        defer { db.close() }
        _ = try db.execute("CREATE TABLE victim (id INTEGER); INSERT INTO victim VALUES (1); CREATE TABLE \"x\nDROP TABLE victim;\" (id INTEGER)")
        let file = folder.appendingPathComponent("dump.sql")
        try Dump.sql(driver: db, objects: try db.objects(schema: nil), to: file, progress: { _, _ in })
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("-- x DROP TABLE victim;\nCREATE TABLE"), "the comment with the name is one line; the name's own line break only stands inside its quotes")
        let copy = try SQLiteDriver(path: folder.appendingPathComponent("b.sqlite").path, create: true)
        defer { copy.close() }
        _ = try copy.execute(text)
        XCTAssertEqual(try copy.rows("SELECT count(*) FROM victim").first?[0], "1")
    }

    func testCSVFormulaProtectionIsAChoiceAndLeavesNumbersAlone() {
        let columns = [ResultColumn(name: "a", typeName: ""), ResultColumn(name: "b", typeName: "")]
        let rows: [[String?]] = [["=HYPERLINK(\"http://evil\",\"x\")", "+1+cmd|' /C calc'!A0"], ["-5", "+3.2e4"], ["@SUM(A1)", "-x"], ["\tx", "\rx"], ["plain", nil], ["1=1", "a-b"]]
        let protected = Export.csv(columns: columns, rows: rows, protectFormulas: true)
        XCTAssertEqual(Export.parseCSV(protected), [["a", "b"], ["'=HYPERLINK(\"http://evil\",\"x\")", "'+1+cmd|' /C calc'!A0"], ["-5", "+3.2e4"], ["'@SUM(A1)", "'-x"],
                                                    ["'\tx", "'\rx"], ["plain", ""], ["1=1", "a-b"]])
        // Without it the file holds the values exactly as they are, so it reads back the same.
        XCTAssertEqual(Export.parseCSV(Export.csv(columns: columns, rows: rows)).dropFirst().map { $0 }, rows.map { $0.map { $0 ?? "" } })
        XCTAssertEqual(Export.csv(columns: columns, rows: [["=1", "x"]]), "a,b\n=1,x\n", "off unless asked for")
        for number in ["-5", "+5", "-0.25", "+3.2e4", "-1e-3"] { XCTAssertFalse(Export.looksLikeFormula(number), number) }
        for formula in ["=1", "+A1", "-A1", "@x", "\t=1", "\r=1", "=", "-", "+", "--5", "-5-5"] { XCTAssertTrue(Export.looksLikeFormula(formula), formula) }
    }
}

final class ReadOnlyTests: XCTestCase {
    func testOnlyKnownReadsAreReads() {
        for read in ["select 1", "SELECT * FROM updates", "  -- note\n select 1;", "(select 1) union (select 2)", "with x as (select 1) select * from x",
                     "values (1), (2)", "show tables", "describe t", "explain select 1", "EXPLAIN DELETE FROM t", "select 'insert into t' as s", "select \"delete\" from t",
                     "select 1; select 2", "begin; select 1; commit", "start transaction read only", "rollback", "table t", ""] {
            XCTAssertFalse(SQLText.isWrite(read, kind: .postgres), read)
        }
        for write in ["insert into t values (1)", "update t set a = 1", "delete from t", "drop table t", "truncate t", "create table t (a int)", "alter table t add b int",
                      "CALL do_things()", "DO $$ begin delete from t; end $$", "EXEC sp_x", "EXECUTE p", "MERGE INTO t USING s ON (1=1) WHEN MATCHED THEN DELETE",
                      "COPY t FROM '/tmp/x'", "COPY (select 1) TO PROGRAM 'id'", "LOAD DATA INFILE 'x' INTO TABLE t", "REPLACE INTO t VALUES (1)", "UPSERT INTO t VALUES (1)",
                      "VACUUM", "REFRESH MATERIALIZED VIEW v", "SELECT * INTO copy FROM t", "select 1 into outfile '/tmp/x'",
                      "with x as (select 1) insert into t select * from x", "with d as (delete from t returning *) select * from d", "WITH x AS (SELECT 1) UPDATE t SET a = 1",
                      "explain analyze delete from t", "EXPLAIN (ANALYZE) UPDATE t SET a = 1", "explain analyze select f(); drop table t", "select 1; drop table t",
                      "grant all on t to u", "set role admin", "lock table t", "reindex table t", "comment on table t is 'x'", "begin; delete from t; commit",
                      "something the app has never heard of", "select nextval('s'); delete from t", "attach database 'x' as y", "listen x", "prepare p as delete from t"] {
            XCTAssertTrue(SQLText.isWrite(write, kind: .postgres), write)
        }
    }

    func testAQuoteCantHideASecondStatement() {
        // Where a backslash escapes the quote the string goes on; where it doesn't, the DELETE is a statement.
        XCTAssertTrue(SQLText.isWrite(#"select 'a\'; delete from t; --'"#, kind: .mysql))
        XCTAssertTrue(SQLText.isWrite(#"select 'a\'; delete from t; --'"#, kind: .postgres))
        XCTAssertTrue(SQLText.isWrite("select 1 /*! ; delete from t */", kind: .mysql), "MySQL runs what is in /*! … */")
        XCTAssertTrue(SQLText.isWrite("select 1 --x\n; delete from t", kind: .mysql))
        XCTAssertTrue(SQLText.isWrite("select 1 # note\n; delete from t", kind: .mysql))
    }

    func testEnginesWithTheirOwnWaysOfWriting() {
        XCTAssertTrue(SQLText.isWrite("select 1 exec sp_configure 'x', 1", kind: .sqlserver), "no semicolon needed in T-SQL")
        XCTAssertTrue(SQLText.isWrite("select * from t drop table t", kind: .sqlserver))
        XCTAssertFalse(SQLText.isWrite("select [delete], [drop table] from t", kind: .sqlserver))
        XCTAssertFalse(SQLText.isWrite("PRAGMA table_info(t)", kind: .sqlite))
        XCTAssertTrue(SQLText.isWrite("PRAGMA journal_mode = DELETE", kind: .sqlite))
        XCTAssertTrue(SQLText.isWrite("PRAGMA writable_schema(1)", kind: .sqlite))
        XCTAssertTrue(SQLText.isWrite("PRAGMA table_info(t)", kind: .postgres))
        XCTAssertTrue(SQLText.isWrite(".shell touch /tmp/x", kind: .duckdb))
        XCTAssertTrue(SQLText.isWrite("COPY t TO '/tmp/x.csv'", kind: .duckdb))
        XCTAssertTrue(SQLText.isWrite("INSTALL httpfs", kind: .duckdb))
        XCTAssertTrue(SQLText.isWrite("ALTER TABLE t DELETE WHERE 1", kind: .clickhouse))
        XCTAssertTrue(SQLText.isWrite("HOST touch /tmp/x", kind: .oracle))
    }

    func testAReadOnlySQLiteConnectionRefusesWritesItself() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-ro-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("a.sqlite").path, other = folder.appendingPathComponent("b.sqlite").path
        for p in [path, other] {
            let db = try SQLiteDriver(path: p, create: true)
            _ = try db.execute("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1)")
            db.close()
        }
        let db = try SQLiteDriver(path: path, readOnly: true)
        defer { db.close() }
        XCTAssertEqual(try db.rows("SELECT a FROM t").first?[0], "1")
        XCTAssertThrowsError(try db.execute("INSERT INTO t VALUES (2)"))
        // A second file attached to a read-only connection would be writable without query_only.
        _ = try db.execute("ATTACH DATABASE '\(other)' AS o")
        XCTAssertThrowsError(try db.execute("INSERT INTO o.t VALUES (2)"))
        XCTAssertThrowsError(try db.execute("PRAGMA query_only = OFF; INSERT INTO o.t VALUES (2)") , "the file itself is still opened read-only") { _ in }
        db.close()
        let check = try SQLiteDriver(path: other)
        defer { check.close() }
        XCTAssertEqual(try check.rows("SELECT count(*) FROM t").first?[0], "1")
    }
}

final class ReleaseFeedSafetyTests: XCTestCase {
    private let download = "https://github.com/maxbenschop/maben-base/releases/download/v0.3/Maben-Base.zip"
    private func feed(zip: String, page: String = "https://github.com/maxbenschop/maben-base/releases/tag/v0.3") -> Data {
        let object: [String: Any] = ["tag_name": "v0.3", "draft": false, "prerelease": false, "html_url": page, "body": "- Fix",
                                     "assets": [["name": "Maben-Base.zip", "browser_download_url": zip]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testOnlyDownloadsThisRepositorysReleaseFromGitHub() throws {
        XCTAssertEqual(try XCTUnwrap(ReleaseFeed.parse(feed(zip: download))).zip.absoluteString, download)
        for zip in ["http://github.com/maxbenschop/maben-base/releases/download/v0.3/Maben-Base.zip",
                    "https://example.com/maxbenschop/maben-base/releases/download/v0.3/Maben-Base.zip",
                    "https://github.com.example.com/maxbenschop/maben-base/releases/download/v0.3/Maben-Base.zip",
                    "https://github.com@example.com/maxbenschop/maben-base/releases/download/v0.3/Maben-Base.zip",
                    "https://github.com:8443/maxbenschop/maben-base/releases/download/v0.3/Maben-Base.zip",
                    "https://github.com/someone/else/releases/download/v0.3/Maben-Base.zip",
                    "https://github.com/maxbenschop/maben-base/releases/download/../../../../someone/else/releases/download/v1/Maben-Base.zip",
                    "https://github.com/maxbenschop/maben-base/releases/download/%2e%2e/%2e%2e/x/Maben-Base.zip",
                    "https://github.com/maxbenschop/maben-base/archive/Maben-Base.zip",
                    "file:///tmp/Maben-Base.zip"] {
            XCTAssertNil(ReleaseFeed.parse(feed(zip: zip)), zip)
        }
    }

    func testOnlyOpensAReleasePageOnGitHub() throws {
        XCTAssertEqual(try XCTUnwrap(ReleaseFeed.parse(feed(zip: download))).page.absoluteString, "https://github.com/maxbenschop/maben-base/releases/tag/v0.3")
        for page in ["http://github.com/maxbenschop/maben-base/releases/tag/v0.3", "https://example.com/phish", "file:///Applications/Calculator.app", "x-apple.systempreferences:"] {
            let release = try XCTUnwrap(ReleaseFeed.parse(feed(zip: download, page: page)), page)
            XCTAssertEqual(release.page.absoluteString, "https://github.com/maxbenschop/maben-base/releases", page)
        }
    }

    func testReleaseNotesOnlyLinkOverHTTPS() {
        let notes = "- [Docs](https://base.maben.gg/changelog) [plain](http://example.com) [file](file:///etc/passwd) [prefs](x-apple.systempreferences:com.apple.preference.security)"
        let text = ReleaseFeed.notesText(notes)
        XCTAssertEqual(text.runs.compactMap(\.link).map(\.absoluteString), ["https://base.maben.gg/changelog"])
        XCTAssertEqual(String(text.characters), "- Docs plain file prefs", "a link that isn't https stays as plain text")
    }
}

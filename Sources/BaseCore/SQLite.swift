import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite through the system library.
public final class SQLiteDriver: Driver, SQLiteSchema {
    public let kind = DatabaseKind.sqlite
    public let dialect = Dialect(kind: .sqlite)
    public let serverVersion = String(cString: sqlite3_libversion())
    public let path: String
    public var currentDatabase: String? { "main" }

    private var db: OpaquePointer?

    public init(path: String, readOnly: Bool = false, create: Bool = false) throws {
        self.path = path
        var flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if create { flags |= SQLITE_OPEN_CREATE }
        if !create && !FileManager.default.fileExists(atPath: path) {
            throw DatabaseError("There's no database file at \((path as NSString).abbreviatingWithTildeInPath).")
        }
        if sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw DatabaseError("Couldn't open the database file.", detail: message)
        }
        sqlite3_busy_timeout(db, 5000)
        sqlite3_extended_result_codes(db, 1)
    }

    private var lastError: DatabaseError {
        DatabaseError(String(cString: sqlite3_errmsg(db)), code: "\(sqlite3_extended_errcode(db))")
    }

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        guard let db else { throw DatabaseError("The connection was closed.") }
        var results: [QueryResult] = []
        let utf8 = Array(sql.utf8CString)
        do { try run(utf8, rowLimit: rowLimit, into: &results) } catch var e as DatabaseError {
            e.completed = results
            throw e
        }
        return results
    }

    private func run(_ utf8: [CChar], rowLimit: Int, into results: inout [QueryResult]) throws {
        let db = self.db
        try utf8.withUnsafeBufferPointer { buffer in
            var cursor = buffer.baseAddress!
            while cursor.pointee != 0 {
                var stmt: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(db, cursor, -1, &stmt, &tail) == SQLITE_OK else { throw lastError }
                defer { sqlite3_finalize(stmt) }
                guard let tail else { break }
                cursor = tail
                guard let stmt else { continue }  // only whitespace or a comment
                let count = Int(sqlite3_column_count(stmt))
                var result = QueryResult()
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, Int32(i)))
                    let decl = sqlite3_column_decltype(stmt, Int32(i)).map { String(cString: $0) } ?? ""
                    let upper = decl.uppercased()
                    result.columns.append(ResultColumn(name: name, typeName: decl.isEmpty ? "any" : decl.lowercased(),
                                                       isBinary: upper.contains("BLOB")))
                }
                let before = sqlite3_total_changes(db)
                while true {
                    let rc = sqlite3_step(stmt)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw lastError }
                    if result.rows.count >= rowLimit { result.truncated = true; continue }
                    var row: [String?] = []
                    row.reserveCapacity(count)
                    for i in 0..<Int32(count) {
                        switch sqlite3_column_type(stmt, i) {
                        case SQLITE_NULL: row.append(nil)
                        case SQLITE_BLOB:
                            let n = Int(sqlite3_column_bytes(stmt, i))
                            if let p = sqlite3_column_blob(stmt, i) {
                                let bytes = UnsafeRawBufferPointer(start: p, count: n)
                                row.append("0x" + bytes.map { String(format: "%02X", $0) }.joined())
                            } else { row.append("0x") }
                            if !result.columns[Int(i)].isBinary { result.columns[Int(i)].isBinary = true }
                        default:
                            row.append(String(cString: sqlite3_column_text(stmt, i)))
                        }
                    }
                    result.rows.append(row)
                }
                if count == 0 {
                    let changed = Int(sqlite3_total_changes(db) - before)
                    let verb = String(cString: sqlite3_sql(stmt)).trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: " ").first.map { $0.uppercased() } ?? ""
                    if ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(verb) || changed > 0 {
                        result.affectedRows = changed
                        result.message = "\(changed) row\(changed == 1 ? "" : "s") affected"
                    } else {
                        result.message = verb.isEmpty ? "Done" : verb
                    }
                } else {
                    result.message = "\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")"
                }
                results.append(result)
            }
        }
    }

    public func cancel() {
        if let db { sqlite3_interrupt(db) }
    }

    public func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    deinit { close() }

    // MARK: Schema

    public func databases() throws -> [String] { ["main"] }
    public func use(database: String) throws {}
    public func schemas() throws -> [String] { [] }

    public func objects(schema: String?) throws -> [DBObject] { try sqliteObjects() }
    public func columns(of table: TableRef) throws -> [ColumnInfo] { try sqliteColumns(table) }
    public func indexes(of table: TableRef) throws -> [IndexInfo] { try sqliteIndexes(table) }
    public func definition(of object: DBObject) throws -> String? { try sqliteDefinition(object) }
    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] { try sqliteForeignKeys(table) }

    public func estimatedCount(of table: TableRef) throws -> Int? { nil }

}

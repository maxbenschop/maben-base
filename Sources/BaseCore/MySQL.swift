import Foundation
import Security

/// MySQL and MariaDB over the client/server protocol (text protocol, so values arrive as text).
/// Auth: mysql_native_password and caching_sha2_password (MySQL 8's default), with or without TLS.
public final class MySQLDriver: Driver {
    public let kind = DatabaseKind.mysql
    public let dialect = Dialect(kind: .mysql)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?

    private var socket: Socket
    private var sequence: UInt8 = 0
    private var connectionID: UInt32 = 0
    private var usingTLS = false
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let tls: TLSOptions

    private enum Cap {
        static let longPassword: UInt32 = 1
        static let foundRows: UInt32 = 2
        static let longFlag: UInt32 = 4
        static let connectWithDB: UInt32 = 8
        static let protocol41: UInt32 = 0x200
        static let ssl: UInt32 = 0x800
        static let transactions: UInt32 = 0x2000
        static let secureConnection: UInt32 = 0x8000
        static let multiStatements: UInt32 = 0x10000
        static let multiResults: UInt32 = 0x20000
        static let pluginAuth: UInt32 = 0x80000
        static let pluginAuthLenencData: UInt32 = 0x200000
    }

    public init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.tls = tls
        socket = try Socket(host: host, port: port)
        try handshake(database: database)
        currentDatabase = database.isEmpty ? nil : database
        if currentDatabase == nil { currentDatabase = try? rows("SELECT DATABASE()").first?[0] ?? nil }
    }

    // MARK: Packets

    private func readPacket() throws -> [UInt8] {
        var payload = [UInt8]()
        while true {
            var header = ByteReader(try socket.read(4))
            let length = Int(header.intLE(3))
            sequence = header.byte() &+ 1
            payload += try socket.read(length)
            if length < 0xFFFFFF { return payload }
        }
    }

    private func writePacket(_ payload: [UInt8]) throws {
        var offset = 0
        repeat {
            let chunk = min(0xFFFFFF, payload.count - offset)
            var packet = [UInt8]()
            packet.appendLE(UInt32(chunk), bytes: 3)
            packet.append(sequence)
            sequence &+= 1
            packet += payload[offset..<offset + chunk]
            try socket.write(packet)
            offset += chunk
            if chunk < 0xFFFFFF { break }
        } while true
    }

    private func error(from packet: [UInt8]) -> DatabaseError {
        var r = ByteReader(packet)
        _ = r.byte()
        let code = r.intLE(2)
        var state: String?
        if r.remaining > 0, r.bytes[r.pos] == UInt8(ascii: "#") {
            _ = r.byte()
            state = String(decoding: r.take(5), as: UTF8.self)
        }
        return DatabaseError(String(decoding: r.rest(), as: UTF8.self), code: state.map { "\(code) (\($0))" } ?? "\(code)")
    }

    // MARK: Handshake

    private func handshake(database: String) throws {
        let greeting = try readPacket()
        if greeting.first == 0xFF { throw error(from: greeting) }
        var r = ByteReader(greeting)
        _ = r.byte()
        serverVersion = r.cString()
        connectionID = UInt32(r.intLE(4))
        var nonce = Array(r.take(8))
        _ = r.byte()
        var serverCaps = UInt32(r.intLE(2))
        _ = r.byte()  // charset
        _ = r.intLE(2)  // status
        serverCaps |= UInt32(r.intLE(2)) << 16
        let authDataLength = Int(r.byte())
        _ = r.take(10)
        if serverCaps & Cap.secureConnection != 0 {
            let part2 = Array(r.take(max(13, authDataLength - 8)))
            nonce += part2.prefix(while: { $0 != 0 })
        }
        var plugin = serverCaps & Cap.pluginAuth != 0 ? r.cString() : "mysql_native_password"
        if plugin.isEmpty { plugin = "mysql_native_password" }

        // Found rows: UPDATE reports rows matched, not rows changed, so saving an unchanged value isn't "not found".
        var caps = Cap.longPassword | Cap.foundRows | Cap.longFlag | Cap.protocol41 | Cap.transactions | Cap.secureConnection
            | Cap.multiStatements | Cap.multiResults | Cap.pluginAuth | Cap.pluginAuthLenencData
        if !database.isEmpty { caps |= Cap.connectWithDB }
        caps &= serverCaps | Cap.connectWithDB

        if tls.mode != .off && !host.hasPrefix("/") {
            if serverCaps & Cap.ssl != 0 {
                caps |= Cap.ssl
                var req = [UInt8]()
                req.appendLE(caps, bytes: 4)
                req.appendLE(16 * 1024 * 1024, bytes: 4)
                req.append(45)
                req += [UInt8](repeating: 0, count: 23)
                try writePacket(req)
                socket.startTLS(tls)
                usingTLS = true
            } else if tls.mode != .prefer {
                throw DatabaseError("The server doesn't accept TLS connections.", detail: "Set TLS to Prefer or Off for this connection.")
            }
        }

        var response = [UInt8]()
        response.appendLE(caps, bytes: 4)
        response.appendLE(16 * 1024 * 1024, bytes: 4)
        response.append(45)  // utf8mb4_general_ci
        response += [UInt8](repeating: 0, count: 23)
        response.appendCString(user)
        let auth = scramble(plugin: plugin, nonce: nonce)
        response += lenenc(auth.count)
        response += auth
        if !database.isEmpty { response.appendCString(database) }
        response.appendCString(plugin)
        try writePacket(response)
        try finishAuth(plugin: plugin, nonce: nonce)
    }

    private func scramble(plugin: String, nonce: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let pw = Array(password.utf8)
        switch plugin {
        case "caching_sha2_password":
            let p1 = Crypto.sha256(pw)
            let p2 = Crypto.sha256(Crypto.sha256(p1) + nonce)
            return Crypto.xor(p1, p2)
        case "mysql_clear_password":
            return pw + [0]
        default:  // mysql_native_password
            let s1 = Crypto.sha1(pw)
            let s2 = Crypto.sha1(nonce + Crypto.sha1(s1))
            return Crypto.xor(s1, s2)
        }
    }

    private func finishAuth(plugin startPlugin: String, nonce startNonce: [UInt8]) throws {
        var plugin = startPlugin
        var nonce = startNonce
        while true {
            let packet = try readPacket()
            switch packet.first {
            case 0x00:
                return
            case 0xFF:
                throw error(from: packet)
            case 0xFE:  // switch to another auth method
                var r = ByteReader(packet)
                _ = r.byte()
                plugin = r.cString()
                nonce = Array(r.rest()).prefix(while: { $0 != 0 }).map { $0 }
                if plugin == "mysql_clear_password" && !usingTLS {
                    throw DatabaseError("The server wants the password in plain text; turn on TLS for this connection.")
                }
                try writePacket(scramble(plugin: plugin, nonce: nonce))
            case 0x01:  // more data: caching_sha2_password
                guard packet.count >= 2 else { continue }
                if packet[1] == 3 { continue }  // fast auth worked; OK follows
                if packet[1] == 4 {
                    if usingTLS || host.hasPrefix("/") {  // a Unix socket counts as a secure channel
                        try writePacket(Array(password.utf8) + [0])
                    } else {
                        try writePacket([2])  // ask for the public key
                        let keyPacket = try readPacket()
                        guard keyPacket.first == 0x01 else { throw error(from: keyPacket) }
                        let pem = String(decoding: keyPacket.dropFirst(), as: UTF8.self)
                        try writePacket(try rsaEncrypt(password: Array(password.utf8) + [0], nonce: nonce, pem: pem))
                    }
                }
            default:
                throw DatabaseError("The server sent an unexpected reply while signing in.")
            }
        }
    }

    private func rsaEncrypt(password: [UInt8], nonce: [UInt8], pem: String) throws -> [UInt8] {
        let xored = password.enumerated().map { $0.element ^ nonce[$0.offset % nonce.count] }
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard var der = Data(base64Encoded: base64) else { throw DatabaseError("The server's public key couldn't be read.") }
        // SubjectPublicKeyInfo → PKCS#1: Security wants the bare RSA key.
        if let range = Self.pkcs1Range(in: Array(der)) { der = der.subdata(in: range) }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err),
              let out = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(xored) as CFData, &err) else {
            throw DatabaseError("Couldn't encrypt the password for the server.", detail: err?.takeRetainedValue().localizedDescription)
        }
        return Array(out as Data)
    }

    /// Finds the RSAPublicKey inside a SubjectPublicKeyInfo: the content of its BIT STRING.
    static func pkcs1Range(in der: [UInt8]) -> Range<Int>? {
        var i = 0
        func length() -> Int? {
            guard i < der.count else { return nil }
            var len = Int(der[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                len = 0
                for _ in 0..<n { guard i < der.count else { return nil }; len = len << 8 | Int(der[i]); i += 1 }
            }
            return len
        }
        guard der.first == 0x30 else { return nil }
        i = 1; _ = length()
        guard i < der.count, der[i] == 0x30 else { return nil }  // AlgorithmIdentifier
        i += 1
        guard let algLen = length() else { return nil }
        i += algLen
        guard i < der.count, der[i] == 0x03 else { return nil }  // BIT STRING
        i += 1
        guard let bitLen = length() else { return nil }
        i += 1  // unused-bits byte
        return i..<min(der.count, i + bitLen - 1)
    }

    // MARK: Queries

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        sequence = 0
        try writePacket([0x03] + Array(sql.utf8))
        var results: [QueryResult] = []
        while true {
            let first = try readPacket()
            switch first.first {
            case 0xFF:
                var e = error(from: first)
                e.completed = results
                throw e
            case 0x00:
                var r = ByteReader(first)
                _ = r.byte()
                let affected = readLenenc(&r)
                _ = readLenenc(&r)
                let status = UInt16(r.intLE(2))
                let warnings = Int(r.intLE(2))
                var message = "\(affected) row\(affected == 1 ? "" : "s") affected"
                if warnings > 0 { message += ", \(warnings) warning\(warnings == 1 ? "" : "s")" }
                results.append(QueryResult(affectedRows: Int(affected), message: message))
                if status & 0x08 == 0 { return results }
            case 0xFB:
                throw DatabaseError("LOAD DATA LOCAL isn't supported in Maben Base.")
            default:
                var r = ByteReader(first)
                let count = Int(readLenenc(&r))
                var columns: [ResultColumn] = []
                for _ in 0..<count {
                    var c = ByteReader(try readPacket())
                    for _ in 0..<4 { _ = readLenencString(&c) }  // catalog, schema, table, org_table
                    let name = readLenencString(&c) ?? ""
                    _ = readLenencString(&c)
                    _ = readLenenc(&c)
                    let charset = c.intLE(2)
                    _ = c.intLE(4)
                    let type = c.byte()
                    let flags = c.intLE(2)
                    let binary = (charset == 63 && [0xF9, 0xFA, 0xFB, 0xFC, 0xFE, 0xFD, 0x0F].contains(type) && flags & 0x80 != 0)
                        || type == 0x10
                    let typeName = flags & 0x100 != 0 ? "enum" : flags & 0x800 != 0 ? "set" : Self.typeName(type, binary: binary)
                    columns.append(ResultColumn(name: name, typeName: typeName, isBinary: binary))
                }
                _ = try readPacket()  // EOF after columns
                var result = QueryResult(columns: columns)
                var status: UInt16 = 0
                while true {
                    let packet = try readPacket()
                    if packet.first == 0xFE && packet.count < 9 {
                        var e = ByteReader(packet)
                        _ = e.byte(); _ = e.intLE(2)
                        status = UInt16(e.intLE(2))
                        break
                    }
                    if packet.first == 0xFF { throw error(from: packet) }
                    if result.rows.count >= rowLimit { result.truncated = true; continue }
                    var r = ByteReader(packet)
                    var row: [String?] = []
                    row.reserveCapacity(count)
                    for i in 0..<count {
                        if r.pos < r.bytes.count && r.bytes[r.pos] == 0xFB { _ = r.byte(); row.append(nil); continue }
                        let len = Int(readLenenc(&r))
                        let bytes = r.take(len)
                        if columns[i].isBinary {
                            row.append("0x" + bytes.map { String(format: "%02X", $0) }.joined())
                        } else {
                            row.append(String(decoding: bytes, as: UTF8.self))
                        }
                    }
                    result.rows.append(row)
                }
                result.message = "\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")"
                results.append(result)
                if status & 0x08 == 0 { return results }
            }
        }
    }

    private func lenenc(_ n: Int) -> [UInt8] {
        var b = [UInt8]()
        switch n {
        case ..<251: b.append(UInt8(n))
        case ..<0x10000: b.append(0xFC); b.appendLE(UInt32(n), bytes: 2)
        case ..<0x1000000: b.append(0xFD); b.appendLE(UInt32(n), bytes: 3)
        default:
            b.append(0xFE)
            b.appendLE(UInt32(n & 0xFFFF_FFFF), bytes: 4)
            b.appendLE(UInt32(n >> 32), bytes: 4)
        }
        return b
    }

    private func readLenenc(_ r: inout ByteReader) -> UInt64 {
        let first = r.byte()
        switch first {
        case 0xFC: return r.intLE(2)
        case 0xFD: return r.intLE(3)
        case 0xFE: return r.intLE(8)
        default: return UInt64(first)
        }
    }

    private func readLenencString(_ r: inout ByteReader) -> String? {
        if r.pos < r.bytes.count && r.bytes[r.pos] == 0xFB { _ = r.byte(); return nil }
        let n = Int(readLenenc(&r))
        return String(decoding: r.take(n), as: UTF8.self)
    }

    static func typeName(_ type: UInt8, binary: Bool) -> String {
        switch type {
        case 0x00, 0xF6: "decimal"
        case 0x01: "tinyint"
        case 0x02: "smallint"
        case 0x03: "int"
        case 0x04: "float"
        case 0x05: "double"
        case 0x06: "null"
        case 0x07: "timestamp"
        case 0x08: "bigint"
        case 0x09: "mediumint"
        case 0x0A: "date"
        case 0x0B: "time"
        case 0x0C: "datetime"
        case 0x0D: "year"
        case 0x0F: binary ? "varbinary" : "varchar"
        case 0x10: "bit"
        case 0xF5: "json"
        case 0xF7: "enum"
        case 0xF8: "set"
        case 0xF9, 0xFA, 0xFB, 0xFC: binary ? "blob" : "text"
        case 0xFD: binary ? "varbinary" : "varchar"
        case 0xFE: binary ? "binary" : "char"
        case 0xFF: "geometry"
        default: "type \(type)"
        }
    }

    public func cancel() {
        guard connectionID != 0 else { return }
        DispatchQueue.global().async { [host, port, user, password, tls, connectionID] in
            guard let other = try? MySQLDriver(host: host, port: port, user: user, password: password, database: "", tls: tls) else { return }
            _ = try? other.execute("KILL QUERY \(connectionID)")
            other.close()
        }
    }

    public func close() {
        if !socket.isClosed {
            sequence = 0
            try? writePacket([0x01])
        }
        socket.close()
    }

    deinit { close() }

    // MARK: Schema

    public func databases() throws -> [String] {
        try rows("SHOW DATABASES").compactMap { $0[0] }
    }

    public func use(database: String) throws {
        _ = try execute("USE \(dialect.quote(database))")
        currentDatabase = database
    }

    public func schemas() throws -> [String] { [] }

    public func objects(schema: String?) throws -> [DBObject] {
        guard let db = currentDatabase else { return [] }
        let d = dialect.literal(db)
        var objects: [DBObject] = try rows("""
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(d) ORDER BY TABLE_NAME
            """).compactMap { row in
            guard let name = row[0] else { return nil }
            return DBObject(schema: nil, name: name, kind: row[1] == "VIEW" ? .view : .table)
        }
        objects += try rows("""
            SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(d) ORDER BY ROUTINE_NAME
            """).compactMap { $0[0].map { DBObject(schema: nil, name: $0, kind: .function) } }
        return objects
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        try rows("SHOW FULL COLUMNS FROM \(dialect.qualified(table))").map { row in
            // Field, Type, Collation, Null, Key, Default, Extra, Privileges, Comment
            ColumnInfo(name: row[0] ?? "", type: row[1] ?? "", nullable: row[3] == "YES", defaultValue: row[5],
                       isPrimaryKey: row[4] == "PRI", comment: (row[8] ?? "").isEmpty ? nil : row[8],
                       extra: (row[6] ?? "").isEmpty ? nil : row[6], enumValues: Self.enumValues(row[1] ?? ""))
        }
    }

    /// enum('a','b''c') → ["a", "b'c"]
    static func enumValues(_ type: String) -> [String]? {
        let lower = type.lowercased()
        guard lower.hasPrefix("enum(") || lower.hasPrefix("set("), let open = type.firstIndex(of: "("), type.hasSuffix(")") else { return nil }
        return SQLText.quotedList(String(type[type.index(after: open)..<type.index(before: type.endIndex)]))
    }

    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] {
        guard let db = currentDatabase else { return [] }
        let rows = try rows("""
            SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME,
                   r.UPDATE_RULE, r.DELETE_RULE
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
            WHERE k.TABLE_SCHEMA = \(dialect.literal(db)) AND k.TABLE_NAME = \(dialect.literal(table.name))
              AND k.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """)
        var order: [String] = []
        var byName: [String: ForeignKeyInfo] = [:]
        for r in rows {
            guard let name = r[0], let col = r[1], let refTable = r[3], let refCol = r[4] else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = ForeignKeyInfo(name: name, columns: [], refSchema: r[2] == db ? nil : r[2], refTable: refTable,
                                              refColumns: [], onUpdate: r[5] ?? "NO ACTION", onDelete: r[6] ?? "NO ACTION")
            }
            byName[name]!.columns.append(col)
            byName[name]!.refColumns.append(refCol)
        }
        return order.compactMap { byName[$0] }
    }

    public func estimatedCount(of table: TableRef) throws -> Int? {
        guard let db = currentDatabase else { return nil }
        return try rows("""
            SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(dialect.literal(db)) AND TABLE_NAME = \(dialect.literal(table.name))
            """).first?[0].flatMap { $0 }.flatMap { Int($0) }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        var order: [String] = []
        var byName: [String: IndexInfo] = [:]
        for row in try rows("SHOW INDEX FROM \(dialect.qualified(table))") {
            // Table, Non_unique, Key_name, Seq_in_index, Column_name, ...
            guard let name = row[2], let column = row[4] else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = IndexInfo(name: name, columns: [], unique: row[1] == "0", primary: name == "PRIMARY")
            }
            byName[name]!.columns.append(column)
        }
        return order.compactMap { byName[$0] }
    }

    public func definition(of object: DBObject) throws -> String? {
        switch object.kind {
        case .function:
            for kind in ["FUNCTION", "PROCEDURE"] {
                if let r = try? execute("SHOW CREATE \(kind) \(dialect.quote(object.name))").first?.rows.first, r.count > 2 { return r[2] }
            }
            return nil
        case .view:
            return try rows("SHOW CREATE VIEW \(dialect.qualified(object.table))").first?[1] ?? nil
        default:
            return try rows("SHOW CREATE TABLE \(dialect.qualified(object.table))").first?[1] ?? nil
        }
    }
}

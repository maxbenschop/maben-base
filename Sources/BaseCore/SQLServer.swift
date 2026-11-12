import Foundation

/// SQL Server and Azure SQL over TDS 7.4 (SQL Server 2012 and later), with SQL Server sign-in.
/// TLS uses TDS 8 ("strict": TLS from the first byte), which SQL Server 2022 and Azure SQL support; with TLS
/// off, the connection isn't encrypted, which servers that require encryption refuse.
public final class SQLServerDriver: Driver {
    public let kind = DatabaseKind.sqlserver
    public let dialect = Dialect(kind: .sqlserver)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?
    private var socket: ByteStream
    private var packetSize = 4096
    private var transaction = [UInt8](repeating: 0, count: 8)
    private let writeLock = NSLock()

    public init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions, strict: Bool = false) throws {
        if strict {
            // TDS 8: TLS 1.2/1.3 from the first byte, with the tds/8.0 protocol name (SQL Server 2022, Azure SQL).
            socket = try NWStream(host: host, port: port, tls: tls, alpn: ["tds/8.0"])
            _ = try exchange(0x12, Self.prelogin(encryption: 0x01))
            try login(host: host, user: user, password: password, database: database)
            return
        }
        let plain = try Socket(host: host, port: port)
        socket = plain
        // TDS 7: say whether we'll encrypt; the server answers ON, OFF (login only), NOT_SUP or REQ.
        let wantTLS = tls.mode != .off
        let reply = try exchange(0x12, Self.prelogin(encryption: wantTLS ? 0x01 : 0x02))
        var r = ByteReader(reply)
        var encryption: UInt8 = 2
        while !r.atEnd {
            let token = r.byte()
            if token == 0xFF { break }
            let offset = Int(UInt16(bitPattern: r.int16BE())), length = Int(UInt16(bitPattern: r.int16BE()))
            if token == 0x01, length > 0, offset < reply.count { encryption = reply[offset] }
        }
        switch encryption {
        case 0x00, 0x01, 0x03 where wantTLS || encryption == 0x03:
            if !wantTLS { throw DatabaseError("This SQL Server requires encryption.", detail: "Set TLS to Prefer, Require or Verify for this connection.") }
            let secure = try TDSTLS(socket: plain, host: host, tls: tls.mode == .prefer ? TLSOptions(.require, anchors: tls.anchors, identity: tls.identity) : tls)
            secure.dropAfterLogin = encryption == 0x00
            socket = secure
        default:
            if tls.mode == .require || tls.mode == .verify {
                throw DatabaseError("This SQL Server doesn't offer encryption.", detail: "Set TLS to Prefer or Off, or use the strict option (TDS 8).")
            }
        }
        try login(host: host, user: user, password: password, database: database)
    }

    // MARK: Packets

    private static func prelogin(encryption: UInt8) -> [UInt8] {
        // VERSION (6), ENCRYPTION (1), INSTOPT (1), THREADID (4), MARS (1)
        let options: [(UInt8, [UInt8])] = [(0x00, [16, 0, 0, 0, 0, 0]), (0x01, [encryption]), (0x02, [0]), (0x03, [0, 0, 0, 0]), (0x04, [0])]
        var header: [UInt8] = []
        var data: [UInt8] = []
        let start = options.count * 5 + 1
        for (token, value) in options {
            header.append(token)
            header.appendInt16BE(Int16(start + data.count))
            header.appendInt16BE(Int16(value.count))
            data += value
        }
        return header + [0xFF] + data
    }

    private func send(_ type: UInt8, _ payload: [UInt8]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let max = packetSize - 8
        var offset = 0
        var id: UInt8 = 1
        repeat {
            let chunk = Array(payload[offset..<min(payload.count, offset + max)])
            offset += chunk.count
            let last = offset >= payload.count
            var p: [UInt8] = [type, last ? 0x01 : 0x00]
            p.appendInt16BE(Int16(chunk.count + 8))
            p += [0, 0, id, 0]
            p += chunk
            try socket.write(p)
            id &+= 1
        } while offset < payload.count
    }

    private func receive() throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            var h = ByteReader(try socket.read(8))
            _ = h.byte()
            let status = h.byte()
            let length = Int(UInt16(bitPattern: h.int16BE()))
            out += try socket.read(length - 8)
            if status & 0x01 != 0 { return out }
        }
    }

    private func exchange(_ type: UInt8, _ payload: [UInt8]) throws -> [UInt8] {
        try send(type, payload)
        return try receive()
    }

    private static func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }

    private func login(host: String, user: String, password: String, database: String) throws {
        let fields: [[UInt8]] = [
            Self.utf16(ProcessInfo.processInfo.hostName), Self.utf16(user),
            Self.utf16(password).map { b in ((b << 4) | (b >> 4)) ^ 0xA5 },  // TDS password scrambling (not encryption)
            Self.utf16("Maben Base"), Self.utf16(host), [], Self.utf16("Maben Base"), [], Self.utf16(database),
        ]
        var fixed: [UInt8] = []
        func le32(_ v: UInt32) { fixed.appendLE(v, bytes: 4) }
        le32(0)  // length, filled in below
        le32(0x7400_0004)  // TDS 7.4
        le32(UInt32(packetSize))
        le32(7)
        le32(UInt32(ProcessInfo.processInfo.processIdentifier))
        le32(0)
        fixed += [0xE0, 0x03, 0x00, 0x00]  // USE_DB, INIT_DB_FATAL, SET_LANG / INIT_LANG_FATAL, ODBC
        le32(0)
        le32(0x0409)
        var data: [UInt8] = []
        let headerSize = 94
        func entry(_ bytes: [UInt8], chars: Int) {
            fixed.appendLE(UInt32(headerSize + data.count), bytes: 2)
            fixed.appendLE(UInt32(chars), bytes: 2)
            data += bytes
        }
        for (i, f) in fields.enumerated() {
            if i == 5 { fixed.appendLE(0, bytes: 2); fixed.appendLE(0, bytes: 2); continue }  // unused extension
            entry(f, chars: f.count / 2)
        }
        fixed += [0, 0, 0, 0, 0, 0]  // client MAC
        entry([], chars: 0)  // SSPI
        entry([], chars: 0)  // attach DB file
        entry([], chars: 0)  // change password
        le32(0)  // long SSPI
        var packet = fixed + data
        let total = UInt32(packet.count)
        packet.replaceSubrange(0..<4, with: withUnsafeBytes(of: total.littleEndian, Array.init))
        let reply = try exchange(0x10, packet)
        var loggedIn = false
        var error: DatabaseError?
        _ = try parse(reply, rowLimit: 0) { token in
            switch token {
            case .loginAck(let version): loggedIn = true; self.serverVersion = version
            case .error(let e): error = error ?? e
            default: break
            }
        }
        if let error { throw DatabaseError("SQL Server refused the sign-in.", detail: error.message, code: error.code) }
        guard loggedIn else { throw DatabaseError("SQL Server didn't accept the sign-in.") }
    }

    // MARK: Results

    struct Column { var name: String; var type: UInt8; var length: Int; var precision: UInt8; var scale: UInt8; var utf8: Bool; var typeName: String }

    enum Token { case loginAck(String), error(DatabaseError), columns([Column]), row([String?]), done(status: UInt16, count: Int) }

    /// Reads a token stream; returns the results it held.
    private func parse(_ bytes: [UInt8], rowLimit: Int, handle: ((Token) -> Void)? = nil) throws -> [QueryResult] {
        var r = ByteReader(bytes)
        var columns: [Column] = []
        var results: [QueryResult] = []
        var current: QueryResult?
        var error: DatabaseError?
        while !r.atEnd {
            let token = r.byte()
            switch token {
            case 0x81:  // COLMETADATA
                let count = Int(r.intLE(2))
                columns = []
                if count == 0xFFFF { continue }
                for _ in 0..<count {
                    _ = r.intLE(4); _ = r.intLE(2)
                    var c = try typeInfo(&r)
                    c.name = bVarchar(&r)
                    columns.append(c)
                }
                if let c = current { results.append(c) }
                current = QueryResult(columns: columns.map { ResultColumn(name: $0.name, typeName: $0.typeName, isBinary: [0xA5, 0xAD, 0x22].contains($0.type)) })
                handle?(.columns(columns))
            case 0xD1, 0xD2:  // ROW, NBCROW
                var nulls = [Bool](repeating: false, count: columns.count)
                if token == 0xD2 {
                    let bitmap = Array(r.take((columns.count + 7) / 8))
                    for i in columns.indices { nulls[i] = bitmap[i / 8] & (1 << (i % 8)) != 0 }
                }
                var row: [String?] = []
                for (i, c) in columns.enumerated() { row.append(nulls[i] ? nil : try value(&r, c)) }
                if current != nil {
                    if current!.rows.count < rowLimit { current!.rows.append(row) } else { current!.truncated = true }
                }
            case 0xFD, 0xFE, 0xFF:  // DONE, DONEPROC, DONEINPROC
                let status = UInt16(r.intLE(2))
                _ = r.intLE(2)
                let count = Int(r.intLE(8))
                handle?(.done(status: status, count: count))
                if var c = current {
                    c.message = "\(c.rows.count) row\(c.rows.count == 1 ? "" : "s")"
                    results.append(c)
                    current = nil
                } else if status & 0x10 != 0 && token == 0xFD {
                    results.append(QueryResult(affectedRows: count, message: "\(count) row\(count == 1 ? "" : "s") affected"))
                }
                if status & 0x20 != 0 { error = DatabaseError("Stopped.") }
            case 0xAA, 0xAB:  // ERROR, INFO
                let length = Int(r.intLE(2))
                let start = r.pos
                let number = Int(r.intLE(4)); _ = r.byte()
                let severity = r.byte()
                let message = usVarchar(&r)
                r.pos = start + length
                if token == 0xAA || severity > 10 {
                    let e = DatabaseError(message, code: String(number))
                    error = error ?? e
                    handle?(.error(e))
                }
            case 0xAD:  // LOGINACK
                let length = Int(r.intLE(2))
                let start = r.pos
                _ = r.byte(); _ = r.take(4)
                let name = bVarchar(&r)
                let v = Array(r.take(4))
                r.pos = start + length
                handle?(.loginAck("\(name) \(v[0]).\(v[1]).\(Int(v[2]) << 8 | Int(v[3]))"))
            case 0xE3:  // ENVCHANGE
                let length = Int(r.intLE(2))
                let start = r.pos
                let type = r.byte()
                switch type {
                case 1: currentDatabase = bVarchar(&r)
                case 4: packetSize = Int(bVarchar(&r)) ?? packetSize
                case 8: let n = Int(r.byte()); transaction = Array(r.take(n))
                case 9, 10: transaction = [UInt8](repeating: 0, count: 8)
                default: break
                }
                r.pos = start + length
            case 0x79: _ = r.take(4)  // RETURNSTATUS
            case 0xA9, 0xA5, 0xA4, 0xED: _ = r.take(Int(r.intLE(2)))  // ORDER, COLINFO, TABNAME, SSPI
            case 0xAE:  // FEATUREEXTACK
                while true { let id = r.byte(); if id == 0xFF { break }; _ = r.take(Int(r.intLE(4))) }
            default:
                throw DatabaseError("SQL Server sent something this app doesn't read (token 0x\(String(token, radix: 16))).")
            }
        }
        if let c = current { results.append(c) }
        if var error { error.completed = results; throw error }
        return results
    }

    private func bVarchar(_ r: inout ByteReader) -> String {
        let n = Int(r.byte())
        return String(decoding: Array(r.take(n * 2)).withUnsafeBufferPointer { b in
            Array(UnsafeRawBufferPointer(b).bindMemory(to: UInt16.self)).map { UInt16(littleEndian: $0) }
        }, as: UTF16.self)
    }

    private func usVarchar(_ r: inout ByteReader) -> String {
        let n = Int(r.intLE(2))
        return utf16LE(Array(r.take(n * 2)))
    }

    private func utf16LE(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count { units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8); i += 2 }
        return String(decoding: units, as: UTF16.self)
    }

    private func typeInfo(_ r: inout ByteReader) throws -> Column {
        let t = r.byte()
        var c = Column(name: "", type: t, length: 0, precision: 0, scale: 0, utf8: false, typeName: "")
        func collation() { let col = Array(r.take(5)); c.utf8 = col.count == 5 && col[3] & 0x04 != 0 }
        switch t {
        case 0x1F: c.typeName = "null"
        case 0x30: c.length = 1; c.typeName = "tinyint"
        case 0x32: c.length = 1; c.typeName = "bit"
        case 0x34: c.length = 2; c.typeName = "smallint"
        case 0x38: c.length = 4; c.typeName = "int"
        case 0x7F: c.length = 8; c.typeName = "bigint"
        case 0x3A: c.length = 4; c.typeName = "smalldatetime"
        case 0x3B: c.length = 4; c.typeName = "real"
        case 0x3C: c.length = 8; c.typeName = "money"
        case 0x3D: c.length = 8; c.typeName = "datetime"
        case 0x3E: c.length = 8; c.typeName = "float"
        case 0x7A: c.length = 4; c.typeName = "smallmoney"
        case 0x26: c.length = Int(r.byte()); c.typeName = ["", "tinyint", "smallint", "", "int", "", "", "", "bigint"][min(c.length, 8)]
        case 0x68: c.length = Int(r.byte()); c.typeName = "bit"
        case 0x6D: c.length = Int(r.byte()); c.typeName = c.length == 4 ? "real" : "float"
        case 0x6E: c.length = Int(r.byte()); c.typeName = "money"
        case 0x6F: c.length = Int(r.byte()); c.typeName = c.length == 4 ? "smalldatetime" : "datetime"
        case 0x24: c.length = Int(r.byte()); c.typeName = "uniqueidentifier"
        case 0x6A, 0x6C: c.length = Int(r.byte()); c.precision = r.byte(); c.scale = r.byte(); c.typeName = "decimal(\(c.precision),\(c.scale))"
        case 0x28: c.typeName = "date"
        case 0x29: c.scale = r.byte(); c.typeName = "time"
        case 0x2A: c.scale = r.byte(); c.typeName = "datetime2"
        case 0x2B: c.scale = r.byte(); c.typeName = "datetimeoffset"
        case 0xA5, 0xAD: c.length = Int(r.intLE(2)); c.typeName = t == 0xA5 ? "varbinary" : "binary"
        case 0xA7, 0xAF: c.length = Int(r.intLE(2)); collation(); c.typeName = t == 0xA7 ? "varchar" : "char"
        case 0xE7, 0xEF: c.length = Int(r.intLE(2)); collation(); c.typeName = t == 0xE7 ? "nvarchar" : "nchar"
        case 0x23, 0x63, 0x22:
            c.length = Int(r.intLE(4))
            if t != 0x22 { collation() }
            let parts = Int(r.byte())
            for _ in 0..<parts { _ = usVarchar(&r) }
            c.typeName = t == 0x23 ? "text" : t == 0x63 ? "ntext" : "image"
        case 0xF1:
            if r.byte() != 0 { _ = bVarchar(&r); _ = bVarchar(&r); _ = usVarchar(&r) }
            c.length = 0xFFFF; c.typeName = "xml"
        case 0xF0:
            c.length = Int(r.intLE(2)); _ = bVarchar(&r); _ = bVarchar(&r)
            c.typeName = bVarchar(&r); _ = usVarchar(&r); c.length = 0xFFFF
        case 0x62: c.length = Int(r.intLE(4)); c.typeName = "sql_variant"
        default: throw DatabaseError("SQL Server sent a column type this app doesn't read (0x\(String(t, radix: 16))).")
        }
        return c
    }

    /// PLP: an 8-byte total, then chunks until a zero-length one. nil for NULL.
    private func plp(_ r: inout ByteReader) -> [UInt8]? {
        let total = r.intLE(8)
        if total == 0xFFFF_FFFF_FFFF_FFFF { return nil }
        var out: [UInt8] = []
        while true {
            let n = Int(r.intLE(4))
            if n == 0 { break }
            out += r.take(n)
        }
        return out
    }

    private func value(_ r: inout ByteReader, _ c: Column) throws -> String? {
        let t = c.type
        // How many bytes, or nil for NULL.
        var bytes: [UInt8]
        switch t {
        case 0x30, 0x32, 0x34, 0x38, 0x7F, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x7A:
            bytes = Array(r.take(c.length))
        case 0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x24, 0x6A, 0x6C, 0x28, 0x29, 0x2A, 0x2B:
            let n = Int(r.byte())
            if n == 0 { return nil }
            bytes = Array(r.take(n))
        case 0xA5, 0xAD, 0xA7, 0xAF, 0xE7, 0xEF, 0xF0:
            if c.length == 0xFFFF || t == 0xF0 { guard let b = plp(&r) else { return nil }; bytes = b }
            else {
                let n = Int(r.intLE(2))
                if n == 0xFFFF { return nil }
                bytes = Array(r.take(n))
            }
        case 0xF1:
            guard let b = plp(&r) else { return nil }
            return utf16LE(b)
        case 0x23, 0x63, 0x22:
            let ptr = Int(r.byte())
            if ptr == 0 { return nil }
            _ = r.take(ptr + 8)
            bytes = Array(r.take(Int(r.intLE(4))))
        case 0x62:
            let n = Int(r.intLE(4))
            if n == 0 { return nil }
            var v = ByteReader(Array(r.take(n)))
            let base = v.byte()
            let props = Int(v.byte())
            var inner = Column(name: "", type: base, length: 0, precision: 0, scale: 0, utf8: false, typeName: "")
            switch base {
            case 0x6A, 0x6C: inner.precision = v.byte(); inner.scale = v.byte()
            case 0x29, 0x2A, 0x2B: inner.scale = v.byte()
            default: _ = v.take(props)
            }
            let rest = Array(v.rest())
            return format([0x30, 0x32, 0x34, 0x38, 0x7F, 0x3B, 0x3C, 0x3D, 0x3E, 0x7A].contains(base) ? 0 : 1, rest, inner)
        case 0x1F:
            return nil
        default:
            throw DatabaseError("Unreadable value.")
        }
        return format(0, bytes, c)
    }

    private func format(_: Int, _ b: [UInt8], _ c: Column) -> String {
        func le(_ n: Int) -> Int64 { var v: UInt64 = 0; for i in 0..<min(n, b.count) { v |= UInt64(b[i]) << (8 * UInt64(i)) }; return n >= 8 ? Int64(bitPattern: v) : Int64(v) }
        func signed(_ n: Int) -> Int64 { let v = le(n); let bits = Int64(n * 8); return n >= 8 ? v : (v >= (1 << (bits - 1)) ? v - (1 << bits) : v) }
        func decimalText(_ value: Int64Wide, scale: Int) -> String {
            var s = value.digits
            if scale > 0 {
                if s.count <= scale { s = String(repeating: "0", count: scale - s.count + 1) + s }
                s.insert(".", at: s.index(s.endIndex, offsetBy: -scale))
            }
            return (value.negative ? "-" : "") + s
        }
        let iso = { (d: Date, frac: Int, withOffset: Int?) -> String in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: withOffset.map { $0 * 60 } ?? 0)!
            let p = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d)
            var s = String(format: "%04d-%02d-%02d %02d:%02d:%02d", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
            if frac > 0 { s += "." + String(String(format: "%09d", p.nanosecond ?? 0).prefix(frac)) }
            if let o = withOffset { s += String(format: " %@%02d:%02d", o < 0 ? "-" : "+", abs(o) / 60, abs(o) % 60) }
            return s
        }
        let base1900 = Date(timeIntervalSince1970: -2_208_988_800)
        let base0001 = Date(timeIntervalSince1970: -62_135_596_800)
        func timeOf(_ bytes: ArraySlice<UInt8>, scale: Int) -> Double {
            var v: UInt64 = 0
            for (i, x) in bytes.enumerated() { v |= UInt64(x) << (8 * UInt64(i)) }
            return Double(v) / pow(10, Double(scale))
        }
        func days(_ bytes: ArraySlice<UInt8>) -> Double { Double(Int(bytes[bytes.startIndex]) | Int(bytes[bytes.startIndex + 1]) << 8 | Int(bytes[bytes.startIndex + 2]) << 16) }
        let timeBytes = c.scale <= 2 ? 3 : c.scale <= 4 ? 4 : 5
        switch c.type {
        case 0x30: return String(b[0])
        case 0x32, 0x68: return b.first == 0 ? "0" : "1"
        case 0x34, 0x38, 0x7F, 0x26: return String(signed(b.count))
        case 0x3B: return String(Float(bitPattern: UInt32(truncatingIfNeeded: le(4))))
        case 0x3E: return String(Double(bitPattern: UInt64(bitPattern: le(8))))
        case 0x6D: return b.count == 4 ? String(Float(bitPattern: UInt32(truncatingIfNeeded: le(4)))) : String(Double(bitPattern: UInt64(bitPattern: le(8))))
        case 0x3C, 0x6E, 0x7A:
            let cents: Int64 = b.count == 4 ? signed(4) : (Int64(Int32(truncatingIfNeeded: le(4))) << 32) | Int64(UInt32(truncatingIfNeeded: Int64(b[4]) | Int64(b[5]) << 8 | Int64(b[6]) << 16 | Int64(b[7]) << 24))
            return decimalText(Int64Wide(cents), scale: 4)
        case 0x6A, 0x6C:
            var magnitude = [UInt8](b.dropFirst())
            while magnitude.count < 16 { magnitude.append(0) }
            var w = Int64Wide(bytes: magnitude)
            w.negative = b.first == 0
            return decimalText(w, scale: Int(c.scale))
        case 0x3D, 0x6F where b.count == 8:
            let day = Int32(truncatingIfNeeded: le(4))
            let ticks = UInt32(truncatingIfNeeded: Int64(b[4]) | Int64(b[5]) << 8 | Int64(b[6]) << 16 | Int64(b[7]) << 24)
            return iso(base1900.addingTimeInterval(Double(day) * 86400 + Double(ticks) / 300), 3, nil)
        case 0x3A, 0x6F:
            let day = Int(b[0]) | Int(b[1]) << 8, minutes = Int(b[2]) | Int(b[3]) << 8
            return iso(base1900.addingTimeInterval(Double(day) * 86400 + Double(minutes) * 60), 0, nil)
        case 0x28:
            return String(iso(base0001.addingTimeInterval(days(b[0...]) * 86400), 0, nil).prefix(10))
        case 0x29:
            let s = timeOf(b[0...], scale: Int(c.scale))
            return String(iso(Date(timeIntervalSince1970: s), Int(c.scale), nil).dropFirst(11))
        case 0x2A:
            let s = timeOf(b[0..<timeBytes], scale: Int(c.scale))
            return iso(base0001.addingTimeInterval(days(b[timeBytes...]) * 86400 + s), Int(c.scale), nil)
        case 0x2B:
            let s = timeOf(b[0..<timeBytes], scale: Int(c.scale))
            let offset = Int(Int16(bitPattern: UInt16(b[timeBytes + 3]) | UInt16(b[timeBytes + 4]) << 8))
            return iso(base0001.addingTimeInterval(days(b[timeBytes..<(timeBytes + 3)]) * 86400 + s), Int(c.scale), offset)
        case 0x24:
            let p = { (r: [Int]) in r.map { String(format: "%02X", b[$0]) }.joined() }
            return "\(p([3, 2, 1, 0]))-\(p([5, 4]))-\(p([7, 6]))-\(p([8, 9]))-\(p([10, 11, 12, 13, 14, 15]))"
        case 0xE7, 0xEF, 0x63: return utf16LE(b)
        case 0xA7, 0xAF, 0x23:
            return String(data: Data(b), encoding: c.utf8 ? .utf8 : .windowsCP1252) ?? String(decoding: b, as: UTF8.self)
        default:
            return "0x" + b.map { String(format: "%02X", $0) }.joined()
        }
    }

    // MARK: Running

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        // ALL_HEADERS with the transaction descriptor, so BEGIN TRANSACTION spans batches.
        var payload: [UInt8] = []
        payload.appendLE(22, bytes: 4)
        payload.appendLE(18, bytes: 4)
        payload.appendLE(2, bytes: 2)
        payload += transaction.count == 8 ? transaction : [UInt8](repeating: 0, count: 8)
        payload.appendLE(1, bytes: 4)
        // GO separates batches, as in SSMS.
        let batches = sql.components(separatedBy: "\n").split { $0.trimmingCharacters(in: .whitespaces).uppercased() == "GO" }.map { $0.joined(separator: "\n") }
        var out: [QueryResult] = []
        for batch in batches where !batch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var p = payload
            p.replaceSubrange(10..<18, with: transaction.count == 8 ? transaction : [UInt8](repeating: 0, count: 8))
            do {
                out += try parse(try exchange(0x01, p + Self.utf16(batch)), rowLimit: rowLimit)
            } catch var e as DatabaseError {
                e.completed = out + e.completed
                throw e
            }
        }
        return out
    }

    /// An attention packet: the server stops the batch and confirms with DONE (attention).
    public func cancel() { try? send(0x06, []) }
    public func close() { socket.close() }
    deinit { close() }

    // MARK: Schema

    public func databases() throws -> [String] {
        try rows("SELECT name FROM sys.databases WHERE HAS_DBACCESS(name) = 1 ORDER BY CASE WHEN database_id <= 4 THEN 1 ELSE 0 END, name").compactMap { $0[0] }
    }

    public func use(database: String) throws { _ = try execute("USE \(dialect.quote(database))") }

    public func schemas() throws -> [String] {
        try rows("""
            SELECT s.name FROM sys.schemas s WHERE s.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'guest')
              AND s.name NOT LIKE 'db[_]%' ORDER BY CASE s.name WHEN 'dbo' THEN 0 ELSE 1 END, s.name
            """).compactMap { $0[0] }
    }

    public func objects(schema: String?) throws -> [DBObject] {
        let s = dialect.literal(schema ?? "dbo")
        return try rows("""
            SELECT o.name, o.type FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE s.name = \(s) AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF') AND o.is_ms_shipped = 0 ORDER BY o.name
            """).compactMap { r in
            guard let name = r[0], let type = r[1]?.trimmingCharacters(in: .whitespaces) else { return nil }
            let kind: DBObject.Kind = type == "U" ? .table : type == "V" ? .view : .function
            return DBObject(schema: schema ?? "dbo", name: name, kind: kind)
        }
    }

    private func objectID(_ t: TableRef) -> String { "OBJECT_ID(\(dialect.literal(dialect.qualified(t))))" }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        try rows("""
            SELECT c.name,
                   ty.name + CASE WHEN ty.name IN ('varchar','char','varbinary','binary') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length AS varchar) END + ')'
                                  WHEN ty.name IN ('nvarchar','nchar') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length / 2 AS varchar) END + ')'
                                  WHEN ty.name IN ('decimal','numeric') THEN '(' + CAST(c.precision AS varchar) + ',' + CAST(c.scale AS varchar) + ')' ELSE '' END,
                   c.is_nullable, OBJECT_DEFINITION(c.default_object_id),
                   CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                     WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 1 ELSE 0 END,
                   CAST(ep.value AS nvarchar(4000)), CASE WHEN c.is_identity = 1 THEN 'identity' WHEN c.is_computed = 1 THEN 'computed' END
            FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
            LEFT JOIN sys.extended_properties ep ON ep.major_id = c.object_id AND ep.minor_id = c.column_id AND ep.name = 'MS_Description'
            WHERE c.object_id = \(objectID(table)) ORDER BY c.column_id
            """).map { r in
            ColumnInfo(name: r[0] ?? "", type: r[1] ?? "", nullable: r[2] == "1", defaultValue: r[3], isPrimaryKey: r[4] == "1", comment: r[5], extra: r[6])
        }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        var byName: [String: IndexInfo] = [:]
        var order: [String] = []
        for r in try rows("""
            SELECT i.name, c.name, i.is_unique, i.is_primary_key FROM sys.indexes i
            JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE i.object_id = \(objectID(table)) AND i.name IS NOT NULL ORDER BY i.name, ic.key_ordinal
            """) {
            guard let name = r[0], let col = r[1] else { continue }
            if byName[name] == nil { order.append(name); byName[name] = IndexInfo(name: name, columns: [], unique: r[2] == "1", primary: r[3] == "1") }
            byName[name]!.columns.append(col)
        }
        return order.compactMap { byName[$0] }
    }

    public func definition(of object: DBObject) throws -> String? {
        if object.kind != .table { return try rows("SELECT OBJECT_DEFINITION(\(objectID(object.table)))").first?[0] ?? nil }
        let cols = try columns(of: object.table)
        var lines = cols.map { "  \(dialect.quote($0.name)) \($0.type)\($0.extra == "identity" ? " IDENTITY" : "")\($0.nullable ? "" : " NOT NULL")\($0.defaultValue.map { " DEFAULT \($0)" } ?? "")" }
        let pk = cols.filter(\.isPrimaryKey).map { dialect.quote($0.name) }
        if !pk.isEmpty { lines.append("  PRIMARY KEY (\(pk.joined(separator: ", ")))") }
        return "CREATE TABLE \(dialect.qualified(object.table)) (\n\(lines.joined(separator: ",\n"))\n);"
    }

    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] {
        var byName: [String: ForeignKeyInfo] = [:]
        var order: [String] = []
        for r in try rows("""
            SELECT fk.name, pc.name, SCHEMA_NAME(rt.schema_id), rt.name, rc.name, fk.update_referential_action_desc, fk.delete_referential_action_desc
            FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
            JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
            JOIN sys.tables rt ON rt.object_id = fkc.referenced_object_id
            JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
            WHERE fk.parent_object_id = \(objectID(table)) ORDER BY fk.name, fkc.constraint_column_id
            """) {
            guard let name = r[0], let col = r[1], let refTable = r[3], let refCol = r[4] else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = ForeignKeyInfo(name: name, columns: [], refSchema: r[2], refTable: refTable, refColumns: [],
                                              onUpdate: (r[5] ?? "NO_ACTION").replacingOccurrences(of: "_", with: " "),
                                              onDelete: (r[6] ?? "NO_ACTION").replacingOccurrences(of: "_", with: " "))
            }
            byName[name]!.columns.append(col)
            byName[name]!.refColumns.append(refCol)
        }
        return order.compactMap { byName[$0] }
    }

    public func estimatedCount(of table: TableRef) throws -> Int? {
        try rows("SELECT SUM(rows) FROM sys.partitions WHERE object_id = \(objectID(table)) AND index_id IN (0, 1)").first?[0].flatMap { $0 }.flatMap { Int($0) }
    }
}

/// A 128-bit unsigned magnitude with a sign, for DECIMAL and MONEY.
struct Int64Wide {
    var words: [UInt32]  // little-endian 32-bit words
    var negative = false

    init(_ v: Int64) {
        negative = v < 0
        let m = v.magnitude
        words = [UInt32(m & 0xFFFF_FFFF), UInt32(m >> 32), 0, 0]
    }

    init(bytes: [UInt8]) {
        var w: [UInt32] = []
        for i in stride(from: 0, to: 16, by: 4) {
            let b0 = UInt32(bytes[i]), b1 = UInt32(bytes[i + 1]) << 8
            let b2 = UInt32(bytes[i + 2]) << 16, b3 = UInt32(bytes[i + 3]) << 24
            w.append(b0 | b1 | b2 | b3)
        }
        words = w
    }

    var digits: String {
        var w = words
        var out: [Character] = []
        while w.contains(where: { $0 != 0 }) {
            var remainder: UInt64 = 0
            for i in stride(from: w.count - 1, through: 0, by: -1) {
                let cur = remainder << 32 | UInt64(w[i])
                w[i] = UInt32(cur / 10)
                remainder = cur % 10
            }
            out.append(Character(String(remainder)))
        }
        return out.isEmpty ? "0" : String(out.reversed())
    }
}

// MARK: - TDS 7 encryption

import Security

/// TLS the TDS 7 way: the handshake travels inside PRELOGIN packets, then TLS records go straight on the wire.
/// This uses SecureTransport (deprecated, but still in macOS) because it lets us carry the handshake inside
/// another protocol's packets; Network.framework only runs TLS directly on a socket.
/// With "login only" encryption (the server said ENCRYPT_OFF), TLS is dropped after the login packet.
final class TDSTLS: ByteStream, @unchecked Sendable {
    private let socket: Socket
    private var context: SSLContext!
    private var handshaking = true
    private var pending: [UInt8] = []  // handshake bytes from the server's PRELOGIN packets
    private var outgoing: [UInt8] = []  // our handshake bytes, sent as one PRELOGIN message per flight

    /// Sends what TLS wrote during this handshake flight as one TDS message.
    private func flush() throws {
        guard !outgoing.isEmpty else { return }
        var p: [UInt8] = [0x12, 0x01]
        p.appendInt16BE(Int16(outgoing.count + 8))
        p += [0, 0, 0, 0]
        try socket.write(p + outgoing)
        outgoing = []
    }
    private var plainBuffer: [UInt8] = []
    var dropAfterLogin = false
    private var active = true

    init(socket: Socket, host: String, tls: TLSOptions) throws {
        self.socket = socket
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else { throw DatabaseError("TLS couldn't start.") }
        context = ctx
        SSLSetIOFuncs(ctx, { connection, data, length in
            let me = Unmanaged<TDSTLS>.fromOpaque(connection).takeUnretainedValue()
            return me.ioRead(data, length)
        }, { connection, data, length in
            let me = Unmanaged<TDSTLS>.fromOpaque(connection).takeUnretainedValue()
            return me.ioWrite(data, length)
        })
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        SSLSetPeerDomainName(ctx, host, host.utf8.count)
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        if let identity = tls.identity { SSLSetCertificate(ctx, [identity] as CFArray) }
        var status: OSStatus
        repeat {
            status = SSLHandshake(ctx)
            if status == errSSLPeerAuthCompleted {
                guard tls.mode == .verify else { continue }
                var trust: SecTrust?
                SSLCopyPeerTrust(ctx, &trust)
                guard let trust else { throw DatabaseError("SQL Server's certificate couldn't be read.") }
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
                if !tls.anchors.isEmpty {
                    SecTrustSetAnchorCertificates(trust, tls.anchors as CFArray)
                    SecTrustSetAnchorCertificatesOnly(trust, true)
                }
                var error: CFError?
                if !SecTrustEvaluateWithError(trust, &error) {
                    throw DatabaseError("SQL Server's certificate isn't trusted for \(host).",
                                        detail: (error.map { ($0 as Error).localizedDescription } ?? "") + "\nUse TLS Require to connect without checking it.")
                }
            }
        } while status == errSSLWouldBlock || status == errSSLPeerAuthCompleted
        guard status == errSecSuccess else { throw DatabaseError("The TLS handshake with SQL Server failed (\(status)).") }
        try flush()
        handshaking = false
    }

    private func ioRead(_ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
        let wanted = length.pointee
        do {
            if handshaking {
                // During the handshake, the server's TLS bytes come inside TDS packets.
                try flush()
                while pending.count < wanted {
                    var h = ByteReader(try socket.read(8))
                    _ = h.byte(); _ = h.byte()
                    let len = Int(UInt16(bitPattern: h.int16BE()))
                    pending += try socket.read(len - 8)
                }
                pending.prefix(wanted).withUnsafeBufferPointer { data.copyMemory(from: $0.baseAddress!, byteCount: wanted) }
                pending.removeFirst(wanted)
            } else {
                let bytes = try socket.read(wanted)
                bytes.withUnsafeBufferPointer { data.copyMemory(from: $0.baseAddress!, byteCount: wanted) }
            }
            return errSecSuccess
        } catch {
            length.pointee = 0
            return errSSLClosedAbort
        }
    }

    private func ioWrite(_ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
        let bytes = Array(UnsafeRawBufferPointer(start: data, count: length.pointee))
        do {
            if handshaking {
                outgoing += bytes
            } else {
                try socket.write(bytes)
            }
            return errSecSuccess
        } catch {
            return errSSLClosedAbort
        }
    }

    func write(_ bytes: [UInt8]) throws {
        guard active else { return try socket.write(bytes) }
        var written = 0
        let status = bytes.withUnsafeBytes { SSLWrite(context, $0.baseAddress, bytes.count, &written) }
        guard status == errSecSuccess else { throw DatabaseError("The connection was lost (TLS \(status)).") }
        // Login-only encryption: everything after the login packet is plain again.
        if dropAfterLogin && bytes.first == 0x10 { active = false; SSLClose(context) }
    }

    func read(_ count: Int) throws -> [UInt8] {
        guard active else { return try socket.read(count) }
        var out = plainBuffer
        plainBuffer = []
        while out.count < count {
            var chunk = [UInt8](repeating: 0, count: max(count - out.count, 16384))
            var got = 0
            let status = chunk.withUnsafeMutableBytes { SSLRead(context, $0.baseAddress!, $0.count, &got) }
            if got > 0 { out += chunk.prefix(got) }
            if status != errSecSuccess && status != errSSLWouldBlock && got == 0 { throw DatabaseError("The connection was lost (TLS \(status)).") }
        }
        plainBuffer = Array(out.dropFirst(count))
        return Array(out.prefix(count))
    }

    func readByte() throws -> UInt8 { try read(1)[0] }

    func close() {
        if active { SSLClose(context) }
        socket.close()
    }
}

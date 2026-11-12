import CryptoKit
import Foundation

// MARK: - BSON

/// A BSON value. Documents keep their field order.
public indirect enum BSON: Equatable {
    case double(Double), string(String), document([(String, BSON)]), array([BSON]), binary(UInt8, Data), objectId(Data)
    case bool(Bool), date(Int64), null, regex(String, String), int32(Int32), timestamp(UInt64), int64(Int64), decimal(Data)
    case minKey, maxKey, undefined

    public static func == (a: BSON, b: BSON) -> Bool { a.shell == b.shell }

    subscript(_ key: String) -> BSON? {
        if case .document(let fields) = self { return fields.first { $0.0 == key }?.1 }
        return nil
    }

    var int: Int? {
        switch self {
        case .int32(let v): Int(v)
        case .int64(let v): Int(v)
        case .double(let v): Int(v)
        default: nil
        }
    }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var arrayValue: [BSON] { if case .array(let a) = self { return a }; return [] }
    var fields: [(String, BSON)] { if case .document(let f) = self { return f }; return [] }

    var typeName: String {
        switch self {
        case .double: "double"
        case .string: "string"
        case .document: "object"
        case .array: "array"
        case .binary: "binData"
        case .objectId: "objectId"
        case .bool: "bool"
        case .date: "date"
        case .null: "null"
        case .regex: "regex"
        case .int32: "int"
        case .timestamp: "timestamp"
        case .int64: "long"
        case .decimal: "decimal"
        default: "other"
        }
    }

    // Encoding

    func encodeDocument() -> [UInt8] {
        guard case .document(let fields) = self else { return BSON.document([]).encodeDocument() }
        var body: [UInt8] = []
        for (k, v) in fields { body += v.element(k) }
        body.append(0)
        return le32(Int32(body.count + 4)) + body
    }

    private func le32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    private func le64(_ v: Int64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    private func cstr(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

    private func element(_ key: String) -> [UInt8] {
        let k = cstr(key)
        switch self {
        case .double(let d): return [0x01] + k + withUnsafeBytes(of: d.bitPattern.littleEndian, Array.init)
        case .string(let s): let b = Array(s.utf8); return [0x02] + k + le32(Int32(b.count + 1)) + b + [0]
        case .document: return [0x03] + k + encodeDocument()
        case .array(let items):
            return [0x04] + k + BSON.document(items.enumerated().map { (String($0.offset), $0.element) }).encodeDocument()
        case .binary(let sub, let data): return [0x05] + k + le32(Int32(data.count)) + [sub] + Array(data)
        case .objectId(let id): return [0x07] + k + Array(id)
        case .bool(let b): return [0x08] + k + [b ? 1 : 0]
        case .date(let ms): return [0x09] + k + le64(ms)
        case .null: return [0x0A] + k
        case .regex(let p, let o): return [0x0B] + k + cstr(p) + cstr(String(o.sorted()))
        case .int32(let i): return [0x10] + k + le32(i)
        case .timestamp(let t): return [0x11] + k + withUnsafeBytes(of: t.littleEndian, Array.init)
        case .int64(let i): return [0x12] + k + le64(i)
        case .decimal(let d): return [0x13] + k + Array(d)
        case .minKey: return [0xFF] + k
        case .maxKey: return [0x7F] + k
        case .undefined: return [0x06] + k
        }
    }

    // Decoding

    static func decode(_ bytes: [UInt8], at start: Int = 0) throws -> (BSON, Int) {
        var r = ByteReader(bytes)
        r.pos = start
        let length = Int(Int32(truncatingIfNeeded: r.intLE(4)))
        let end = start + length
        guard length >= 5, end <= bytes.count else { throw DatabaseError("MongoDB sent a malformed document.") }
        var fields: [(String, BSON)] = []
        while r.pos < end - 1 {
            let type = r.byte()
            let key = r.cString()
            let value: BSON
            switch type {
            case 0x01: value = .double(Double(bitPattern: r.intLE(8)))
            case 0x02, 0x0D, 0x0E:
                let n = Int(Int32(truncatingIfNeeded: r.intLE(4)))
                value = .string(String(decoding: r.take(n - 1), as: UTF8.self)); _ = r.byte()
            case 0x03, 0x04:
                let (doc, len) = try decode(bytes, at: r.pos)
                r.pos += len
                value = type == 0x03 ? doc : .array(doc.fields.map(\.1))
            case 0x05:
                let n = Int(Int32(truncatingIfNeeded: r.intLE(4)))
                let sub = r.byte()
                value = .binary(sub, Data(r.take(n)))
            case 0x06: value = .undefined
            case 0x07: value = .objectId(Data(r.take(12)))
            case 0x08: value = .bool(r.byte() != 0)
            case 0x09: value = .date(Int64(bitPattern: r.intLE(8)))
            case 0x0A: value = .null
            case 0x0B: let p = r.cString(); value = .regex(p, r.cString())
            case 0x10: value = .int32(Int32(truncatingIfNeeded: r.intLE(4)))
            case 0x11: value = .timestamp(r.intLE(8))
            case 0x12: value = .int64(Int64(bitPattern: r.intLE(8)))
            case 0x13: value = .decimal(Data(r.take(16)))
            case 0xFF: value = .minKey
            case 0x7F: value = .maxKey
            default: throw DatabaseError("MongoDB sent a value of a kind this app doesn't read (0x\(String(type, radix: 16))).")
            }
            fields.append((key, value))
        }
        return (.document(fields), length)
    }

    // Display: shell syntax, as mongosh shows it.

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var shell: String {
        switch self {
        case .double(let d): return d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
        case .string(let s): return MongoText.jsonString(s)
        case .document(let f): return f.isEmpty ? "{}" : "{ " + f.map { "\(MongoText.key($0.0)): \($0.1.shell)" }.joined(separator: ", ") + " }"
        case .array(let a): return "[" + a.map(\.shell).joined(separator: ", ") + "]"
        case .binary(4, let d) where d.count == 16:
            return "UUID(\"\(UUID(uuid: d.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString.lowercased())\")"
        case .binary(let sub, let d): return "BinData(\(sub), \"\(d.base64EncodedString())\")"
        case .objectId(let id): return "ObjectId(\"\(id.map { String(format: "%02x", $0) }.joined())\")"
        case .bool(let b): return b ? "true" : "false"
        case .date(let ms): return "ISODate(\"\(Self.isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)))\")"
        case .null: return "null"
        case .regex(let p, let o): return "/\(p)/\(o)"
        case .int32(let i): return String(i)
        case .timestamp(let t): return "Timestamp(\(t >> 32), \(t & 0xFFFF_FFFF))"
        case .int64(let i): return String(i)
        case .decimal(let d): return "NumberDecimal(\"\(Self.decimalString(d))\")"
        case .minKey: return "MinKey()"
        case .maxKey: return "MaxKey()"
        case .undefined: return "undefined"
        }
    }

    /// How a top-level field shows in a cell: strings without quotes, everything else in shell syntax.
    var cell: String? {
        switch self {
        case .string(let s): s
        case .null, .undefined: nil
        default: shell
        }
    }

    /// Decimal128 to text (enough for normal values; NaN/Infinity aside).
    static func decimalString(_ d: Data) -> String {
        let low = d.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }.littleEndian
        let high = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }.littleEndian
        let negative = high >> 63 == 1
        let exponent = Int((high >> 49) & 0x3FFF) - 6176
        let coeffHigh = high & 0x1FFFF_FFFF_FFFF
        // 113-bit coefficient: build it in decimal.
        var digits = [UInt8](repeating: 0, count: 1)
        func mulAdd(_ m: UInt64, _ a: UInt64) {
            var carry = a
            for i in 0..<digits.count {
                let v = UInt64(digits[i]) * m + carry
                digits[i] = UInt8(v % 10); carry = v / 10
            }
            while carry > 0 { digits.append(UInt8(carry % 10)); carry /= 10 }
        }
        for word in [coeffHigh >> 32, coeffHigh & 0xFFFF_FFFF, low >> 32, low & 0xFFFF_FFFF] { mulAdd(1 << 32, word) }
        var s = String(digits.reversed().map { Character(String($0)) }).drop { $0 == "0" }
        if s.isEmpty { s = "0" }
        var text = String(s)
        if exponent < 0 {
            let places = -exponent
            if text.count <= places { text = String(repeating: "0", count: places - text.count + 1) + text }
            text.insert(".", at: text.index(text.endIndex, offsetBy: -places))
        } else if exponent > 0 {
            text += String(repeating: "0", count: exponent)
        }
        return (negative ? "-" : "") + text
    }
}

// MARK: - Shell syntax: parsing and writing

public enum MongoText {
    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    static func key(_ k: String) -> String {
        k.first.map { $0.isLetter || $0 == "_" || $0 == "$" } == true && k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) ? k : jsonString(k)
    }

    /// Parses shell values: relaxed JSON (unquoted keys, single quotes, trailing commas) plus ObjectId(),
    /// ISODate(), new Date(), NumberLong(), NumberInt(), NumberDecimal(), UUID(), BinData(), /regex/.
    struct Parser {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skip() {
            while i < chars.count {
                if chars[i].isWhitespace { i += 1 }
                else if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" { while i < chars.count && chars[i] != "\n" { i += 1 } }
                else { break }
            }
        }

        var atEnd: Bool { mutating get { skip(); return i >= chars.count } }
        mutating func peek() -> Character? { skip(); return i < chars.count ? chars[i] : nil }

        mutating func expect(_ c: Character) throws {
            guard peek() == c else { throw DatabaseError("Expected \(c) at position \(i + 1)\(i < chars.count ? " but found \(chars[i])" : "").") }
            i += 1
        }

        mutating func identifier() -> String {
            skip()
            let start = i
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" { i += 1 }
            return String(chars[start..<i])
        }

        mutating func string() throws -> String {
            let q = chars[i]
            i += 1
            var out = ""
            while i < chars.count, chars[i] != q {
                if chars[i] == "\\", i + 1 < chars.count {
                    i += 1
                    switch chars[i] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "u":
                        let hex = String(chars[(i + 1)..<min(chars.count, i + 5)])
                        if let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) { out.unicodeScalars.append(sc) }
                        i += 4
                    default: out.append(chars[i])
                    }
                } else {
                    out.append(chars[i])
                }
                i += 1
            }
            guard i < chars.count else { throw DatabaseError("A string isn't closed.") }
            i += 1
            return out
        }

        mutating func value() throws -> BSON {
            guard let c = peek() else { throw DatabaseError("Expected a value.") }
            switch c {
            case "{":
                i += 1
                var fields: [(String, BSON)] = []
                while peek() != "}" {
                    let k: String
                    if peek() == "\"" || peek() == "'" { k = try string() } else { k = identifier() }
                    guard !k.isEmpty else { throw DatabaseError("Expected a field name at position \(i + 1).") }
                    try expect(":")
                    fields.append((k, try value()))
                    if peek() == "," { i += 1 } else { break }
                }
                try expect("}")
                return .document(fields)
            case "[":
                i += 1
                var items: [BSON] = []
                while peek() != "]" {
                    items.append(try value())
                    if peek() == "," { i += 1 } else { break }
                }
                try expect("]")
                return .array(items)
            case "\"", "'":
                return .string(try string())
            case "/":
                i += 1
                var pattern = ""
                while i < chars.count, chars[i] != "/" {
                    if chars[i] == "\\", i + 1 < chars.count { pattern.append(chars[i]); i += 1 }
                    pattern.append(chars[i]); i += 1
                }
                i += 1
                var flags = ""
                while i < chars.count, chars[i].isLetter { flags.append(chars[i]); i += 1 }
                return .regex(pattern, flags)
            case "-", "+", "0"..."9", ".":
                let start = i
                i += 1
                while i < chars.count, chars[i].isNumber || ".eE+-".contains(chars[i]) { i += 1 }
                let text = String(chars[start..<i])
                if !text.contains(where: { ".eE".contains($0) }), let n = Int64(text) {
                    return n >= Int64(Int32.min) && n <= Int64(Int32.max) ? .int32(Int32(n)) : .int64(n)
                }
                guard let d = Double(text) else { throw DatabaseError("\(text) isn't a number.") }
                return .double(d)
            default:
                var name = identifier()
                if name == "new" { name = identifier() }
                switch name {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "null": return .null
                case "undefined": return .undefined
                case "MinKey", "MaxKey":
                    if peek() == "(" { i += 1; try expect(")") }
                    return name == "MinKey" ? .minKey : .maxKey
                case "":
                    throw DatabaseError("Unexpected \(c) at position \(i + 1).")
                default:
                    try expect("(")
                    var args: [BSON] = []
                    while peek() != ")" {
                        args.append(try value())
                        if peek() == "," { i += 1 } else { break }
                    }
                    try expect(")")
                    return try call(name, args)
                }
            }
        }

        func call(_ name: String, _ args: [BSON]) throws -> BSON {
            let text = args.first?.stringValue
            switch name {
            case "ObjectId", "ObjectID":
                guard let hex = text?.lowercased(), hex.count == 24, let data = Data(hexString: hex) else {
                    if args.isEmpty { return .objectId(Data(Crypto.randomBytes(12))) }
                    throw DatabaseError("ObjectId needs 24 hex characters.")
                }
                return .objectId(data)
            case "ISODate", "Date":
                guard let text else { return .date(Int64(Date().timeIntervalSince1970 * 1000)) }
                return .date(Int64((try MongoText.date(text)).timeIntervalSince1970 * 1000))
            case "NumberLong": return .int64(args.first?.int.map(Int64.init) ?? Int64(text ?? "") ?? 0)
            case "NumberInt": return .int32(Int32(args.first?.int ?? Int(text ?? "") ?? 0))
            case "NumberDecimal", "Decimal128":
                guard let text, let d = Decimal(string: text) else { throw DatabaseError("NumberDecimal needs a number in quotes.") }
                return .double(NSDecimalNumber(decimal: d).doubleValue)
            case "UUID":
                guard let text, let u = UUID(uuidString: text) else { throw DatabaseError("UUID needs a UUID in quotes.") }
                return .binary(4, withUnsafeBytes(of: u.uuid) { Data($0) })
            case "BinData":
                guard args.count == 2, let sub = args[0].int, let b64 = args[1].stringValue, let d = Data(base64Encoded: b64) else {
                    throw DatabaseError("BinData needs a subtype and base64 text.")
                }
                return .binary(UInt8(sub), d)
            case "Timestamp":
                return .timestamp(UInt64(args.first?.int ?? 0) << 32 | UInt64(args.count > 1 ? args[1].int ?? 0 : 0))
            default:
                throw DatabaseError("\(name)() isn't something this app knows.")
            }
        }
    }

    static func date(_ s: String) throws -> Date {
        let f = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS"] {
            df.dateFormat = format
            if let d = df.date(from: s) { return d }
        }
        throw DatabaseError("\(s) isn't a date this app can read.")
    }

    public static func parse(_ s: String) throws -> BSON {
        var p = Parser(s)
        let v = try p.value()
        guard p.atEnd else { throw DatabaseError("Unexpected text after the value at position \(p.i + 1).") }
        return v
    }

    /// What a typed cell becomes: shell syntax when it parses as a value, otherwise a string.
    /// In a string column, text stays a string unless it's written in quotes or shell syntax that isn't a number.
    public static func value(_ text: String, type: String? = nil) -> BSON {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = try? parse(trimmed) else { return .string(text) }
        if type == "string", case .string = parsed { return parsed }
        if type == "string" { switch parsed { case .int32, .int64, .double, .bool, .null: return .string(text); default: return parsed } }
        return parsed
    }

    static func literal(_ text: String, type: String? = nil) -> String { value(text, type: type).shell }

    // Commands the app writes.

    static func collection(_ table: TableRef) -> String { "db.getCollection(\(jsonString(table.name)))" }

    static func filter(_ filters: [Filter], types: [String: String] = [:]) -> String? {
        var parts: [String] = []
        for f in filters where f.enabled {
            if f.op == .sql {
                if !f.value.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(f.value) }
                continue
            }
            guard !f.column.isEmpty else { continue }
            let k = key(f.column)
            let v = literal(f.value, type: types[f.column])
            func regex(_ p: String) -> String { "{ $regex: \(jsonString(p)), $options: \"i\" }" }
            let escaped = NSRegularExpression.escapedPattern(for: f.value)
            switch f.op {
            case .equals: parts.append("{ \(k): \(v) }")
            case .notEquals: parts.append("{ \(k): { $ne: \(v) } }")
            case .less: parts.append("{ \(k): { $lt: \(v) } }")
            case .greater: parts.append("{ \(k): { $gt: \(v) } }")
            case .lessOrEqual: parts.append("{ \(k): { $lte: \(v) } }")
            case .greaterOrEqual: parts.append("{ \(k): { $gte: \(v) } }")
            case .contains: parts.append("{ \(k): \(regex(escaped)) }")
            case .notContains: parts.append("{ \(k): { $not: { $regex: \(jsonString(escaped)), $options: \"i\" } } }")
            case .startsWith: parts.append("{ \(k): \(regex("^" + escaped)) }")
            case .endsWith: parts.append("{ \(k): \(regex(escaped + "$")) }")
            case .in: parts.append("{ \(k): { $in: [\(f.value.split(separator: ",").map { literal($0.trimmingCharacters(in: .whitespaces), type: types[f.column]) }.joined(separator: ", "))] } }")
            case .isNull: parts.append("{ \(k): null }")
            case .isNotNull: parts.append("{ \(k): { $ne: null } }")
            case .sql: break
            }
        }
        if parts.isEmpty { return nil }
        return parts.count == 1 ? parts[0] : "{ $and: [\(parts.joined(separator: ", "))] }"
    }

    static func page(_ table: TableRef, filter: String?, order: [(column: String, ascending: Bool)], limit: Int, offset: Int) -> String {
        var s = "\(collection(table)).find(\(filter ?? "{}"))"
        if !order.isEmpty { s += ".sort({ " + order.map { "\(key($0.column)): \($0.ascending ? 1 : -1)" }.joined(separator: ", ") + " })" }
        if offset > 0 { s += ".skip(\(offset))" }
        return s + ".limit(\(limit))"
    }

    static func count(_ table: TableRef, filter: String?) -> String { "\(collection(table)).countDocuments(\(filter ?? "{}"))" }

    /// Edits as updateOne / deleteOne / insertOne, found by _id.
    static func statements(for changes: ChangeSet, table: TableRef, columns: [ResultColumn]) throws -> [String] {
        guard let idIndex = columns.firstIndex(where: { $0.name == "_id" }) else {
            throw DatabaseError("Documents are found by _id, which isn't in this result.")
        }
        let c = collection(table)
        func idFilter(_ original: [String?]) throws -> String {
            guard let id = original[idIndex] else { throw DatabaseError("A document without _id can't be changed here.") }
            return "{ _id: \(literal(id, type: columns[idIndex].typeName)) }"
        }
        var out: [String] = []
        for row in changes.deletes.sorted() {
            guard let original = changes.originals[row] else { continue }
            out.append("\(c).deleteOne(\(try idFilter(original)))")
        }
        for row in changes.updates.keys.sorted() where !changes.deletes.contains(row) {
            guard let original = changes.originals[row], let edits = changes.updates[row], !edits.isEmpty else { continue }
            if edits[idIndex] != nil { throw DatabaseError("_id can't be changed; duplicate the document and delete the old one instead.") }
            let sets = edits.keys.sorted().map { i in "\(key(columns[i].name)): \(edits[i]!.map { literal($0, type: columns[i].typeName) } ?? "null")" }
            out.append("\(c).updateOne(\(try idFilter(original)), { $set: { \(sets.joined(separator: ", ")) } })")
        }
        for insert in changes.inserts {
            let fields = insert.values.keys.sorted().compactMap { i -> String? in
                guard let v = insert.values[i] ?? nil else { return nil }
                return "\(key(columns[i].name)): \(literal(v, type: columns[i].typeName))"
            }
            out.append("\(c).insertOne({ \(fields.joined(separator: ", ")) })")
        }
        return out
    }

    // Splitting a script into commands: on ; and on new lines that start a new command, outside brackets.

    static func commands(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        let chars = Array(text)
        var i = 0
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !t.hasPrefix("//") { out.append(t) }
            current = ""
        }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if c == "\\", i + 1 < chars.count { current.append(chars[i + 1]); i += 2; continue }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c; current.append(c)
            } else if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            } else if "({[".contains(c) {
                depth += 1; current.append(c)
            } else if ")}]".contains(c) {
                depth -= 1; current.append(c)
            } else if c == ";" && depth == 0 {
                flush()
            } else if c == "\n" && depth == 0 {
                let rest = String(chars[(i + 1)...].prefix(20)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(".") { current.append(c) } else { flush() }
            } else {
                current.append(c)
            }
            i += 1
        }
        flush()
        return out
    }
}

extension Data {
    init?(hexString: String) {
        var data = Data(capacity: hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            guard let j = hexString.index(i, offsetBy: 2, limitedBy: hexString.endIndex), let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        self = data
    }
}

// MARK: - Driver

/// MongoDB over OP_MSG (MongoDB 3.6 and later). Collections show as tables whose columns come from the
/// documents' top-level fields; the query editor takes mongosh-style commands.
public final class MongoDriver: Driver {
    public let kind = DatabaseKind.mongodb
    public let dialect = Dialect(kind: .mongodb)
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?
    private var socket: Socket
    private var requestID: Int32 = 1
    private let authSource: String
    private let host: String
    private let port: Int

    public init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions, options: [String: String]) throws {
        var hosts: [(String, Int)] = host.split(separator: ",").map { part in
            let p = part.split(separator: ":")
            return (String(p[0]), p.count > 1 ? Int(p[1]) ?? port : port)
        }
        var authSource = options["authSource"] ?? (database.isEmpty ? "admin" : database)
        if options["srv"] == "1", let first = hosts.first {
            let srv = try Self.lookupSRV(first.0)
            if srv.isEmpty { throw DatabaseError("No MongoDB servers are listed for \(first.0).") }
            hosts = srv
            if options["authSource"] == nil, let txt = Self.lookupTXT(first.0), let src = txt["authSource"] { authSource = src }
        }
        self.authSource = authSource
        var lastError: Error = DatabaseError("No MongoDB server to connect to.")
        var connected: (Socket, String, Int)?
        // Use the writable primary of a replica set; a standalone server is its own primary.
        for (h, p) in hosts {
            do {
                let s = try Socket(host: h, port: p)
                if tls.mode != .off { s.startTLS(tls) }
                socket = s
                let hello = try Self.command(s, [("hello", .int32(1)), ("$db", .string("admin"))], &requestID)
                if hello["isWritablePrimary"] == .bool(true) || hello["ismaster"] == .bool(true) || hosts.count == 1 {
                    connected = (s, h, p); break
                }
                s.close()
            } catch { lastError = error }
        }
        guard let connected else { throw lastError }
        socket = connected.0
        self.host = connected.1
        self.port = connected.2
        if !user.isEmpty {
            let mechanism = options["authMechanism"] ?? "SCRAM-SHA-256"
            do {
                try authenticate(user: user, password: password, mechanism: mechanism)
            } catch where options["authMechanism"] == nil {
                // Servers before 4.0, or users made for SCRAM-SHA-1 only.
                try authenticate(user: user, password: password, mechanism: "SCRAM-SHA-1")
            }
        }
        currentDatabase = database.isEmpty ? "test" : database
        serverVersion = (try? run([("buildInfo", .int32(1))], db: "admin"))?["version"]?.stringValue ?? ""
    }

    // MARK: Wire

    private static func command(_ socket: Socket, _ doc: [(String, BSON)], _ requestID: inout Int32) throws -> BSON {
        let body = BSON.document(doc).encodeDocument()
        var msg: [UInt8] = []
        msg.appendLE(UInt32(16 + 4 + 1 + body.count), bytes: 4)
        msg.appendLE(UInt32(bitPattern: requestID), bytes: 4)
        requestID &+= 1
        msg.appendLE(0, bytes: 4)
        msg.appendLE(2013, bytes: 4)  // OP_MSG
        msg.appendLE(0, bytes: 4)  // flags
        msg.append(0)  // section kind 0: body
        msg += body
        try socket.write(msg)
        var header = ByteReader(try socket.read(16))
        let length = Int(header.intLE(4))
        _ = header.intLE(8)
        let opcode = header.intLE(4)
        let payload = try socket.read(length - 16)
        guard opcode == 2013 else { throw DatabaseError("MongoDB answered with an old message type (\(opcode)); it needs to be 3.6 or newer.") }
        var r = ByteReader(payload)
        _ = r.intLE(4)
        guard r.byte() == 0 else { throw DatabaseError("MongoDB sent an unexpected reply.") }
        let (doc, _) = try BSON.decode(payload, at: r.pos)
        return doc
    }

    /// Runs a command; a failed command (ok: 0) becomes an error.
    @discardableResult
    func run(_ doc: [(String, BSON)], db: String? = nil) throws -> BSON {
        let reply = try Self.command(socket, doc + [("$db", .string(db ?? currentDatabase ?? "test"))], &requestID)
        if let ok = reply["ok"], ok.int != 1 && ok != .bool(true) && (ok.int ?? 0) == 0 {
            throw DatabaseError(reply["errmsg"]?.stringValue ?? "The command failed.", code: reply["codeName"]?.stringValue)
        }
        if let errors = reply["writeErrors"]?.arrayValue, let first = errors.first {
            throw DatabaseError(first["errmsg"]?.stringValue ?? "The write failed.", code: first["code"]?.int.map(String.init))
        }
        return reply
    }

    // MARK: Auth (SCRAM-SHA-256 and SCRAM-SHA-1)

    private func authenticate(user: String, password: String, mechanism: String) throws {
        let sha1 = mechanism == "SCRAM-SHA-1"
        // SHA-1 uses the old MongoDB password digest as its password.
        let secret = sha1 ? Insecure.MD5.hash(data: Data("\(user):mongo:\(password)".utf8)).map { String(format: "%02x", $0) }.joined()
                          : password.precomposedStringWithCompatibilityMapping
        let nonce = Data(Crypto.randomBytes(24)).base64EncodedString()
        let escapedUser = user.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
        let firstBare = "n=\(escapedUser),r=\(nonce)"
        var reply = try run([("saslStart", .int32(1)), ("mechanism", .string(mechanism)),
                             ("payload", .binary(0, Data(("n,," + firstBare).utf8))), ("autoAuthorize", .int32(1)),
                             ("options", .document([("skipEmptyExchange", .bool(true))]))], db: authSource)
        guard case .binary(_, let serverFirstData) = reply["payload"] ?? .null else { throw DatabaseError("MongoDB didn't start the sign-in.") }
        let serverFirst = String(decoding: serverFirstData, as: UTF8.self)
        var f: [Character: String] = [:]
        for part in serverFirst.split(separator: ",") where part.count > 2 { f[part.first!] = String(part.dropFirst(2)) }
        guard let r = f["r"], r.hasPrefix(nonce), let s = f["s"], let salt = Data(base64Encoded: s), let i = f["i"].flatMap(Int.init) else {
            throw DatabaseError("MongoDB's sign-in reply was malformed.")
        }
        let withoutProof = "c=biws,r=\(r)"
        let auth = Array("\(firstBare),\(serverFirst),\(withoutProof)".utf8)
        let proof: [UInt8]
        let serverSignature: [UInt8]
        if sha1 {
            let salted = Self.pbkdf2SHA1(Array(secret.utf8), salt: Array(salt), iterations: i)
            let clientKey = Array(HMAC<Insecure.SHA1>.authenticationCode(for: Array("Client Key".utf8), using: SymmetricKey(data: salted)))
            let stored = Array(Insecure.SHA1.hash(data: clientKey))
            proof = Crypto.xor(clientKey, Array(HMAC<Insecure.SHA1>.authenticationCode(for: auth, using: SymmetricKey(data: stored))))
            let serverKey = Array(HMAC<Insecure.SHA1>.authenticationCode(for: Array("Server Key".utf8), using: SymmetricKey(data: salted)))
            serverSignature = Array(HMAC<Insecure.SHA1>.authenticationCode(for: auth, using: SymmetricKey(data: serverKey)))
        } else {
            let salted = Crypto.pbkdf2SHA256(password: Array(secret.utf8), salt: Array(salt), iterations: i)
            let clientKey = Crypto.hmacSHA256(key: salted, Array("Client Key".utf8))
            proof = Crypto.xor(clientKey, Crypto.hmacSHA256(key: Crypto.sha256(clientKey), auth))
            serverSignature = Crypto.hmacSHA256(key: Crypto.hmacSHA256(key: salted, Array("Server Key".utf8)), auth)
        }
        let conversation = reply["conversationId"] ?? .int32(1)
        reply = try run([("saslContinue", .int32(1)), ("conversationId", conversation),
                         ("payload", .binary(0, Data("\(withoutProof),p=\(Data(proof).base64EncodedString())".utf8)))], db: authSource)
        if case .binary(_, let final) = reply["payload"] ?? .null {
            let text = String(decoding: final, as: UTF8.self)
            if text.hasPrefix("v="), Data(base64Encoded: String(text.dropFirst(2))).map(Array.init) != serverSignature {
                throw DatabaseError("MongoDB's sign-in signature didn't match.")
            }
        }
        while reply["done"] != .bool(true) {
            reply = try run([("saslContinue", .int32(1)), ("conversationId", conversation), ("payload", .binary(0, Data()))], db: authSource)
        }
    }

    static func pbkdf2SHA1(_ password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        // PBKDF2 with HMAC-SHA1, one 20-byte block.
        let key = SymmetricKey(data: password)
        var u = Array(HMAC<Insecure.SHA1>.authenticationCode(for: salt + [0, 0, 0, 1], using: key))
        var out = u
        for _ in 1..<iterations {
            u = Array(HMAC<Insecure.SHA1>.authenticationCode(for: u, using: key))
            out = Crypto.xor(out, u)
        }
        return out
    }

    // MARK: DNS for mongodb+srv

    static func dig(_ args: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        p.arguments = ["+short"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    static func lookupSRV(_ host: String) throws -> [(String, Int)] {
        dig(["SRV", "_mongodb._tcp.\(host)"]).compactMap { line in
            let p = line.split(separator: " ")
            guard p.count == 4, let port = Int(p[2]) else { return nil }
            return (String(p[3]).trimmingCharacters(in: CharacterSet(charactersIn: ".")), port)
        }
    }

    static func lookupTXT(_ host: String) -> [String: String]? {
        guard let line = dig(["TXT", host]).first else { return nil }
        var out: [String: String] = [:]
        for pair in line.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    // MARK: Results

    /// Documents as rows: one column per top-level field (first seen first, _id first).
    static func table(_ docs: [BSON], truncated: Bool = false) -> QueryResult {
        var names: [String] = []
        var seen = Set<String>()
        var types: [String: [String: Int]] = [:]
        if docs.contains(where: { $0["_id"] != nil }) { names.append("_id"); seen.insert("_id") }
        for d in docs {
            for (k, v) in d.fields {
                if seen.insert(k).inserted { names.append(k) }
                types[k, default: [:]][v.typeName, default: 0] += 1
            }
        }
        if docs.contains(where: { if case .document = $0 { false } else { true } }) {
            // Not documents (distinct, scalar results): one value column.
            return QueryResult(columns: [ResultColumn(name: "value", typeName: "")], rows: docs.map { [$0.cell] }, truncated: truncated)
        }
        let columns = names.map { n in
            ResultColumn(name: n, typeName: types[n]?.filter { $0.key != "null" }.max { $0.value < $1.value }?.key ?? "null", isBinary: false)
        }
        let rows = docs.map { d in names.map { d[$0]?.cell } }
        return QueryResult(columns: columns, rows: rows, message: "\(rows.count) document\(rows.count == 1 ? "" : "s")", truncated: truncated)
    }

    private func cursor(_ first: BSON, limit: Int) throws -> (docs: [BSON], truncated: Bool) {
        guard let cursor = first["cursor"] else { return ([], false) }
        var docs = cursor["firstBatch"]?.arrayValue ?? []
        var id = cursor["id"] ?? .int64(0)
        let ns = cursor["ns"]?.stringValue ?? ""
        let collection = ns.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""
        while (id.int ?? 0) != 0 && docs.count < limit {
            let more = try run([("getMore", id), ("collection", .string(collection))])
            docs += more["cursor"]?["nextBatch"]?.arrayValue ?? []
            id = more["cursor"]?["id"] ?? .int64(0)
        }
        if (id.int ?? 0) != 0 { _ = try? run([("killCursors", .string(collection)), ("cursors", .array([id]))]) }
        let truncated = docs.count > limit || (id.int ?? 0) != 0
        return (Array(docs.prefix(limit)), truncated)
    }

    // MARK: Running commands

    public func execute(_ sql: String, rowLimit: Int) throws -> [QueryResult] {
        var results: [QueryResult] = []
        for text in MongoText.commands(sql) {
            do { results.append(try executeOne(text, rowLimit: rowLimit)) } catch var e as DatabaseError {
                e.completed = results
                throw e
            }
        }
        return results
    }

    private struct Call { var name: String; var args: [BSON] }

    private func executeOne(_ text: String, rowLimit: Int) throws -> QueryResult {
        let lower = text.lowercased()
        if lower == "show dbs" || lower == "show databases" {
            return QueryResult(columns: [ResultColumn(name: "database", typeName: "string")], rows: try databases().map { [$0] })
        }
        if lower == "show collections" || lower == "show tables" {
            return QueryResult(columns: [ResultColumn(name: "collection", typeName: "string")], rows: try objects(schema: nil).map { [$0.name] })
        }
        if lower.hasPrefix("use ") {
            let name = String(text.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: " ;\"'"))
            try use(database: name)
            return QueryResult(message: "switched to db \(name)")
        }
        // db.<collection>.<method>(…).<method>(…) or db.<method>(…)
        var p = MongoText.Parser(text)
        guard p.identifier() == "db" else { throw DatabaseError("Commands start with db., show dbs, show collections or use <database>.") }
        var collection: String?
        var calls: [Call] = []
        while let c = p.peek() {
            if c == "." {
                p.i += 1
                let name = p.identifier()
                if p.peek() == "(" {
                    p.i += 1
                    var args: [BSON] = []
                    while p.peek() != ")" {
                        args.append(try p.value())
                        if p.peek() == "," { p.i += 1 } else { break }
                    }
                    try p.expect(")")
                    if name == "getCollection", calls.isEmpty, collection == nil { collection = args.first?.stringValue; continue }
                    calls.append(Call(name: name, args: args))
                } else if collection == nil && calls.isEmpty {
                    collection = name
                } else {
                    throw DatabaseError("Expected ( after \(name).")
                }
            } else if c == "[" {
                p.i += 1
                guard case .string(let name) = try p.value() else { throw DatabaseError("Expected a collection name in [\"…\"].") }
                try p.expect("]")
                collection = name
            } else {
                throw DatabaseError("Unexpected \(c) at position \(p.i + 1).")
            }
        }
        guard let first = calls.first else { throw DatabaseError("Nothing to run: add a method like .find().") }
        if let collection { return try collectionCall(collection, first, Array(calls.dropFirst()), rowLimit: rowLimit) }
        return try databaseCall(first, rowLimit: rowLimit)
    }

    private func databaseCall(_ call: Call, rowLimit: Int) throws -> QueryResult {
        switch call.name {
        case "runCommand", "adminCommand":
            guard case .document(let fields) = call.args.first ?? .null else { throw DatabaseError("runCommand needs a document.") }
            let reply = try run(fields, db: call.name == "adminCommand" ? "admin" : nil)
            if reply["cursor"] != nil { let c = try cursor(reply, limit: rowLimit); return Self.table(c.docs, truncated: c.truncated) }
            return Self.table([reply])
        case "getCollectionNames":
            return QueryResult(columns: [ResultColumn(name: "collection", typeName: "string")], rows: try objects(schema: nil).map { [$0.name] })
        case "createCollection":
            guard let name = call.args.first?.stringValue else { throw DatabaseError("createCollection needs a name.") }
            try run([("create", .string(name))] + (call.args.count > 1 ? call.args[1].fields : []))
            return QueryResult(message: "Created \(name)")
        case "dropDatabase":
            try run([("dropDatabase", .int32(1))])
            return QueryResult(message: "Dropped \(currentDatabase ?? "")")
        case "getName":
            return QueryResult(columns: [ResultColumn(name: "value", typeName: "string")], rows: [[currentDatabase]])
        default:
            throw DatabaseError("db.\(call.name)() isn't supported here; use db.runCommand({ … }).")
        }
    }

    private func collectionCall(_ collection: String, _ call: Call, _ chain: [Call], rowLimit: Int) throws -> QueryResult {
        let c = BSON.string(collection)
        let a = call.args
        func doc(_ i: Int) -> BSON { a.count > i ? a[i] : .document([]) }
        func written(_ reply: BSON, _ verb: String) -> QueryResult {
            let n = reply["nModified"]?.int ?? reply["n"]?.int ?? 0
            let matched = reply["n"]?.int ?? n
            var result = QueryResult(affectedRows: verb == "updated" ? matched : n, message: "\(verb == "updated" ? matched : n) document\(n == 1 ? "" : "s") \(verb)")
            if let up = reply["upserted"]?.arrayValue, !up.isEmpty { result.message! += ", \(up.count) upserted" }
            return result
        }
        switch call.name {
        case "find", "findOne":
            var cmd: [(String, BSON)] = [("find", c), ("filter", doc(0))]
            if a.count > 1 { cmd.append(("projection", a[1])) }
            var limit = call.name == "findOne" ? 1 : rowLimit
            for m in chain {
                switch m.name {
                case "sort": cmd.append(("sort", m.args.first ?? .document([])))
                case "skip": cmd.append(("skip", .int64(Int64(m.args.first?.int ?? 0))))
                case "limit": limit = min(limit, max(1, m.args.first?.int ?? limit))
                case "projection": cmd.append(("projection", m.args.first ?? .document([])))
                case "count", "itcount", "size":
                    let n = try run([("count", c), ("query", doc(0))])["n"]?.int ?? 0
                    return QueryResult(columns: [ResultColumn(name: "count", typeName: "int")], rows: [[String(n)]])
                case "pretty", "toArray": break
                default: throw DatabaseError(".\(m.name)() isn't supported after find.")
                }
            }
            cmd.append(("limit", .int64(Int64(limit == .max ? 0 : limit == rowLimit ? Swift.min(rowLimit, Int(Int32.max)) : limit))))
            if limit == rowLimit && rowLimit != .max { cmd[cmd.count - 1] = ("limit", .int64(Int64(rowLimit) + 1)) }
            cmd.append(("batchSize", .int32(Int32(Swift.min(limit, 1000)))))
            let r = try cursor(try run(cmd), limit: limit)
            return Self.table(r.docs, truncated: r.truncated)
        case "aggregate":
            let pipeline = a.first ?? .array([])
            let r = try cursor(try run([("aggregate", c), ("pipeline", pipeline), ("cursor", .document([]))]), limit: rowLimit)
            return Self.table(r.docs, truncated: r.truncated)
        case "countDocuments", "count":
            let reply = try run([("aggregate", c), ("pipeline", .array([.document([("$match", doc(0))]), .document([("$count", .string("n"))])])),
                                 ("cursor", .document([]))])
            let n = reply["cursor"]?["firstBatch"]?.arrayValue.first?["n"]?.int ?? 0
            return QueryResult(columns: [ResultColumn(name: "count", typeName: "int")], rows: [[String(n)]])
        case "estimatedDocumentCount":
            let n = try run([("count", c)])["n"]?.int ?? 0
            return QueryResult(columns: [ResultColumn(name: "count", typeName: "int")], rows: [[String(n)]])
        case "distinct":
            guard let field = a.first?.stringValue else { throw DatabaseError("distinct needs a field name.") }
            let values = try run([("distinct", c), ("key", .string(field)), ("query", doc(1))])["values"]?.arrayValue ?? []
            return QueryResult(columns: [ResultColumn(name: field, typeName: "")], rows: values.map { [$0.cell] })
        case "insertOne":
            return written(try run([("insert", c), ("documents", .array([doc(0)]))]), "inserted")
        case "insertMany":
            return written(try run([("insert", c), ("documents", a.first ?? .array([]))]), "inserted")
        case "updateOne", "updateMany", "replaceOne":
            var u: [(String, BSON)] = [("q", doc(0)), ("u", doc(1)), ("multi", .bool(call.name == "updateMany"))]
            if a.count > 2, a[2]["upsert"] == .bool(true) { u.append(("upsert", .bool(true))) }
            return written(try run([("update", c), ("updates", .array([.document(u)]))]), "updated")
        case "deleteOne", "deleteMany":
            return written(try run([("delete", c), ("deletes", .array([.document([("q", doc(0)), ("limit", .int32(call.name == "deleteOne" ? 1 : 0))])]))]), "deleted")
        case "createIndex":
            var spec: [(String, BSON)] = [("key", doc(0))]
            spec += doc(1).fields
            if spec.first(where: { $0.0 == "name" }) == nil {
                spec.append(("name", .string(doc(0).fields.map { "\($0.0)_\($0.1.int.map(String.init) ?? $0.1.cell ?? "")" }.joined(separator: "_"))))
            }
            try run([("createIndexes", c), ("indexes", .array([.document(spec)]))])
            return QueryResult(message: "Index created")
        case "dropIndex":
            try run([("dropIndexes", c), ("index", a.first ?? .string("*"))])
            return QueryResult(message: "Index dropped")
        case "getIndexes":
            let r = try cursor(try run([("listIndexes", c)]), limit: rowLimit)
            return Self.table(r.docs)
        case "drop":
            try run([("drop", c)])
            return QueryResult(message: "Dropped \(collection)")
        case "renameCollection":
            guard let to = a.first?.stringValue, let db = currentDatabase else { throw DatabaseError("renameCollection needs a new name.") }
            try run([("renameCollection", .string("\(db).\(collection)")), ("to", .string("\(db).\(to)"))], db: "admin")
            return QueryResult(message: "Renamed to \(to)")
        default:
            throw DatabaseError(".\(call.name)() isn't supported here; use db.runCommand({ … }).")
        }
    }

    public func cancel() {
        // killOp from a second connection would need its own sign-in; closing the socket stops the wait.
    }

    public func close() {
        socket.close()
    }

    deinit { close() }

    // MARK: Schema

    public func databases() throws -> [String] {
        do {
            return try run([("listDatabases", .int32(1)), ("nameOnly", .bool(true))], db: "admin")["databases"]?.arrayValue
                .compactMap { $0["name"]?.stringValue }.sorted() ?? []
        } catch {
            return [currentDatabase].compactMap { $0 }
        }
    }

    public func use(database: String) throws { currentDatabase = database }
    public func schemas() throws -> [String] { [] }

    public func objects(schema: String?) throws -> [DBObject] {
        let r = try cursor(try run([("listCollections", .int32(1)), ("nameOnly", .bool(false))]), limit: 10_000)
        return r.docs.compactMap { d -> DBObject? in
            guard let name = d["name"]?.stringValue, !name.hasPrefix("system.") else { return nil }
            return DBObject(schema: nil, name: name, kind: d["type"]?.stringValue == "view" ? .view : .table)
        }.sorted { $0.name < $1.name }
    }

    /// Fields from a sample of documents; _id is the key.
    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        let r = try cursor(try run([("aggregate", .string(table.name)), ("pipeline", .array([.document([("$sample", .document([("size", .int32(200))]))])])),
                                    ("cursor", .document([]))]), limit: 200)
        let t = Self.table(r.docs)
        if t.columns.isEmpty { return [ColumnInfo(name: "_id", type: "objectId", nullable: false, defaultValue: nil, isPrimaryKey: true)] }
        return t.columns.map { ColumnInfo(name: $0.name, type: $0.typeName, nullable: $0.name != "_id", defaultValue: nil, isPrimaryKey: $0.name == "_id") }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        try cursor(try run([("listIndexes", .string(table.name))]), limit: 1000).docs.map { d in
            IndexInfo(name: d["name"]?.stringValue ?? "", columns: d["key"]?.fields.map { "\($0.0) \($0.1.cell ?? "")" } ?? [],
                      unique: d["unique"] == .bool(true), primary: d["name"]?.stringValue == "_id_", definition: d.shell)
        }
    }

    public func definition(of object: DBObject) throws -> String? {
        let r = try cursor(try run([("listCollections", .int32(1)), ("filter", .document([("name", .string(object.name))]))]), limit: 1)
        return r.docs.first?["options"]?.shell
    }

    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] { [] }

    public func estimatedCount(of table: TableRef) throws -> Int? {
        try run([("count", .string(table.name))])["n"]?.int
    }
}

import Compression
import Foundation

// MARK: - Markdown and Excel

extension Export {
    public static func markdown(columns: [ResultColumn], rows: [[String?]]) -> String {
        func cell(_ s: String?) -> String {
            (s ?? "NULL").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        var out = "| " + columns.map { cell($0.name) }.joined(separator: " | ") + " |\n"
        out += "|" + columns.map { _ in " --- |" }.joined() + "\n"
        for row in rows { out += "| " + row.map(cell).joined(separator: " | ") + " |\n" }
        return out
    }

    public struct Sheet {
        public var name: String
        public var columns: [ResultColumn]
        public var rows: [[String?]]
        public init(name: String, columns: [ResultColumn], rows: [[String?]]) {
            self.name = name
            self.columns = columns
            self.rows = rows
        }
    }

    /// An Excel workbook (.xlsx), one sheet per result, header row in bold. Numbers in numeric columns stay numbers.
    public static func xlsx(_ sheets: [Sheet]) -> Data {
        var used = Set<String>()
        let names = sheets.map { sheet -> String in
            var n = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if n.isEmpty { n = "Sheet" }
            var candidate = n
            var k = 2
            while !used.insert(candidate.lowercased()).inserted { candidate = String(n.prefix(28)) + " \(k)"; k += 1 }
            return candidate
        }
        var files: [(String, Data)] = []
        let sheetList = names.indices.map { #"<sheet name="\#(xml(names[$0]))" sheetId="\#($0 + 1)" r:id="rId\#($0 + 1)"/>"# }.joined()
        files.append(("[Content_Types].xml", Data(("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            """ + names.indices.map { #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# }.joined()
            + "</Types>").utf8)))
        files.append(("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """.utf8)))
        files.append(("xl/workbook.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets>\(sheetList)</sheets></workbook>
            """.utf8)))
        files.append(("xl/_rels/workbook.xml.rels", Data(("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            """ + names.indices.map { #"<Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"# }.joined()
            + #"<Relationship Id="rId\#(names.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
            + "</Relationships>").utf8)))
        files.append(("xl/styles.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
            </styleSheet>
            """.utf8)))
        for (i, sheet) in sheets.enumerated() {
            files.append(("xl/worksheets/sheet\(i + 1).xml", worksheet(sheet)))
        }
        return Zip.archive(files)
    }

    private static func worksheet(_ sheet: Sheet) -> Data {
        let numeric = sheet.columns.map { EditorKind(type: $0.typeName) == .number }
        var xmlText = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetData>"#
        func ref(_ col: Int, _ row: Int) -> String {
            var n = col + 1
            var letters = ""
            while n > 0 { let r = (n - 1) % 26; letters = String(UnicodeScalar(65 + r)!) + letters; n = (n - 1) / 26 }
            return "\(letters)\(row)"
        }
        func text(_ s: String, _ r: String, bold: Bool = false) -> String {
            let clipped = s.count > 32_000 ? String(s.prefix(32_000)) : s
            return #"<c r="\#(r)" t="inlineStr"\#(bold ? #" s="1""# : "")><is><t xml:space="preserve">\#(xml(clipped))</t></is></c>"#
        }
        xmlText += #"<row r="1">"# + sheet.columns.enumerated().map { text($0.element.name, ref($0.offset, 1), bold: true) }.joined() + "</row>"
        var parts: [String] = [xmlText]
        for (r, row) in sheet.rows.enumerated() {
            var line = #"<row r="\#(r + 2)">"#
            for (c, value) in row.enumerated() {
                guard let value else { continue }
                if c < numeric.count, numeric[c], Double(value) != nil {
                    line += #"<c r="\#(ref(c, r + 2))"><v>\#(value)</v></c>"#
                } else {
                    line += text(value, ref(c, r + 2))
                }
            }
            parts.append(line + "</row>")
        }
        parts.append("</sheetData></worksheet>")
        return Data(parts.joined().utf8)
    }

    static func xml(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // Control characters aren't allowed in XML 1.0.
                if scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}

/// A ZIP file writer: deflate (raw, through Compression) with stored as the fallback.
enum Zip {
    static func archive(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in files {
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            let compressed = deflate(data)
            let method: UInt16 = compressed == nil ? 0 : 8
            let body = compressed ?? data
            let offset = UInt32(out.count)
            out.le32(0x04034b50); out.le16(20); out.le16(0x0800); out.le16(method); out.le16(0); out.le16(0x21)
            out.le32(crc); out.le32(UInt32(body.count)); out.le32(UInt32(data.count))
            out.le16(UInt16(nameBytes.count)); out.le16(0)
            out.append(nameBytes); out.append(body)
            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(method)
            central.le16(0); central.le16(0x21); central.le32(crc); central.le32(UInt32(body.count)); central.le32(UInt32(data.count))
            central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0); central.le32(offset)
            central.append(nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x06054b50); out.le16(0); out.le16(0); out.le16(UInt16(files.count)); out.le16(UInt16(files.count))
        out.le32(UInt32(central.count)); out.le32(centralOffset); out.le16(0)
        return out
    }

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 10 + 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&buffer, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        guard n > 0, n < data.count else { return nil }
        return Data(buffer[0..<n])
    }

    nonisolated(unsafe) static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for b in raw.bindMemory(to: UInt8.self) { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

// MARK: - Whole-database SQL dump

public enum Dump {
    /// Writes CREATE statements and INSERTs for the given tables to a file, a table at a time.
    /// For full fidelity (sequences, triggers, permissions) use the engine's own dump tool; see `BackupTool`.
    public static func sql(driver: Driver, objects: [DBObject], to url: URL, progress: (Int, String) -> Void) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let d = driver.dialect
        func write(_ s: String) throws { try handle.write(contentsOf: Data(s.utf8)) }
        try write("-- Maben Base export of \(driver.currentDatabase ?? "database") (\(driver.kind.title) \(driver.serverVersion))\n-- \(ISO8601DateFormatter().string(from: Date()))\n\n")
        let tables = objects.filter { $0.kind == .table }
        for (i, object) in tables.enumerated() {
            progress(i, object.name)
            if let create = try driver.definition(of: object) {
                try write("-- \(object.name)\n\(create.hasSuffix(";") ? create : create + ";")\n\n")
            }
            let result = try driver.execute("SELECT * FROM \(d.qualified(object.table))").first(where: \.hasRows) ?? QueryResult()
            for chunk in stride(from: 0, to: result.rows.count, by: 1000) {
                let rows = Array(result.rows[chunk..<min(chunk + 1000, result.rows.count)])
                try write(d.insertStatements(table: object.table, columns: result.columns, rows: rows).joined(separator: "\n") + "\n")
            }
            try write("\n")
        }
        for object in objects where object.kind == .view || object.kind == .materializedView {
            if let create = try driver.definition(of: object) { try write("\(create.hasSuffix(";") ? create : create + ";")\n\n") }
        }
        progress(tables.count, "")
    }
}

/// The engines' own dump and restore tools (pg_dump, mysqldump, …), found on this Mac.
public enum BackupTool {
    public static let searchPaths: [String] = {
        var paths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/libpq/bin", "/usr/local/opt/libpq/bin",
                     "/opt/homebrew/opt/mysql-client/bin", "/usr/local/opt/mysql-client/bin",
                     "/Applications/Postgres.app/Contents/Versions/latest/bin", "/usr/bin"]
        // Versioned Homebrew formulas, newest first.
        for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: prefix)) ?? []
            for n in names.filter({ $0.hasPrefix("postgresql@") || $0.hasPrefix("mysql@") || $0.hasPrefix("mariadb") })
                .sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending }) {
                paths.insert("\(prefix)/\(n)/bin", at: 0)
            }
        }
        return paths
    }()

    public static func find(_ name: String) -> String? {
        searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct Command {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        /// Read the file into the tool's input (mysql restores).
        public var inputFile: String?
        /// Write the tool's output to the file (mysqldump).
        public var outputFile: String?
    }

    /// A backup command. Postgres writes its own compressed format (.dump) or plain SQL (.sql); MySQL writes SQL.
    public static func backup(kind: DatabaseKind, host: String, port: Int, user: String, password: String, database: String,
                              tls: ConnectionConfig.TLS, file: String, plainSQL: Bool, serverVersion: String = "") throws -> Command {
        let maria = serverVersion.localizedCaseInsensitiveContains("mariadb")
        switch kind {
        case .postgres:
            guard let exe = find("pg_dump") else { throw missing("pg_dump", brew: "libpq") }
            return Command(executable: exe,
                           arguments: ["-h", host, "-p", "\(port)", "-U", user, "-d", database, "--no-password",
                                       "-F", plainSQL ? "p" : "c", "-f", file],
                           environment: pgEnvironment(password: password, tls: tls))
        case .mysql:
            // MySQL 9's tools can't sign in to MariaDB (no mysql_native_password), so MariaDB gets its own.
            let exe = maria ? find("mariadb-dump") ?? find("mysqldump") : find("mysqldump") ?? find("mariadb-dump")
            guard let exe else { throw missing("mysqldump", brew: maria ? "mariadb" : "mysql-client") }
            return Command(executable: exe,
                           arguments: ["-h", host, "-P", "\(port)", "-u", user, "--protocol=TCP", "--single-transaction",
                                       "--routines", "--triggers", "--events", "--hex-blob", "--default-character-set=utf8mb4",
                                       "--result-file=\(file)", database] + mysqlTLS(tls),
                           environment: ["MYSQL_PWD": password])
        default:
            throw DatabaseError("Backups for \(kind.title) are made with its own tools, or with Export Database.")
        }
    }

    public static func restore(kind: DatabaseKind, host: String, port: Int, user: String, password: String, database: String,
                               tls: ConnectionConfig.TLS, file: String, serverVersion: String = "") throws -> Command {
        let maria = serverVersion.localizedCaseInsensitiveContains("mariadb")
        switch kind {
        case .postgres:
            let plain = try isPlainSQL(file)
            if plain {
                guard let exe = find("psql") else { throw missing("psql", brew: "libpq") }
                return Command(executable: exe,
                               arguments: ["-h", host, "-p", "\(port)", "-U", user, "-d", database, "--no-password",
                                           "-v", "ON_ERROR_STOP=1", "-q", "-f", file],
                               environment: pgEnvironment(password: password, tls: tls))
            }
            guard let exe = find("pg_restore") else { throw missing("pg_restore", brew: "libpq") }
            return Command(executable: exe,
                           arguments: ["-h", host, "-p", "\(port)", "-U", user, "-d", database, "--no-password",
                                       "--no-owner", "--exit-on-error", file],
                           environment: pgEnvironment(password: password, tls: tls))
        case .mysql:
            let exe = maria ? find("mariadb") ?? find("mysql") : find("mysql") ?? find("mariadb")
            guard let exe else { throw missing("mysql", brew: maria ? "mariadb" : "mysql-client") }
            return Command(executable: exe,
                           arguments: ["-h", host, "-P", "\(port)", "-u", user, "--protocol=TCP", "--default-character-set=utf8mb4",
                                       database] + mysqlTLS(tls),
                           environment: ["MYSQL_PWD": password], inputFile: file)
        default:
            throw DatabaseError("Restores for \(kind.title) run with its own tools, or with Import SQL File.")
        }
    }

    /// A plain-language hint for well-known tool errors.
    public static func hint(for output: String) -> String? {
        if output.contains("mysql_native_password") {
            return "This MySQL client can't sign in to this server (MySQL 9 dropped the older sign-in method that MariaDB uses). Install MariaDB's tools with brew install mariadb, or use Export database (SQL) instead."
        }
        if output.contains("server version mismatch") || output.contains("aborting because of server version mismatch") {
            return "pg_dump must be at least as new as the server. Install a newer one, for example brew install postgresql@17."
        }
        if output.contains("password authentication failed") || output.contains("Access denied") {
            return "The server refused the user name or password."
        }
        return nil
    }

    static func isPlainSQL(_ file: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 5) ?? Data()
        return head != Data("PGDMP".utf8)
    }

    static func pgEnvironment(password: String, tls: ConnectionConfig.TLS) -> [String: String] {
        let mode = switch tls {
        case .off: "disable"
        case .prefer: "prefer"
        case .require: "require"
        case .verify: "verify-full"
        }
        return ["PGPASSWORD": password, "PGSSLMODE": mode, "PGAPPNAME": "Maben Base"]
    }

    static func mysqlTLS(_ tls: ConnectionConfig.TLS) -> [String] {
        switch tls {
        case .off: ["--ssl-mode=DISABLED"]
        case .prefer: []
        case .require: ["--ssl-mode=REQUIRED"]
        case .verify: ["--ssl-mode=VERIFY_IDENTITY"]
        }
    }

    static func missing(_ tool: String, brew: String) -> DatabaseError {
        DatabaseError("\(tool) isn't installed on this Mac.", detail: "Install it with Homebrew: brew install \(brew)\nOr use Export database (SQL) instead, which needs nothing extra.")
    }
}

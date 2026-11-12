import Foundation
import Security

/// Saved connections, history and saved queries, as JSON in Application Support. Passwords go to the Keychain.
public final class Store {
    public let folder: URL

    public init(folder: URL? = nil) {
        // MABEN_BASE_DATA points the app at another data folder (testing without touching your connections).
        let env = ProcessInfo.processInfo.environment["MABEN_BASE_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.folder = folder ?? env ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maben Base", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    private func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? decoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Connections

    public func connections() -> [ConnectionConfig] { load("connections.json", as: [ConnectionConfig].self) ?? [] }
    public func save(connections: [ConnectionConfig]) { save(connections, "connections.json") }

    // MARK: History and saved queries

    public struct HistoryItem: Codable, Hashable, Identifiable, Sendable {
        public var id = UUID()
        public var sql: String
        public var date: Date
        public var database: String?
        public var milliseconds: Int?
        public var failed: Bool

        public init(sql: String, date: Date = Date(), database: String?, milliseconds: Int?, failed: Bool) {
            self.sql = sql
            self.date = date
            self.database = database
            self.milliseconds = milliseconds
            self.failed = failed
        }
    }

    public struct SavedQuery: Codable, Hashable, Identifiable, Sendable {
        public var id = UUID()
        public var name: String
        public var sql: String
        public init(name: String, sql: String) { self.name = name; self.sql = sql }
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func history(for connection: UUID) -> [HistoryItem] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("history-\(connection).json")) else { return [] }
        return (try? decoder().decode([HistoryItem].self, from: data)) ?? []
    }

    public func save(history: [HistoryItem], for connection: UUID) {
        save(Array(history.prefix(1000)), "history-\(connection).json")
    }

    public func savedQueries(for connection: UUID) -> [SavedQuery] { load("queries-\(connection).json", as: [SavedQuery].self) ?? [] }
    public func save(queries: [SavedQuery], for connection: UUID) { save(queries, "queries-\(connection).json") }

    // MARK: Snippets (shared by all connections)

    public struct Snippet: Codable, Hashable, Identifiable, Sendable {
        public var id = UUID()
        /// Typed in the editor, then Tab expands it.
        public var trigger: String
        public var name: String
        /// ${1:placeholder}, ${2}, … are visited with Tab; $0 is where the cursor ends.
        public var body: String
        public init(trigger: String, name: String, body: String) { self.trigger = trigger; self.name = name; self.body = body }
    }

    public func snippets() -> [Snippet]? { load("snippets.json", as: [Snippet].self) }
    public func save(snippets: [Snippet]) { save(snippets, "snippets.json") }

    public func forget(connection: UUID) {
        for name in ["history-\(connection).json", "queries-\(connection).json"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        for suffix in ["", ".ssh", ".p12"] { Keychain.delete(account: connection.uuidString + suffix) }
    }
}

/// Generic passwords under the service "Maben Base", one per connection.
public enum Keychain {
    static let service = "gg.maben.base"

    public static func password(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func set(_ password: String?, account: String) {
        delete(account: account)
        guard let password, !password.isEmpty else { return }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecAttrLabel as String: "Maben Base connection",
                                   kSecValueData as String: Data(password.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Export and import

public enum Export {
    public static func csv(columns: [ResultColumn], rows: [[String?]]) -> String {
        func field(_ s: String?) -> String {
            guard let s else { return "" }
            if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var out = columns.map { field($0.name) }.joined(separator: ",") + "\n"
        for row in rows { out += row.map(field).joined(separator: ",") + "\n" }
        return out
    }

    public static func tsv(columns: [ResultColumn]?, rows: [[String?]]) -> String {
        func clean(_ s: String?) -> String {
            (s ?? "NULL").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var lines: [String] = []
        if let columns { lines.append(columns.map(\.name).joined(separator: "\t")) }
        lines += rows.map { $0.map(clean).joined(separator: "\t") }
        return lines.joined(separator: "\n")
    }

    public static func json(columns: [ResultColumn], rows: [[String?]]) -> String {
        let objects: [[String: Any]] = rows.map { row in
            var o: [String: Any] = [:]
            for (i, c) in columns.enumerated() { o[c.name] = row[i] ?? NSNull() }
            return o
        }
        let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Parses CSV (RFC 4180, comma or semicolon). The first row is the header.
    public static func parseCSV(_ text: String) -> [[String]] {
        let firstLine = text.prefix(while: { $0 != "\n" })
        let sep: Character = firstLine.filter({ $0 == ";" }).count > firstLine.filter({ $0 == "," }).count ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

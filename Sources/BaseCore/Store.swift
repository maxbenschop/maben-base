import Foundation
import Security

/// Saved connections, history and saved queries, as JSON in Application Support. Passwords go to the Keychain.
public final class Store {
    public let folder: URL

    public init(folder: URL? = nil) {
        // MABEN_BASE_DATA points a development build at another data folder (testing without touching your
        // connections). The released app doesn't read it: its data folder isn't something the environment sets.
        #if DEBUG
        let env = ProcessInfo.processInfo.environment["MABEN_BASE_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        let env: URL? = nil
        #endif
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

    /// The saved connections, each with the tool path that was set for it on this Mac. Control characters
    /// (pasted into a field, or saved by an older version) are taken out on the way in.
    public func connections() -> [ConnectionConfig] {
        let tools = toolPaths()
        return (load("connections.json", as: [ConnectionConfig].self) ?? []).map { saved in
            var c = saved
            c.localToolPath = tools[c.id] ?? ""
            c.stripControlCharacters()
            return c
        }
    }

    public func save(connections: [ConnectionConfig]) {
        save(connections, "connections.json")
        save(Dictionary(connections.filter { !$0.localToolPath.isEmpty }.map { ($0.id.uuidString, $0.localToolPath) }, uniquingKeysWith: { a, _ in a }), "tools.json")
    }

    /// Where sqlplus or duckdb is, per connection. A file of its own that stays on this Mac: connections.json
    /// has the same shape as the files that are synced and exported, and a program to run must never ride along.
    func toolPaths() -> [UUID: String] {
        (load("tools.json", as: [String: String].self) ?? [:]).reduce(into: [:]) { out, pair in
            if let id = UUID(uuidString: pair.key) { out[id] = pair.value }
        }
    }

    /// Older versions saved each password under its connection's ID alone. The first time this version
    /// opens this data folder, every password of a connection that is saved here gets tied to what that
    /// connection points at now, so unchanged connections go on working without asking again. It runs once:
    /// afterwards a password without a fingerprint belongs to no connection and is never handed out.
    public func adoptSavedPasswords() {
        let marker = folder.appendingPathComponent("keychain-bound")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for c in connections() {
            for slot in SecretSlot.allCases { Keychain.adopt(account: c.secretAccount(slot), binding: c.secretBinding(slot)) }
        }
        try? Data().write(to: marker, options: .atomic)
    }

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
        for slot in SecretSlot.allCases { Keychain.delete(account: connection.uuidString + slot.rawValue) }
        var tools = toolPaths()
        if tools.removeValue(forKey: connection) != nil {
            save(Dictionary(uniqueKeysWithValues: tools.map { ($0.key.uuidString, $0.value) }), "tools.json")
        }
    }
}

/// Where secrets are kept. The app uses the Keychain; tests put a dictionary in its place.
protocol SecretVault: AnyObject {
    func read(_ account: String) -> (password: String, binding: String?)?
    func write(_ account: String, password: String, binding: String)
    /// Sets the fingerprint of a secret that is already there. False when it couldn't be done.
    func bind(_ account: String, to binding: String) -> Bool
    func delete(_ account: String)
}

/// Generic passwords under the service "gg.maben.base". The fingerprint is the item's "generic" attribute.
final class SystemKeychain: SecretVault {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Keychain.service, kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> (password: String, binding: String?)? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess, let dict = found as? [String: Any],
              let data = dict[kSecValueData as String] as? Data, let password = String(data: data, encoding: .utf8) else { return nil }
        let binding = (dict[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return (password, binding?.isEmpty == false ? binding : nil)
    }

    func write(_ account: String, password: String, binding: String) {
        delete(account)
        var item = query(account)
        item[kSecAttrLabel as String] = "Maben Base connection"
        item[kSecAttrGeneric as String] = Data(binding.utf8)
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    func bind(_ account: String, to binding: String) -> Bool {
        SecItemUpdate(query(account) as CFDictionary, [kSecAttrGeneric as String: Data(binding.utf8)] as CFDictionary) == errSecSuccess
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// A connection's secrets, one Keychain item each. Each is saved together with a fingerprint of where it is
/// for (see `ConnectionConfig.secretBinding`) and is only handed back for the same place: a connection that
/// arrives from a file or from sync with a known ID but another server doesn't get the password that was
/// saved for the first one.
public enum Keychain {
    static let service = "gg.maben.base"
    nonisolated(unsafe) static var vault: SecretVault = SystemKeychain()

    public enum Lookup: Equatable, Sendable {
        case none
        case found(String)
        /// A secret is saved under this name, but for another server (or by an older version, for a
        /// connection this Mac didn't have when it updated).
        case elsewhere
    }

    public static func lookup(account: String, binding: String) -> Lookup {
        guard let item = vault.read(account) else { return .none }
        return item.binding == binding ? .found(item.password) : .elsewhere
    }

    public static func password(account: String, binding: String) -> String? {
        if case .found(let p) = lookup(account: account, binding: binding) { return p }
        return nil
    }

    /// Saves a secret for `binding`, in place of whatever was saved under this name. Nil or empty removes it.
    public static func set(_ password: String?, account: String, binding: String) {
        guard let password, !password.isEmpty else { return vault.delete(account) }
        vault.write(account, password: password, binding: binding)
    }

    /// For the one-time move from older versions, which saved passwords under the connection's ID alone:
    /// gives a password that has no fingerprint yet the one for what its connection points at now.
    /// Passwords that already have one are left alone.
    public static func adopt(account: String, binding: String) {
        guard let item = vault.read(account), item.binding == nil else { return }
        if !vault.bind(account, to: binding) { vault.write(account, password: item.password, binding: binding) }
    }

    public static func delete(account: String) { vault.delete(account) }
}

/// The three secrets a connection can have.
public enum SecretSlot: String, CaseIterable, Sendable {
    case password = "", ssh = ".ssh", certificate = ".p12"
}

public extension ConnectionConfig {
    /// The Keychain name of one of this connection's secrets.
    func secretAccount(_ slot: SecretSlot) -> String { id.uuidString + slot.rawValue }

    /// A fingerprint of where a secret goes: the database password to the engine, host, port and user (and
    /// the SSH server it is reached through, and a custom endpoint); the SSH secret to the SSH host, port and
    /// user; the certificate's password to the certificate file. Changing any of them by hand in the editor
    /// saves the password again under the new fingerprint; a change that arrives from elsewhere doesn't.
    func secretBinding(_ slot: SecretSlot) -> String {
        let parts: [String]
        switch slot {
        case .password:
            parts = ["password", kind.rawValue, host.lowercased(), String(port), user,
                     sshEnabled ? "\(sshHost.lowercased()):\(sshPort):\(sshUser)" : "", options["endpoint"] ?? "", kind.isCloudAPI || kind.isFile ? filePath : ""]
        case .ssh:
            parts = ["ssh", sshHost.lowercased(), String(sshPort), sshUser]
        case .certificate:
            parts = ["certificate", clientCertFile]
        }
        // Length-prefixed, so no two different sets of fields read the same.
        let text = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return "v1:" + Crypto.sha256(Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Export and import

public enum Export {
    /// True for text a spreadsheet would run as a formula when the file is opened: it starts with = + - @,
    /// a tab or a return. Numbers (-5, +3.2e4) are numbers, not formulas.
    static func looksLikeFormula(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) else { return false }
        return Double(s) == nil
    }

    /// `protectFormulas` puts an apostrophe in front of text a spreadsheet would run as a formula (a cell
    /// that says =HYPERLINK(…) or @SUM(…) is data here, but a command to Excel). The apostrophe is then part
    /// of the file, so it is a choice: without it, the file holds the values exactly as they are.
    public static func csv(columns: [ResultColumn], rows: [[String?]], protectFormulas: Bool = false) -> String {
        func field(_ value: String?) -> String {
            guard var s = value else { return "" }
            if protectFormulas, looksLikeFormula(s) { s = "'" + s }
            if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var out = columns.map { field($0.name) }.joined(separator: ",") + "\n"
        for row in rows { out += row.map(field).joined(separator: ",") + "\n" }
        return out
    }

    /// A file name for a table: the name with everything taken out that could put the file somewhere else
    /// (slashes, a leading dot, "..") or that a file name can't hold.
    public static func fileName(_ name: String) -> String {
        var out = String(String.UnicodeScalarView(name.unicodeScalars.map { ConnectionConfig.isControl($0) || $0 == "/" || $0 == ":" || $0 == "\\" ? "-" : $0 }))
        out = String(out.drop(while: { $0 == "." || $0 == " " }))
        while out.utf8.count > 200 { out.removeLast() }
        return out.isEmpty ? "table" : out
    }

    /// Where a table's file goes inside the folder you chose: a name made by `fileName`, numbered when two
    /// tables would get the same one, and checked to really be inside that folder.
    public static func destination(in folder: URL, table: String, fileExtension: String, taken: inout Set<String>) throws -> URL {
        let base = fileName(table)
        var name = "\(base).\(fileExtension)"
        var n = 2
        while !taken.insert(name.lowercased()).inserted { name = "\(base) \(n).\(fileExtension)"; n += 1 }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent().path == root.path, url.lastPathComponent == name else {
            throw DatabaseError("The table \(table.prefix(60)) can't be written as a file in that folder.")
        }
        return url
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
            for (i, c) in columns.enumerated() { o[c.name] = (row[safe: i] ?? nil) ?? NSNull() }
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

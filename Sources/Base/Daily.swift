import AppKit
import BaseCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Preferences

enum Preferences {
    private static var d: UserDefaults { .standard }

    static var reopenAtLaunch: Bool {
        get { d.object(forKey: "reopenAtLaunch") as? Bool ?? true }
        set { d.set(newValue, forKey: "reopenAtLaunch") }
    }

    /// New connections open as tabs of one window (macOS window tabs).
    static var connectionTabs: Bool {
        get { d.object(forKey: "connectionTabs") as? Bool ?? true }
        set { d.set(newValue, forKey: "connectionTabs") }
    }

    /// Rows kept from one query; 0 keeps them all.
    static var queryRowLimit: Int {
        get { d.object(forKey: "queryRowLimit") as? Int ?? 50_000 }
        set { d.set(newValue, forKey: "queryRowLimit") }
    }

    static var syncThroughICloud: Bool {
        get { d.bool(forKey: "syncThroughICloud") }
        set { d.set(newValue, forKey: "syncThroughICloud") }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = makeMabenWindow(size: NSSize(width: 560, height: 430), autosave: "MabenBaseSettings", resizable: false)
        window.title = "Settings"
        super.init(window: window)
        window.setContent(SettingsView(), size: NSSize(width: 560, height: 430), autosave: "MabenBaseSettings")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @State private var appearance = Appearance.current
    @State private var reopen = Preferences.reopenAtLaunch
    @State private var tabs = Preferences.connectionTabs
    @State private var rowLimit = Preferences.queryRowLimit
    @State private var sync = Preferences.syncThroughICloud
    @State private var syncNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text).padding(.leading, 64)
            row("Appearance") {
                MBSegmented(options: Appearance.allCases, selection: $appearance) { $0.title }
                    .onChange(of: appearance) { _, a in Appearance.current = a }
            }
            row("At launch") {
                Toggle("Reopen the connections and tabs that were open", isOn: $reopen).toggleStyle(.checkbox)
                    .onChange(of: reopen) { _, v in Preferences.reopenAtLaunch = v }
            }
            row("Windows") {
                Toggle("Open connections as tabs in one window", isOn: $tabs).toggleStyle(.checkbox)
                    .onChange(of: tabs) { _, v in Preferences.connectionTabs = v }
            }
            row("Query results") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $rowLimit) {
                        Text("First 50,000 rows").tag(50_000)
                        Text("First 200,000 rows").tag(200_000)
                        Text("First 1,000,000 rows").tag(1_000_000)
                        Text("All rows").tag(0)
                    }
                    .labelsHidden().frame(width: 220)
                    .onChange(of: rowLimit) { _, v in Preferences.queryRowLimit = v }
                    Text("Rows past the limit can still be loaded with Load all. Every row takes memory.")
                        .font(.system(size: 11.5)).foregroundStyle(MB.dim)
                }
            }
            row("Sync") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep connections in sync through iCloud Drive", isOn: $sync).toggleStyle(.checkbox)
                        .onChange(of: sync) { _, v in
                            Preferences.syncThroughICloud = v
                            syncNote = v ? ConnectionSync.enable() : nil
                        }
                    Text(syncNote ?? "Connections (not passwords) go in a Maben Base folder in your iCloud Drive. Each Mac keeps its own passwords in its Keychain.")
                        .font(.system(size: 11.5)).foregroundStyle(syncNote == nil ? MB.dim : MB.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .font(.system(size: 12.5))
        .foregroundStyle(MB.text)
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MB.bg)
        .tint(MB.accent)
        .ignoresSafeArea()
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(MB.muted).frame(width: 110, alignment: .trailing)
            content()
        }
    }
}

// MARK: - Reopening the last session

/// What a window had open, so the next launch can bring it back.
struct SavedWorkspace: Codable {
    struct Tab: Codable {
        var table: String?
        var schema: String?
        var kind: String?
        var structure: Bool?
        var queryName: String?
        var queryText: String?
        var savedQuery: UUID?
    }

    var connection: UUID
    var database: String?
    var schema: String?
    var tabs: [Tab]
    var selected: Int?
}

extension Workspace {
    func snapshot() -> SavedWorkspace {
        let tabs: [SavedWorkspace.Tab] = self.tabs.map { tab in
            switch tab {
            case .table(let t):
                SavedWorkspace.Tab(table: t.object.name, schema: t.object.schema, kind: t.object.kind.rawValue, structure: t.mode == .structure)
            case .query(let q):
                SavedWorkspace.Tab(queryName: q.name, queryText: q.text, savedQuery: q.savedID)
            }
        }
        return SavedWorkspace(connection: config.id, database: database, schema: schema, tabs: tabs,
                              selected: self.tabs.firstIndex { $0.id == selectedTab })
    }

    /// Opens the saved tabs once the connection has loaded its database and tables.
    func restore(_ saved: SavedWorkspace) async {
        if let db = saved.database, db != database, session.kind != .sqlite {
            do {
                try await session.run { try $0.use(database: db) }
                database = db
            } catch {}
        }
        if let s = saved.schema, s != schema, schemas.contains(s) { schema = s }
        await reloadObjects()
        for tab in saved.tabs {
            if let name = tab.table {
                let kind = tab.kind.flatMap(DBObject.Kind.init(rawValue:)) ?? .table
                let object = objects.first { $0.name == name && $0.schema == tab.schema } ?? DBObject(schema: tab.schema, name: name, kind: kind)
                open(object, structure: tab.structure ?? false)
            } else {
                newQuery(name: tab.queryName, text: tab.queryText ?? "", saved: tab.savedQuery)
            }
        }
        if let i = saved.selected, tabs.indices.contains(i) { selectedTab = tabs[i].id }
    }
}

@MainActor
enum SessionMemory {
    private static var url: URL { Store().folder.appendingPathComponent("open-windows.json") }

    static func save() {
        let saved = WorkspaceWindowController.open.map { $0.workspace.snapshot() }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Reopens last session's connections. Returns false when there was nothing to reopen.
    static func reopen() -> Bool {
        guard Preferences.reopenAtLaunch, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([SavedWorkspace].self, from: data), !saved.isEmpty else { return false }
        let store = Store()
        let configs = store.connections()
        var opened = false
        for item in saved {
            guard let config = configs.first(where: { $0.id == item.connection }) else { continue }
            opened = true
            Task {
                do {
                    let session = try await Session.open(config, secrets: Secrets.load(config.id))
                    let controller = WorkspaceWindowController(session: session, store: store, restoring: item)
                    controller.show()
                } catch {
                    ConnectionsWindowController.shared.show()
                    ConnectionsWindowController.shared.list.select(config.id)
                    ConnectionsWindowController.shared.list.testResult = (false, "\(config.displayName): \(error.localizedDescription)")
                }
            }
        }
        return opened
    }
}

// MARK: - Connection files

/// A file of connections to move to another Mac. Passwords are only included when you give a passphrase;
/// they're then encrypted with AES-GCM under a key made from it (PBKDF2-SHA256, 210,000 rounds).
struct ConnectionFile: Codable {
    var format = "maben-base-connections"
    var version = 1
    var connections: [ConnectionConfig]
    var secrets: SecretBox.Sealed?

    struct SecretSet: Codable {
        var password: String?
        var ssh: String?
        var certificate: String?
    }

    static func make(_ connections: [ConnectionConfig], passphrase: String?) throws -> Data {
        var file = ConnectionFile(connections: connections)
        if let passphrase, !passphrase.isEmpty {
            var map: [String: SecretSet] = [:]
            for c in connections {
                let s = Secrets.load(c.id)
                map[c.id.uuidString] = SecretSet(password: s.password, ssh: s.ssh, certificate: s.certificate)
            }
            file.secrets = try SecretBox.seal(try JSONEncoder().encode(map), passphrase: passphrase)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func read(_ data: Data) throws -> ConnectionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(ConnectionFile.self, from: data), file.format == "maben-base-connections" else {
            throw DatabaseError("This isn't a Maben Base connections file.")
        }
        return file
    }

    func openSecrets(_ passphrase: String) throws -> [UUID: Secrets] {
        guard let secrets else { return [:] }
        let plain = try SecretBox.open(secrets, passphrase: passphrase)
        guard let map = try? JSONDecoder().decode([String: SecretSet].self, from: plain) else { throw DatabaseError("The passwords in the file can't be read.") }
        var out: [UUID: Secrets] = [:]
        for (k, v) in map { if let id = UUID(uuidString: k) { out[id] = Secrets(password: v.password, ssh: v.ssh, certificate: v.certificate) } }
        return out
    }
}

/// A text prompt as a modal alert (passphrases, URL lists).
@MainActor
func ask(_ title: String, detail: String, placeholder: String = "", secure: Bool = false, multiline: Bool = false, button: String = "OK") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    let field: NSView
    if multiline {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        (scroll.documentView as? NSTextView)?.font = MB.nsMono
        (scroll.documentView as? NSTextView)?.isAutomaticQuoteSubstitutionEnabled = false
        field = scroll
    } else {
        let f = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        f.placeholderString = placeholder
        field = f
    }
    alert.accessoryView = field
    alert.window.initialFirstResponder = multiline ? (field as? NSScrollView)?.documentView : field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    if let scroll = field as? NSScrollView { return (scroll.documentView as? NSTextView)?.string }
    return (field as? NSTextField)?.stringValue
}

extension ConnectionList {
    func exportConnections(_ ids: [UUID]? = nil) {
        let chosen = ids.map { ids in connections.filter { ids.contains($0.id) } } ?? connections
        guard !chosen.isEmpty else { return }
        guard let passphrase = ask("Export \(chosen.count) connection\(chosen.count == 1 ? "" : "s")",
                                   detail: "To include passwords, give a passphrase; they're encrypted with it and the other Mac needs it to import them. Leave it empty to export without passwords.",
                                   placeholder: "Passphrase (optional)", secure: true, button: "Export…") else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Connections.mabenbase"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ConnectionFile.make(chosen, passphrase: passphrase.isEmpty ? nil : passphrase).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError(error, in: nil, title: "Export failed")
        }
    }

    func importConnections() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Maben Base connections file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try ConnectionFile.read(try Data(contentsOf: url))
            var secrets: [UUID: Secrets] = [:]
            if file.secrets != nil {
                while true {
                    guard let pass = ask("Passwords are encrypted", detail: "Type the passphrase used for the export, or cancel to import without passwords.",
                                         secure: true, button: "Import") else { break }
                    do { secrets = try file.openSecrets(pass); break } catch { NSSound.beep() }
                }
            }
            for var c in file.connections {
                if let i = connections.firstIndex(where: { $0.id == c.id }) {
                    connections[i] = c
                } else {
                    if c.modified == Date(timeIntervalSince1970: 0) { c.modified = Date() }
                    connections.append(c)
                }
                if persist, let s = secrets[c.id] { s.save(c.id) }
            }
            persistAll()
            if let first = file.connections.first { select(first.id) }
            testResult = (true, "Imported \(file.connections.count) connection\(file.connections.count == 1 ? "" : "s")\(secrets.isEmpty ? "" : " with passwords").")
        } catch {
            showError(error, in: nil, title: "Import failed")
        }
    }

    /// One postgres://, mysql:// or sqlite:// URL per line; passwords in them go to the Keychain.
    func importURLs() {
        guard let text = ask("Import from URLs", detail: "One URL per line, like postgres://user:pass@host:5432/db or mysql://root@localhost/shop.",
                             multiline: true, button: "Import") else { return }
        var added = 0
        for line in text.split(whereSeparator: \.isNewline) {
            var c = ConnectionConfig()
            let r = c.apply(url: String(line))
            guard r.ok else { continue }
            c.modified = Date()
            connections.append(c)
            if persist { Secrets(password: r.password).save(c.id) }
            added += 1
        }
        persistAll()
        testResult = (added > 0, added > 0 ? "Imported \(added) connection\(added == 1 ? "" : "s")." : "No database URLs found.")
    }

    func persistAll() {
        guard persist else { return }
        store.save(connections: connections)
        ConnectionSync.push(connections)
    }
}

// MARK: - Sync through iCloud Drive

/// Keeps connections (not passwords) in a JSON file in iCloud Drive. Each change carries a date; the newer
/// version of a connection wins, and deletions are remembered so they don't come back.
@MainActor
enum ConnectionSync {
    struct File: Codable {
        var connections: [ConnectionConfig]
        var deleted: [UUID: Date]
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Maben Base", isDirectory: true)
    }

    static var file: URL { folder.appendingPathComponent("connections.json") }

    /// Returns a problem to show, or nil when sync is set up.
    static func enable() -> String? {
        let drive = folder.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: drive.path) else {
            Preferences.syncThroughICloud = false
            return "iCloud Drive isn't turned on for this Mac (System Settings › Apple Account › iCloud › iCloud Drive)."
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return "The Maben Base folder in iCloud Drive can't be created: \(error.localizedDescription)"
        }
        ConnectionsWindowController.shared.list.syncNow()
        return nil
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static func readRemote() -> File? {
        guard Preferences.syncThroughICloud, let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(File.self, from: data)
    }

    /// Local deletions waiting to be written to the shared file.
    static var deletedLocally: [UUID: Date] {
        get { (UserDefaults.standard.dictionary(forKey: "sync.deleted") as? [String: Date] ?? [:]).reduce(into: [:]) { d, kv in if let id = UUID(uuidString: kv.key) { d[id] = kv.value } } }
        set { UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) }), forKey: "sync.deleted") }
    }

    /// Merges local and remote: newest version of each connection, minus anything deleted after its last change.
    static func merge(local: [ConnectionConfig], remote: File?) -> (connections: [ConnectionConfig], deleted: [UUID: Date]) {
        var deleted = remote?.deleted ?? [:]
        for (id, date) in deletedLocally { deleted[id] = max(date, deleted[id] ?? date) }
        return (ConnectionMerge.merge(local: local, remote: remote?.connections ?? [], deleted: deleted), deleted)
    }

    static func push(_ connections: [ConnectionConfig]) {
        guard Preferences.syncThroughICloud else { return }
        let merged = merge(local: connections, remote: readRemote())
        guard let data = try? encoder.encode(File(connections: merged.connections, deleted: merged.deleted)) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        deletedLocally = [:]
    }
}

extension ConnectionList {
    /// Pulls changes from iCloud Drive (at launch and whenever the app comes to the front).
    func syncNow() {
        guard persist, Preferences.syncThroughICloud else { return }
        let merged = ConnectionSync.merge(local: connections, remote: ConnectionSync.readRemote())
        if merged.connections != connections {
            connections = merged.connections
            store.save(connections: connections)
            if let id = selected, !connections.contains(where: { $0.id == id }) { select(connections.first?.id) }
        }
        ConnectionSync.push(connections)
    }
}

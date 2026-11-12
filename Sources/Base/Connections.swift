import AppKit
import BaseCore
import SwiftUI

/// The saved connections, and the editor for one.
@MainActor
final class ConnectionList: ObservableObject {
    @Published var connections: [ConnectionConfig]
    @Published var selected: UUID?
    @Published var draft = ConnectionConfig()
    @Published var password = ""
    @Published var sshSecret = ""
    @Published var certificatePassword = ""
    var secrets: Secrets { Secrets(password: password, ssh: sshSecret, certificate: certificatePassword) }
    @Published var filter = ""
    @Published var busy: String?
    @Published var testResult: (ok: Bool, text: String)?
    let store: Store
    /// Demo mode keeps everything in memory.
    let persist: Bool

    init(store: Store, persist: Bool = true, initial: [ConnectionConfig]? = nil) {
        self.store = store
        self.persist = persist
        connections = initial ?? store.connections()
        if let first = connections.first { select(first.id) }
    }

    func select(_ id: UUID?) {
        selected = id
        testResult = nil
        if let id, let c = connections.first(where: { $0.id == id }) {
            draft = c
            let s = persist ? Secrets.load(c.id) : Secrets()
            password = s.password ?? ""
            sshSecret = s.ssh ?? ""
            certificatePassword = s.certificate ?? ""
        }
    }

    func newConnection(kind: DatabaseKind = .postgres) {
        var c = ConnectionConfig()
        c.kind = kind
        c.port = kind.defaultPort
        c.user = kind == .postgres ? NSUserName() : kind == .mysql ? "root" : ""
        c.tls = kind == .sqlite ? .off : .prefer
        draft = c
        password = ""
        sshSecret = ""
        certificatePassword = ""
        selected = nil
        testResult = nil
    }

    var isNew: Bool { !connections.contains { $0.id == draft.id } }

    var grouped: [(group: String, items: [ConnectionConfig])] {
        let f = filter.lowercased()
        let list = connections.filter { f.isEmpty || $0.displayName.lowercased().contains(f) || $0.summary.lowercased().contains(f) || $0.group.lowercased().contains(f) }
        let groups = Dictionary(grouping: list, by: \.group)
        return groups.keys.sorted { a, b in a.isEmpty != b.isEmpty ? a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending }
            .map { ($0, groups[$0]!.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) }
    }

    func save() {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = draft.displayName }
        if connections.first(where: { $0.id == draft.id }) != draft { draft.modified = Date() }
        if let i = connections.firstIndex(where: { $0.id == draft.id }) { connections[i] = draft } else { connections.append(draft) }
        selected = draft.id
        if persist { secrets.save(draft.id) }
        persistAll()
    }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        if persist {
            store.forget(connection: id)
            var deleted = ConnectionSync.deletedLocally
            deleted[id] = Date()
            ConnectionSync.deletedLocally = deleted
        }
        persistAll()
        if let first = connections.first { select(first.id) } else { newConnection() }
    }

    func duplicate(_ id: UUID) {
        guard var c = connections.first(where: { $0.id == id }) else { return }
        let s = persist ? Secrets.load(id) : Secrets()
        c.id = UUID()
        c.name += " copy"
        c.modified = Date()
        connections.append(c)
        if persist { s.save(c.id) }
        persistAll()
        select(c.id)
    }

    func test() {
        let config = draft, secrets = secrets
        busy = "Testing…"
        testResult = nil
        Task {
            do {
                let session = try await Session.open(config, secrets: secrets)
                let version = session.serverVersion
                session.close()
                testResult = (true, "Connected · \(config.kind.shortTitle) \(version.split(separator: " ").first ?? "")")
            } catch {
                testResult = (false, error.localizedDescription)
            }
            busy = nil
        }
    }

    func connect(window: NSWindow?) {
        save()
        let config = draft, secrets = secrets
        busy = "Connecting…"
        testResult = nil
        Task {
            do {
                let session = try await Session.open(config, secrets: secrets)
                busy = nil
                WorkspaceWindowController(session: session, store: store).show()
                ConnectionsWindowController.shared.close()
            } catch {
                busy = nil
                testResult = (false, error.localizedDescription)
            }
        }
    }
}

@MainActor
final class ConnectionsWindowController: NSWindowController, NSWindowDelegate {
    static var shared = ConnectionsWindowController(list: ConnectionList(store: Store()))
    let list: ConnectionList

    init(list: ConnectionList) {
        self.list = list
        let window = makeMabenWindow(size: NSSize(width: 900, height: 600), autosave: "MabenBaseConnections")
        window.minSize = NSSize(width: 760, height: 520)
        window.title = "Maben Base"
        super.init(window: window)
        window.delegate = self
        window.setContent(ConnectionsView(list: list, window: { [weak window] in window }), size: NSSize(width: 900, height: 600),
                          autosave: "MabenBaseConnections")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newConnection(_ sender: Any?) { list.newConnection() }
}

struct ConnectionsView: View {
    @ObservedObject var list: ConnectionList
    let window: () -> NSWindow?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280).background(MB.sidebar)
            Hairline(vertical: true)
            ConnectionEditor(list: list, window: window).frame(maxWidth: .infinity)
        }
        .background(MB.bg)
        .tint(MB.accent)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                MBWordmark(size: 15)
                Spacer()
            }
            .padding(.leading, 84).padding(.trailing, 14)
            .frame(height: 52)
            Hairline()
            MBSearchField(placeholder: "Search connections", text: $list.filter).padding(10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list.grouped, id: \.group) { group in
                        if !group.group.isEmpty {
                            Text(group.group.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4)
                                .foregroundStyle(MB.dim).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                        }
                        ForEach(group.items) { c in
                            ConnectionRow(config: c, selected: list.selected == c.id)
                                .onTapGesture(count: 2) { list.select(c.id); list.connect(window: window()) }
                                .onTapGesture { list.select(c.id) }
                                .contextMenu {
                                    Button("Connect") { list.select(c.id); list.connect(window: window()) }
                                    Button("Duplicate") { list.duplicate(c.id) }
                                    Button("Export…") { list.exportConnections([c.id]) }
                                    Divider()
                                    Button("Delete…") {
                                        Task {
                                            if await confirm("Delete \(c.displayName)?", detail: "The connection, its saved password, history and saved queries are removed. The database itself isn't touched.",
                                                             button: "Delete", window: window()) { list.delete(c.id) }
                                        }
                                    }
                                }
                        }
                    }
                    if list.connections.isEmpty {
                        Text("No connections yet").font(.system(size: 12)).foregroundStyle(MB.dim).padding(16)
                    }
                }
                .padding(.vertical, 4)
            }
            Hairline()
            HStack {
                Menu {
                    ForEach(DatabaseKind.allCases, id: \.self) { k in Button(k.title) { list.newConnection(kind: k) } }
                    Divider()
                    Button("Import connections…") { list.importConnections() }
                    Button("Import from URLs…") { list.importURLs() }
                    Button("Export connections…") { list.exportConnections() }
                } label: {
                    Label("New connection", systemImage: "plus")
                } primaryAction: {
                    list.newConnection()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 44)
        }
    }
}

struct ConnectionRow: View {
    let config: ConnectionConfig
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(MB.wash(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(MB.line))
                Image(systemName: config.kind.symbol).font(.system(size: 12)).foregroundStyle(MB.muted)
            }
            .frame(width: 30, height: 30)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(config.environment.color).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(MB.sidebar, lineWidth: 1.5)).offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(config.displayName).font(.system(size: 13, weight: .medium)).foregroundStyle(MB.text).lineLimit(1)
                Text(config.summary).font(.system(size: 11)).foregroundStyle(MB.dim).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? MB.selected : hovering ? MB.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ConnectionEditor: View {
    @ObservedObject var list: ConnectionList
    let window: () -> NSWindow?
    @State private var url = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(list.isNew ? "New connection" : list.draft.displayName)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 24).frame(height: 52)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    row("Type") {
                        Picker("", selection: kindBinding) {
                            ForEach(DatabaseKind.allCases, id: \.self) { k in Label(k.title, systemImage: k.symbol).tag(k) }
                        }
                        .labelsHidden().frame(width: 240)
                    }
                    row("Name") { MBField(placeholder: list.draft.displayName, text: $list.draft.name) }
                    row("Tag") {
                        MBSegmented(options: ConnectionConfig.Environment.allCases, selection: Binding(get: { list.draft.environment }, set: { e in
                            // Tagging a connection production makes it ask before writes, unless you chose something stricter.
                            if e == .production && list.draft.safeMode == .off { list.draft.safeMode = .confirmWrites }
                            list.draft.environment = e
                        }),
                                    label: { $0.title }, tint: { $0.color })
                    }
                    row("Group") { MBField(placeholder: "Optional, e.g. a client or project", text: $list.draft.group) }
                    Hairline()
                    if list.draft.kind.isFile {
                        row("File") {
                            HStack(spacing: 8) {
                                MBField(placeholder: list.draft.kind == .duckdb ? "~/data.duckdb, or empty for in-memory" : "~/path/to/database.sqlite",
                                        text: $list.draft.filePath, mono: true)
                                Button("Choose…") { chooseFile() }.buttonStyle(.mbQuiet)
                            }
                        }
                        if list.draft.kind == .duckdb { toolRow("duckdb", install: "brew install duckdb") }
                    } else if list.draft.kind.isCloudAPI {
                        cloudFields
                    } else {
                        row("URL") {
                            HStack(spacing: 8) {
                                MBField(placeholder: "Paste postgres://user:pass@host:5432/db to fill in", text: $url, mono: true)
                                    .onSubmit(applyURL)
                                Button("Fill in") { applyURL() }.buttonStyle(.mbQuiet).disabled(url.isEmpty)
                            }
                        }
                        row(list.draft.kind == .libsql ? "URL" : "Host") {
                            HStack(spacing: 8) {
                                MBField(placeholder: hostPlaceholder, text: $list.draft.host, mono: true)
                                Text("Port").font(.system(size: 12)).foregroundStyle(MB.dim)
                                MBField(placeholder: "\(list.draft.kind.defaultPort)", text: portBinding, mono: true).frame(width: 80)
                            }
                        }
                        if list.draft.kind != .libsql {
                            row("User") { MBField(placeholder: list.draft.kind == .redis ? "Optional (ACL user)" : "user", text: $list.draft.user, mono: true) }
                        }
                        row(list.draft.kind == .libsql ? "Token" : "Password") {
                            MBField(placeholder: list.draft.kind == .libsql ? "Auth token (empty for a local sqld); stored in your Keychain" : "Stored in your Keychain",
                                    text: $list.password, secure: true)
                        }
                        if list.draft.kind != .libsql {
                            row(databaseLabel) { MBField(placeholder: databasePlaceholder, text: $list.draft.database, mono: true) }
                        }
                        if list.draft.kind == .oracle { toolRow("sqlplus", install: "Oracle Instant Client (Basic and SQL*Plus)") }
                        if list.draft.kind == .mongodb {
                            row("Auth source") { MBField(placeholder: "admin", text: option("authSource"), mono: true) }
                            row("") {
                                Toggle("mongodb+srv (look the servers up in DNS, as Atlas does)", isOn: flag("srv")).toggleStyle(.checkbox)
                                    .font(.system(size: 12.5)).foregroundStyle(MB.text)
                            }
                        }
                        if list.draft.kind == .sqlserver {
                            row("") {
                                Toggle("Strict encryption (TDS 8: TLS from the start, SQL Server 2022 / Azure SQL)", isOn: flag("strict")).toggleStyle(.checkbox)
                                    .font(.system(size: 12.5)).foregroundStyle(MB.text)
                            }
                        }
                        row("TLS") {
                            HStack(spacing: 10) {
                                MBSegmented(options: ConnectionConfig.TLS.allCases, selection: $list.draft.tls) { $0.title }
                                Text(tlsHelp).font(.system(size: 11.5)).foregroundStyle(MB.dim)
                            }
                        }
                        if list.draft.tls != .off {
                            row("CA file") {
                                HStack(spacing: 8) {
                                    MBField(placeholder: "Optional: your own CA certificate (.pem, .crt)", text: $list.draft.caFile, mono: true)
                                    Button("Choose…") { choose(\.caFile, message: "Choose the CA certificate") }.buttonStyle(.mbQuiet)
                                }
                            }
                            row("Client cert") {
                                HStack(spacing: 8) {
                                    MBField(placeholder: "Optional: certificate and key as .p12", text: $list.draft.clientCertFile, mono: true)
                                    Button("Choose…") { choose(\.clientCertFile, message: "Choose the client certificate (.p12)") }.buttonStyle(.mbQuiet)
                                }
                            }
                            if !list.draft.clientCertFile.isEmpty {
                                row(".p12 password") { MBField(placeholder: "Stored in your Keychain", text: $list.certificatePassword, secure: true) }
                            }
                        }
                        Hairline()
                        row("SSH") {
                            Toggle("Connect through an SSH tunnel", isOn: $list.draft.sshEnabled).toggleStyle(.checkbox)
                                .font(.system(size: 12.5)).foregroundStyle(MB.text)
                        }
                        if list.draft.sshEnabled {
                            row("SSH host") {
                                HStack(spacing: 8) {
                                    MBField(placeholder: "server or ~/.ssh/config alias", text: $list.draft.sshHost, mono: true)
                                    Text("Port").font(.system(size: 12)).foregroundStyle(MB.dim)
                                    MBField(placeholder: "22", text: sshPortBinding, mono: true).frame(width: 64)
                                }
                            }
                            row("SSH user") { MBField(placeholder: "Optional, from ~/.ssh/config", text: $list.draft.sshUser, mono: true) }
                            row("Sign in with") {
                                MBSegmented(options: [false, true], selection: $list.draft.sshUsePassword) { $0 ? "Password" : "Key or agent" }
                            }
                            if list.draft.sshUsePassword {
                                row("SSH password") { MBField(placeholder: "Stored in your Keychain", text: $list.sshSecret, secure: true) }
                            } else {
                                row("Key file") {
                                    HStack(spacing: 8) {
                                        MBField(placeholder: "Optional; your ssh agent is used otherwise", text: $list.draft.sshKeyPath, mono: true)
                                        Button("Choose…") { chooseKey() }.buttonStyle(.mbQuiet)
                                    }
                                }
                                row("Passphrase") { MBField(placeholder: "Only if the key has one; stored in your Keychain", text: $list.sshSecret, secure: true) }
                            }
                            row("") {
                                Text("Host and port above are as seen from the SSH server, often 127.0.0.1. Your ~/.ssh/config, agent and known hosts are used as in Terminal.")
                                    .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Hairline()
                    row("Safe mode") {
                        Picker("", selection: $list.draft.safeMode) {
                            ForEach(ConnectionConfig.SafeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 240)
                    }
                    row("") {
                        Text(safeModeHelp).font(.system(size: 11.5)).foregroundStyle(list.draft.safeMode == .off ? MB.dim : MB.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
            }
            Hairline()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let busy = list.busy {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text(busy).font(.system(size: 12)).foregroundStyle(MB.muted)
            } else if let r = list.testResult {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.ok ? MB.green : MB.red).font(.system(size: 12))
                Text(r.text).font(.system(size: 12)).foregroundStyle(r.ok ? MB.muted : MB.red).lineLimit(3)
                    .textSelection(.enabled).help(r.text)
            }
            Spacer()
            Button("Test") { list.test() }.buttonStyle(.mbQuiet).disabled(list.busy != nil)
            Button("Save") { list.save() }.buttonStyle(.mbQuiet).disabled(list.busy != nil)
            Button("Connect") { list.connect(window: window()) }.buttonStyle(.mbPrimary).disabled(list.busy != nil)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20).frame(height: 54)
        .background(MB.bar)
    }

    private var hostPlaceholder: String {
        switch list.draft.kind {
        case .libsql: "https://your-db.turso.io, or 127.0.0.1"
        case .mongodb: "127.0.0.1, or a,b,c for a replica set"
        default: "127.0.0.1, or a socket like /tmp"
        }
    }

    private var databaseLabel: String {
        switch list.draft.kind {
        case .redis: "DB number"
        case .cassandra: "Keyspace"
        case .oracle: "Service"
        default: "Database"
        }
    }

    private var databasePlaceholder: String {
        switch list.draft.kind {
        case .postgres: "Defaults to the user name"
        case .redis: "0"
        case .oracle: "FREEPDB1, ORCLPDB1, …"
        case .sqlserver: "master"
        case .clickhouse: "default"
        case .mongodb: "test"
        default: "Optional"
        }
    }

    private func option(_ key: String) -> Binding<String> {
        Binding(get: { list.draft.options[key] ?? "" }, set: { list.draft.options[key] = $0.isEmpty ? nil : $0 })
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { list.draft.options[key] == "1" }, set: { list.draft.options[key] = $0 ? "1" : nil })
    }

    @ViewBuilder private func toolRow(_ name: String, install: String) -> some View {
        row("Tool") {
            VStack(alignment: .leading, spacing: 4) {
                MBField(placeholder: ToolFinder.find(name, configured: nil).map { "Found: \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "Path to \(name)",
                        text: option("tool"), mono: true)
                Text(ToolFinder.find(name, configured: list.draft.options["tool"]) == nil ? "\(name) isn't installed. Install \(install)." :
                        "Maben Base runs your \(name) to talk to the database.")
                    .font(.system(size: 11.5)).foregroundStyle(ToolFinder.find(name, configured: list.draft.options["tool"]) == nil ? MB.orange : MB.dim)
            }
        }
    }

    /// BigQuery, Snowflake and D1: reached over HTTPS with their own sign-in.
    @ViewBuilder private var cloudFields: some View {
        switch list.draft.kind {
        case .bigquery:
            row("Project ID") { MBField(placeholder: "my-project-123", text: $list.draft.host, mono: true) }
            row("Dataset") { MBField(placeholder: "Optional default dataset", text: $list.draft.database, mono: true) }
            row("Key file") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        MBField(placeholder: "Service account key (.json); empty uses your gcloud login", text: $list.draft.filePath, mono: true)
                        Button("Choose…") { choose(\.filePath, message: "Choose the service account key (.json)") }.buttonStyle(.mbQuiet)
                    }
                }
            }
            row("Endpoint") { MBField(placeholder: "Optional, for an emulator: http://127.0.0.1:9050", text: option("endpoint"), mono: true) }
        case .snowflake:
            row("Account") { MBField(placeholder: "orgname-accountname, or xy12345.eu-west-1", text: $list.draft.host, mono: true) }
            row("User") { MBField(placeholder: "user", text: $list.draft.user, mono: true) }
            row("Token") { MBField(placeholder: "Programmatic access token; stored in your Keychain", text: $list.password, secure: true) }
            row("Key file") {
                HStack(spacing: 8) {
                    MBField(placeholder: "Or: key-pair sign-in with an unencrypted .p8 key", text: $list.draft.filePath, mono: true)
                    Button("Choose…") { choose(\.filePath, message: "Choose the private key (.p8)") }.buttonStyle(.mbQuiet)
                }
            }
            row("Database") { MBField(placeholder: "Optional", text: $list.draft.database, mono: true) }
            row("Warehouse") { MBField(placeholder: "Optional", text: option("warehouse"), mono: true) }
            row("Role") { MBField(placeholder: "Optional", text: option("role"), mono: true) }
        default:
            row("Account ID") { MBField(placeholder: "Cloudflare account ID", text: $list.draft.host, mono: true) }
            row("Database ID") { MBField(placeholder: "The D1 database's UUID", text: $list.draft.database, mono: true) }
            row("API token") { MBField(placeholder: "A token with D1 edit permission; stored in your Keychain", text: $list.password, secure: true) }
        }
    }

    private var safeModeHelp: String {
        switch list.draft.safeMode {
        case .off: "Queries and edits run right away."
        case .confirmWrites: "Asks before saving edits, changing structure, or running statements that change data."
        case .confirmAll: "Asks before every query you run, and before saving edits."
        case .authenticate: "Asks for Touch ID or your Mac password before anything that changes data."
        case .readOnly: "Never writes: editing is off and statements that change data don't run."
        }
    }

    private func choose(_ field: WritableKeyPath<ConnectionConfig, String>, message: String) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.showsHiddenFiles = true
        guard let w = window() else { return }
        panel.beginSheetModal(for: w) { r in
            guard r == .OK, let url = panel.url else { return }
            list.draft[keyPath: field] = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private var tlsHelp: String {
        switch list.draft.tls {
        case .off: "Plain connection"
        case .prefer: "TLS when the server offers it"
        case .require: "TLS, any certificate"
        case .verify: "TLS, valid certificate"
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(MB.muted).frame(width: 80, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindBinding: Binding<DatabaseKind> {
        Binding(get: { list.draft.kind }, set: { k in
            if list.draft.port == list.draft.kind.defaultPort || list.draft.port == 0 { list.draft.port = k.defaultPort }
            list.draft.kind = k
        })
    }

    private var portBinding: Binding<String> {
        Binding(get: { list.draft.port == 0 ? "" : "\(list.draft.port)" },
                set: { list.draft.port = Int($0.filter(\.isNumber)) ?? 0 })
    }

    private var sshPortBinding: Binding<String> {
        Binding(get: { "\(list.draft.sshPort)" }, set: { list.draft.sshPort = Int($0.filter(\.isNumber)) ?? 22 })
    }

    private func applyURL() {
        var c = list.draft
        let r = c.apply(url: url)
        guard r.ok else {
            list.testResult = (false, "That isn't a postgres://, mysql:// or sqlite:// URL.")
            return
        }
        list.draft = c
        if let pw = r.password { list.password = pw }
        url = ""
        list.testResult = nil
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SQLite database file"
        guard let w = window() else { return }
        panel.beginSheetModal(for: w) { r in
            guard r == .OK, let url = panel.url else { return }
            list.draft.filePath = (url.path as NSString).abbreviatingWithTildeInPath
            if list.draft.name.isEmpty { list.draft.name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.showsHiddenFiles = true
        guard let w = window() else { return }
        panel.beginSheetModal(for: w) { r in
            guard r == .OK, let url = panel.url else { return }
            list.draft.sshKeyPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

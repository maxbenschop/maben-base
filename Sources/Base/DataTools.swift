import AppKit
import BaseCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export formats

enum ExportFormat: String, CaseIterable, Hashable {
    case csv, json, xlsx, markdown, sql

    static let results: [ExportFormat] = [.csv, .json, .xlsx, .markdown, .sql]

    var title: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .xlsx: "Excel"
        case .markdown: "Markdown"
        case .sql: "SQL inserts"
        }
    }

    var fileExtension: String { self == .markdown ? "md" : rawValue }

    var type: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        case .xlsx: UTType(filenameExtension: "xlsx") ?? .data
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .sql: UTType(filenameExtension: "sql") ?? .plainText
        }
    }

    func data(columns: [ResultColumn], rows: [[String?]], name: String, table: TableRef?, dialect: Dialect) -> Data {
        switch self {
        case .csv: Data(Export.csv(columns: columns, rows: rows).utf8)
        case .json: Data(Export.json(columns: columns, rows: rows).utf8)
        case .xlsx: Export.xlsx([.init(name: name, columns: columns, rows: rows)])
        case .markdown: Data(Export.markdown(columns: columns, rows: rows).utf8)
        case .sql: Data((dialect.insertStatements(table: table ?? TableRef(schema: nil, name: name), columns: columns, rows: rows)
                         .joined(separator: "\n") + "\n").utf8)
        }
    }
}

// MARK: - Snippets

/// Snippets for the SQL editor, shared by every connection. Starts with the built-in set.
@MainActor
final class SnippetLibrary: ObservableObject {
    static let shared = SnippetLibrary()
    private let store = Store()
    @Published var snippets: [Store.Snippet]

    private init() { snippets = store.snippets() ?? SnippetText.builtIn }

    func save() { store.save(snippets: snippets) }

    func resetToBuiltIn() {
        snippets = SnippetText.builtIn
        save()
    }
}

struct SnippetsSheet: View {
    @ObservedObject var library = SnippetLibrary.shared
    @State private var selection: UUID?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippets").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
            Text("Type a trigger in the editor and press Tab. ${1:name} marks a place Tab visits; $0 is where the cursor ends.")
                .font(.system(size: 12)).foregroundStyle(MB.dim)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(library.snippets) { s in
                                HStack {
                                    Text(s.trigger).font(MB.mono).foregroundStyle(MB.accentInk).frame(width: 54, alignment: .leading)
                                    Text(s.name).font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(selection == s.id ? MB.selected : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { selection = s.id }
                            }
                        }
                        .padding(4)
                    }
                    Hairline()
                    HStack {
                        MBIconButton(symbol: "plus", help: "New snippet") {
                            let s = Store.Snippet(trigger: "new", name: "New snippet", body: "SELECT ${1:*} FROM ${2:table};$0")
                            library.snippets.append(s)
                            selection = s.id
                            library.save()
                        }
                        MBIconButton(symbol: "minus", help: "Delete snippet") {
                            library.snippets.removeAll { $0.id == selection }
                            selection = library.snippets.first?.id
                            library.save()
                        }
                        Spacer()
                        Button("Restore built-in") { library.resetToBuiltIn(); selection = library.snippets.first?.id }.buttonStyle(.mbPlain)
                    }
                    .padding(4)
                }
                .frame(width: 260, height: 360)
                .background(RoundedRectangle(cornerRadius: 8).fill(MB.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MB.line))

                if let i = library.snippets.firstIndex(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            MBField(placeholder: "trigger", text: $library.snippets[i].trigger, mono: true).frame(width: 110)
                            MBField(placeholder: "name", text: $library.snippets[i].name)
                        }
                        TextEditor(text: $library.snippets[i].body)
                            .font(MB.mono).scrollContentBackground(.hidden).padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(MB.wash(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MB.line))
                    }
                    .onChange(of: library.snippets) { _, _ in library.save() }
                } else {
                    Text("Pick a snippet to edit it.").font(.system(size: 12)).foregroundStyle(MB.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack { Spacer(); Button("Done", action: close).buttonStyle(.mbPrimary).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 760, height: 520)
        .background(MB.bg)
        .onAppear { selection = library.snippets.first?.id }
    }
}

// MARK: - Export a whole database

struct ExportDatabaseSheet: View {
    @ObservedObject var workspace: Workspace
    let close: () -> Void
    enum Kind: String, CaseIterable { case sql = "One SQL file", xlsx = "Excel workbook", csv = "CSV per table", json = "JSON per table" }
    @State private var kind: Kind = .sql
    @State private var chosen: Set<String> = []
    @State private var progress: (done: Int, total: Int, name: String)?
    @State private var result: String?

    private var tables: [DBObject] { workspace.objects.filter { $0.kind.isRelation && $0.kind != .function } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export \(workspace.database ?? workspace.config.displayName)").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
            MBSegmented(options: Kind.allCases, selection: $kind) { $0.rawValue }
            Text(kind == .sql ? "CREATE statements and INSERTs for the tables, then the views. For a full backup with sequences, triggers and permissions, use Backup instead."
                 : kind == .xlsx ? "One sheet per table or view." : "One file per table or view, in a folder you choose.")
                .font(.system(size: 12)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(chosen.count) of \(tables.count) chosen").font(.system(size: 12)).foregroundStyle(MB.muted)
                Spacer()
                Button("All") { chosen = Set(tables.map(\.id)) }.buttonStyle(.mbPlain)
                Button("None") { chosen = [] }.buttonStyle(.mbPlain)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(tables) { o in
                        Toggle(isOn: Binding(get: { chosen.contains(o.id) }, set: { if $0 { chosen.insert(o.id) } else { chosen.remove(o.id) } })) {
                            HStack(spacing: 6) {
                                Image(systemName: o.kind.symbol).font(.system(size: 10)).foregroundStyle(MB.dim)
                                Text(o.name).font(.system(size: 12.5)).foregroundStyle(MB.text)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
                .padding(10)
            }
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: 8).fill(MB.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MB.line))
            if let p = progress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))) { Text(p.name).font(.system(size: 11.5)).foregroundStyle(MB.dim) }
            }
            if let result { Text(result).font(.system(size: 12)).foregroundStyle(MB.muted).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done", action: close).buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button("Export…") { start() }.buttonStyle(.mbPrimary).disabled(chosen.isEmpty || progress != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(MB.bg)
        .onAppear { chosen = Set(tables.filter { $0.kind == .table }.map(\.id)) }
    }

    private func start() {
        let objects = tables.filter { chosen.contains($0.id) }
        let base = (workspace.database ?? workspace.config.displayName).replacingOccurrences(of: "/", with: "-")
        let url: URL?
        if kind == .csv || kind == .json {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export here"
            url = panel.runModal() == .OK ? panel.url : nil
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(base).\(kind == .sql ? "sql" : "xlsx")"
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return }
        progress = (0, objects.count, "")
        let kind = self.kind
        let report: @Sendable (Int, String) -> Void = { done, name in
            DispatchQueue.main.async { progress = (done, objects.count, name) }
        }
        Task {
            do {
                try await workspace.session.run { d in
                    switch kind {
                    case .sql:
                        try Dump.sql(driver: d, objects: objects, to: url, progress: report)
                    case .xlsx:
                        var sheets: [Export.Sheet] = []
                        for (i, o) in objects.enumerated() {
                            report(i, o.name)
                            let r = try d.execute("SELECT * FROM \(d.dialect.qualified(o.table))").first(where: \.hasRows) ?? QueryResult()
                            sheets.append(.init(name: o.name, columns: r.columns, rows: r.rows))
                        }
                        try Export.xlsx(sheets).write(to: url)
                    case .csv, .json:
                        for (i, o) in objects.enumerated() {
                            report(i, o.name)
                            let r = try d.execute("SELECT * FROM \(d.dialect.qualified(o.table))").first(where: \.hasRows) ?? QueryResult()
                            let text = kind == .csv ? Export.csv(columns: r.columns, rows: r.rows) : Export.json(columns: r.columns, rows: r.rows)
                            try text.write(to: url.appendingPathComponent("\(o.name).\(kind == .csv ? "csv" : "json")"), atomically: true, encoding: .utf8)
                        }
                    }
                }
                progress = nil
                result = "Exported \(objects.count) to \((url.path as NSString).abbreviatingWithTildeInPath)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                progress = nil
                result = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Backup and restore

struct BackupSheet: View {
    @ObservedObject var workspace: Workspace
    let close: () -> Void
    @State private var plainSQL = false
    @State private var running: String?
    @State private var log = ""
    @State private var succeeded: Bool?

    private var kind: DatabaseKind { workspace.session.kind }
    private var maria: Bool { workspace.session.serverVersion.localizedCaseInsensitiveContains("mariadb") }

    private var dumpTool: String? {
        switch kind {
        case .postgres: BackupTool.find("pg_dump")
        case .mysql: maria ? BackupTool.find("mariadb-dump") ?? BackupTool.find("mysqldump") : BackupTool.find("mysqldump") ?? BackupTool.find("mariadb-dump")
        case .sqlite: "built in"
        default: nil
        }
    }

    /// Engines with a backup here: Postgres and MySQL through their tools, SQLite inside the app.
    private var supported: Bool { [.postgres, .mysql, .sqlite].contains(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backup and restore").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
            Text(workspace.database.map { "Database \($0) on \(workspace.config.displayName)" } ?? workspace.config.displayName)
                .font(.system(size: 12)).foregroundStyle(MB.dim)
            if !supported {
                Text("\(kind.title) backups are made with its own tools or console. File › Export Database writes the tables and their rows as SQL, Excel, CSV or JSON.")
                    .font(.system(size: 12.5)).foregroundStyle(MB.muted).fixedSize(horizontal: false, vertical: true)
            } else if kind == .sqlite {
                Text("Backup writes a consistent copy of the database file (VACUUM INTO), safe while the app is using it. To restore, open the copy as a connection, or run a .sql file with Import SQL.")
                    .font(.system(size: 12.5)).foregroundStyle(MB.muted).fixedSize(horizontal: false, vertical: true)
            } else if let tool = dumpTool {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(MB.green).font(.system(size: 11))
                    Text("Uses \((tool as NSString).abbreviatingWithTildeInPath)").font(MB.mono).foregroundStyle(MB.muted)
                }
                if kind == .postgres {
                    Toggle("Plain SQL file instead of pg_dump's compressed format", isOn: $plainSQL).toggleStyle(.checkbox)
                        .font(.system(size: 12.5)).foregroundStyle(MB.text)
                }
                Text("Restore reads a .dump (pg_restore), or a .sql file (\(kind == .postgres ? "psql" : maria ? "mariadb" : "mysql")), into this database. It adds to what's there; it doesn't empty the database first.")
                    .font(.system(size: 12)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(kind == .postgres ? "pg_dump" : maria ? "mariadb-dump" : "mysqldump") isn't installed.").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MB.orange)
                    Text("Install it with Homebrew: brew install \(kind == .postgres ? "libpq" : maria ? "mariadb" : "mysql-client"). Or use File › Export Database for a SQL file made by the app itself.")
                        .font(.system(size: 12)).foregroundStyle(MB.muted).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if !log.isEmpty || running != nil {
                ScrollView {
                    Text(log.isEmpty ? (running ?? "") : log).font(MB.mono).foregroundStyle(succeeded == false ? MB.red : MB.muted)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 8).fill(MB.card))
            }
            HStack {
                if let running { ProgressView().controlSize(.small); Text(running).font(.system(size: 12)).foregroundStyle(MB.muted) }
                Spacer()
                Button("Close", action: close).buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                if kind != .sqlite && supported {
                    Button("Restore…") { restore() }.buttonStyle(.mbQuiet).disabled(running != nil || dumpTool == nil || workspace.config.readOnly)
                }
                Button("Back up…") { backup() }.buttonStyle(.mbPrimary).disabled(running != nil || dumpTool == nil || !supported)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(MB.bg)
    }

    private var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }

    private func backup() {
        let panel = NSSavePanel()
        let base = (workspace.database ?? workspace.config.displayName).replacingOccurrences(of: "/", with: "-")
        let ext = kind == .sqlite ? "sqlite" : (kind == .postgres && !plainSQL) ? "dump" : "sql"
        panel.nameFieldStringValue = "\(base)-\(stamp).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if kind == .sqlite {
            running = "Copying…"
            Task {
                do {
                    try? FileManager.default.removeItem(at: url)
                    _ = try await workspace.session.run { try $0.execute("VACUUM INTO \(Dialect(kind: .sqlite).literal(url.path))") }
                    finish(true, "Saved \((url.path as NSString).abbreviatingWithTildeInPath).")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch { finish(false, error.localizedDescription) }
            }
            return
        }
        do {
            let (host, port) = workspace.session.endpoint
            let cmd = try BackupTool.backup(kind: kind, host: host, port: port, user: workspace.config.user, password: workspace.session.password ?? "",
                                            database: workspace.database ?? workspace.config.database, tls: workspace.config.tls,
                                            file: url.path, plainSQL: plainSQL, serverVersion: workspace.session.serverVersion)
            run(cmd, label: "Backing up…") { ok in
                if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                return ok ? "Saved \((url.path as NSString).abbreviatingWithTildeInPath)." : nil
            }
        } catch { finish(false, error.localizedDescription) }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.message = "Choose a backup to restore into \(workspace.database ?? "this database")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let env = workspace.config.environment == .production ? "This is a production connection.\n\n" : ""
            guard await confirm("Restore \(url.lastPathComponent) into \(workspace.database ?? "this database")?",
                                detail: "\(env)The backup's statements run against this database. Tables that already exist can make it fail partway.",
                                button: "Restore", window: workspace.window) else { return }
            guard await workspace.allow("restore \(url.lastPathComponent)", write: true, alreadyConfirmed: true) else { return }
            do {
                let (host, port) = workspace.session.endpoint
                let cmd = try BackupTool.restore(kind: kind, host: host, port: port, user: workspace.config.user, password: workspace.session.password ?? "",
                                                 database: workspace.database ?? workspace.config.database, tls: workspace.config.tls,
                                                 file: url.path, serverVersion: workspace.session.serverVersion)
                run(cmd, label: "Restoring…") { ok in
                    if ok { Task { await workspace.reloadObjects() } }
                    return ok ? "Restored \(url.lastPathComponent)." : nil
                }
            } catch { finish(false, error.localizedDescription) }
        }
    }

    private func run(_ cmd: BackupTool.Command, label: String, done: @escaping (Bool) -> String?) {
        running = label
        log = ""
        succeeded = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd.executable)
        process.arguments = cmd.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(cmd.environment) { $1 }
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        if let input = cmd.inputFile { process.standardInput = FileHandle(forReadingAtPath: input) }
        DispatchQueue.global(qos: .userInitiated).async {
            var text = ""
            var status: Int32 = -1
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                status = process.terminationStatus
                text = String(decoding: data, as: UTF8.self)
            } catch {
                text = error.localizedDescription
            }
            let ok = status == 0
            let finalText = text
            DispatchQueue.main.async {
                let message = done(ok)
                var out = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let hint = BackupTool.hint(for: out) { out = hint + "\n\n" + out }
                finish(ok, [message, out.isEmpty ? nil : out].compactMap { $0 }.joined(separator: "\n\n"))
            }
        }
    }

    private func finish(_ ok: Bool, _ text: String) {
        running = nil
        succeeded = ok
        log = text.isEmpty ? (ok ? "Done." : "It didn't work.") : text
    }
}

// MARK: - Import a SQL file

extension Workspace {
    /// Runs a .sql file statement by statement, stopping at the first error.
    func importSQLFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.message = "Choose a SQL file to run against \(database ?? config.displayName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("FROM stdin;") || text.range(of: #"(?m)^DELIMITER "#, options: .regularExpression) != nil {
                    throw DatabaseError("This file needs the database's own tool.",
                                        detail: "It uses COPY … FROM stdin or DELIMITER, which only psql and mysql understand. Use File › Backup and Restore › Restore instead.")
                }
                let statements = SQLText.statements(in: text).map(\.sql)
                guard !statements.isEmpty else { throw DatabaseError("The file has no SQL statements.") }
                let env = config.environment == .production ? "This is a production connection.\n\n" : ""
                guard await confirm("Run \(statements.count.formatted()) statement\(statements.count == 1 ? "" : "s") from \(url.lastPathComponent)?",
                                    detail: "\(env)They run one by one against \(database ?? config.displayName), and stop at the first error. What ran before an error stays.",
                                    button: "Run", destructive: config.environment == .production, window: window) else { return }
                guard await allow(statements.prefix(5).joined(separator: ";\n"), write: statements.contains(where: SQLText.isWrite), alreadyConfirmed: true) else { return }
                importProgress = (0, statements.count)
                let report: @Sendable (Int) -> Void = { done in DispatchQueue.main.async { self.importProgress = (done, statements.count) } }
                do {
                    try await session.run { d in
                        for (i, s) in statements.enumerated() {
                            do { _ = try d.execute(s) } catch var e as DatabaseError {
                                e.message = "Statement \(i + 1) of \(statements.count): \(e.message)"
                                e.detail = [e.detail, String(s.prefix(300))].compactMap { $0 }.joined(separator: "\n\n")
                                throw e
                            }
                            if i % 25 == 0 { report(i) }
                        }
                    }
                    importProgress = nil
                    recordHistory("-- ran \(url.lastPathComponent) (\(statements.count) statements)", ms: nil, failed: false)
                } catch {
                    importProgress = nil
                    throw error
                }
                await reloadObjects()
                for case .table(let t) in tabs { await t.load() }
            } catch {
                showError(error, in: window, title: "Import stopped")
            }
        }
    }
}

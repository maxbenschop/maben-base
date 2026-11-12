import AppKit
import BaseCore
import SwiftUI

/// A SQL editor with its results. Results are read-only and sort in memory.
@MainActor
final class QueryTab: ObservableObject, GridSource, Identifiable {
    let id = UUID()
    unowned let workspace: Workspace

    @Published var name: String
    @Published var text: String
    @Published private(set) var results: [QueryResult] = []
    @Published var selectedResult = 0
    @Published private(set) var error: String?
    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published private(set) var gridVersion = 0
    @Published private(set) var gridColumnsVersion = 0
    @Published var focusToken = 0
    @Published private(set) var selection = IndexSet()
    /// A query plan as text (Explain), shown instead of the grid.
    @Published private(set) var plan: String?
    /// Waiting for values of :name parameters.
    @Published var prompt: ParameterPrompt?
    /// Format and snippet insertion go through the editor so they can be undone.
    @Published private(set) var replaceToken = 0
    @Published private(set) var replacement = ""
    @Published private(set) var snippetToken = 0
    @Published private(set) var snippetToInsert: Store.Snippet?
    /// The saved query this tab edits, if any.
    var savedID: UUID?
    /// The statement under the cursor (or the selection), for Explain and Run in new tab.
    var cursorStatement = ""
    var statementAtCursor: String { cursorStatement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : cursorStatement }
    private var sortedRows: [[String?]]?
    /// Last values typed for each parameter, offered again next time.
    private var parameterValues: [String: String] = [:]

    struct ParameterPrompt: Identifiable {
        let id = UUID()
        var sql: String
        var names: [String]
        var values: [String: String]
        var explain: Bool
    }

    /// Settings › Query results; 0 keeps every row.
    static var rowLimit: Int { Preferences.queryRowLimit == 0 ? .max : Preferences.queryRowLimit }
    /// The last statements run, for Load all.
    private var lastRun: String?

    init(workspace: Workspace, name: String = "Query", text: String = "") {
        self.workspace = workspace
        self.name = name
        self.text = text
    }

    var title: String { name }

    // MARK: Running

    func run(_ sql: String) {
        guard !running else { return }
        if let p = promptIfNeeded(sql, explain: false) { prompt = p; return }
        Task { await execute(sql) }
    }

    func runAll() { run(text) }

    /// Runs this statement in a new tab, so these results stay.
    func runInNewTab(_ sql: String) {
        let tab = workspace.newQuery(text: sql)
        tab.run(sql)
    }

    private func promptIfNeeded(_ sql: String, explain: Bool) -> ParameterPrompt? {
        let names = SQLText.parameters(in: sql)
        // MySQL user variables (@x) and Postgres $1 never get here; only :name.
        guard !names.isEmpty else { return nil }
        return ParameterPrompt(sql: sql, names: names, values: Dictionary(uniqueKeysWithValues: names.map { ($0, parameterValues[$0] ?? "") }),
                               explain: explain)
    }

    func runPrompt(_ p: ParameterPrompt) {
        prompt = nil
        for (k, v) in p.values { parameterValues[k] = v }
        let bound = SQLText.bind(p.sql, values: p.values, dialect: workspace.session.dialect)
        Task { p.explain ? await explainNow(bound, analyze: false) : await execute(bound) }
    }

    /// Runs the last statements again, keeping every row.
    func loadAll() {
        guard let sql = lastRun, !running else { return }
        Task { await execute(sql, limit: .max, confirmed: true) }
    }

    private func execute(_ sql: String, limit: Int? = nil, confirmed: Bool = false) async {
        let limit = limit ?? Self.rowLimit
        if !confirmed { guard await workspace.allow(sql, write: SQLText.isWrite(sql)) else { return } }
        lastRun = sql
        running = true
        error = nil
        plan = nil
        status = "Running…"
        let start = Date()
        do {
            // Postgres runs a multi-statement string as one implicit transaction (so CREATE DATABASE fails and
            // one error undoes everything before it). Send statements one at a time, as psql does.
            // MySQL and SQLite already run a script statement by statement and keep what ran.
            let parts = workspace.session.kind == .postgres ? SQLText.statements(in: sql).map(\.sql) : [sql]
            let out = try await workspace.session.run { d -> [QueryResult] in
                var all: [QueryResult] = []
                for part in parts {
                    do { all += try d.execute(part, rowLimit: limit) } catch var e as DatabaseError {
                        e.completed = all + e.completed
                        if parts.count > 1 { e.message = "Statement \(all.count + 1) of \(parts.count): " + e.message }
                        throw e
                    }
                }
                return all
            }
            show(out, ms: Int(Date().timeIntervalSince(start) * 1000))
            workspace.recordHistory(sql, ms: Int(Date().timeIntervalSince(start) * 1000), failed: false)
            // Schema may have changed.
            if SQLText.isWrite(sql) && sql.range(of: #"\b(create|drop|alter|rename)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                await workspace.reloadObjects()
            }
        } catch let e as DatabaseError {
            if !e.completed.isEmpty { show(e.completed, ms: Int(Date().timeIntervalSince(start) * 1000)) }
            error = e.localizedDescription
            status = nil
            workspace.recordHistory(sql, ms: nil, failed: true)
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
        running = false
    }

    private func show(_ out: [QueryResult], ms: Int) {
        results = out
        plan = nil
        let withRows = out.lastIndex(where: \.hasRows)
        selectedResult = withRows ?? max(0, out.count - 1)
        sortedRows = nil
        selection = []
        gridColumnsVersion += 1
        gridVersion += 1
        let last = out.isEmpty ? nil : out[selectedResult]
        var parts: [String] = []
        if let last {
            if last.hasRows {
                if last.truncated {
                    parts.append("First \(last.rows.count.formatted()) rows; more weren't loaded")
                } else {
                    parts.append("\(last.rows.count.formatted()) row\(last.rows.count == 1 ? "" : "s")")
                }
            } else if let m = last.message {
                parts.append(m)
            }
        }
        if out.count > 1 { parts.append("\(out.count) statements") }
        parts.append("\(ms) ms")
        status = parts.joined(separator: " · ")
    }

    func cancel() { workspace.session.cancel() }

    // MARK: Explain

    /// Shows how the database plans to run the statement. With analyze, Postgres and MySQL run it and report real timings.
    func explain(_ sql: String, analyze: Bool) {
        guard !running else { return }
        let statement = SQLText.statements(in: sql).first?.sql ?? sql
        if let p = promptIfNeeded(statement, explain: true), !analyze { prompt = p; return }
        Task {
            if analyze, SQLText.isWrite(statement) {
                guard await confirm("Run this statement to measure it?", detail: "Explain with timings runs the statement for real, so its changes happen.\n\n\(statement.prefix(400))",
                                    button: "Run and explain", window: workspace.window) else { return }
            }
            await explainNow(statement, analyze: analyze)
        }
    }

    private func explainNow(_ statement: String, analyze: Bool) async {
        let kind = workspace.session.kind
        let serverVersion = workspace.session.serverVersion
        running = true
        error = nil
        status = "Explaining…"
        let start = Date()
        do {
            let text = try await workspace.session.run { d -> String in
                switch kind {
                case .postgres:
                    let options = analyze ? "(ANALYZE, BUFFERS, FORMAT TEXT)" : "(FORMAT TEXT)"
                    return try d.rows("EXPLAIN \(options) \(statement)").compactMap { $0.first ?? nil }.joined(separator: "\n")
                case .sqlite, .libsql, .d1:
                    let rows = try d.rows("EXPLAIN QUERY PLAN \(statement)")
                    return Self.sqlitePlan(rows)
                case .duckdb, .clickhouse:
                    let r = try d.execute("EXPLAIN \(analyze && kind == .duckdb ? "ANALYZE " : "")\(statement)").last(where: \.hasRows) ?? QueryResult()
                    return r.rows.map { $0.compactMap { $0 }.last ?? "" }.joined(separator: "\n")
                case .snowflake:
                    return try d.rows("EXPLAIN USING TEXT \(statement)").compactMap { $0.first ?? nil }.joined(separator: "\n")
                case .oracle:
                    _ = try d.execute("EXPLAIN PLAN FOR \(statement)")
                    return try d.rows("SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY())").compactMap { $0.first ?? nil }.joined(separator: "\n")
                case .sqlserver:
                    _ = try d.execute("SET SHOWPLAN_TEXT ON")
                    defer { _ = try? d.execute("SET SHOWPLAN_TEXT OFF") }
                    return try d.execute(statement).compactMap { $0.rows.first?.first ?? nil }.joined(separator: "\n")
                case .bigquery, .cassandra, .mongodb, .redis:
                    throw DatabaseError("Explain isn't available for \(kind.title) here.",
                                        detail: kind == .mongodb ? "Use db.runCommand({ explain: { find: \"collection\", filter: { … } } })." : nil)
                case .mysql:
                    let maria = serverVersion.localizedCaseInsensitiveContains("mariadb")
                    if analyze {
                        let r = try d.execute(maria ? "ANALYZE FORMAT=JSON \(statement)" : "EXPLAIN ANALYZE \(statement)")
                        return r.first?.rows.compactMap { $0.first ?? nil }.joined(separator: "\n") ?? ""
                    }
                    if !maria, let r = try? d.execute("EXPLAIN FORMAT=TREE \(statement)"), let t = r.first?.rows.first?.first ?? nil { return t }
                    let r = try d.execute("EXPLAIN \(statement)").first ?? QueryResult()
                    // Classic EXPLAIN is a table; show it as aligned text.
                    let cols = r.columns.map(\.name)
                    let widths = cols.indices.map { i in max(cols[i].count, r.rows.map { ($0[i] ?? "NULL").count }.max() ?? 0) }
                    func line(_ cells: [String]) -> String { zip(cells, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ") }
                    return ([line(cols), line(widths.map { String(repeating: "-", count: $0) })] + r.rows.map { line($0.map { $0 ?? "NULL" }) }).joined(separator: "\n")
                }
            }
            plan = text.isEmpty ? "(The database returned no plan.)" : text
            status = "\(analyze ? "Explained with timings" : "Plan") · \(Int(Date().timeIntervalSince(start) * 1000)) ms"
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
        running = false
    }

    /// SQLite's EXPLAIN QUERY PLAN rows (id, parent, notused, detail) as an indented tree.
    nonisolated static func sqlitePlan(_ rows: [[String?]]) -> String {
        var children: [String: [(String, String)]] = [:]
        for r in rows where r.count >= 4 { children[r[1] ?? "0", default: []].append((r[0] ?? "", r[3] ?? "")) }
        var out: [String] = []
        func walk(_ parent: String, _ depth: Int) {
            for (id, detail) in children[parent] ?? [] {
                out.append(String(repeating: "   ", count: depth) + (depth > 0 ? "└─ " : "") + detail)
                walk(id, depth + 1)
            }
        }
        walk("0", 0)
        return out.joined(separator: "\n")
    }

    // MARK: Editing helpers

    func format() {
        replacement = SQLFormatter.format(text)
        replaceToken += 1
    }

    func insert(_ snippet: Store.Snippet) {
        snippetToInsert = snippet
        snippetToken += 1
    }

    // MARK: Results

    func selectResult(_ i: Int) {
        selectedResult = i
        sortedRows = nil
        gridColumnsVersion += 1
        gridVersion += 1
    }

    var current: QueryResult? { results.indices.contains(selectedResult) ? results[selectedResult] : nil }
    var currentRows: [[String?]] { sortedRows ?? current?.rows ?? [] }

    func popOut() {
        guard let r = current, r.hasRows else { return }
        ResultWindowController.show(columns: r.columns, rows: currentRows, title: "\(name) · \(workspace.config.displayName)", workspace: workspace)
    }

    // MARK: GridSource

    var gridColumns: [ResultColumn] { current?.columns ?? [] }
    var gridRowCount: Int { currentRows.count }
    var canEdit: Bool { false }
    func gridValue(row: Int, column: Int) -> String? { currentRows[row][column] }
    func gridRowState(_ row: Int) -> RowState { .normal }
    func gridIsEdited(row: Int, column: Int) -> Bool { false }
    func gridEdit(row: Int, column: Int, value: String?) {}
    func gridDelete(rows: IndexSet) {}
    func gridSelectionChanged(_ rows: IndexSet) { selection = rows }

    func gridSort(column: Int, ascending: Bool) {
        guard let rows = current?.rows else { return }
        sortedRows = ResultSorter.sort(rows, column: column, ascending: ascending)
        gridVersion += 1
    }
}

enum ResultSorter {
    static func sort(_ rows: [[String?]], column: Int, ascending: Bool) -> [[String?]] {
        let numeric = rows.prefix(200).allSatisfy { $0[column] == nil || Double($0[column]!) != nil }
        return rows.sorted { a, b in
            switch (a[column], b[column]) {
            case (nil, nil): return false
            case (nil, _): return !ascending
            case (_, nil): return ascending
            case let (x?, y?):
                if numeric, let dx = Double(x), let dy = Double(y) { return ascending ? dx < dy : dx > dy }
                let r = x.localizedStandardCompare(y)
                return ascending ? r == .orderedAscending : r == .orderedDescending
            }
        }
    }
}

struct QueryTabView: View {
    @ObservedObject var tab: QueryTab
    @ObservedObject var workspace: Workspace
    @ObservedObject private var library = SnippetLibrary.shared
    @State private var editorHeight: CGFloat = 220
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                SQLEditor(text: $tab.text, completions: { workspace.completionWords(context: $0) }, onRun: { tab.run($0) },
                          focusToken: tab.focusToken, replaceToken: tab.replaceToken, replacement: tab.replacement,
                          snippets: library.snippets, snippetToken: tab.snippetToken, snippetToInsert: tab.snippetToInsert,
                          onCursorStatement: { tab.cursorStatement = $0 })
                    .frame(height: min(max(90, editorHeight), geo.size.height - 120))
                editorBar
                    .overlay(alignment: .top) {
                        // Drag the top edge of the bar to resize the editor.
                        Color.clear.frame(height: 6).contentShape(Rectangle())
                            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                                if dragStart == nil { dragStart = editorHeight }
                                editorHeight = (dragStart ?? editorHeight) + v.translation.height
                            }.onEnded { _ in dragStart = nil })
                            .offset(y: -3)
                    }
                Hairline()
                results
            }
        }
        .sheet(item: $tab.prompt) { p in ParameterSheet(prompt: p, run: { tab.runPrompt($0) }, cancel: { tab.prompt = nil }) }
    }

    private var editorBar: some View {
        HStack(spacing: 8) {
            if tab.running {
                Button { tab.cancel() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.mbDanger)
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else {
                Button { tab.run(tab.text) } label: { Text("Run all") }.buttonStyle(.mbQuiet).help("Run every statement (⇧⌘↩)")
                HStack(spacing: 4) { MBKey(text: "⌘↩"); Text("runs the statement at the cursor").font(.system(size: 11)).foregroundStyle(MB.dim) }
            }
            Spacer()
            if tab.results.count > 1 && tab.plan == nil {
                ForEach(Array(tab.results.enumerated()), id: \.offset) { i, r in
                    Button { tab.selectResult(i) } label: {
                        Text(r.hasRows ? "Result \(i + 1)" : (r.message ?? "Result \(i + 1)")).lineLimit(1)
                            .foregroundStyle(i == tab.selectedResult ? MB.text : MB.dim)
                    }
                    .buttonStyle(.mbPlain)
                }
                Hairline(vertical: true).frame(height: 16)
            }
            Menu {
                ForEach(library.snippets) { s in Button("\(s.name)  ·  \(s.trigger)") { tab.insert(s) } }
                Divider()
                Button("Edit snippets…") { workspace.sheet = .snippets }
            } label: { Text("Snippets").font(.system(size: 12, weight: .semibold)) }
                .menuStyle(.borderlessButton).fixedSize().tint(MB.text).help("Insert a snippet, or type its trigger and press Tab")
            if workspace.session.kind.isSQL {
                Button("Format") { tab.format() }.buttonStyle(.mbPlain).help("Format SQL (⌥⇧F)")
            }
            Menu {
                Button("Explain") { tab.explain(tab.statementAtCursor, analyze: false) }
                Button("Explain with timings (runs it)") { tab.explain(tab.statementAtCursor, analyze: true) }
            } label: { Text("Explain").font(.system(size: 12, weight: .semibold)) }
                .menuStyle(.borderlessButton).fixedSize().tint(MB.text).help("Show the query plan (⌥⌘E)")
            Button { workspace.saveQuery(tab) } label: { Text(tab.savedID == nil ? "Save query" : "Saved") }
                .buttonStyle(.mbPlain).help("Keep this query under Queries in the sidebar")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(MB.bar)
        .overlay(alignment: .top) { Hairline() }
    }

    @ViewBuilder private var results: some View {
        VStack(spacing: 0) {
            ZStack {
                if let plan = tab.plan {
                    ScrollView([.vertical, .horizontal]) {
                        Text(plan).font(MB.mono).foregroundStyle(MB.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
                    }
                    .background(MB.bg)
                } else if let current = tab.current, current.hasRows {
                    DataGrid(source: tab, version: tab.gridVersion, columnsVersion: tab.gridColumnsVersion)
                } else {
                    VStack(spacing: 6) {
                        if let error = tab.error {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(MB.red)
                            Text(error).font(.system(size: 12.5)).foregroundStyle(MB.text).multilineTextAlignment(.center)
                                .textSelection(.enabled).frame(maxWidth: 520)
                        } else if let m = tab.current?.message {
                            Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(MB.green)
                            Text(m).font(.system(size: 13)).foregroundStyle(MB.text)
                        } else {
                            Text("Results show here").font(.system(size: 12.5)).foregroundStyle(MB.dim)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MB.bg)
                }
            }
            Hairline()
            HStack(spacing: 8) {
                if let error = tab.error, tab.current?.hasRows == true || tab.plan != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MB.red).font(.system(size: 11))
                    Text(error.components(separatedBy: "\n").first ?? error).font(.system(size: 12)).foregroundStyle(MB.red).lineLimit(1)
                }
                Spacer()
                if let status = tab.status { Text(status).font(.system(size: 12)).foregroundStyle(MB.muted).monospacedDigit() }
                if tab.current?.truncated == true && tab.plan == nil && !tab.running {
                    Button("Load all") { tab.loadAll() }.buttonStyle(.mbPlain)
                        .help("Run it again and keep every row. Very large results take a lot of memory.")
                }
                if tab.plan == nil, tab.current?.hasRows == true {
                    MBIconButton(symbol: "macwindow.on.rectangle", help: "Open these results in their own window") { tab.popOut() }
                } else if tab.plan != nil {
                    Button("Back to results") { tab.selectResult(tab.selectedResult) ; tab.clearPlan() }.buttonStyle(.mbPlain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(MB.bar)
        }
    }
}

extension QueryTab {
    func clearPlan() { plan = nil; status = nil }
}

/// Asks for the values of :name parameters before running.
struct ParameterSheet: View {
    @State var prompt: QueryTab.ParameterPrompt
    let run: (QueryTab.ParameterPrompt) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.explain ? "Parameters for Explain" : "Parameters").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
            Text("Numbers and NULL go in as they are; anything else is quoted as text. Start with = for raw SQL, like =now().")
                .font(.system(size: 12)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
            ForEach(prompt.names, id: \.self) { name in
                HStack(spacing: 10) {
                    Text(":" + name).font(MB.mono).foregroundStyle(MB.muted).frame(width: 140, alignment: .trailing)
                    MBField(placeholder: "value", text: Binding(get: { prompt.values[name] ?? "" }, set: { prompt.values[name] = $0 }), mono: true)
                        .onSubmit { run(prompt) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button(prompt.explain ? "Explain" : "Run") { run(prompt) }.buttonStyle(.mbPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(MB.bg)
    }
}

// MARK: - Results in their own window

/// A copy of a result in its own window, so you can keep it next to the editor.
@MainActor
final class ResultSnapshot: ObservableObject, GridSource {
    let columns: [ResultColumn]
    private let original: [[String?]]
    private var rows: [[String?]]
    @Published private(set) var gridVersion = 0
    let gridColumnsVersion = 1

    init(columns: [ResultColumn], rows: [[String?]]) {
        self.columns = columns
        original = rows
        self.rows = rows
    }

    var gridColumns: [ResultColumn] { columns }
    var gridRowCount: Int { rows.count }
    var canEdit: Bool { false }
    func gridValue(row: Int, column: Int) -> String? { rows[row][column] }
    func gridRowState(_ row: Int) -> RowState { .normal }
    func gridIsEdited(row: Int, column: Int) -> Bool { false }
    func gridEdit(row: Int, column: Int, value: String?) {}
    func gridDelete(rows: IndexSet) {}
    func gridSelectionChanged(_ rows: IndexSet) {}
    func gridSort(column: Int, ascending: Bool) {
        rows = ResultSorter.sort(original, column: column, ascending: ascending)
        gridVersion += 1
    }
    var allRows: [[String?]] { rows }
}

@MainActor
final class ResultWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ResultWindowController] = []
    private let snapshot: ResultSnapshot

    static func show(columns: [ResultColumn], rows: [[String?]], title: String, workspace: Workspace) {
        let c = ResultWindowController(columns: columns, rows: rows, title: title, workspace: workspace)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init(columns: [ResultColumn], rows: [[String?]], title: String, workspace: Workspace) {
        snapshot = ResultSnapshot(columns: columns, rows: rows)
        let window = makeMabenWindow(size: NSSize(width: 900, height: 560), autosave: "MabenBaseResult")
        window.title = title
        window.minSize = NSSize(width: 420, height: 260)
        super.init(window: window)
        window.delegate = self
        window.setContent(ResultWindowView(snapshot: snapshot, title: title, workspace: workspace), size: NSSize(width: 900, height: 560),
                          autosave: "MabenBaseResult")
        if let main = workspace.window?.frame { window.setFrameOrigin(NSPoint(x: main.midX - 300, y: main.midY - 200)) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}

struct ResultWindowView: View {
    @ObservedObject var snapshot: ResultSnapshot
    let title: String
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 64, height: 1)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(MB.text).lineLimit(1)
                Text("\(snapshot.gridRowCount.formatted()) rows").font(.system(size: 12)).foregroundStyle(MB.dim)
                Spacer()
                Menu("Export") {
                    ForEach(ExportFormat.results, id: \.self) { f in
                        Button(f.title + "…") {
                            workspace.exportResult(columns: snapshot.columns, rows: snapshot.allRows, name: "result", format: f, table: nil)
                        }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 12).frame(height: 40).background(MB.bar)
            Hairline()
            DataGrid(source: snapshot, version: snapshot.gridVersion, columnsVersion: snapshot.gridColumnsVersion)
        }
        .background(MB.bg)
        .ignoresSafeArea()
    }
}

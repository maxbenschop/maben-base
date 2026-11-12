import AppKit
import BaseCore
import SwiftUI
import UniformTypeIdentifiers

enum WorkTab: Identifiable {
    case table(TableTab)
    case query(QueryTab)

    var id: UUID {
        switch self {
        case .table(let t): t.id
        case .query(let q): q.id
        }
    }
}

/// One connection's window: the object list, the open tabs, and everything they share.
@MainActor
final class Workspace: ObservableObject {
    enum SidebarMode: String, CaseIterable { case items = "Items", queries = "Queries", history = "History" }
    enum Palette { case open, databases }

    let session: Session
    let store: Store
    weak var window: NSWindow?

    @Published var database: String?
    @Published var databases: [String] = []
    @Published var schemas: [String] = []
    @Published var schema: String?
    @Published var objects: [DBObject] = []
    @Published var loadingObjects = false
    @Published var objectsError: String?
    @Published var tabs: [WorkTab] = []
    @Published var selectedTab: UUID?
    /// The tab on the right in split view.
    @Published var splitTab: UUID?
    @Published var rightFocused = false
    /// Where the right pane starts and ends, in window coordinates, so clicks can focus a pane.
    var splitRange: ClosedRange<CGFloat>?
    var leftStart: CGFloat = 0
    @Published var showSidebar = true
    @Published var showInspector = true
    @Published var sidebarMode: SidebarMode = .items
    @Published var sidebarFilter = ""
    @Published var history: [Store.HistoryItem]
    @Published var savedQueries: [Store.SavedQuery]
    @Published var palette: Palette?
    @Published var sheet: Sheet?
    /// Room taken by macOS's window tab bar (connections as tabs), so our title bar sits below it.
    @Published var windowTabBarHeight: CGFloat = 0
    /// A running SQL file import: statements done, total.
    @Published var importProgress: (done: Int, total: Int)?

    enum Sheet: String, Identifiable { case newTable, newView, backup, exportDatabase, snippets; var id: String { rawValue } }
    private var columnCache: [TableRef: [String]] = [:]
    private var queryCount = 0

    init(session: Session, store: Store) {
        self.session = session
        self.store = store
        history = store.history(for: session.config.id)
        savedQueries = store.savedQueries(for: session.config.id)
    }

    var config: ConnectionConfig { session.config }

    func start(restoring saved: SavedWorkspace? = nil) {
        Task {
            database = try? await session.run { $0.currentDatabase }
            databases = (try? await session.run { try $0.databases() }) ?? []
            await loadSchemas()
            await reloadObjects()
            if let saved { await restore(saved) }
        }
    }

    private func loadSchemas() async {
        guard session.kind.hasSchemas else { schemas = []; schema = nil; return }
        schemas = (try? await session.run { try $0.schemas() }) ?? ["public"]
        if schema == nil || !schemas.contains(schema!) { schema = schemas.first }
    }

    func reloadObjects() async {
        loadingObjects = true
        objectsError = nil
        let schema = self.schema
        do {
            objects = try await session.run { try $0.objects(schema: schema) }
        } catch {
            objectsError = error.localizedDescription
        }
        loadingObjects = false
    }

    func switchSchema(_ s: String) {
        schema = s
        Task { await reloadObjects() }
    }

    func switchDatabase(_ name: String) {
        guard name != database else { return }
        Task {
            do {
                try await session.run { try $0.use(database: name) }
                database = name
                columnCache = [:]
                // Tables from the old database can't stay open.
                tabs.removeAll { if case .table = $0 { true } else { false } }
                if let sel = selectedTab, !tabs.contains(where: { $0.id == sel }) { selectedTab = tabs.last?.id }
                if let split = splitTab, !tabs.contains(where: { $0.id == split }) || split == selectedTab { splitTab = nil; rightFocused = false }
                await loadSchemas()
                await reloadObjects()
            } catch {
                showError(error, in: window, title: "Couldn't open \(name)")
            }
        }
    }

    // MARK: Tabs

    /// The pane you last clicked in split view; menus, the inspector and new tabs follow it.
    var focusedTab: UUID? { rightFocused && splitTab != nil ? splitTab : selectedTab }
    var activeTab: WorkTab? { tabs.first { $0.id == focusedTab } }

    /// Shows a tab in the focused pane. The same tab can't be in both panes, so they swap.
    func select(_ id: UUID?) {
        guard let id else { selectedTab = nil; return }
        if splitTab != nil && rightFocused {
            if id == selectedTab { selectedTab = splitTab }
            splitTab = id
        } else {
            if id == splitTab { splitTab = selectedTab }
            selectedTab = id
        }
    }

    /// Split view on or off. On: the next tab (or a new query) opens on the right.
    func toggleSplit() {
        if splitTab != nil {
            splitTab = nil
            rightFocused = false
            return
        }
        let other = tabs.first { $0.id != selectedTab }?.id ?? newQuery().id
        if selectedTab == nil { selectedTab = tabs.first { $0.id != other }?.id }
        splitTab = other
        if splitTab == selectedTab { splitTab = nil; return }
        rightFocused = true
    }

    func openOnRight(_ id: UUID) {
        if splitTab == nil, selectedTab == id { selectedTab = tabs.first { $0.id != id }?.id }
        if selectedTab == id { return }
        splitTab = id
        rightFocused = true
    }

    var activeTable: TableTab? { if case .table(let t) = activeTab { t } else { nil } }
    var activeQuery: QueryTab? { if case .query(let q) = activeTab { q } else { nil } }

    func open(_ object: DBObject, structure: Bool = false) {
        if object.kind == .function {
            Task {
                let sql = (try? await session.run { try $0.definition(of: object) }) ?? nil
                newQuery(name: object.name, text: sql ?? "-- No definition available for \(object.name)")
            }
            return
        }
        if let existing = tabs.first(where: { if case .table(let t) = $0 { t.object == object } else { false } }) {
            select(existing.id)
            if structure, case .table(let t) = existing { t.mode = .structure }
            return
        }
        let tab = TableTab(object: object, workspace: self)
        if structure { tab.mode = .structure }
        tabs.append(.table(tab))
        select(tab.id)
    }

    @discardableResult
    func newQuery(name: String? = nil, text: String = "", saved: UUID? = nil) -> QueryTab {
        if let saved, let existing = tabs.first(where: { if case .query(let q) = $0 { q.savedID == saved } else { false } }) {
            select(existing.id)
            if case .query(let q) = existing { return q }
        }
        queryCount += 1
        let tab = QueryTab(workspace: self, name: name ?? (queryCount == 1 ? "Query" : "Query \(queryCount)"), text: text)
        tab.savedID = saved
        tabs.append(.query(tab))
        select(tab.id)
        return tab
    }

    func close(_ id: UUID) {
        Task {
            if let tab = tabs.first(where: { $0.id == id }), case .table(let t) = tab, !t.changes.isEmpty {
                guard await confirm("Close \(t.title) with \(t.changes.count) unsaved change\(t.changes.count == 1 ? "" : "s")?",
                                    detail: "They haven't been written to the database.", button: "Close without saving", window: window) else { return }
            }
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            tabs.remove(at: index)
            if splitTab == id { splitTab = nil; rightFocused = false }
            else if selectedTab == id {
                let rest = tabs.filter { $0.id != splitTab }
                selectedTab = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
                if selectedTab == nil, let split = splitTab { selectedTab = split; splitTab = nil; rightFocused = false }
            }
        }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == focusedTab } ?? 0
        select(tabs[(i + offset + tabs.count) % tabs.count].id)
    }

    var hasUnsavedChanges: Bool {
        tabs.contains { if case .table(let t) = $0 { !t.changes.isEmpty } else { false } }
    }

    // MARK: History and saved queries

    func recordHistory(_ sql: String, ms: Int?, failed: Bool) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0.sql == trimmed }
        history.insert(Store.HistoryItem(sql: trimmed, database: database, milliseconds: ms, failed: failed), at: 0)
        if history.count > 1000 { history.removeLast(history.count - 1000) }
        store.save(history: history, for: config.id)
    }

    func clearHistory() {
        history = []
        store.save(history: [], for: config.id)
    }

    func saveQuery(_ tab: QueryTab) {
        if let id = tab.savedID, let i = savedQueries.firstIndex(where: { $0.id == id }) {
            savedQueries[i].sql = tab.text
            savedQueries[i].name = tab.name
        } else {
            let alert = NSAlert()
            alert.messageText = "Save query"
            alert.informativeText = "It's kept under Queries in the sidebar, for this connection."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = tab.name.hasPrefix("Query") ? "" : tab.name
            field.placeholderString = "Name"
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            let q = Store.SavedQuery(name: name.isEmpty ? tab.name : name, sql: tab.text)
            savedQueries.append(q)
            tab.savedID = q.id
            tab.name = q.name
        }
        store.save(queries: savedQueries, for: config.id)
        objectWillChange.send()
    }

    func deleteSavedQuery(_ q: Store.SavedQuery) {
        savedQueries.removeAll { $0.id == q.id }
        store.save(queries: savedQueries, for: config.id)
    }

    // MARK: Completion

    func rememberColumns(_ table: TableRef, _ columns: [String]) { columnCache[table] = columns }

    private func columns(named table: String) -> [String]? {
        let lower = table.lowercased()
        return columnCache.first { $0.key.name.lowercased() == lower }?.value
    }

    /// Loads the columns of every table once, in the background.
    private func ensureColumnCache() {
        guard columnCache.isEmpty, !objects.isEmpty else { return }
        let tables = objects.filter { $0.kind.isRelation }.prefix(300).map(\.table)
        columnCache[TableRef(schema: nil, name: "\u{1}loading")] = []
        Task {
            for t in tables {
                if let cols = try? await session.run({ try $0.columns(of: t) }) { columnCache[t] = cols.map(\.name) }
            }
        }
    }

    /// Words for the editor's completion. After `alias.` only that table's columns; otherwise the columns of the
    /// tables in this statement first, then table names, then everything else.
    func completionWords(context: CompletionContext) -> [String] {
        ensureColumnCache()
        let aliases = SQLText.tableAliases(in: context.statement)
        if let q = context.qualifier?.lowercased() {
            if let table = aliases[q] ?? objects.first(where: { $0.name.lowercased() == q })?.name {
                if let cols = columns(named: table) { return cols }
                if let o = objects.first(where: { $0.name.lowercased() == table.lowercased() }) {
                    Task { if let cols = try? await session.run({ try $0.columns(of: o.table) }) { columnCache[o.table] = cols.map(\.name) } }
                }
                return []
            }
            if schemas.contains(where: { $0.lowercased() == q }) { return objects.map { $0.name.components(separatedBy: "(").first ?? $0.name } }
            return []
        }
        var words: [String] = []
        for t in Set(aliases.values) { words += columns(named: t) ?? [] }
        words += objects.map { $0.name.components(separatedBy: "(").first ?? $0.name }
        for (key, cols) in columnCache where !aliases.values.contains(key.name) { words += cols }
        words += schemas
        return words
    }

    /// A first query for a table, in the engine's own language.
    func starterQuery(_ object: DBObject) -> String {
        let d = session.dialect
        switch session.kind {
        case .mongodb: return "db.getCollection(\"\(object.name)\").find({}).limit(100)"
        case .redis: return "SCAN 0 MATCH * COUNT 100"
        case .sqlserver: return "SELECT TOP 100 * FROM \(d.qualified(object.table));"
        case .oracle: return "SELECT * FROM \(d.qualified(object.table)) FETCH FIRST 100 ROWS ONLY;"
        default: return "SELECT * FROM \(d.qualified(object.table)) LIMIT 100;"
        }
    }

    /// Opens a table filtered to the given conditions (following a foreign key).
    func openFiltered(_ table: TableRef, filters: [Filter]) {
        let object = objects.first { $0.name == table.name && ($0.schema == table.schema || table.schema == nil || $0.schema == nil) && $0.kind.isRelation }
            ?? DBObject(schema: table.schema ?? schema, name: table.name, kind: .table)
        if let existing = tabs.first(where: { if case .table(let t) = $0 { t.object.name == object.name && t.object.schema == object.schema } else { false } }),
           case .table(let t) = existing {
            select(t.id)
            t.show(filters: filters)
            return
        }
        let tab = TableTab(object: object, workspace: self)
        tabs.append(.table(tab))
        select(tab.id)
        tab.show(filters: filters)
    }

    // MARK: Table actions

    func exportTable(_ object: DBObject, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(object.name).\(format.fileExtension)"
        panel.allowedContentTypes = [format.type]
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let dialect = self.session.dialect
            let sql = "SELECT * FROM \(dialect.qualified(object.table))"
            Task {
                do {
                    let result = try await self.session.run { try $0.execute(sql).first(where: \.hasRows) ?? QueryResult() }
                    try format.data(columns: result.columns, rows: result.rows, name: object.name, table: object.table, dialect: dialect).write(to: url)
                } catch {
                    showError(error, in: self.window, title: "Export failed")
                }
            }
        }
    }

    func exportResult(columns: [ResultColumn], rows: [[String?]], name: String, format: ExportFormat, table: TableRef?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
        panel.allowedContentTypes = [format.type]
        let dialect = session.dialect
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try format.data(columns: columns, rows: rows, name: name, table: table, dialect: dialect).write(to: url) }
            catch { showError(error, in: self.window, title: "Export failed") }
        }
        if let key = NSApp.keyWindow, key != window { panel.beginSheetModal(for: key, completionHandler: handler) }
        else if let window { panel.beginSheetModal(for: window, completionHandler: handler) }
    }

    /// CSV with a header row; columns are matched by name, others are left to their default.
    func importCSV(into object: DBObject) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self.runImport(url: url, into: object) }
        }
    }

    private func runImport(url: URL, into object: DBObject) async {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rows = Export.parseCSV(text)
            guard let header = rows.first, rows.count > 1 else { throw DatabaseError("The file has no rows under its header.") }
            let table = object.table
            let columns = try await session.run { try $0.columns(of: table) }
            let names = Set(columns.map(\.name))
            let used = header.enumerated().filter { names.contains($0.element) }
            guard !used.isEmpty else { throw DatabaseError("None of the CSV's columns match \(object.name).", detail: "Header: \(header.joined(separator: ", "))") }
            let skipped = header.filter { !names.contains($0) }
            var detail = "\(rows.count - 1) rows into \(used.count) column\(used.count == 1 ? "" : "s"): \(used.map(\.element).joined(separator: ", "))."
            if !skipped.isEmpty { detail += "\nNot in the table, skipped: \(skipped.joined(separator: ", "))." }
            detail += "\nEmpty fields are written as NULL. It all runs in one transaction."
            if config.environment == .production { detail = "This is a production connection.\n\n" + detail }
            guard config.safeMode != .readOnly else { _ = await allow("", write: true); return }
            guard await confirm("Import \(url.lastPathComponent) into \(object.name)?", detail: detail, button: "Import",
                                destructive: config.environment == .production, window: window) else { return }
            guard await allow("INSERT INTO \(object.name) …", write: true, alreadyConfirmed: true) else { return }
            let d = session.dialect
            let cols = used.map { d.quote($0.element) }.joined(separator: ", ")
            let body = rows.dropFirst().map { r in
                "(" + used.map { i, _ in i < r.count && !r[i].isEmpty ? d.literal(r[i]) : "NULL" }.joined(separator: ", ") + ")"
            }
            let inserts = stride(from: 0, to: body.count, by: 500).map { chunk in
                "INSERT INTO \(d.qualified(table)) (\(cols)) VALUES\n" + body[chunk..<min(chunk + 500, body.count)].joined(separator: ",\n")
            }
            try await session.run { driver in try driver.runAsUnit(inserts) }
            for case .table(let t) in tabs where t.object == object { await t.load() }
        } catch {
            showError(error, in: window, title: "Import failed")
        }
    }

    func dangerous(_ action: String, _ object: DBObject) {
        let d = session.dialect
        let sql: String
        switch action {
        case "truncate": sql = session.kind == .sqlite ? "DELETE FROM \(d.qualified(object.table))" : "TRUNCATE TABLE \(d.qualified(object.table))"
        default:
            let what = object.kind == .view ? "VIEW" : object.kind == .materializedView ? "MATERIALIZED VIEW" : "TABLE"
            sql = "DROP \(what) \(d.qualified(object.table))"
        }
        Task {
            let env = config.environment == .production ? "This is a production connection. " : ""
            guard await confirm(action == "truncate" ? "Empty \(object.name)?" : "Delete \(object.name)?",
                                detail: "\(env)This runs:\n\n\(sql)\n\nIt can't be undone.",
                                button: action == "truncate" ? "Empty table" : "Delete", window: window) else { return }
            guard await allow(sql, write: true, alreadyConfirmed: true) else { return }
            do {
                _ = try await session.run { try $0.execute(sql) }
                recordHistory(sql, ms: nil, failed: false)
                if action != "truncate" {
                    tabs.removeAll { if case .table(let t) = $0 { t.object == object } else { false } }
                    if let sel = selectedTab, !tabs.contains(where: { $0.id == sel }) { selectedTab = tabs.last?.id }
                if let split = splitTab, !tabs.contains(where: { $0.id == split }) || split == selectedTab { splitTab = nil; rightFocused = false }
                } else {
                    for case .table(let t) in tabs where t.object == object { await t.load() }
                }
                await reloadObjects()
            } catch {
                showError(error, in: window)
            }
        }
    }
}

// MARK: - Window

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let workspace: Workspace
    static var open: [WorkspaceWindowController] = []

    init(session: Session, store: Store, restoring saved: SavedWorkspace? = nil) {
        workspace = Workspace(session: session, store: store)
        let window = makeMabenWindow(size: NSSize(width: 1280, height: 800), autosave: "MabenBaseWorkspace")
        window.minSize = NSSize(width: 760, height: 460)
        window.title = session.config.displayName
        // Connections as macOS window tabs in one window (Settings › Windows).
        window.tabbingIdentifier = "gg.maben.base.workspace"
        window.tabbingMode = Preferences.connectionTabs ? .preferred : .disallowed
        super.init(window: window)
        workspace.window = window
        window.delegate = self
        window.setContent(WorkspaceView(workspace: workspace), size: NSSize(width: 1280, height: 800), autosave: "MabenBaseWorkspace")
        workspace.start(restoring: saved)
        watchPaneClicks()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        Self.open.append(self)
        if Preferences.connectionTabs, let host = Self.open.dropLast().last?.window, let window {
            host.addTabbedWindow(window, ordered: .above)
        } else if let frame = Self.open.dropLast().last?.window?.frame {
            window?.setFrameOrigin(NSPoint(x: frame.minX + 24, y: frame.minY - 24))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--demo") && Self.open.count == 1 { Demo.prepare(workspace) }
        DispatchQueue.main.async { for c in Self.open { c.refreshTabBar() } }
    }

    private var tabObservation: NSKeyValueObservation?

    /// Keeps our title bar below macOS's tab bar when connections share one window.
    func refreshTabBar() {
        guard let window else { return }
        if tabObservation == nil, let group = window.tabGroup {
            tabObservation = group.observe(\.isTabBarVisible) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshTabBar() } }
            }
        }
        let visible = window.tabGroup?.isTabBarVisible ?? false
        let top = (window.contentView?.bounds.height ?? 0) - window.contentLayoutRect.maxY
        let titlebar: CGFloat = 28
        let height = visible ? max(0, top - titlebar) + titlebar : 0
        if abs(workspace.windowTabBarHeight - height) > 0.5 { workspace.windowTabBarHeight = height }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        tabObservation = nil
        refreshTabBar()
        // Other windows in the group may have changed too.
        for c in Self.open where c !== self { c.refreshTabBar() }
    }

    func windowDidResize(_ notification: Notification) { refreshTabBar() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace.hasUnsavedChanges else { return true }
        Task {
            if await confirm("Close with unsaved changes?", detail: "Edits in open tabs haven't been written to the database.",
                             button: "Close without saving", window: window) {
                window?.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        DispatchQueue.main.async { for c in Self.open { c.refreshTabBar() } }
        workspace.session.close()
        Self.open.removeAll { $0 === self }
        if Self.open.isEmpty { ConnectionsWindowController.shared.show() }
    }

    // MARK: Menu actions (reach here through the responder chain)

    @objc func newQueryTab(_ sender: Any?) { workspace.newQuery() }
    @objc func toggleSplit(_ sender: Any?) { workspace.toggleSplit() }
    @objc func showServer(_ sender: Any?) { AdminWindowController.show(for: workspace) }
    private var clickMonitor: Any?

    /// In split view, a click in a pane makes it the focused one.
    func watchPaneClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window, self.workspace.splitTab != nil, let range = self.workspace.splitRange else { return event }
            let x = event.locationInWindow.x
            if range.contains(x) { if !self.workspace.rightFocused { self.workspace.rightFocused = true } }
            else if x >= self.workspace.leftStart && x < range.lowerBound { if self.workspace.rightFocused { self.workspace.rightFocused = false } }
            return event
        }
    }
    @objc func closeTab(_ sender: Any?) {
        if let id = workspace.selectedTab { workspace.close(id) } else { window?.performClose(nil) }
    }
    @objc func refresh(_ sender: Any?) {
        if let t = workspace.activeTable { t.refresh() } else { Task { await workspace.reloadObjects() } }
    }
    @objc func saveChanges(_ sender: Any?) {
        if let t = workspace.activeTable { Task { await t.commit() } }
        else if let q = workspace.activeQuery { workspace.saveQuery(q) }
    }
    @objc func discardChanges(_ sender: Any?) { workspace.activeTable?.discard() }
    @objc func quickOpen(_ sender: Any?) { workspace.palette = .open }
    @objc func switchDatabase(_ sender: Any?) { workspace.palette = .databases }
    @objc func toggleSidebar(_ sender: Any?) { workspace.showSidebar.toggle() }
    @objc func toggleInspector(_ sender: Any?) { workspace.showInspector.toggle() }
    @objc func toggleFilters(_ sender: Any?) {
        guard let t = workspace.activeTable else { return }
        t.mode = .data
        t.showFilters.toggle()
        if t.showFilters && t.filters.isEmpty, let first = t.columns.first { t.filters = [Filter(column: first.name)] }
    }
    @objc func runAll(_ sender: Any?) { workspace.activeQuery?.runAll() }
    @objc func cancelQuery(_ sender: Any?) { workspace.session.cancel() }
    @objc func nextTab(_ sender: Any?) { workspace.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { workspace.selectTab(offset: -1) }
    @objc func addRow(_ sender: Any?) { workspace.activeTable?.addRow() }
    @objc func nextPage(_ sender: Any?) { workspace.activeTable?.nextPage() }
    @objc func previousPage(_ sender: Any?) { workspace.activeTable?.previousPage() }
    @objc func showStructure(_ sender: Any?) {
        guard let t = workspace.activeTable else { return }
        t.mode = t.mode == .data ? .structure : .data
    }
    @objc func exportCurrent(_ sender: Any?) {
        let format = ExportFormat(rawValue: (sender as? NSMenuItem)?.representedObject as? String ?? "csv") ?? .csv
        if let t = workspace.activeTable {
            workspace.exportTable(t.object, format: format)
        } else if let q = workspace.activeQuery, let r = q.current, r.hasRows {
            workspace.exportResult(columns: r.columns, rows: q.currentRows, name: q.name, format: format, table: nil)
        }
    }
    @objc func importCSV(_ sender: Any?) {
        if let t = workspace.activeTable, t.object.kind == .table { workspace.importCSV(into: t.object) }
    }
    @objc func importSQL(_ sender: Any?) { workspace.importSQLFile() }
    @objc func exportDatabase(_ sender: Any?) { workspace.sheet = .exportDatabase }
    @objc func backupRestore(_ sender: Any?) { workspace.sheet = .backup }
    @objc func newTable(_ sender: Any?) { workspace.sheet = .newTable }
    @objc func newView(_ sender: Any?) { workspace.sheet = .newView }
    @objc func editSnippets(_ sender: Any?) { workspace.sheet = .snippets }
    @objc func formatSQL(_ sender: Any?) { workspace.activeQuery?.format() }
    @objc func explainQuery(_ sender: Any?) {
        if let q = workspace.activeQuery { q.explain(q.statementAtCursor, analyze: false) }
    }
    @objc func runInNewTab(_ sender: Any?) {
        if let q = workspace.activeQuery { q.runInNewTab(q.statementAtCursor) }
    }
    @objc func popOutResults(_ sender: Any?) { workspace.activeQuery?.popOut() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveChanges(_:)): return workspace.activeTable.map { !$0.changes.isEmpty } ?? (workspace.activeQuery != nil)
        case #selector(discardChanges(_:)): return workspace.activeTable.map { !$0.changes.isEmpty } ?? false
        case #selector(runAll(_:)): return workspace.activeQuery != nil
        case #selector(cancelQuery(_:)): return workspace.activeQuery?.running ?? false
        case #selector(addRow(_:)): return workspace.activeTable?.canEdit ?? false
        case #selector(toggleFilters(_:)), #selector(showStructure(_:)), #selector(nextPage(_:)), #selector(previousPage(_:)):
            return workspace.activeTable != nil
        case #selector(importCSV(_:)): return workspace.activeTable?.object.kind == .table && !workspace.config.readOnly
        case #selector(exportCurrent(_:)): return workspace.activeTable != nil || workspace.activeQuery?.current?.hasRows == true
        case #selector(switchDatabase(_:)): return workspace.session.kind != .sqlite
        case #selector(newTable(_:)): return !workspace.config.readOnly && workspace.session.dialect.supportsDesign
        case #selector(newView(_:)): return !workspace.config.readOnly && workspace.session.kind.isSQL && workspace.session.kind != .cassandra
        case #selector(importSQL(_:)): return !workspace.config.readOnly && workspace.session.kind.isSQL
        case #selector(formatSQL(_:)), #selector(explainQuery(_:)), #selector(runInNewTab(_:)): return workspace.activeQuery != nil
        case #selector(popOutResults(_:)): return workspace.activeQuery?.current?.hasRows == true
        case #selector(showServer(_:)): return Admin.supported(workspace.session.kind)
        default: return true
        }
    }
}

// MARK: - Views

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(workspace: workspace)
            Hairline()
            HStack(spacing: 0) {
                if workspace.showSidebar {
                    Sidebar(workspace: workspace).frame(width: 250).background(MB.sidebar)
                    Hairline(vertical: true)
                }
                VStack(spacing: 0) {
                    TabStrip(workspace: workspace)
                    Hairline()
                    if let split = workspace.splitTab, let right = workspace.tabs.first(where: { $0.id == split }) {
                        HStack(spacing: 0) {
                            pane(workspace.tabs.first { $0.id == workspace.selectedTab }, right: false)
                            Rectangle().fill(MB.lineStrong).frame(width: 1)
                            pane(right, right: true)
                        }
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity)
                if workspace.showInspector, let table = workspace.activeTable, table.mode == .data {
                    Hairline(vertical: true)
                    RowInspector(tab: table).frame(width: 290).background(MB.sidebar)
                }
            }
        }
        .background(MB.bg)
        .tint(MB.accent)
        .ignoresSafeArea()
        .overlay {
            if let palette = workspace.palette {
                PaletteView(workspace: workspace, kind: palette)
            }
        }
        .overlay(alignment: .bottom) {
            if let p = workspace.importProgress {
                HStack(spacing: 10) {
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 180)
                    Text("Running statement \(p.done.formatted()) of \(p.total.formatted())").font(.system(size: 12)).foregroundStyle(MB.text)
                    Button("Stop") { workspace.session.cancel() }.buttonStyle(.mbQuiet)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(MB.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MB.lineStrong))
                .padding(.bottom, 54)
            }
        }
        .sheet(item: $workspace.sheet) { sheet in
            let close = { workspace.sheet = nil }
            Group {
            switch sheet {
            case .newTable: NewTableSheet(workspace: workspace, close: close)
            case .newView: NewViewSheet(workspace: workspace, close: close)
            case .backup: BackupSheet(workspace: workspace, close: close)
            case .exportDatabase: ExportDatabaseSheet(workspace: workspace, close: close)
            case .snippets: SnippetsSheet(close: close)
            }
            }
            .tint(MB.accent)
        }
    }

    private func pane(_ tab: WorkTab?, right: Bool) -> some View {
        Group {
            switch tab {
            case .table(let t): TableTabView(tab: t).id(t.id)
            case .query(let q): QueryTabView(tab: q, workspace: workspace).id(q.id)
            case nil: EmptyWorkspace(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(MB.accent).frame(height: 2).opacity(workspace.rightFocused == right ? 1 : 0)
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { record(g.frame(in: .global), right: right) }
                .onChange(of: g.frame(in: .global)) { _, f in record(f, right: right) }
        })
    }

    private func record(_ frame: CGRect, right: Bool) {
        if right { workspace.splitRange = frame.minX...frame.maxX } else { workspace.leftStart = frame.minX }
    }

    @ViewBuilder private var content: some View {
        switch workspace.activeTab {
        case .table(let t): TableTabView(tab: t).id(t.id)
        case .query(let q): QueryTabView(tab: q, workspace: workspace).id(q.id)
        case nil: EmptyWorkspace(workspace: workspace)
        }
    }
}

/// 52 pt bar across the window: room for the window buttons, then what you're connected to.
struct TitleBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 6) {
            // Room for the window buttons, unless macOS's tab bar has moved us below them.
            Color.clear.frame(width: workspace.windowTabBarHeight > 0 ? 4 : 72, height: 1)
            MBIconButton(symbol: "sidebar.left", help: "Show or hide the sidebar (⌃⌘S)", active: false) { workspace.showSidebar.toggle() }
            HStack(spacing: 8) {
                Circle().fill(workspace.config.environment.color).frame(width: 8, height: 8)
                Text(workspace.config.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(MB.text).lineLimit(1)
                if workspace.config.environment != .local {
                    MBTag(text: workspace.config.environment.title.lowercased(), color: workspace.config.environment.color)
                }
                Text(breadcrumb).font(.system(size: 12)).foregroundStyle(MB.dim).lineLimit(1)
            }
            .padding(.leading, 6)
            Spacer(minLength: 12)
            if workspace.session.kind != .sqlite {
                Button { workspace.palette = .databases } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cylinder").font(.system(size: 11))
                        Text(workspace.database ?? "Database").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.mbQuiet).help("Switch database (⌘K)")
            }
            if workspace.session.kind.hasSchemas, workspace.schemas.count > 1 {
                Menu {
                    ForEach(workspace.schemas, id: \.self) { s in Button(s) { workspace.switchSchema(s) } }
                } label: {
                    Text(workspace.schema ?? "schema")
                }
                .menuStyle(.borderlessButton).fixedSize().tint(MB.text).help("Schema")
            }
            if Admin.supported(workspace.session.kind) {
                MBIconButton(symbol: "server.rack", help: "Server: processes, users, metrics (⇧⌘M)") { AdminWindowController.show(for: workspace) }
            }
            MBIconButton(symbol: "magnifyingglass", help: "Open anything (⌘P)") { workspace.palette = .open }
            MBIconButton(symbol: "plus.rectangle", help: "New query (⌘T)") { workspace.newQuery() }
            MBIconButton(symbol: "sidebar.right", help: "Row details (⌥⌘I)", active: false) { workspace.showInspector.toggle() }
        }
        .padding(.trailing, 10)
        .frame(height: 52)
        .padding(.top, workspace.windowTabBarHeight)
        .background(MB.bar)
    }

    private var breadcrumb: String {
        var parts = ["\(workspace.session.kind.shortTitle) \(shortVersion)"]
        if workspace.session.kind == .sqlite { parts.append((workspace.config.filePath as NSString).abbreviatingWithTildeInPath) }
        else if workspace.config.sshEnabled { parts.append("via \(workspace.config.sshHost)") }
        if workspace.config.readOnly { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }

    private var shortVersion: String {
        String(workspace.session.serverVersion.split(separator: " ").first ?? "").components(separatedBy: "-").first ?? ""
    }
}

struct TabStrip: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(workspace.tabs) { tab in
                        TabButton(workspace: workspace, tab: tab, selected: tab.id == workspace.selectedTab || tab.id == workspace.splitTab,
                                  focused: tab.id == workspace.focusedTab)
                    }
                }
            }
            MBIconButton(symbol: "plus", help: "New query (⌘T)") { workspace.newQuery() }.padding(.horizontal, 4)
        }
        .frame(height: 34)
        .background(MB.bar)
    }
}

struct TabButton: View {
    @ObservedObject var workspace: Workspace
    let tab: WorkTab
    let selected: Bool
    var focused = true
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10.5)).foregroundStyle(selected ? MB.accent : MB.dim)
            Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? MB.text : MB.muted).lineLimit(1)
            if dirty { Circle().fill(MB.accent).frame(width: 6, height: 6) }
            Button { workspace.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(MB.dim)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? MB.hover : .clear))
            }
            .buttonStyle(.plain).opacity(hovering || selected ? 1 : 0)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 34)
        .frame(minWidth: 110, maxWidth: 220)
        .background(selected ? MB.bg : hovering ? MB.hover : .clear)
        .overlay(alignment: .top) { if selected { Rectangle().fill(focused ? MB.accent : MB.dim.opacity(0.5)).frame(height: 2) } }
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
        .contentShape(Rectangle())
        .onTapGesture { workspace.select(tab.id) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close tab") { workspace.close(tab.id) }
            if workspace.splitTab == tab.id {
                Button("Close split view") { workspace.toggleSplit() }
            } else {
                Button("Open on the right") { workspace.openOnRight(tab.id) }
            }
            Button("Close other tabs") { for t in workspace.tabs where t.id != tab.id { workspace.close(t.id) } }
        }
    }

    private var title: String {
        switch tab {
        case .table(let t): t.title
        case .query(let q): q.title
        }
    }

    private var symbol: String {
        switch tab {
        case .table(let t): t.object.kind.symbol
        case .query: "terminal"
        }
    }

    private var dirty: Bool { if case .table(let t) = tab { !t.changes.isEmpty } else { false } }
}

struct EmptyWorkspace: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 18) {
            GateMark().fill(MB.accent.opacity(0.9)).frame(width: 44, height: 37)
            Text("Pick a table on the left, or start a query").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
            VStack(alignment: .leading, spacing: 9) {
                shortcut("⌘P", "Open a table, view or function")
                shortcut("⌘T", "New query")
                if workspace.session.kind != .sqlite { shortcut("⌘K", "Switch database") }
                shortcut("⌘↩", "Run the statement at the cursor")
                shortcut("⌘S", "Save edited rows")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MB.bg)
    }

    private func shortcut(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            MBKey(text: key).frame(width: 36, alignment: .trailing)
            Text(text).font(.system(size: 12.5)).foregroundStyle(MB.muted)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var workspace: Workspace
    @State private var collapsed: Set<DBObject.Kind> = [.function]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                MBSegmented(options: Workspace.SidebarMode.allCases, selection: $workspace.sidebarMode) { $0.rawValue }
                HStack(spacing: 6) {
                    MBSearchField(placeholder: workspace.sidebarMode == .items ? "Search tables" : "Search", text: $workspace.sidebarFilter)
                    if workspace.sidebarMode == .items && !workspace.config.readOnly {
                        Menu {
                            Button("New table…") { workspace.sheet = .newTable }
                            Button("New view…") { workspace.sheet = .newView }
                            Divider()
                            Button("Import SQL file…") { workspace.importSQLFile() }
                            Button("Export database…") { workspace.sheet = .exportDatabase }
                            Button("Backup and restore…") { workspace.sheet = .backup }
                        } label: { Image(systemName: "plus") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(MB.muted).help("New table, view, import, export, backup")
                    }
                }
            }
            .padding(10)
            Hairline()
            switch workspace.sidebarMode {
            case .items: items
            case .queries: queries
            case .history: history
            }
        }
    }

    private var filtered: [DBObject] {
        let f = workspace.sidebarFilter.lowercased()
        return f.isEmpty ? workspace.objects : workspace.objects.filter { $0.name.lowercased().contains(f) }
    }

    @ViewBuilder private var items: some View {
        if let error = workspace.objectsError {
            Text(error).font(.system(size: 12)).foregroundStyle(MB.red).padding(12)
            Spacer()
        } else if workspace.loadingObjects && workspace.objects.isEmpty {
            ProgressView().controlSize(.small).padding(20)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(DBObject.Kind.allCases, id: \.self) { kind in
                        let list = filtered.filter { $0.kind == kind }
                        if !list.isEmpty {
                            let open = !collapsed.contains(kind) || !workspace.sidebarFilter.isEmpty
                            Button {
                                if collapsed.contains(kind) { collapsed.remove(kind) } else { collapsed.insert(kind) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                        .rotationEffect(.degrees(open ? 90 : 0))
                                    Text(kind.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4)
                                    Text("\(list.count)").font(.system(size: 10.5)).foregroundStyle(MB.dim.opacity(0.7))
                                    Spacer()
                                }
                                .foregroundStyle(MB.dim)
                                .padding(.horizontal, 12).frame(height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if open {
                                ForEach(list) { object in ObjectRow(workspace: workspace, object: object) }
                            }
                        }
                    }
                    if filtered.isEmpty && !workspace.loadingObjects {
                        Text(workspace.sidebarFilter.isEmpty ? "No tables yet" : "Nothing matches")
                            .font(.system(size: 12)).foregroundStyle(MB.dim).padding(14)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var queries: some View {
        let f = workspace.sidebarFilter.lowercased()
        let list = workspace.savedQueries.filter { f.isEmpty || $0.name.lowercased().contains(f) || $0.sql.lowercased().contains(f) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if list.isEmpty {
                    Text("Save a query from its tab to keep it here.").font(.system(size: 12)).foregroundStyle(MB.dim).padding(14)
                }
                ForEach(list) { q in
                    SidebarTextRow(title: q.name, detail: q.sql.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        workspace.newQuery(name: q.name, text: q.sql, saved: q.id)
                    }
                    .contextMenu {
                        Button("Open") { workspace.newQuery(name: q.name, text: q.sql, saved: q.id) }
                        Button("Delete") { workspace.deleteSavedQuery(q) }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var history: some View {
        let f = workspace.sidebarFilter.lowercased()
        let list = workspace.history.filter { f.isEmpty || $0.sql.lowercased().contains(f) }.prefix(300)
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if list.isEmpty {
                        Text("Statements you run show up here.").font(.system(size: 12)).foregroundStyle(MB.dim).padding(14)
                    }
                    ForEach(Array(list)) { item in
                        SidebarTextRow(title: item.sql.replacingOccurrences(of: "\n", with: " "),
                                       detail: item.date.formatted(date: .abbreviated, time: .shortened)
                                        + (item.milliseconds.map { " · \($0) ms" } ?? "") + (item.failed ? " · failed" : ""),
                                       mono: true, failed: item.failed) {
                            if let q = workspace.activeQuery, q.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                q.text = item.sql
                            } else {
                                workspace.newQuery(text: item.sql)
                            }
                        }
                        .contextMenu {
                            Button("Open in new tab") { workspace.newQuery(text: item.sql) }
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.sql, forType: .string)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            if !workspace.history.isEmpty {
                Hairline()
                Button("Clear history") { workspace.clearHistory() }.buttonStyle(.mbPlain).padding(6)
            }
        }
    }
}

struct ObjectRow: View {
    @ObservedObject var workspace: Workspace
    let object: DBObject
    @State private var hovering = false

    var body: some View {
        let open = workspace.activeTable?.object == object
        HStack(spacing: 8) {
            Image(systemName: object.kind.symbol).font(.system(size: 10.5))
                .foregroundStyle(open ? MB.accent : MB.dim).frame(width: 14)
            Text(object.name).font(.system(size: 12.5)).foregroundStyle(open ? MB.text : MB.muted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(open ? MB.selected : hovering ? MB.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { workspace.open(object) }
        .onHover { hovering = $0 }
        .help(object.name)
        .contextMenu {
            Button("Open") { workspace.open(object) }
            if object.kind.isRelation {
                Button("Open structure") { workspace.open(object, structure: true) }
                Button("New query on \(object.name)") { workspace.newQuery(text: workspace.starterQuery(object)) }
            }
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(object.name, forType: .string)
            }
            if object.kind.isRelation {
                Divider()
                Menu("Export") {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Button(f.title + "…") { workspace.exportTable(object, format: f) }
                    }
                }
                if object.kind == .table && !workspace.config.readOnly {
                    Button("Import CSV…") { workspace.importCSV(into: object) }
                    Divider()
                    Button("Empty table…") { workspace.dangerous("truncate", object) }
                }
                if !workspace.config.readOnly && object.kind != .foreignTable {
                    Button("Delete \(object.kind == .table ? "table" : "view")…") { workspace.dangerous("drop", object) }
                }
            }
        }
    }
}

struct SidebarTextRow: View {
    let title: String
    let detail: String
    var mono = false
    var failed = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5, weight: .medium))
                .foregroundStyle(failed ? MB.red : MB.text).lineLimit(2)
            Text(detail).font(.system(size: 11)).foregroundStyle(MB.dim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? MB.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

// MARK: - Row inspector

struct RowInspector: View {
    @ObservedObject var tab: TableTab

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(header).font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.muted)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 34)
            Hairline()
            if let row = tab.selection.first, tab.selection.count == 1, row < tab.gridRowCount {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(tab.columns.enumerated()), id: \.offset) { i, column in
                            InspectorField(tab: tab, row: row, column: i, info: tab.columnInfo.first { $0.name == column.name })
                                .id("\(row)-\(i)-\(tab.gridVersion)")
                        }
                    }
                    .padding(14)
                }
            } else {
                Spacer()
                Text(tab.selection.count > 1 ? "\(tab.selection.count) rows selected" : "Select a row to see all its values")
                    .font(.system(size: 12)).foregroundStyle(MB.dim).multilineTextAlignment(.center).padding(20)
                Spacer()
            }
        }
    }

    private var header: String {
        guard let row = tab.selection.first, tab.selection.count == 1 else { return "Row" }
        if row >= tab.rows.count { return "New row" }
        return "Row \(tab.page * tab.pageSize + row + 1)"
    }
}

// MARK: - Palette (⌘P open anything, ⌘K databases)

struct PaletteView: View {
    @ObservedObject var workspace: Workspace
    let kind: Workspace.Palette
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let action: () -> Void
    }

    private var items: [Item] {
        let q = query.lowercased()
        switch kind {
        case .open:
            var list = workspace.objects.filter { q.isEmpty || fuzzy($0.name.lowercased(), q) }.map { o in
                Item(id: o.id, title: o.name, detail: o.kind.title.lowercased().dropLast().description + (o.schema.map { " in \($0)" } ?? ""),
                     symbol: o.kind.symbol) { workspace.open(o) }
            }
            list += workspace.savedQueries.filter { q.isEmpty || fuzzy($0.name.lowercased(), q) }.map { s in
                Item(id: s.id.uuidString, title: s.name, detail: "saved query", symbol: "bookmark") {
                    workspace.newQuery(name: s.name, text: s.sql, saved: s.id)
                }
            }
            return list.sorted { a, b in
                let ap = a.title.lowercased().hasPrefix(q), bp = b.title.lowercased().hasPrefix(q)
                return ap != bp ? ap : a.title.count < b.title.count
            }
        case .databases:
            return workspace.databases.filter { q.isEmpty || $0.lowercased().contains(q) }.map { d in
                Item(id: d, title: d, detail: d == workspace.database ? "current" : "", symbol: "cylinder") { workspace.switchDatabase(d) }
            }
        }
    }

    private func fuzzy(_ s: String, _ q: String) -> Bool {
        if s.contains(q) { return true }
        // Letters in order, like "ordit" for order_items.
        var i = s.startIndex
        for c in q {
            guard let found = s[i...].firstIndex(of: c) else { return false }
            i = s.index(after: found)
        }
        return true
    }

    var body: some View {
        let list = items
        ZStack(alignment: .top) {
            MB.scrim.ignoresSafeArea().onTapGesture { workspace.palette = nil }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: kind == .open ? "magnifyingglass" : "cylinder").foregroundStyle(MB.dim)
                    TextField(kind == .open ? "Open a table, view, function or saved query" : "Switch database", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(MB.text)
                        .focused($focused)
                        .onSubmit { pick(list) }
                        .onKeyPress(.downArrow) { index = min(index + 1, max(0, list.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.escape) { workspace.palette = nil; return .handled }
                }
                .padding(.horizontal, 16).frame(height: 48)
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(list.prefix(200).enumerated()), id: \.element.id) { i, item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(i == index ? MB.accent : MB.dim).frame(width: 16)
                                    Text(item.title).font(.system(size: 13)).foregroundStyle(MB.text).lineLimit(1)
                                    Spacer()
                                    Text(item.detail).font(.system(size: 11.5)).foregroundStyle(MB.dim)
                                }
                                .padding(.horizontal, 14).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 7).fill(i == index ? MB.selected : .clear))
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                                .onTapGesture { index = i; pick(list) }
                                .id(i)
                            }
                            if list.isEmpty {
                                Text("Nothing matches").font(.system(size: 12.5)).foregroundStyle(MB.dim).padding(16)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(MB.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MB.lineStrong))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .frame(width: 560)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private func pick(_ list: [Item]) {
        guard list.indices.contains(index) else { return }
        let action = list[index].action
        workspace.palette = nil
        action()
    }
}

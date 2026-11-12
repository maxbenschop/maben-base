import AppKit
import BaseCore
import SwiftUI

/// A table or view opened in a tab: rows a page at a time, sort, filters, staged edits, and its structure.
@MainActor
final class TableTab: ObservableObject, GridSource, Identifiable {
    enum Mode { case data, structure }

    let id = UUID()
    let object: DBObject
    unowned let workspace: Workspace

    @Published var mode: Mode = .data
    @Published private(set) var columns: [ResultColumn] = []
    @Published private(set) var rows: [[String?]] = []
    @Published private(set) var columnInfo: [ColumnInfo] = []
    @Published private(set) var indexes: [IndexInfo] = []
    @Published private(set) var definition: String?
    @Published private(set) var foreignKeys: [ForeignKeyInfo] = []
    @Published private(set) var primaryKey: [String] = []
    /// The count is an estimate from the statistics (huge tables), until you ask for the exact one.
    @Published private(set) var countIsEstimate = false
    @Published var page = 0
    @Published var pageSize = 300
    @Published private(set) var totalCount: Int?
    @Published private(set) var order: [(column: String, ascending: Bool)] = []
    @Published var filters: [Filter] = []
    @Published var showFilters = false
    @Published private(set) var changes = ChangeSet()
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var lastSQL = ""
    @Published private(set) var elapsed: Int?
    @Published private(set) var selection = IndexSet()
    @Published private(set) var gridVersion = 0
    @Published private(set) var gridColumnsVersion = 0
    private var loadedOnce = false

    init(object: DBObject, workspace: Workspace) {
        self.object = object
        self.workspace = workspace
    }

    var title: String { object.name }
    var dialect: Dialect { workspace.session.dialect }

    /// Column → type, so strict engines (BigQuery, ClickHouse, Cassandra) get numbers bare in filters.
    var columnTypes: [String: String] {
        var t: [String: String] = [:]
        for c in columns { t[c.name] = c.typeName }
        for c in columnInfo { t[c.name] = c.type }
        return t
    }

    var canEdit: Bool {
        object.kind == .table && !primaryKey.isEmpty && !workspace.session.config.readOnly
            && primaryKey.allSatisfy { key in columns.contains { $0.name == key } }
    }

    var readOnlyReason: String? {
        if workspace.session.config.readOnly { return "Read-only connection" }
        if object.kind != .table { return "Views are read-only" }
        if primaryKey.isEmpty && !columns.isEmpty { return "No primary key: read-only" }
        return nil
    }

    // MARK: Loading

    func loadIfNeeded() {
        guard !loadedOnce else { return }
        loadedOnce = true
        Task { await loadStructure(); await load() }
    }

    func loadStructure() async {
        let table = object.table
        let object = self.object
        do {
            let (cols, idx, fks) = try await workspace.session.run { d in
                (try d.columns(of: table), try d.indexes(of: table), (try? d.foreignKeys(of: table)) ?? [])
            }
            columnInfo = cols
            indexes = idx
            foreignKeys = fks
            gridColumnsVersion += 1
            primaryKey = cols.filter(\.isPrimaryKey).map(\.name)
            workspace.rememberColumns(table, cols.map(\.name))
        } catch {
            self.error = error.localizedDescription
        }
        definition = try? await workspace.session.run { d in try d.definition(of: object) }
    }

    func load(keepPage: Bool = true) async {
        if !keepPage { page = 0 }
        loading = true
        error = nil
        let filter = dialect.whereClause(filters, types: columnTypes)
        var order = self.order
        // A stable order makes paging reliable: fall back to the primary key.
        if order.isEmpty, !primaryKey.isEmpty { order = primaryKey.map { ($0, true) } }
        let sql = dialect.selectPage(object.table, filter: filter, order: order, limit: pageSize, offset: page * pageSize)
        let countSQL = dialect.count(object.table, filter: filter)
        lastSQL = sql
        let start = Date()
        do {
            let result = try await workspace.session.run { d in try d.execute(sql).first(where: \.hasRows) ?? QueryResult() }
            elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let columnsChanged = result.columns.map(\.name) != columns.map(\.name)
            columns = result.columns
            rows = result.rows
            changes = ChangeSet()
            selection = []
            if columnsChanged || gridColumnsVersion == 0 { gridColumnsVersion += 1 }
            gridVersion += 1
            workspace.objectWillChange.send()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        await count(filter: filter, countSQL: countSQL)
    }

    /// Exact counts get slow on huge tables, so without a filter, tables the statistics put over
    /// 500,000 rows show an estimate first, with a button for the exact count.
    private func count(filter: String?, countSQL: String) async {
        let table = object.table
        if filter == nil, !exactCountRequested,
           let estimate = try? await workspace.session.run({ d in try d.estimatedCount(of: table) }), estimate > 500_000 {
            totalCount = estimate
            countIsEstimate = true
            return
        }
        if let count = try? await workspace.session.run({ d in try d.rows(countSQL).first?[0] ?? nil }) {
            totalCount = Int(count)
            countIsEstimate = false
        }
    }

    private var exactCountRequested = false

    func countExactly() {
        exactCountRequested = true
        let filter = dialect.whereClause(filters, types: columnTypes)
        let sql = dialect.count(object.table, filter: filter)
        Task { await count(filter: filter, countSQL: sql) }
    }

    func refresh() {
        Task {
            await loadStructure()
            await load()
        }
    }

    func applyFilters() { Task { await load(keepPage: false) } }

    func nextPage() {
        guard rows.count == pageSize else { return }
        Task { await guardChanges { self.page += 1; await self.load() } }
    }

    func previousPage() {
        guard page > 0 else { return }
        Task { await guardChanges { self.page -= 1; await self.load() } }
    }

    /// Asks before throwing away unsaved edits.
    private func guardChanges(_ then: @escaping () async -> Void) async {
        if !changes.isEmpty {
            let ok = await confirm("Discard \(changes.count) unsaved change\(changes.count == 1 ? "" : "s")?",
                                   detail: "They haven't been written to the database.", button: "Discard", window: workspace.window)
            guard ok else { return }
        }
        await then()
    }

    var pageLabel: String {
        guard !rows.isEmpty else { return totalCount == 0 ? "No rows" : "" }
        let from = page * pageSize + 1
        let to = page * pageSize + rows.count
        if let totalCount { return "\(from.formatted())–\(to.formatted()) of \(countIsEstimate ? "about " : "")\(totalCount.formatted())" }
        return "\(from.formatted())–\(to.formatted())"
    }

    // MARK: GridSource

    var gridColumns: [ResultColumn] { columns }
    var gridLayoutKey: String? { "\(workspace.config.id)|\(workspace.database ?? "")|\(object.schema ?? "")|\(object.name)" }

    func gridForeignKey(column: Int) -> ForeignKeyInfo? {
        guard column < columns.count else { return nil }
        let name = columns[column].name
        return foreignKeys.first { $0.columns.contains(name) }
    }

    /// Opens the referenced table filtered to the row this cell points at.
    func gridFollow(row: Int, column: Int) {
        guard let fk = gridForeignKey(column: column) else { return }
        var filters: [Filter] = []
        for (from, to) in zip(fk.columns, fk.refColumns) {
            guard let i = columns.firstIndex(where: { $0.name == from }) else { continue }
            let v = gridValue(row: row, column: i)
            filters.append(Filter(column: to, op: v == nil ? .isNull : .equals, value: v ?? ""))
        }
        workspace.openFiltered(fk.target, filters: filters)
    }

    func gridPaste(_ values: [[String?]], startRow: Int, columns cols: [Int]) {
        guard canEdit else { return }
        for (i, row) in values.enumerated() {
            let target = startRow + i
            if target < gridRowCount, gridRowState(target) != .deleted {
                for (value, c) in zip(row, cols) { gridEdit(row: target, column: c, value: value) }
            } else if target >= gridRowCount {
                var insert = ChangeSet.Insert()
                for (value, c) in zip(row, cols) { insert.values[c] = .some(value) }
                changes.inserts.append(insert)
            }
        }
        gridVersion += 1
    }
    var gridRowCount: Int { rows.count + changes.inserts.count }

    func gridValue(row: Int, column: Int) -> String? {
        if row >= rows.count {
            let insert = changes.inserts[row - rows.count]
            return insert.values[column] ?? nil
        }
        if let edited = changes.value(row: row, column: column) { return edited }
        return rows[row][column]
    }

    func gridRowState(_ row: Int) -> RowState {
        if row >= rows.count { return .inserted }
        return changes.deletes.contains(row) ? .deleted : .normal
    }

    func gridIsEdited(row: Int, column: Int) -> Bool {
        if row >= rows.count { return changes.inserts[row - rows.count].values[column] != nil }
        return changes.value(row: row, column: column) != nil
    }

    func gridEdit(row: Int, column: Int, value: String?) {
        guard canEdit else { return }
        if row >= rows.count {
            changes.inserts[row - rows.count].values[column] = .some(value)
        } else {
            changes.set(row: row, column: column, value: value, original: rows[row])
        }
        gridVersion += 1
    }

    func gridDelete(rows indexes: IndexSet) {
        guard canEdit else { return }
        var removeInserts: [Int] = []
        var anyUndelete = false
        for r in indexes {
            if r >= rows.count { removeInserts.append(r - rows.count) }
            else if changes.deletes.contains(r) { anyUndelete = true }
        }
        for r in indexes where r < rows.count {
            // Pressing Delete again on deleted rows brings them back.
            if anyUndelete { changes.undelete(row: r) } else { changes.delete(row: r, original: rows[r]) }
        }
        for i in removeInserts.sorted(by: >) { changes.inserts.remove(at: i) }
        gridVersion += 1
    }

    func gridDuplicate(rows indexes: IndexSet) {
        guard canEdit else { return }
        let pk = Set(primaryKey.compactMap { key in columns.firstIndex { $0.name == key } })
        for r in indexes {
            var values: [Int: String?] = [:]
            for c in columns.indices where !pk.contains(c) { values[c] = .some(gridValue(row: r, column: c)) }
            changes.inserts.append(.init(values: values))
        }
        gridVersion += 1
    }

    func addRow() {
        guard canEdit else { return }
        changes.inserts.append(.init())
        gridVersion += 1
    }

    func gridSort(column: Int, ascending: Bool) {
        guard column < columns.count else { return }
        order = [(columns[column].name, ascending)]
        Task { await guardChanges { await self.load(keepPage: false) } }
    }

    func gridSelectionChanged(_ rows: IndexSet) { selection = rows }

    func gridFilter(column: Int, value: String?) {
        filters = [Filter(column: columns[column].name, op: value == nil ? .isNull : .equals, value: value ?? "")]
        showFilters = true
        applyFilters()
    }

    /// Shows only the rows matching these filters (used when following a foreign key here).
    func show(filters new: [Filter]) {
        filters = new
        showFilters = true
        mode = .data
        if loadedOnce {
            Task { await load(keepPage: false) }
        } else {
            loadedOnce = true
            Task { await loadStructure(); await load(keepPage: false) }
        }
    }

    // MARK: Saving

    func discard() {
        changes = ChangeSet()
        gridVersion += 1
    }

    func sqlForChanges() throws -> [String] {
        try dialect.statements(for: changes, table: object.table, columns: columns, primaryKey: primaryKey)
    }

    /// Writes all staged changes in one transaction. On production, asks first and shows the SQL.
    func commit() async {
        guard !changes.isEmpty else { return }
        let statements: [String]
        do { statements = try sqlForChanges() } catch { self.error = error.localizedDescription; return }
        let preview = statements.prefix(8).joined(separator: ";\n") + (statements.count > 8 ? ";\n…" : ";")
        guard await workspace.allow(preview, write: true) else { return }
        loading = true
        do {
            // One transaction where the engine has them; an UPDATE or DELETE that matches nothing stops it.
            try await workspace.session.run { d in try d.runAsUnit(statements, checkFound: true) }
            workspace.recordHistory(statements.joined(separator: ";\n") + ";", ms: nil, failed: false)
            await load()
        } catch {
            loading = false
            showError(error, in: workspace.window, title: "Changes weren't saved")
        }
    }
}

// MARK: - View

struct TableTabView: View {
    @ObservedObject var tab: TableTab
    @State private var showSQL = false

    var body: some View {
        VStack(spacing: 0) {
            if tab.mode == .data {
                if tab.showFilters { FilterBar(tab: tab); Hairline() }
                ZStack {
                    DataGrid(source: tab, version: tab.gridVersion, columnsVersion: tab.gridColumnsVersion)
                    if let error = tab.error, tab.rows.isEmpty { ErrorPanel(message: error) }
                }
            } else {
                StructureEditorView(tab: tab)
            }
            Hairline()
            bottomBar
        }
        .onAppear { tab.loadIfNeeded() }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            MBSegmented(options: [TableTab.Mode.data, .structure], selection: $tab.mode) { $0 == .data ? "Data" : "Structure" }
            if tab.mode == .data {
                if tab.canEdit {
                    MBIconButton(symbol: "plus", help: "Add row") { tab.addRow() }
                }
                MBIconButton(symbol: "line.3.horizontal.decrease", help: "Filters (⌘F)", active: tab.showFilters || tab.filters.contains(where: \.enabled)) {
                    tab.showFilters.toggle()
                    if tab.showFilters && tab.filters.isEmpty, let first = tab.columns.first {
                        tab.filters = [Filter(column: first.name)]
                    }
                }
                MBIconButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)") { tab.refresh() }
                if let reason = tab.readOnlyReason { MBTag(text: reason) }
            }
            Spacer(minLength: 8)
            if tab.loading { ProgressView().controlSize(.small).scaleEffect(0.8) }
            if !tab.changes.isEmpty {
                Button("Show SQL") { showSQL = true }
                    .buttonStyle(.mbPlain)
                    .popover(isPresented: $showSQL, arrowEdge: .top) { ChangesPreview(tab: tab) }
                Button("Discard") { tab.discard() }.buttonStyle(.mbQuiet)
                Button("Save \(tab.changes.count) change\(tab.changes.count == 1 ? "" : "s")") { Task { await tab.commit() } }
                    .buttonStyle(.mbPrimary)
                    .help("Save changes (⌘S)")
            } else if tab.mode == .data {
                if let ms = tab.elapsed { Text("\(ms) ms").font(.system(size: 11)).foregroundStyle(MB.dim).lineLimit(1).fixedSize() }
                Text(tab.pageLabel).font(.system(size: 12)).foregroundStyle(MB.muted).monospacedDigit().lineLimit(1).fixedSize()
                if tab.countIsEstimate {
                    Button("Count") { tab.countExactly() }.buttonStyle(.mbPlain).help("Count the rows exactly (can take a while on a big table)")
                }
                MBIconButton(symbol: "chevron.left", help: "Previous page") { tab.previousPage() }.disabled(tab.page == 0)
                MBIconButton(symbol: "chevron.right", help: "Next page") { tab.nextPage() }.disabled(tab.rows.count < tab.pageSize)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(MB.bar)
    }
}

struct ChangesPreview: View {
    @ObservedObject var tab: TableTab

    var body: some View {
        let sql = (try? tab.sqlForChanges().map { $0 + ";" }.joined(separator: "\n")) ?? "—"
        VStack(alignment: .leading, spacing: 10) {
            Text("These statements run in one transaction").font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.muted)
            ScrollView {
                Text(sql).font(MB.mono).foregroundStyle(MB.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                }.buttonStyle(.mbQuiet)
            }
        }
        .padding(14)
        .frame(width: 520)
        .background(MB.card)
    }
}

struct ErrorPanel: View {
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(MB.red)
            Text(message).font(.system(size: 12.5)).foregroundStyle(MB.text).multilineTextAlignment(.center)
                .textSelection(.enabled).frame(maxWidth: 460)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MB.bg)
    }
}

/// Filter rows: column, operator, value, one line per condition, all joined with AND.
struct FilterBar: View {
    @ObservedObject var tab: TableTab

    var body: some View {
        VStack(spacing: 6) {
            ForEach($tab.filters) { $filter in
                HStack(spacing: 6) {
                    Toggle("", isOn: $filter.enabled).toggleStyle(.checkbox).labelsHidden().tint(MB.accent)
                    if filter.op != .sql {
                        Picker("", selection: $filter.column) {
                            ForEach(tab.columns, id: \.name) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden().frame(width: 170)
                    }
                    Picker("", selection: $filter.op) {
                        ForEach(Filter.Op.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    if filter.op.takesValue {
                        MBField(placeholder: filter.op == .sql ? "WHERE …  e.g. price > 10 AND active" : filter.op == .in ? "a, b, c" : "Value",
                                text: $filter.value, mono: true)
                            .onSubmit { tab.applyFilters() }
                    } else {
                        Spacer()
                    }
                    MBIconButton(symbol: "minus", help: "Remove condition") {
                        tab.filters.removeAll { $0.id == filter.id }
                        if tab.filters.isEmpty { tab.showFilters = false }
                        tab.applyFilters()
                    }
                    MBIconButton(symbol: "plus", help: "Add condition") {
                        tab.filters.append(Filter(column: tab.columns.first?.name ?? ""))
                    }
                }
            }
            HStack {
                Text("Conditions are joined with AND").font(.system(size: 11)).foregroundStyle(MB.dim)
                Spacer()
                Button("Clear") { tab.filters = []; tab.showFilters = false; tab.applyFilters() }.buttonStyle(.mbPlain)
                Button("Apply") { tab.applyFilters() }.buttonStyle(.mbQuiet)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MB.bar)
    }
}

/// Columns, indexes and the CREATE statement.
struct StructureView: View {
    @ObservedObject var tab: TableTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Columns") {
                    header(["", "Name", "Type", "Nullable", "Default", "Comment"])
                    ForEach(tab.columnInfo) { c in
                        row([c.isPrimaryKey ? "key" : "", c.name, c.type + (c.extra.map { " · \($0)" } ?? ""),
                             c.nullable ? "yes" : "no", c.defaultValue ?? "", c.comment ?? ""])
                    }
                }
                if !tab.indexes.isEmpty {
                    section("Indexes") {
                        header(["", "Name", "Columns", "Unique", "", ""])
                        ForEach(tab.indexes) { i in
                            row([i.primary ? "key" : "", i.name, i.columns.joined(separator: ", "), i.unique ? "yes" : "no", "", ""])
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(MB.bg)
    }

    private let widths: [CGFloat] = [22, 180, 200, 70, 200, 200]

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.dim)
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: MB.radius).fill(MB.card))
                .overlay(RoundedRectangle(cornerRadius: MB.radius).strokeBorder(MB.line))
        }
    }

    private func header(_ cells: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, s in
                Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(MB.dim)
                    .frame(width: widths[i], alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func row(_ cells: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, s in
                Group {
                    if i == 0 {
                        Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(MB.accent).opacity(s.isEmpty ? 0 : 1)
                    } else {
                        Text(s).font(i == 1 ? .system(size: 12.5, weight: .medium) : MB.mono)
                            .foregroundStyle(i == 1 ? MB.text : MB.muted).lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(width: widths[i], alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .overlay(alignment: .bottom) { Hairline() }
        .textSelection(.enabled)
    }
}

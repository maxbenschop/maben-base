import AppKit
import BaseCore
import SwiftUI

/// Common column types per engine, offered next to the type field.
enum ColumnTypes {
    static func common(_ kind: DatabaseKind) -> [String] {
        switch kind {
        case .postgres: ["bigint", "integer", "smallint", "bigserial", "serial", "numeric(12,2)", "double precision", "boolean",
                         "text", "varchar(255)", "uuid", "date", "timestamptz", "timestamp", "time", "interval", "jsonb", "json",
                         "bytea", "text[]", "integer[]", "inet"]
        case .mysql: ["bigint", "int", "smallint", "tinyint(1)", "decimal(12,2)", "double", "varchar(255)", "char(36)", "text",
                      "longtext", "date", "datetime", "timestamp", "time", "json", "blob", "varbinary(255)", "enum('a','b')"]
        case .sqlite, .libsql, .d1: ["integer", "real", "numeric", "text", "blob"]
        case .duckdb: ["BIGINT", "INTEGER", "DOUBLE", "DECIMAL(12,2)", "BOOLEAN", "VARCHAR", "DATE", "TIMESTAMP", "TIMESTAMPTZ", "UUID", "JSON", "BLOB"]
        default: []
        }
    }
}

/// Runs a design's statements: Postgres and SQLite in one transaction, MySQL one by one (its DDL commits itself).
@MainActor
enum DesignRunner {
    /// The SQL was shown in a review sheet first, so safe mode only adds read-only and Touch ID here.
    static func apply(_ statements: [String], workspace: Workspace) async throws {
        guard await workspace.allow(statements.joined(separator: ";\n"), write: true, alreadyConfirmed: true) else {
            throw DatabaseError("Not run.", detail: "This connection's safe mode didn't allow it.")
        }
        let session = workspace.session
        // MySQL's DDL commits itself, so it runs one by one and says how far it got.
        let transactional = session.kind != .mysql
        try await session.run { d in
            if transactional {
                try d.runAsUnit(statements)
            } else {
                for (i, s) in statements.enumerated() {
                    do { _ = try d.execute(s) } catch var e as DatabaseError {
                        if i > 0 { e.detail = [e.detail, "The first \(i) statement\(i == 1 ? "" : "s") already ran (MySQL can't undo schema changes)."].compactMap { $0 }.joined(separator: "\n") }
                        throw e
                    }
                }
            }
        }
        workspace.recordHistory(statements.joined(separator: ";\n") + ";", ms: nil, failed: false)
    }
}

// MARK: - Structure tab

struct StructureEditorView: View {
    @ObservedObject var tab: TableTab
    @State private var original: TableDesign?
    @State private var draft: TableDesign?
    @State private var review: [String]?
    @State private var problem: String?
    @State private var applying = false

    private var editable: Bool { tab.object.kind == .table && !tab.workspace.config.readOnly && tab.dialect.supportsDesign }


    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if editable, draft != nil {
                        DesignEditor(design: Binding(get: { draft! }, set: { draft = $0 }), workspace: tab.workspace)
                    } else {
                        StructureView(tab: tab)
                    }
                    if let definition = tab.definition {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Definition").font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.dim)
                            Text(definition).font(MB.mono).foregroundStyle(MB.text).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(RoundedRectangle(cornerRadius: MB.radius).fill(MB.card))
                                .overlay(RoundedRectangle(cornerRadius: MB.radius).strokeBorder(MB.line))
                        }
                    }
                }
                .padding(20)
            }
            .background(MB.bg)
            if editable, let draft, let original, draft != original {
                Hairline()
                HStack(spacing: 8) {
                    if let problem {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MB.red).font(.system(size: 11))
                        Text(problem).font(.system(size: 12)).foregroundStyle(MB.red).lineLimit(2)
                    } else {
                        Text("Changes aren't applied until you review them").font(.system(size: 12)).foregroundStyle(MB.dim)
                    }
                    Spacer()
                    Button("Discard") { self.draft = original; problem = nil }.buttonStyle(.mbQuiet)
                    Button("Review changes…") { prepareReview() }.buttonStyle(.mbPrimary)
                }
                .padding(.horizontal, 12).frame(height: 44).background(MB.bar)
            }
        }
        .onAppear(perform: reset)
        .onChange(of: tab.columnInfo) { _, _ in reset() }
        .onChange(of: tab.foreignKeys) { _, _ in reset() }
        .onChange(of: tab.indexes) { _, _ in reset() }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            ReviewSheet(title: "Change \(tab.object.name)", statements: review ?? [], applying: applying,
                        note: tab.workspace.session.kind == .mysql ? "MySQL applies schema changes one by one and can't undo them if one fails."
                            : "These run in one transaction: all of them, or none.",
                        production: false) {
                Task { await apply() }
            } cancel: { review = nil }
        }
    }

    private func reset() {
        guard !tab.columnInfo.isEmpty else { return }
        let d = TableDesign(table: tab.object.table, kind: tab.workspace.session.kind, columns: tab.columnInfo,
                            indexes: tab.indexes, foreignKeys: tab.foreignKeys)
        original = d
        draft = d
        problem = nil
    }

    private func prepareReview() {
        guard let draft else { return }
        do {
            let statements = try tab.dialect.designStatements(original: original, draft: draft)
            if statements.isEmpty { problem = "Nothing to change."; return }
            problem = nil
            review = statements
        } catch {
            problem = error.localizedDescription
        }
    }

    private func apply() async {
        guard let statements = review else { return }
        applying = true
        do {
            try await DesignRunner.apply(statements, workspace: tab.workspace)
            review = nil
            applying = false
            await tab.loadStructure()
            await tab.load()
            await tab.workspace.reloadObjects()
            reset()
        } catch {
            applying = false
            review = nil
            showError(error, in: tab.workspace.window, title: "The structure wasn't changed")
        }
    }
}

/// The SQL that's about to run, with Apply.
struct ReviewSheet: View {
    let title: String
    let statements: [String]
    let applying: Bool
    let note: String
    let production: Bool
    let apply: () -> Void
    let cancel: () -> Void
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
            Text(note).font(.system(size: 12)).foregroundStyle(MB.dim)
            ScrollView {
                Text(statements.map { $0 + ";" }.joined(separator: "\n\n"))
                    .font(MB.mono).foregroundStyle(MB.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(minHeight: 160, maxHeight: 360)
            .background(RoundedRectangle(cornerRadius: 8).fill(MB.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MB.line))
            if production {
                Toggle("I know this is the production database", isOn: $confirmed).toggleStyle(.checkbox)
                    .font(.system(size: 12.5)).foregroundStyle(MB.red)
            }
            HStack {
                Button("Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(statements.map { $0 + ";" }.joined(separator: "\n"), forType: .string)
                }.buttonStyle(.mbPlain)
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel).buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button("Apply \(statements.count) statement\(statements.count == 1 ? "" : "s")", action: apply)
                    .buttonStyle(.mbPrimary).disabled(applying || (production && !confirmed))
            }
        }
        .padding(20)
        .frame(width: 640)
        .background(MB.bg)
    }
}

// MARK: - The design editor

/// Columns, primary key, indexes and foreign keys of one table, all editable.
struct DesignEditor: View {
    @Binding var design: TableDesign
    @ObservedObject var workspace: Workspace
    @State private var refColumns: [String: [String]] = [:]

    private var kind: DatabaseKind { workspace.session.kind }
    private var columnNames: [String] { design.columns.map(\.name).filter { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Columns", add: ("Add column", { design.columns.append(.init(name: nextName("column"), type: kind == .sqlite ? "text" : "text")) })) {
                header(["Key", "Name", "Type", "Null", "Default", kind == .sqlite ? "" : "Comment"], widths: [34, 170, 170, 34, 150, nil])
                ForEach($design.columns) { $c in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $c.primaryKey).toggleStyle(.checkbox).labelsHidden().frame(width: 34).help("Part of the primary key")
                        cellField("name", text: Binding(get: { c.name }, set: { design.renameColumn(c.id, to: $0) })).frame(width: 170)
                        HStack(spacing: 2) {
                            cellField("type", text: $c.type, mono: true)
                            Menu {
                                ForEach(ColumnTypes.common(kind), id: \.self) { t in Button(t) { c.type = t } }
                            } label: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        .frame(width: 170)
                        Toggle("", isOn: $c.nullable).toggleStyle(.checkbox).labelsHidden().frame(width: 34).help("Allows NULL")
                        cellField("none", text: $c.defaultValue, mono: true).frame(width: 150)
                            .help("A SQL expression: 'text', 42, now()")
                        if kind != .sqlite { cellField("", text: $c.comment) } else { Spacer() }
                        removeButton { design.columns.removeAll { $0.id == c.id } }
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(c.original == nil ? MB.green.opacity(0.06) : .clear)
                    .overlay(alignment: .bottom) { Hairline() }
                }
            }

            section("Indexes", add: ("Add index", { design.indexes.append(.init(name: "\(design.table.name)_\(columnNames.first ?? "idx")_idx", columns: Array(columnNames.prefix(1)))) })) {
                if design.indexes.isEmpty { empty("No indexes besides the primary key") } else {
                    header(["", "Name", "Columns", "Unique"], widths: [34, 170, 260, 50])
                    ForEach($design.indexes) { $i in
                        HStack(spacing: 8) {
                            Color.clear.frame(width: 34, height: 1)
                            cellField("name", text: $i.name).frame(width: 170)
                            ColumnPicker(all: columnNames, selected: $i.columns).frame(width: 260, alignment: .leading)
                            Toggle("", isOn: $i.unique).toggleStyle(.checkbox).labelsHidden().frame(width: 50)
                            Spacer()
                            removeButton { design.indexes.removeAll { $0.id == i.id } }
                        }
                        .padding(.horizontal, 12).frame(height: 36)
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                }
            }

            section("Foreign keys", add: ("Add foreign key", addForeignKey)) {
                if design.foreignKeys.isEmpty { empty("No foreign keys") } else {
                    header(["", "Name", "Columns", "References", "Columns", "On delete"], widths: [34, 170, 150, 150, 130, 120])
                    ForEach($design.foreignKeys) { $f in
                        HStack(spacing: 8) {
                            Color.clear.frame(width: 34, height: 1)
                            cellField("name", text: $f.name).frame(width: 170)
                            ColumnPicker(all: columnNames, selected: $f.columns).frame(width: 150, alignment: .leading)
                            Menu {
                                ForEach(workspace.objects.filter { $0.kind == .table }) { o in
                                    Button(o.name) {
                                        f.refTable = o.name
                                        f.refSchema = o.schema
                                        loadColumns(o.table)
                                    }
                                }
                            } label: { Text(f.refTable.isEmpty ? "Table" : f.refTable).lineLimit(1) }
                                .menuStyle(.borderlessButton).frame(width: 150, alignment: .leading)
                            ColumnPicker(all: refColumns[f.refTable] ?? f.refColumns, selected: $f.refColumns).frame(width: 130, alignment: .leading)
                                .onAppear { if refColumns[f.refTable] == nil, !f.refTable.isEmpty { loadColumns(TableRef(schema: f.refSchema, name: f.refTable)) } }
                            Picker("", selection: $f.onDelete) {
                                ForEach(ForeignKeyInfo.actions, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 120)
                            Spacer()
                            removeButton { design.foreignKeys.removeAll { $0.id == f.id } }
                        }
                        .padding(.horizontal, 12).frame(height: 36)
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                }
            }
        }
    }

    private func nextName(_ base: String) -> String {
        var n = 1
        while design.columns.contains(where: { $0.name == "\(base)_\(n)" }) { n += 1 }
        return "\(base)_\(n)"
    }

    private func addForeignKey() {
        let target = workspace.objects.first { $0.kind == .table && $0.name != design.table.name }
        let column = columnNames.first { $0.hasSuffix("_id") } ?? columnNames.first ?? ""
        design.foreignKeys.append(.init(name: "\(design.table.name)_\(column)_fkey", columns: [column],
                                        refTable: target?.name ?? "", refSchema: target?.schema, refColumns: ["id"]))
        if let target { loadColumns(target.table) }
    }

    private func loadColumns(_ table: TableRef) {
        Task {
            if let cols = try? await workspace.session.run({ try $0.columns(of: table) }) {
                refColumns[table.name] = cols.map(\.name)
            }
        }
    }

    private func section<C: View>(_ title: String, add: (String, () -> Void), @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.dim)
                Spacer()
                Button { add.1() } label: { Label(add.0, systemImage: "plus") }.buttonStyle(.mbPlain)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: MB.radius).fill(MB.card))
                .overlay(RoundedRectangle(cornerRadius: MB.radius).strokeBorder(MB.line))
                .clipShape(RoundedRectangle(cornerRadius: MB.radius))
        }
    }

    private func header(_ titles: [String], widths: [CGFloat?]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(MB.dim)
                    .lineLimit(1).fixedSize()
                    .frame(width: widths[i], alignment: .leading)
                    .frame(maxWidth: widths[i] == nil ? .infinity : nil, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(MB.dim).padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cellField(_ placeholder: String, text: Binding<String>, mono: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(mono ? MB.mono : .system(size: 12.5))
            .foregroundStyle(MB.text)
            .padding(.horizontal, 7).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(MB.wash(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(MB.line))
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle").foregroundStyle(MB.dim) }
            .buttonStyle(.plain).frame(width: 20).help("Remove")
    }
}

/// Picks an ordered list of columns from a menu.
struct ColumnPicker: View {
    let all: [String]
    @Binding var selected: [String]

    var body: some View {
        Menu {
            ForEach(all, id: \.self) { name in
                Button {
                    if let i = selected.firstIndex(of: name) { selected.remove(at: i) } else { selected.append(name) }
                } label: {
                    if selected.contains(name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            Text(selected.isEmpty ? "Choose…" : selected.joined(separator: ", ")).lineLimit(1)
                .font(MB.mono)
        }
        .menuStyle(.borderlessButton)
    }
}

// MARK: - New table and new view

struct NewTableSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var design: TableDesign
    @State private var name = ""
    @State private var review: [String]?
    @State private var problem: String?
    @State private var applying = false
    let close: () -> Void

    init(workspace: Workspace, close: @escaping () -> Void) {
        self.workspace = workspace
        self.close = close
        _design = State(initialValue: TableDesign.new(table: TableRef(schema: workspace.schema, name: ""), kind: workspace.session.kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("New table").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                MBField(placeholder: "table_name", text: $name, mono: true).frame(width: 260)
                if let schema = workspace.schema, workspace.session.kind.hasSchemas {
                    Text("in \(schema)").font(.system(size: 12)).foregroundStyle(MB.dim)
                }
                Spacer()
            }
            ScrollView {
                DesignEditor(design: $design, workspace: workspace).padding(.vertical, 4)
            }
            .frame(minHeight: 360)
            if let review {
                Text(review.map { $0 + ";" }.joined(separator: "\n\n")).font(MB.mono).foregroundStyle(MB.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(MB.card))
            }
            HStack {
                if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(MB.red).lineLimit(3) }
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Cancel", action: close).buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button(review == nil ? "Review SQL" : "Create table") {
                    if review == nil { prepare() } else { Task { await create() } }
                }
                    .buttonStyle(.mbPrimary).disabled(applying)
            }
        }
        .padding(20)
        .frame(width: 960, height: 640)
        .background(MB.bg)
        .onChange(of: design) { _, _ in review = nil }
        .onChange(of: name) { _, _ in review = nil }
    }

    private func prepare() {
        design.table = TableRef(schema: workspace.session.kind.hasSchemas ? workspace.schema : nil, name: name.trimmingCharacters(in: .whitespaces))
        do { review = try workspace.session.dialect.designStatements(original: nil, draft: design); problem = nil }
        catch { problem = error.localizedDescription }
    }

    private func create() async {
        guard let statements = review else { return }
        applying = true
        do {
            try await DesignRunner.apply(statements, workspace: workspace)
            await workspace.reloadObjects()
            if let o = workspace.objects.first(where: { $0.name == design.table.name && $0.kind == .table }) { workspace.open(o) }
            close()
        } catch {
            problem = error.localizedDescription
        }
        applying = false
    }
}

struct NewViewSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var name = ""
    @State private var body_ = "SELECT\n  \nFROM "
    @State private var problem: String?
    @State private var applying = false
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("New view").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                MBField(placeholder: "view_name", text: $name, mono: true).frame(width: 260)
                Spacer()
            }
            Text("The query the view shows:").font(.system(size: 12)).foregroundStyle(MB.dim)
            SQLEditor(text: $body_, completions: { workspace.completionWords(context: $0) }, onRun: { _ in })
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MB.line))
            Text(sql).font(MB.mono).foregroundStyle(MB.dim).lineLimit(3).textSelection(.enabled)
            HStack {
                if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(MB.red).lineLimit(3) }
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Cancel", action: close).buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button("Create view") { Task { await create() } }.buttonStyle(.mbPrimary)
                    .disabled(applying || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .background(MB.bg)
    }

    private var table: TableRef {
        TableRef(schema: workspace.session.kind.hasSchemas ? workspace.schema : nil, name: name.trimmingCharacters(in: .whitespaces))
    }

    private var sql: String { workspace.session.dialect.createView(table, body: body_) }

    private func create() async {
        applying = true
        do {
            try await DesignRunner.apply([sql], workspace: workspace)
            await workspace.reloadObjects()
            if let o = workspace.objects.first(where: { $0.name == table.name && $0.kind == .view }) { workspace.open(o) }
            close()
        } catch {
            problem = error.localizedDescription
        }
        applying = false
    }
}

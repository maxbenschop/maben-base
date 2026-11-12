import AppKit
import BaseCore
import SwiftUI

enum RowState { case normal, inserted, deleted }

/// What the grid shows and how edits come back. Table tabs edit; query results are read-only.
@MainActor
protocol GridSource: AnyObject {
    var gridColumns: [ResultColumn] { get }
    var gridRowCount: Int { get }
    /// Bumped on every change; the grid reloads when it moves.
    var gridVersion: Int { get }
    /// Bumped when the columns change; the grid rebuilds its columns.
    var gridColumnsVersion: Int { get }
    var canEdit: Bool { get }
    /// Where column order, widths and hidden columns are remembered (nil: not remembered).
    var gridLayoutKey: String? { get }
    func gridValue(row: Int, column: Int) -> String?
    func gridRowState(_ row: Int) -> RowState
    func gridIsEdited(row: Int, column: Int) -> Bool
    func gridEdit(row: Int, column: Int, value: String?)
    func gridDelete(rows: IndexSet)
    func gridDuplicate(rows: IndexSet)
    func gridSort(column: Int, ascending: Bool)
    func gridSelectionChanged(_ rows: IndexSet)
    /// Filter rows to this value (from the context menu).
    func gridFilter(column: Int, value: String?)
    /// The foreign key a column is part of, so its cells can link to the referenced row.
    func gridForeignKey(column: Int) -> ForeignKeyInfo?
    func gridFollow(row: Int, column: Int)
    /// Pasted values: `columns` are data column indexes, rows start at `startRow` (past the end: new rows).
    func gridPaste(_ values: [[String?]], startRow: Int, columns: [Int])
}

extension GridSource {
    var gridLayoutKey: String? { nil }
    func gridDuplicate(rows: IndexSet) {}
    func gridFilter(column: Int, value: String?) {}
    func gridForeignKey(column: Int) -> ForeignKeyInfo? { nil }
    func gridFollow(row: Int, column: Int) {}
    func gridPaste(_ values: [[String?]], startRow: Int, columns: [Int]) {}
}

/// A rectangle of cells: rows and display-order column positions.
struct CellRange: Equatable {
    var anchor: (row: Int, col: Int)
    var focus: (row: Int, col: Int)

    var rows: ClosedRange<Int> { min(anchor.row, focus.row)...max(anchor.row, focus.row) }
    var cols: ClosedRange<Int> { min(anchor.col, focus.col)...max(anchor.col, focus.col) }
    var isSingle: Bool { anchor == focus }
    func contains(row: Int, col: Int) -> Bool { rows.contains(row) && cols.contains(col) }

    static func == (a: CellRange, b: CellRange) -> Bool { a.anchor == b.anchor && a.focus == b.focus }
}

struct DataGrid: NSViewRepresentable {
    let source: GridSource
    let version: Int
    let columnsVersion: Int

    func makeCoordinator() -> Coordinator { Coordinator(source: source) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.coordinator = context.coordinator
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = MB.nsBg
        table.gridColor = MB.nsGrid
        table.gridStyleMask = [.solidHorizontalGridLineMask]  // column lines are drawn per row, so they stop at the last row
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = GridHeaderView()
        table.headerView?.frame.size.height = 26
        table.headerView?.menu = context.coordinator.makeHeaderMenu()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menu = context.coordinator.makeMenu()
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = MB.nsBg
        scroll.scrollerStyle = .overlay
        // The window's title bar is drawn by SwiftUI above us; don't inset for it again.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        context.coordinator.rebuildColumns()
        NotificationCenter.default.addObserver(forName: .demoSelectCells, object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                coordinator?.select((1, 1), extend: false)
                coordinator?.select((3, 3), extend: true)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.source !== source {
            c.source = source
            c.lastColumnsVersion = -1
        }
        if c.lastColumnsVersion != columnsVersion {
            c.range = nil
            c.rebuildColumns()
            c.lastColumnsVersion = columnsVersion
            c.lastVersion = version
            c.table?.reloadData()
            if (c.table?.numberOfRows ?? 0) > 0 { c.table?.scrollRowToVisible(0) }
        } else if c.lastVersion != version {
            c.lastVersion = version
            c.reloadKeepingSelection()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var source: GridSource
        weak var table: GridTableView?
        var lastVersion = -1
        var lastColumnsVersion = -1
        /// The selected cells (TablePlus-style); rows are selected along with them.
        var range: CellRange?
        private var editing: (row: Int, column: Int)?
        private var applyingLayout = false
        private let headerMenu = NSMenu()

        init(source: GridSource) { self.source = source }

        // MARK: Columns and layout

        struct Layout: Codable {
            var order: [String] = []
            var widths: [String: CGFloat] = [:]
            var hidden: [String] = []
        }

        private var layout: Layout {
            get {
                guard let key = source.gridLayoutKey, let data = UserDefaults.standard.data(forKey: "layout." + key),
                      let l = try? JSONDecoder().decode(Layout.self, from: data) else { return Layout() }
                return l
            }
            set {
                guard let key = source.gridLayoutKey, let data = try? JSONEncoder().encode(newValue) else { return }
                UserDefaults.standard.set(data, forKey: "layout." + key)
            }
        }

        /// The data column shown at a display position.
        func dataColumn(_ displayCol: Int) -> Int? {
            guard let table, displayCol >= 0, displayCol < table.tableColumns.count else { return nil }
            return Int(table.tableColumns[displayCol].identifier.rawValue)
        }

        func rebuildColumns() {
            guard let table else { return }
            applyingLayout = true
            defer { applyingLayout = false }
            for c in table.tableColumns { table.removeTableColumn(c) }
            let saved = layout
            let names = source.gridColumns.map(\.name)
            var order = saved.order.compactMap { names.firstIndex(of: $0) }
            order += names.indices.filter { !order.contains($0) }
            let hidden = Set(saved.hidden)
            let font = MB.nsMono
            let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
            let sample = min(source.gridRowCount, 60)
            for i in order where !hidden.contains(names[i]) {
                let col = source.gridColumns[i]
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                column.title = col.name
                let header = GridHeaderCell(textCell: col.name)
                header.typeName = col.typeName
                header.isLink = source.gridForeignKey(column: i) != nil
                column.headerCell = header
                if let w = saved.widths[col.name] {
                    column.width = w
                } else {
                    var longest = 4
                    for r in 0..<sample { longest = max(longest, min(48, (source.gridValue(row: r, column: i) ?? "NULL").count)) }
                    let headerWidth = (col.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width
                        + ("  " + col.typeName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5)]).width + 30
                    column.width = min(360, max(64, CGFloat(longest) * charWidth + 20, min(headerWidth, 260)))
                }
                column.minWidth = 40
                column.maxWidth = 2000
                column.sortDescriptorPrototype = NSSortDescriptor(key: "\(i)", ascending: true)
                table.addTableColumn(column)
            }
        }

        private func saveLayout() {
            guard !applyingLayout, let table, source.gridLayoutKey != nil else { return }
            var l = layout
            let shown = table.tableColumns.compactMap { Int($0.identifier.rawValue) }.map { source.gridColumns[$0].name }
            // Keep hidden columns where they were in the order.
            l.order = shown + l.order.filter { !shown.contains($0) && l.hidden.contains($0) }
            for c in table.tableColumns { if let i = Int(c.identifier.rawValue) { l.widths[source.gridColumns[i].name] = c.width } }
            layout = l
        }

        func tableViewColumnDidResize(_ notification: Notification) { saveLayout() }
        func tableViewColumnDidMove(_ notification: Notification) { saveLayout() }

        func setHidden(_ name: String, _ hidden: Bool) {
            saveLayout()
            var l = layout
            l.hidden.removeAll { $0 == name }
            if hidden { l.hidden.append(name) }
            layout = l
            range = nil
            rebuildColumns()
            table?.reloadData()
        }

        func resetLayout() {
            if let key = source.gridLayoutKey { UserDefaults.standard.removeObject(forKey: "layout." + key) }
            range = nil
            rebuildColumns()
            table?.reloadData()
        }

        func reloadKeepingSelection() {
            guard let table else { return }
            let selected = table.selectedRowIndexes
            table.reloadData()
            let valid = selected.filteredIndexSet { $0 < source.gridRowCount }
            table.selectRowIndexes(valid, byExtendingSelection: false)
            if let r = range, r.rows.upperBound >= source.gridRowCount || r.cols.upperBound >= table.numberOfColumns { range = nil }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { source.gridRowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? GridCell) ?? GridCell(identifier: id)
            let value = source.gridValue(row: row, column: column)
            let display = tableView.tableColumns.firstIndex(of: tableColumn) ?? -1
            let inRange = range?.contains(row: row, col: display) ?? false
            let isFocus = range.map { $0.focus.row == row && $0.focus.col == display } ?? false
            cell.configure(value: value, edited: source.gridIsEdited(row: row, column: column), state: source.gridRowState(row),
                           selected: inRange && !(range?.isSingle ?? true), focus: isFocus,
                           link: value != nil && source.gridForeignKey(column: column) != nil)
            cell.onFollow = { [weak self] in self?.source.gridFollow(row: row, column: column) }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = GridRowView()
            view.state = source.gridRowState(row)
            return view
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let key = d.key, let column = Int(key) else { return }
            source.gridSort(column: column, ascending: d.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            source.gridSelectionChanged(table.selectedRowIndexes)
        }

        // MARK: Cell selection

        func select(_ cell: (row: Int, col: Int), extend: Bool) {
            guard let table, cell.row >= 0, cell.col >= 0, cell.row < source.gridRowCount, cell.col < table.numberOfColumns else { return }
            let old = range
            if extend, var r = range { r.focus = cell; range = r } else { range = CellRange(anchor: cell, focus: cell) }
            guard let r = range else { return }
            table.selectRowIndexes(IndexSet(integersIn: r.rows), byExtendingSelection: false)
            var rows = IndexSet(integersIn: r.rows)
            if let old { rows.formUnion(IndexSet(integersIn: old.rows)) }
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            table.scrollRowToVisible(cell.row)
            table.scrollColumnToVisible(cell.col)
        }

        func moveFocus(dRow: Int, dCol: Int, extend: Bool) {
            guard let table else { return }
            let current: (row: Int, col: Int) = range?.focus ?? (max(0, table.selectedRow), 0)
            let next = (row: min(max(0, current.row + dRow), source.gridRowCount - 1),
                        col: min(max(0, current.col + dCol), table.numberOfColumns - 1))
            select(next, extend: extend)
        }

        /// The selected cells as rows of values (display order), or the selected rows when no cells are.
        func selectedValues() -> (columns: [ResultColumn], rows: [[String?]]) {
            guard let table else { return ([], []) }
            if let r = range {
                let cols = r.cols.compactMap(dataColumn)
                return (cols.map { source.gridColumns[$0] }, r.rows.map { row in cols.map { source.gridValue(row: row, column: $0) } })
            }
            let cols = table.tableColumns.compactMap { Int($0.identifier.rawValue) }
            return (cols.map { source.gridColumns[$0] }, table.selectedRowIndexes.map { row in cols.map { source.gridValue(row: row, column: $0) } })
        }

        func copySelection(header: Bool) {
            let (cols, rows) = selectedValues()
            guard !rows.isEmpty else { return }
            let text: String
            if !header, rows.count == 1, rows[0].count == 1 { text = rows[0][0] ?? "NULL" }
            else { text = Export.tsv(columns: header ? cols : nil, rows: rows) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func copyAs(_ format: String) {
            let (cols, rows) = selectedValues()
            let text: String = switch format {
            case "csv": Export.csv(columns: cols, rows: rows)
            case "json": Export.json(columns: cols, rows: rows)
            case "markdown": Export.markdown(columns: cols, rows: rows)
            default: (source as? TableTab).map { t in
                t.dialect.insertStatements(table: t.object.table, columns: cols, rows: rows).joined(separator: "\n") } ?? ""
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// Spreadsheet rows (tab-separated) into the grid: from the focused cell, or as new rows when nothing is selected.
        func paste() {
            guard let table, source.canEdit, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { NSSound.beep(); return }
            var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let separator: Character = text.contains("\t") ? "\t" : ","
            var values: [[String?]] = separator == "," ? Export.parseCSV(text).map { $0.map { Optional($0) } }
                : lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map { String($0) } }
            values = values.map { $0.map { $0 == "NULL" ? nil : $0 } }
            let startCol = range.map { $0.cols.lowerBound } ?? 0
            let width = values.map(\.count).max() ?? 0
            let cols = (startCol..<min(table.numberOfColumns, startCol + width)).compactMap(dataColumn)
            // A header row that matches the column names is skipped.
            if let first = values.first, first.count >= cols.count,
               zip(first, cols).allSatisfy({ $0.0?.lowercased() == source.gridColumns[$0.1].name.lowercased() }) {
                values.removeFirst()
            }
            guard !values.isEmpty else { return }
            let startRow = range.map { $0.rows.lowerBound } ?? source.gridRowCount
            source.gridPaste(values, startRow: startRow, columns: cols)
        }

        // MARK: Editing

        @objc func doubleClicked(_ sender: Any?) {
            guard let table else { return }
            let row = table.clickedRow, column = table.clickedColumn
            guard row >= 0, column >= 0 else { return }
            beginEditing(row: row, tableColumn: column)
        }

        func beginEditing(row: Int, tableColumn: Int) {
            guard let table, source.canEdit, source.gridRowState(row) != .deleted, tableColumn < table.numberOfColumns,
                  let column = dataColumn(tableColumn),
                  let cell = table.view(atColumn: tableColumn, row: row, makeIfNecessary: true) as? GridCell else { return }
            editing = (row, column)
            let value = source.gridValue(row: row, column: column)
            cell.beginEditing(value)
            cell.field.delegate = self
            table.window?.makeFirstResponder(cell.field)
            cell.field.currentEditor()?.selectAll(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                editing = nil
                endFieldEditing(control, commit: false)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:)) {
                let tab = selector == #selector(NSResponder.insertTab(_:))
                endFieldEditing(control, commit: true)
                moveFocus(dRow: tab ? 0 : 1, dCol: tab ? 1 : 0, extend: false)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            endFieldEditing(field, commit: true)
        }

        private func endFieldEditing(_ control: NSControl, commit: Bool) {
            guard let field = control as? NSTextField else { return }
            let target = editing
            editing = nil
            field.isEditable = false
            field.delegate = nil
            if commit, let target {
                let newValue = field.stringValue
                let old = source.gridValue(row: target.row, column: target.column)
                if newValue != (old ?? "") || (old == nil && !newValue.isEmpty) {
                    source.gridEdit(row: target.row, column: target.column, value: newValue)
                }
            }
            table?.window?.makeFirstResponder(table)
            reloadKeepingSelection()
        }

        // MARK: Menus

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func makeHeaderMenu() -> NSMenu {
            headerMenu.delegate = self
            return headerMenu
        }

        private func item(_ title: String, _ action: Selector, _ represented: Any? = nil, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            i.representedObject = represented
            return i
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if menu === headerMenu { return buildHeaderMenu(menu) }
            let row = table.clickedRow, col = table.clickedColumn
            guard row >= 0 else { return }
            if !(range?.contains(row: row, col: col) ?? false) && !table.selectedRowIndexes.contains(row) {
                select((row, max(0, col)), extend: false)
            }
            let column = dataColumn(col)
            let target: (Int, Int, Int) = (row, column ?? -1, col)
            menu.addItem(item("Copy", #selector(copyMenu(_:))))
            menu.addItem(item("Copy with column names", #selector(copyWithHeader(_:))))
            let copyAs = NSMenuItem(title: "Copy as", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, format) in [("CSV", "csv"), ("JSON", "json"), ("Markdown table", "markdown")] + (source is TableTab ? [("SQL inserts", "sql")] : []) {
                sub.addItem(item(title, #selector(copyAsMenu(_:)), format))
            }
            copyAs.submenu = sub
            menu.addItem(copyAs)
            if let column {
                if source.gridForeignKey(column: column) != nil, source.gridValue(row: row, column: column) != nil {
                    menu.addItem(.separator())
                    menu.addItem(item("Open referenced row", #selector(follow(_:)), target))
                }
                menu.addItem(.separator())
                menu.addItem(item("Filter by this value", #selector(filterByValue(_:)), target))
            }
            if source.canEdit {
                menu.addItem(.separator())
                if column != nil {
                    menu.addItem(item("Edit value", #selector(editCell(_:)), target))
                    menu.addItem(item("Set to NULL", #selector(setNull(_:)), target))
                }
                menu.addItem(item("Paste", #selector(pasteMenu(_:))))
                menu.addItem(item("Duplicate row", #selector(duplicateRows(_:))))
                menu.addItem(item("Delete row", #selector(deleteRows(_:))))
            }
        }

        private func buildHeaderMenu(_ menu: NSMenu) {
            guard let table, let header = table.headerView, let event = NSApp.currentEvent else { return }
            let point = header.convert(event.locationInWindow, from: nil)
            let col = header.column(at: point)
            if let data = dataColumn(col) {
                let name = source.gridColumns[data].name
                menu.addItem(item("Sort ascending", #selector(sortMenu(_:)), (data, true)))
                menu.addItem(item("Sort descending", #selector(sortMenu(_:)), (data, false)))
                menu.addItem(item("Copy column name", #selector(copyName(_:)), name))
                if source.gridLayoutKey != nil {
                    menu.addItem(.separator())
                    menu.addItem(item("Hide \(name)", #selector(hideColumn(_:)), name))
                }
            }
            guard source.gridLayoutKey != nil else { return }
            let hidden = Set(layout.hidden)
            let columns = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for c in source.gridColumns {
                let i = item(c.name, #selector(toggleColumn(_:)), c.name)
                i.state = hidden.contains(c.name) ? .off : .on
                sub.addItem(i)
            }
            columns.submenu = sub
            menu.addItem(.separator())
            menu.addItem(columns)
            if !hidden.isEmpty { menu.addItem(item("Show all columns", #selector(showAll(_:)))) }
            menu.addItem(item("Reset column layout", #selector(resetLayoutMenu(_:))))
        }

        private func target(_ sender: Any?) -> (row: Int, column: Int, tableColumn: Int)? {
            (sender as? NSMenuItem)?.representedObject as? (Int, Int, Int)
        }

        @objc func copyMenu(_ sender: Any?) { copySelection(header: false) }
        @objc func copyWithHeader(_ sender: Any?) { copySelection(header: true) }
        @objc func copyAsMenu(_ sender: Any?) { copyAs((sender as? NSMenuItem)?.representedObject as? String ?? "csv") }
        @objc func pasteMenu(_ sender: Any?) { paste() }

        @objc func follow(_ sender: Any?) {
            guard let t = target(sender), t.column >= 0 else { return }
            source.gridFollow(row: t.row, column: t.column)
        }

        @objc func filterByValue(_ sender: Any?) {
            guard let t = target(sender), t.column >= 0 else { return }
            source.gridFilter(column: t.column, value: source.gridValue(row: t.row, column: t.column))
        }

        @objc func editCell(_ sender: Any?) {
            guard let t = target(sender) else { return }
            beginEditing(row: t.row, tableColumn: t.tableColumn)
        }

        @objc func setNull(_ sender: Any?) {
            guard let table else { return }
            if let r = range {
                for row in r.rows { for c in r.cols.compactMap(dataColumn) { source.gridEdit(row: row, column: c, value: nil) } }
            } else if let t = target(sender), t.column >= 0 {
                for row in table.selectedRowIndexes { source.gridEdit(row: row, column: t.column, value: nil) }
            }
        }

        @objc func duplicateRows(_ sender: Any?) {
            guard let table else { return }
            source.gridDuplicate(rows: table.selectedRowIndexes)
        }

        @objc func deleteRows(_ sender: Any?) {
            guard let table else { return }
            source.gridDelete(rows: table.selectedRowIndexes)
        }

        @objc func sortMenu(_ sender: Any?) {
            guard let (col, asc) = (sender as? NSMenuItem)?.representedObject as? (Int, Bool) else { return }
            table?.sortDescriptors = [NSSortDescriptor(key: "\(col)", ascending: asc)]
        }

        @objc func copyName(_ sender: Any?) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((sender as? NSMenuItem)?.representedObject as? String ?? "", forType: .string)
        }

        @objc func hideColumn(_ sender: Any?) {
            guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
            setHidden(name, true)
        }

        @objc func toggleColumn(_ sender: Any?) {
            guard let item = sender as? NSMenuItem, let name = item.representedObject as? String else { return }
            setHidden(name, item.state == .on)
        }

        @objc func showAll(_ sender: Any?) {
            var l = layout
            l.hidden = []
            layout = l
            rebuildColumns()
            table?.reloadData()
        }

        @objc func resetLayoutMenu(_ sender: Any?) { resetLayout() }
    }
}

/// The table: click and drag selects cells, arrows move, Return edits, Delete removes rows, ⌘C/⌘V copy and paste.
final class GridTableView: NSTableView {
    weak var coordinator: DataGrid.Coordinator?

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p), c = column(at: p)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Double-clicks (edit) and ⌘-clicks (toggle rows) keep the table's own handling.
        guard r >= 0, c >= 0, event.clickCount == 1, !flags.contains(.command) else {
            if flags.contains(.command) { coordinator.range = nil }
            return super.mouseDown(with: event)
        }
        window?.makeFirstResponder(self)
        coordinator.select((r, c), extend: flags.contains(.shift))
        // Drag to select a rectangle of cells.
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            autoscroll(with: e)
            let q = convert(e.locationInWindow, from: nil)
            let rr = row(at: q), cc = column(at: q)
            if rr >= 0, cc >= 0, coordinator.range.map({ $0.focus.row != rr || $0.focus.col != cc }) ?? true {
                coordinator.select((rr, cc), extend: true)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 51, 117:  // delete, forward delete
            if coordinator.source.canEdit, !selectedRowIndexes.isEmpty {
                coordinator.source.gridDelete(rows: selectedRowIndexes)
                return
            }
        case 36, 76:  // return
            if let f = coordinator.range?.focus { coordinator.beginEditing(row: f.row, tableColumn: f.col); return }
            if selectedRow >= 0, numberOfColumns > 0 { coordinator.beginEditing(row: selectedRow, tableColumn: 0); return }
        case 123: coordinator.moveFocus(dRow: 0, dCol: -1, extend: shift); return
        case 124: coordinator.moveFocus(dRow: 0, dCol: 1, extend: shift); return
        case 125: coordinator.moveFocus(dRow: 1, dCol: 0, extend: shift); return
        case 126: coordinator.moveFocus(dRow: -1, dCol: 0, extend: shift); return
        case 48: coordinator.moveFocus(dRow: 0, dCol: shift ? -1 : 1, extend: false); return
        default: break
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { coordinator?.copySelection(header: false) }
    @objc func paste(_ sender: Any?) { coordinator?.paste() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty || coordinator?.range != nil }
        if item.action == #selector(paste(_:)) { return coordinator?.source.canEdit ?? false }
        return super.validateUserInterfaceItem(item)
    }

    override func drawGrid(inClipRect clipRect: NSRect) {
        // Only draw lines under real rows, not down the empty space.
        guard numberOfRows > 0 else { return }
        let last = rect(ofRow: numberOfRows - 1)
        super.drawGrid(inClipRect: NSIntersectionRect(clipRect, NSRect(x: clipRect.minX, y: 0, width: clipRect.width, height: last.maxY)))
    }
}

final class GridCell: NSTableCellView {
    let field = NSTextField(labelWithString: "")
    private let link = NSButton()
    private var trailing: NSLayoutConstraint!
    var onFollow: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        addSubview(field)
        textField = field
        link.translatesAutoresizingMaskIntoConstraints = false
        link.isBordered = false
        link.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Open referenced row")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        link.contentTintColor = MB.nsDim
        link.imageScaling = .scaleProportionallyDown
        link.target = self
        link.action = #selector(followLink)
        link.toolTip = "Open the referenced row"
        addSubview(link)
        trailing = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            trailing,
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            link.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            link.centerYAnchor.constraint(equalTo: centerYAnchor),
            link.widthAnchor.constraint(equalToConstant: 13),
            link.heightAnchor.constraint(equalToConstant: 13),
        ])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func followLink() { onFollow?() }

    func configure(value: String?, edited: Bool, state: RowState, selected: Bool, focus: Bool, link showLink: Bool) {
        field.isEditable = false
        if let value {
            var shown = value.count > 500 ? String(value.prefix(500)) : value
            if shown.contains(where: \.isNewline) { shown = shown.replacingOccurrences(of: "\n", with: "↵ ").replacingOccurrences(of: "\r", with: "") }
            field.stringValue = shown
            field.font = MB.nsMono
            field.textColor = state == .deleted ? MB.nsNull : MB.nsText
        } else {
            field.stringValue = "NULL"
            field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            field.textColor = MB.nsNull
        }
        link.isHidden = !showLink
        trailing.constant = showLink ? -21 : -5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if edited { layer?.backgroundColor = MB.nsAccent.withAlphaComponent(0.22).cgColor }
            else if selected { layer?.backgroundColor = MB.nsAccent.withAlphaComponent(0.11).cgColor }
            else { layer?.backgroundColor = nil }
            layer?.borderWidth = focus ? 1.5 : 0
            layer?.borderColor = focus ? MB.nsAccentInk.cgColor : nil
        }
    }

    func beginEditing(_ value: String?) {
        field.stringValue = value ?? ""
        field.textColor = MB.nsText
        field.font = MB.nsMono
        field.isEditable = true
        field.isSelectable = true
        link.isHidden = true
        trailing.constant = -5
    }
}

final class GridRowView: NSTableRowView {
    var state: RowState = .normal

    override func drawBackground(in dirtyRect: NSRect) {
        switch state {
        case .inserted: MB.nsGreen.withAlphaComponent(0.12).setFill()
        case .deleted: MB.nsRed.withAlphaComponent(0.13).setFill()
        case .normal: MB.nsBg.setFill()
        }
        dirtyRect.fill()
        guard let table = superview as? NSTableView else { return }
        MB.nsGrid.setFill()
        for i in 0..<table.numberOfColumns {
            let x = table.rect(ofColumn: i).maxX - 1
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        MB.nsWash(isEmphasized ? 0.09 : 0.06).setFill()
        bounds.fill()
    }
}

final class GridHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        MB.nsSidebar.setFill()
        bounds.fill()
        super.draw(dirtyRect)
        MB.nsLine.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// Column header: the name, its type in a dimmer colour, and a link mark for foreign keys.
final class GridHeaderCell: NSTableHeaderCell {
    var typeName = ""
    var isLink = false

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        MB.nsSidebar.setFill()
        cellFrame.fill()
        guard !stringValue.isEmpty else { return }
        MB.nsGrid.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 5, width: 1, height: cellFrame.height - 10).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // The filler past the last column has no name: draw nothing there.
        guard !stringValue.isEmpty else { return }
        let s = NSMutableAttributedString(string: stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: MB.nsText])
        if isLink {
            s.append(NSAttributedString(string: " ↗", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: MB.nsAccentInk]))
        }
        s.append(NSAttributedString(string: "  " + typeName, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: MB.nsDim]))
        let size = s.size()
        var rect = cellFrame.insetBy(dx: 7, dy: 0)
        rect.origin.y = cellFrame.midY - size.height / 2
        rect.size.height = size.height
        rect.size.width -= 12  // room for the sort arrow
        s.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let table = (controlView as? NSTableHeaderView)?.tableView,
           let d = table.sortDescriptors.first, let key = d.key,
           let idx = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == key }),
           table.headerView?.headerRect(ofColumn: idx) == cellFrame {
            let arrow = NSAttributedString(string: d.ascending ? "▲" : "▼", attributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: MB.nsAccentInk])
            arrow.draw(at: NSPoint(x: cellFrame.maxX - 16, y: cellFrame.midY - 6))
        }
    }
}

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

    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(context.coordinator) }

    /// The grid as AppKit views (apart from SwiftUI, so the tests can build one).
    static func makeScrollView(_ coordinator: Coordinator) -> NSScrollView {
        let table = GridTableView()
        table.coordinator = coordinator
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = MB.nsBg
        table.gridStyleMask = []  // rows draw their own lines, so they stop at the last row
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 24
        table.allowsTypeSelect = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = GridHeaderView()
        table.headerView?.frame.size.height = 26
        table.headerView?.menu = coordinator.makeHeaderMenu()
        table.delegate = coordinator
        table.dataSource = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menu = coordinator.makeMenu()
        coordinator.table = table

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
        coordinator.rebuildColumns()
        NotificationCenter.default.addObserver(forName: .demoSelectCells, object: nil, queue: .main) { [weak coordinator] _ in
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
        /// The cell being typed in: data column, not display position.
        private(set) var editing: (row: Int, column: Int)?
        private var editor: NSTextField?
        private var applyingLayout = false
        private var slotCache: [Slot]?
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

        /// Where a shown column sits and what it holds, worked out once per layout instead of once per cell drawn.
        struct Slot {
            let x: CGFloat
            let width: CGFloat
            let column: Int
            let isLink: Bool
        }

        var slots: [Slot] {
            if let slotCache { return slotCache }
            guard let table else { return [] }
            let made = table.tableColumns.indices.compactMap { i -> Slot? in
                guard let column = dataColumn(i) else { return nil }
                let rect = table.rect(ofColumn: i)
                return Slot(x: rect.minX, width: rect.width, column: column, isLink: source.gridForeignKey(column: column) != nil)
            }
            slotCache = made
            return made
        }

        func rebuildColumns() {
            guard let table else { return }
            dropEditor()
            slotCache = nil
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
                column.isEditable = false  // editing goes through beginEditing, with our own field
                column.dataCell = textCell
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

        /// What the table falls back on when it draws a cell itself (the picture of a column being dragged).
        private let textCell: NSTextFieldCell = {
            let cell = NSTextFieldCell(textCell: "")
            cell.font = MB.nsMono
            cell.textColor = MB.nsText
            cell.lineBreakMode = .byTruncatingTail
            cell.usesSingleLineMode = true
            return cell
        }()

        func tableViewColumnDidResize(_ notification: Notification) { slotCache = nil; saveLayout() }
        func tableViewColumnDidMove(_ notification: Notification) { slotCache = nil; saveLayout() }

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
            dropEditor()
            let selected = table.selectedRowIndexes
            table.reloadData()
            let valid = selected.filteredIndexSet { $0 < source.gridRowCount }
            table.selectRowIndexes(valid, byExtendingSelection: false)
            if let r = range, r.rows.upperBound >= source.gridRowCount || r.cols.upperBound >= table.numberOfColumns { range = nil }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { source.gridRowCount }

        /// The grid draws its own cells (GridTableView.drawRow); this is what VoiceOver and other tools read.
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue),
                  row < source.gridRowCount, column < source.gridColumns.count else { return nil }
            return source.gridValue(row: row, column: column) ?? "NULL"
        }

        func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }

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
            // Repaint the rows the old and the new selection cover, as far as they're drawn at all.
            let first = min(r.rows.lowerBound, old?.rows.lowerBound ?? .max), last = max(r.rows.upperBound, old?.rows.upperBound ?? 0)
            table.setNeedsDisplay(table.rect(ofRow: first).union(table.rect(ofRow: last)).intersection(table.preparedContentRect.union(table.visibleRect)))
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
            guard let table, source.canEdit, row < source.gridRowCount, source.gridRowState(row) != .deleted,
                  tableColumn < table.numberOfColumns, let column = dataColumn(tableColumn) else { return }
            dropEditor()
            table.scrollRowToVisible(row)
            table.scrollColumnToVisible(tableColumn)
            // One field, placed over the cell while it's being typed in.
            let field = NSTextField(labelWithString: source.gridValue(row: row, column: column) ?? "")
            field.font = MB.nsMono
            field.textColor = MB.nsText
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.focusRingType = .none
            field.isEditable = true
            field.isSelectable = true
            let cell = table.frameOfCell(atColumn: tableColumn, row: row)
            let height = min(cell.height, field.fittingSize.height)
            // A label keeps 2 pt around its text: this puts what's typed exactly where the value was drawn.
            field.frame = NSRect(x: cell.minX + 5, y: cell.midY - height / 2, width: max(10, cell.width - 8), height: height)
            field.delegate = self
            table.addSubview(field)
            editing = (row, column)
            editor = field
            table.setNeedsDisplay(cell)  // the cell's own text makes way for the field
            table.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                endFieldEditing(commit: false)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:)) {
                let tab = selector == #selector(NSResponder.insertTab(_:))
                endFieldEditing(commit: true)
                moveFocus(dRow: tab ? 0 : 1, dCol: tab ? 1 : 0, extend: false)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard obj.object as? NSTextField === editor else { return }
            endFieldEditing(commit: true)
        }

        private func endFieldEditing(commit: Bool) {
            guard let field = editor else { return }
            let target = editing
            let newValue = field.stringValue
            removeEditor()
            if commit, let target, target.row < source.gridRowCount {
                let old = source.gridValue(row: target.row, column: target.column)
                if newValue != (old ?? "") || (old == nil && !newValue.isEmpty) {
                    source.gridEdit(row: target.row, column: target.column, value: newValue)
                }
            }
            reloadKeepingSelection()
        }

        /// Takes the field away without saving what's in it: the rows under it changed.
        private func dropEditor() {
            guard editor != nil else { return }
            removeEditor()
        }

        private func removeEditor() {
            guard let field = editor else { return }
            editing = nil
            editor = nil
            field.delegate = nil
            if let table, let window = table.window, (window.firstResponder as? NSView)?.isDescendant(of: field) == true {
                window.makeFirstResponder(table)
            }
            field.removeFromSuperview()
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
        // The arrow in a cell that points at another table opens the row it points at.
        if let slot = coordinator.slots[safe: c], slot.isLink, !flags.contains(.shift), r < coordinator.source.gridRowCount,
           linkRect(in: frameOfCell(atColumn: c, row: r)).insetBy(dx: -3, dy: -3).contains(p),
           coordinator.source.gridValue(row: r, column: slot.column) != nil {
            coordinator.source.gridFollow(row: r, column: slot.column)
            return
        }
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

    // MARK: Drawing
    //
    // The table paints its cells itself, a row at a time, and only the part that's on screen. A view per cell
    // (a text field and a link button, laid out with constraints) cost so much that a wide table couldn't
    // keep up with scrolling.

    private let textFont = MB.nsMono
    private let nullFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private lazy var textLook = look(textFont)
    private lazy var nullLook = look(nullFont)
    private lazy var nullLine = CTLineCreateWithAttributedString(NSAttributedString(string: "NULL", attributes: nullLook.attributes))
    private var linkMarks: [NSAppearance.Name: NSImage] = [:]

    /// The arrow for cells that point at another table, in the colour for the appearance being drawn in.
    private var linkMark: NSImage? {
        let name = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
        if let made = linkMarks[name] { return made }
        let colour = NSColor(cgColor: MB.nsDim.cgColor) ?? MB.nsDim
        let made = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [colour])))
        linkMarks[name] = made
        return made
    }

    private struct Look {
        let attributes: [NSAttributedString.Key: Any]
        let ellipsis: CTLine
        /// From the top of the row to the text's baseline, so it sits where a label centred in the row would.
        let baseline: CGFloat
        let characterWidth: CGFloat
    }

    private func look(_ font: NSFont) -> Look {
        // The colour comes from the context, so one set of attributes serves every colour and appearance.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        // Where a label with this font, centred in the row, puts its text.
        let label = NSTextField(labelWithString: "0")
        label.font = font
        return Look(attributes: attributes,
                    ellipsis: CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes)),
                    baseline: (rowHeight - label.fittingSize.height) / 2 + label.firstBaselineOffsetFromTop,
                    characterWidth: max(1, ("0" as NSString).size(withAttributes: [.font: font]).width))
    }

    /// The link mark's area in a cell that points at another table.
    func linkRect(in cell: NSRect) -> NSRect { NSRect(x: cell.maxX - 17, y: cell.midY - 6.5, width: 13, height: 13) }

    private var isEmphasized: Bool {
        guard let window, window.isKeyWindow, let responder = window.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    override func highlightSelection(inClipRect clipRect: NSRect) {}  // drawRow does it, under the cells

    override func drawRow(_ row: Int, clipRect: NSRect) {
        guard let coordinator, let context = NSGraphicsContext.current?.cgContext else { return }
        let source = coordinator.source
        let columnCount = source.gridColumns.count
        guard row < source.gridRowCount else { return }
        let rowRect = rect(ofRow: row)
        let state = source.gridRowState(row)
        let range = coordinator.range, editing = coordinator.editing
        let multiple = !(range?.isSingle ?? true)

        func fill(_ color: NSColor, _ rect: NSRect) {
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }
        switch state {
        case .inserted: fill(MB.nsGreen.withAlphaComponent(0.12), rowRect)
        case .deleted: fill(MB.nsRed.withAlphaComponent(0.13), rowRect)
        case .normal: break
        }
        if isRowSelected(row) { fill(MB.nsWash(isEmphasized ? 0.09 : 0.06), rowRect) }
        fill(MB.nsGrid, NSRect(x: rowRect.minX, y: rowRect.maxY - 1, width: rowRect.width, height: 1))

        let textColor = (state == .deleted ? MB.nsNull : MB.nsText).cgColor, nullColor = MB.nsNull.cgColor
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // the table counts down from the top
        for (display, slot) in coordinator.slots.enumerated() where slot.x < clipRect.maxX && slot.x + slot.width > clipRect.minX {
            let cell = NSRect(x: slot.x, y: rowRect.minY, width: slot.width, height: rowRect.height)
            fill(MB.nsGrid, NSRect(x: cell.maxX - 1, y: cell.minY, width: 1, height: cell.height))
            guard slot.column < columnCount else { continue }
            if source.gridIsEdited(row: row, column: slot.column) {
                fill(MB.nsAccent.withAlphaComponent(0.22), cell)
            } else if multiple, range?.contains(row: row, col: display) == true {
                fill(MB.nsAccent.withAlphaComponent(0.11), cell)
            }
            let isEditing = editing.map { $0.row == row && $0.column == slot.column } ?? false
            if !isEditing {
                let value = source.gridValue(row: row, column: slot.column)
                let showLink = slot.isLink && value != nil
                let width = cell.width - (showLink ? 28 : 12)
                if width > 4 {
                    let line: CTLine
                    if let value {
                        line = self.line(value, width: width)
                        context.setFillColor(textColor)
                    } else {
                        line = nullLine
                        context.setFillColor(nullColor)
                    }
                    context.saveGState()
                    context.clip(to: cell)
                    context.textPosition = CGPoint(x: cell.minX + 7, y: cell.minY + (value == nil ? nullLook : textLook).baseline)
                    CTLineDraw(fitted(line, width: width, look: value == nil ? nullLook : textLook), context)
                    context.restoreGState()
                }
                if showLink, let linkMark = linkMark {
                    let box = linkRect(in: cell), size = linkMark.size
                    linkMark.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2 + 0.5, width: size.width, height: size.height),
                                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            if let range, range.focus.row == row, range.focus.col == display {
                context.setStrokeColor(MB.nsAccentInk.cgColor)
                context.setLineWidth(1.5)
                context.stroke(cell.insetBy(dx: 0.75, dy: 0.75))
            }
        }
    }

    /// One line of a value: only as much of it as can show, with line breaks marked.
    private func line(_ value: String, width: CGFloat) -> CTLine {
        // Wide characters aside, no more than this fits; the rest is never measured or drawn.
        let limit = min(500, Int(width / textLook.characterWidth) + 8)
        var shown = String(value.prefix(limit))
        if shown.contains(where: \.isNewline) { shown = shown.replacingOccurrences(of: "\n", with: "↵ ").replacingOccurrences(of: "\r", with: "") }
        return CTLineCreateWithAttributedString(NSAttributedString(string: shown, attributes: textLook.attributes))
    }

    private func fitted(_ line: CTLine, width: CGFloat, look: Look) -> CTLine {
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) else { return line }
        return CTLineCreateTruncatedLine(line, Double(width), .end, look.ellipsis) ?? line
    }

    // The selection is brighter while the grid has the keyboard.
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyStateChanged(_:)), name: name, object: window)
        }
    }

    @objc private func keyStateChanged(_ notification: Notification) { needsDisplay = true }
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

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

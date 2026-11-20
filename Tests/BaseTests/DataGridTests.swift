import AppKit
@testable import Base
import BaseCore
import XCTest

/// The data grid, built off screen: what it draws, how typing in a cell ends, and that it stays light enough
/// to scroll (no views per cell or row).
@MainActor
final class DataGridTests: XCTestCase {
    private var source: StubSource!
    private var coordinator: DataGrid.Coordinator!
    private var window: NSWindow!
    private var table: GridTableView!

    override func setUp() async throws {
        source = StubSource()
        coordinator = DataGrid.Coordinator(source: source)
        let scroll = DataGrid.makeScrollView(coordinator)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scroll
        table = try XCTUnwrap(scroll.documentView as? GridTableView)
        coordinator.rebuildColumns()
        table.reloadData()
        for column in table.tableColumns { column.width = 120 }
        window.layoutIfNeeded()
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    // MARK: Staying light

    func testNoViewsPerCellOrRow() {
        source.rows = (0..<5000).map { ["\($0)", "7", "text \($0)", nil] }
        coordinator.reloadKeepingSelection()
        window.displayIfNeeded()
        _ = picture()
        table.scrollRowToVisible(4000)
        window.displayIfNeeded()
        // A view per cell is what made wide tables slow to scroll: the table paints its cells itself.
        XCTAssertTrue(table.subviews.isEmpty, "the grid added views: \(table.subviews)")
    }

    func testAVeryLongValueIsCutBeforeItIsMeasured() {
        source.rows[0][2] = String(repeating: "long value ", count: 400_000)
        coordinator.reloadKeepingSelection()
        let start = Date()
        for _ in 0..<20 { _ = picture() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        // …and what shows stays inside its cell.
        XCTAssertEqual(ink(row: 0, column: 3, in: picture()), ink(row: 2, column: 3, in: picture()))
    }

    // MARK: What it draws

    func testDrawsValuesAndLeavesEmptyCellsEmpty() {
        let image = picture()
        XCTAssertGreaterThan(ink(row: 0, column: 2, in: image), 20, "a value shows as text")
        XCTAssertGreaterThan(ink(row: 0, column: 3, in: image), 20, "NULL shows as text")
        XCTAssertEqual(ink(row: 1, column: 2, in: image), 0, "an empty value shows nothing")
    }

    func testEditedCellsArePinkAndTheFocusedCellHasABorder() {
        source.edited = [[1, 2]]
        coordinator.select((2, 0), extend: false)
        let image = picture()
        let edited = colour(at: NSPoint(x: table.frameOfCell(atColumn: 2, row: 1).minX + 4, y: table.frameOfCell(atColumn: 2, row: 1).minY + 4), in: image)
        let plain = colour(at: NSPoint(x: table.frameOfCell(atColumn: 2, row: 0).minX + 4, y: table.frameOfCell(atColumn: 2, row: 0).minY + 4), in: image)
        XCTAssertGreaterThan(edited.red - edited.green, 0.08, "edited cells have the pink wash")
        XCTAssertLessThan(abs(plain.red - plain.green), 0.02)
        let focus = table.frameOfCell(atColumn: 0, row: 2)
        let border = colour(at: NSPoint(x: focus.minX + 0.5, y: focus.midY), in: image)
        XCTAssertGreaterThan(border.red - border.green, 0.3, "the focused cell has a pink border")
    }

    func testSelectingCellsSelectsTheirRows() {
        coordinator.select((1, 1), extend: false)
        coordinator.select((2, 3), extend: true)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(1...2))
        XCTAssertEqual(source.selection, IndexSet(1...2))
        let values = coordinator.selectedValues()
        XCTAssertEqual(values.columns.map(\.name), ["owner_id", "name", "note"])
        XCTAssertEqual(values.rows, [["8", "", "x"], ["9", "third", nil]])
    }

    func testReadsValuesOutForAccessibility() {
        let column = table.tableColumns[3]
        XCTAssertEqual(coordinator.tableView(table, objectValueFor: table.tableColumns[2], row: 0) as? String, "first")
        XCTAssertEqual(coordinator.tableView(table, objectValueFor: column, row: 0) as? String, "NULL")
        XCTAssertNil(coordinator.tableView(table, objectValueFor: column, row: 99), "a row that's gone reads as nothing instead of crashing")
    }

    func testCellsFollowColumnsThatAreResizedAndMoved() {
        table.tableColumns[0].width = 200
        XCTAssertEqual(coordinator.slots.map(\.x), [0, 200, 320, 440])
        table.moveColumn(0, toColumn: 1)
        XCTAssertEqual(coordinator.slots.map(\.column), [1, 0, 2, 3], "cells are drawn in the order the columns show")
        XCTAssertEqual(coordinator.slots.map(\.x), [0, 120, 320, 440])
        XCTAssertEqual(coordinator.slots.map(\.isLink), [true, false, false, false])
    }

    // MARK: Typing in a cell

    func testReturnStagesWhatWasTyped() throws {
        let field = try beginEditing(row: 0, column: 2)
        XCTAssertEqual(field.stringValue, "first")
        type("changed", into: field)
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(source.edits, [StubSource.Edit(row: 0, column: 2, value: "changed")])
        XCTAssertNil(editor, "the field goes away")
        XCTAssertEqual(coordinator.range?.focus.row, 1, "Return moves down a row")
    }

    func testEscapeStagesNothing() throws {
        let field = try beginEditing(row: 0, column: 2)
        type("changed", into: field)
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(source.edits.isEmpty)
        XCTAssertNil(editor)
    }

    func testTheKeysThemselvesEndTyping() throws {
        // Through the window, as a real key press goes: Return keeps what was typed, Escape drops it.
        var field = try beginEditing(row: 0, column: 2)
        type("kept", into: field)
        try press(36)
        XCTAssertEqual(source.edits, [StubSource.Edit(row: 0, column: 2, value: "kept")])
        XCTAssertNil(editor)
        XCTAssertTrue(window.firstResponder === table, "the grid has the keyboard again")

        field = try beginEditing(row: 1, column: 2)
        type("dropped", into: field)
        try press(53)
        XCTAssertEqual(source.edits.count, 1)
        XCTAssertNil(editor)

        coordinator.select((2, 2), extend: false)
        field = try beginEditing(row: 2, column: 2)
        type("tabbed", into: field)
        try press(48)
        XCTAssertEqual(source.edits.last, StubSource.Edit(row: 2, column: 2, value: "tabbed"))
        XCTAssertEqual(coordinator.range?.focus.col, 3, "Tab moves a cell to the right")
    }

    func testAnUnchangedValueStagesNothing() throws {
        let field = try beginEditing(row: 0, column: 2)
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(source.edits.isEmpty)
    }

    func testClickingAwayStagesWhatWasTyped() throws {
        let field = try beginEditing(row: 2, column: 2)
        type("typed", into: field)
        window.makeFirstResponder(table)
        XCTAssertEqual(source.edits, [StubSource.Edit(row: 2, column: 2, value: "typed")])
        XCTAssertNil(editor)
    }

    func testRowsChangingUnderTheFieldStagesNothing() throws {
        let field = try beginEditing(row: 2, column: 2)
        type("typed", into: field)
        // A refresh brought other rows: what was being typed belonged to a row that may be gone.
        source.rows = [["50", "1", "other", nil]]
        coordinator.reloadKeepingSelection()
        XCTAssertTrue(source.edits.isEmpty)
        XCTAssertNil(editor)
    }

    func testTheCellMakesWayForTheField() throws {
        XCTAssertGreaterThan(ink(row: 0, column: 2, in: picture()), 20)
        let field = try beginEditing(row: 0, column: 2)
        // With the field moved aside, the cell is empty: the table doesn't draw the old value under what's being typed.
        field.setFrameOrigin(NSPoint(x: 0, y: 200))
        XCTAssertEqual(ink(row: 0, column: 2, in: picture()), 0)
    }

    func testReadOnlyGridsAndDeletedRowsDontOpenAField() {
        source.deleted = [1]
        coordinator.beginEditing(row: 1, tableColumn: 2)
        XCTAssertNil(editor)
        source.canEdit = false
        coordinator.beginEditing(row: 0, tableColumn: 2)
        XCTAssertNil(editor)
    }

    // MARK: Links

    func testClickingTheArrowOpensTheReferencedRow() throws {
        let cell = table.frameOfCell(atColumn: 1, row: 2)
        try click(table.convert(NSPoint(x: table.linkRect(in: cell).midX, y: cell.midY), to: nil))
        XCTAssertEqual(source.followed, [[2, 1]])
        XCTAssertNil(coordinator.range, "following a link doesn't move the selection")
    }

    // MARK: Helpers

    private var editor: NSTextField? { table.subviews.compactMap { $0 as? NSTextField }.first }

    private func beginEditing(row: Int, column: Int) throws -> NSTextField {
        coordinator.beginEditing(row: row, tableColumn: column)
        return try XCTUnwrap(editor, "no field opened")
    }

    private func type(_ text: String, into field: NSTextField) {
        if let editor = field.currentEditor() { editor.string = text } else { field.stringValue = text }
    }

    private func click(_ pointInWindow: NSPoint) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: pointInWindow, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        table.mouseDown(with: event)
    }

    private func press(_ keyCode: UInt16) throws {
        let characters = [36: "\r", 48: "\t", 53: "\u{1B}"][Int(keyCode)] ?? ""
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                        isARepeat: false, keyCode: keyCode)))
    }

    /// The table as it would show, as pixels.
    private func picture() -> NSBitmapImageRep {
        let rep = table.bitmapImageRepForCachingDisplay(in: table.bounds)!
        table.cacheDisplay(in: table.bounds, to: rep)
        return rep
    }

    private func colour(at point: NSPoint, in image: NSBitmapImageRep) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let scale = CGFloat(image.pixelsWide) / table.bounds.width
        let c = image.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))!.usingColorSpace(.sRGB)!
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// How many pixels inside a cell differ from the cell's background: text, in a cell with no wash or border.
    private func ink(row: Int, column: Int, in image: NSBitmapImageRep) -> Int {
        let cell = table.frameOfCell(atColumn: column, row: row).insetBy(dx: 3, dy: 3)
        let scale = CGFloat(image.pixelsWide) / table.bounds.width
        let background = colour(at: NSPoint(x: cell.minX, y: cell.minY), in: image)
        var count = 0
        for y in Int(cell.minY * scale)..<Int(cell.maxY * scale) {
            for x in Int(cell.minX * scale)..<Int(cell.maxX * scale) {
                let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if abs(c.redComponent - background.red) + abs(c.greenComponent - background.green) + abs(c.blueComponent - background.blue) > 0.15 { count += 1 }
            }
        }
        return count
    }
}

@MainActor
private final class StubSource: GridSource {
    struct Edit: Equatable {
        var row: Int, column: Int
        var value: String?
    }

    var gridColumns = [ResultColumn(name: "id", typeName: "integer"), ResultColumn(name: "owner_id", typeName: "integer"),
                       ResultColumn(name: "name", typeName: "text"), ResultColumn(name: "note", typeName: "text")]
    var rows: [[String?]] = [["1", "7", "first", nil], ["2", "8", "", "x"], ["3", "9", "third", nil]]
    var gridVersion = 0
    var gridColumnsVersion = 0
    var canEdit = true
    var edited: Set<[Int]> = []
    var deleted: Set<Int> = []
    var edits: [Edit] = []
    var followed: [[Int]] = []
    var selection = IndexSet()

    var gridRowCount: Int { rows.count }
    func gridValue(row: Int, column: Int) -> String? { rows[row][column] }
    func gridRowState(_ row: Int) -> RowState { deleted.contains(row) ? .deleted : .normal }
    func gridIsEdited(row: Int, column: Int) -> Bool { edited.contains([row, column]) }
    func gridEdit(row: Int, column: Int, value: String?) {
        edits.append(Edit(row: row, column: column, value: value))
        rows[row][column] = value
    }
    func gridDelete(rows: IndexSet) {}
    func gridSort(column: Int, ascending: Bool) {}
    func gridSelectionChanged(_ rows: IndexSet) { selection = rows }
    func gridForeignKey(column: Int) -> ForeignKeyInfo? {
        column == 1 ? ForeignKeyInfo(name: "fk", columns: ["owner_id"], refSchema: nil, refTable: "owners", refColumns: ["id"]) : nil
    }
    func gridFollow(row: Int, column: Int) { followed.append([row, column]) }
}

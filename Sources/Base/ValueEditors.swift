import AppKit
import BaseCore
import SwiftUI
import UniformTypeIdentifiers

/// One value in the row details, with an editor that suits its type: JSON, dates, enums, booleans,
/// binary data (with an image preview) or plain text.
struct InspectorField: View {
    @ObservedObject var tab: TableTab
    let row: Int
    let column: Int
    let info: ColumnInfo?
    @State private var text = ""
    @State private var loaded = false
    @State private var showCalendar = false
    @FocusState private var focused: Bool

    private var value: String? { tab.gridValue(row: row, column: column) }
    private var editable: Bool { tab.canEdit && tab.gridRowState(row) != .deleted }
    private var kind: EditorKind {
        let k = info?.editorKind ?? EditorKind(type: tab.columns[column].typeName)
        // MongoDB values are edited in shell syntax (ISODate(…), ObjectId(…), { … }), so only plain editors apply.
        if dbKind == .mongodb, k != .boolean, k != .number { return .text }
        // SQLite keeps dates as text: offer the calendar when the value reads as one.
        if k == .text, let v = value, v.count >= 10, v.count <= 32, DatePickerPopover.parse(v) != nil {
            return v.count == 10 ? .date : .dateTime
        }
        return k
    }
    private var dbKind: DatabaseKind { tab.workspace.session.kind }

    var body: some View {
        let col = tab.columns[column]
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if info?.isPrimaryKey == true { Image(systemName: "key.fill").font(.system(size: 8.5)).foregroundStyle(MB.accentInk) }
                Text(col.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(MB.text).lineLimit(1)
                Text(info?.type ?? col.typeName).font(.system(size: 10.5)).foregroundStyle(MB.dim).lineLimit(1)
                Spacer()
                if tab.gridForeignKey(column: column) != nil, value != nil {
                    Button { tab.gridFollow(row: row, column: column) } label: {
                        Label("Open", systemImage: "arrow.up.right").font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(MB.accentInk).help("Open the referenced row")
                }
                if editable {
                    Button(value == nil ? "NULL" : "Set NULL") { set(nil) }
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(value == nil ? MB.dim.opacity(0.6) : MB.dim)
                        .disabled(value == nil || info?.nullable == false)
                }
            }
            editor
        }
        .onAppear { text = value ?? ""; loaded = true }
    }

    @ViewBuilder private var editor: some View {
        switch kind {
        case .choice(let options):
            choice(options)
        case .boolean:
            choice(dbKind == .postgres ? ["true", "false"] : ["1", "0"], labels: ["true", "false"])
        case .json:
            VStack(alignment: .leading, spacing: 4) {
                textBox(lines: 3...16)
                HStack(spacing: 8) {
                    if let problem = jsonProblem {
                        Text(problem).font(.system(size: 10.5)).foregroundStyle(MB.red).lineLimit(2)
                    } else if !text.isEmpty {
                        Text("Valid JSON").font(.system(size: 10.5)).foregroundStyle(MB.dim)
                    }
                    Spacer()
                    if editable {
                        Button("Format") { formatJSON() }.buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(MB.dim)
                            .disabled(jsonProblem != nil || text.isEmpty)
                    }
                }
            }
        case .date, .dateTime, .time:
            HStack(spacing: 4) {
                textBox(lines: 1...1)
                if editable {
                    Button { showCalendar.toggle() } label: { Image(systemName: "calendar") }
                        .buttonStyle(.plain).foregroundStyle(MB.dim).help("Pick a date")
                        .popover(isPresented: $showCalendar, arrowEdge: .leading) { DatePickerPopover(kind: kind, value: value) { set($0); showCalendar = false } }
                }
            }
        case .binary:
            BinaryValueView(value: value, editable: editable, postgres: dbKind == .postgres) { set($0) }
        case .number, .text:
            textBox(lines: kind == .number ? 1...1 : 1...12)
        }
    }

    private func textBox(lines: ClosedRange<Int>) -> some View {
        TextField(value == nil ? "NULL" : "", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(MB.mono)
            .foregroundStyle(MB.text)
            .lineLimit(lines)
            .disabled(!editable)
            .focused($focused)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(tab.gridIsEdited(row: row, column: column) ? MB.accent.opacity(0.16) : MB.wash(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? MB.lineStrong : MB.line))
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func choice(_ options: [String], labels: [String]? = nil) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button(labels?[i] ?? o) { set(o) }
            }
            if info?.nullable != false {
                Divider()
                Button("NULL") { set(nil) }
            }
        } label: {
            HStack {
                Text(display(value, options: options, labels: labels)).font(MB.mono).foregroundStyle(value == nil ? MB.dim : MB.text)
                Spacer()
            }
        }
        .menuStyle(.borderlessButton)
        .disabled(!editable)
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(tab.gridIsEdited(row: row, column: column) ? MB.accent.opacity(0.16) : MB.wash(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MB.line))
    }

    private func display(_ v: String?, options: [String], labels: [String]?) -> String {
        guard let v else { return "NULL" }
        if let labels, let i = options.firstIndex(of: v) { return labels[i] }
        if let labels, ["t", "true", "1"].contains(v.lowercased()) { return labels[0] }
        if let labels, ["f", "false", "0"].contains(v.lowercased()) { return labels[1] }
        return v
    }

    private var jsonProblem: String? {
        guard !text.isEmpty else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            return nil
        } catch {
            return "Not valid JSON"
        }
    }

    private func formatJSON() {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return }
        text = String(decoding: data, as: UTF8.self)
        commit()
    }

    private func set(_ new: String?) {
        tab.gridEdit(row: row, column: column, value: new)
        text = new ?? ""
    }

    private func commit() {
        guard loaded, editable else { return }
        if text != (value ?? "") || (value == nil && !text.isEmpty) {
            tab.gridEdit(row: row, column: column, value: text)
        }
    }
}

/// A calendar and time for date columns, written back in ISO format (the server casts it).
struct DatePickerPopover: View {
    let kind: EditorKind
    let value: String?
    let pick: (String) -> Void
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kind != .time {
                DatePicker("", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            }
            if kind != .date {
                DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
            }
            HStack {
                Button(kind == .date ? "Today" : "Now") { date = Date() }.buttonStyle(.mbPlain)
                Spacer()
                Button("Use") { pick(formatted) }.buttonStyle(.mbPrimary)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { if let value, let d = Self.parse(value) { date = d } }
    }

    private var formatted: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = switch kind {
        case .date: "yyyy-MM-dd"
        case .time: "HH:mm:ss"
        default: "yyyy-MM-dd HH:mm:ss"
        }
        return f.string(from: date)
    }

    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ssX", "yyyy-MM-dd HH:mm:ss.SSSSSS",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

/// Binary data: its size, an image preview when it's a picture, and loading from or saving to a file.
struct BinaryValueView: View {
    let value: String?
    let editable: Bool
    let postgres: Bool
    let set: (String?) -> Void

    private var bytes: Data? {
        guard let value else { return nil }
        var hex = Substring(value)
        if hex.hasPrefix("0x") || hex.hasPrefix("\\x") { hex = hex.dropFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        return data
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bytes {
                if let image = NSImage(data: bytes), bytes.count > 8 {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)) · \(bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))\(bytes.count > 16 ? " …" : "")")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(MB.dim).lineLimit(2)
            } else {
                Text(value == nil ? "NULL" : "Not hex data").font(.system(size: 11)).foregroundStyle(MB.dim)
            }
            HStack(spacing: 10) {
                if editable {
                    Button("Load file…") { load() }.buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(MB.dim)
                }
                if bytes != nil {
                    Button("Save to file…") { save() }.buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(MB.dim)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(MB.wash(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MB.line))
    }

    private func load() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if data.count > 50_000_000 { NSSound.beep(); return }
        set((postgres ? "\\x" : "0x") + data.map { String(format: "%02X", $0) }.joined())
    }

    private func save() {
        guard let bytes else { return }
        let panel = NSSavePanel()
        var ext = "bin"
        if let image = NSImage(data: bytes), image.isValid {
            ext = bytes.starts(with: [0x89, 0x50]) ? "png" : bytes.starts(with: [0xFF, 0xD8]) ? "jpg" : bytes.starts(with: [0x47, 0x49]) ? "gif" : "img"
        }
        panel.nameFieldStringValue = "value.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? bytes.write(to: url)
    }
}

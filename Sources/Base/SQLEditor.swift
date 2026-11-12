import AppKit
import BaseCore
import SwiftUI

/// What the editor knows when it asks for completions.
struct CompletionContext {
    /// The statement around the cursor.
    var statement: String
    /// The word before a dot (`o.` in `o.cust`), when there is one.
    var qualifier: String?
    var partial: String
}

/// The SQL editor: monospaced, highlighted as you type, with completion for keywords, tables and columns
/// (columns of `alias.` follow the query's FROM and JOINs).
/// ⌘↩ runs the statement under the cursor (or the selection), ⇧⌘↩ runs everything.
/// Several cursors: ⌥-click adds one, ⌘D adds the next match of the selection; Esc goes back to one.
/// Snippets: type a trigger (sel, upd, …) and press Tab; Tab moves through the placeholders.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    var completions: (CompletionContext) -> [String]
    var onRun: (_ sql: String) -> Void
    var focusToken: Int = 0
    /// Bump to replace the text from outside as one undoable edit (formatting).
    var replaceToken: Int = 0
    var replacement: String = ""
    var snippets: [Store.Snippet] = SnippetText.builtIn
    /// Bump to insert a snippet at the cursor.
    var snippetToken: Int = 0
    var snippetToInsert: Store.Snippet?
    /// Told the statement under the cursor (or the selection) whenever the cursor moves.
    var onCursorStatement: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = MB.nsBg
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        let old = scroll.documentView as! NSTextView
        let tv = SQLTextView(frame: old.frame, textContainer: old.textContainer)
        tv.autoresizingMask = old.autoresizingMask
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        tv.coordinator = context.coordinator
        tv.delegate = context.coordinator
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = MB.nsText
        tv.backgroundColor = MB.nsBg
        tv.insertionPointColor = MB.nsAccentInk
        tv.selectedTextAttributes = [.backgroundColor: MB.nsAccent.withAlphaComponent(0.3)]
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 10, height: 12)
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.lastReplace = replaceToken
        context.coordinator.lastSnippet = snippetToken
        context.coordinator.highlight()
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if c.lastReplace != replaceToken {
            c.lastReplace = replaceToken
            tv.replaceAll(with: replacement)
        } else if tv.string != text {
            tv.string = text
            c.highlight()
        }
        if c.lastSnippet != snippetToken {
            c.lastSnippet = snippetToken
            if let s = snippetToInsert {
                tv.window?.makeFirstResponder(tv)
                tv.insertSnippet(SnippetText.expand(s.body), replacing: tv.selectedRange())
            }
        }
        if c.lastFocus != focusToken {
            c.lastFocus = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        weak var textView: SQLTextView?
        var lastFocus = 0
        var lastReplace = 0
        var lastSnippet = 0
        private var completing = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView, let report = parent.onCursorStatement else { return }
            let sel = tv.selectedRange()
            if sel.length > 0 { report((tv.string as NSString).substring(with: sel)); return }
            report(SQLText.statement(at: sel.location, in: tv.string)?.sql ?? tv.string)
        }

        init(_ parent: SQLEditor) {
            self.parent = parent
            lastFocus = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            highlight()
            // Offer completions after two letters of a word, or right after a dot.
            if !completing, tv.selectedRanges.count == 1, let event = NSApp.currentEvent, event.type == .keyDown,
               let chars = event.characters, chars.count == 1, chars.first!.isLetter || chars == "_" || chars == "." {
                let range = tv.rangeForUserCompletion
                if range.location != NSNotFound, range.length >= 2 || chars == "." {
                    completing = true
                    tv.complete(nil)
                    completing = false
                }
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            (textView as? SQLTextView)?.trackEdit(range: range, replacement: replacementString ?? "")
            return true
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let ns = textView.string as NSString
            let partial = ns.substring(with: charRange)
            // The word before a dot: `alias.`
            var qualifier: String?
            if charRange.location > 0, ns.character(at: charRange.location - 1) == 46 {
                var start = charRange.location - 1
                while start > 0, let s = Unicode.Scalar(ns.character(at: start - 1)),
                      CharacterSet.alphanumerics.contains(s) || s == "_" || s == "\"" || s == "`" { start -= 1 }
                qualifier = ns.substring(with: NSRange(location: start, length: charRange.location - 1 - start))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            }
            guard !partial.isEmpty || qualifier != nil else { return [] }
            let statement = SQLText.statement(at: charRange.location, in: textView.string)?.sql ?? textView.string
            let context = CompletionContext(statement: statement, qualifier: qualifier, partial: partial)
            let lower = partial.lowercased()
            var seen = Set<String>()
            var out: [String] = []
            let pool = parent.completions(context) + (qualifier == nil ? SQLText.keywords : [])
            for word in pool where (lower.isEmpty || word.lowercased().hasPrefix(lower)) && word != partial {
                if seen.insert(word.lowercased()).inserted { out.append(word) }
                if out.count > 60 { break }
            }
            index?.pointee = -1
            return out
        }

        func run(all: Bool) {
            guard let tv = textView else { return }
            let selected = tv.selectedRange()
            let sql: String
            if all {
                sql = tv.string
            } else if selected.length > 0 {
                sql = (tv.string as NSString).substring(with: selected)
            } else if let statement = SQLText.statement(at: selected.location, in: tv.string) {
                sql = statement.sql
                tv.showFindIndicator(for: statement.range)
            } else {
                sql = tv.string
            }
            guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            parent.onRun(sql)
        }

        // MARK: Highlighting

        private static let keywordSet = Set(SQLText.keywords.map { $0.lowercased() })
        static let keywordColor = MB.dyn(MB.rgb(0xFF78B3), MB.rgb(0xC4166A))
        static let stringColor = MB.dyn(MB.rgb(0x8CDB99), MB.rgb(0x18794E))
        static let numberColor = MB.dyn(MB.rgb(0xFAC773), MB.rgb(0x9A5B00))
        static let commentColor = MB.dyn(MB.rgb(0x737373), MB.rgb(0x80808A))
        static let identColor = MB.dyn(MB.rgb(0x99CCFF), MB.rgb(0x1F5FBF))
        static let paramColor = MB.dyn(MB.rgb(0xC9A0FF), MB.rgb(0x6B3FC0))

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            // Very long scripts: skip highlighting to keep typing fast.
            guard storage.length < 400_000 else { return }
            storage.beginEditing()
            storage.setAttributes([.foregroundColor: MB.nsText, .font: tv.font ?? MB.nsMono], range: full)
            for t in SQLLexer.tokens(storage.string) {
                let range = NSRange(location: t.offset, length: (t.text as NSString).length)
                let color: NSColor? = switch t.kind {
                case .word: Self.keywordSet.contains(t.text.lowercased()) ? Self.keywordColor : nil
                case .string: Self.stringColor
                case .number: Self.numberColor
                case .comment: Self.commentColor
                case .quoted: Self.identColor
                case .param: Self.paramColor
                default: nil
                }
                if let color { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
            storage.endEditing()
        }
    }
}

final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditor.Coordinator?
    /// Snippet placeholders still to visit (absolute ranges), and which one we're in.
    private var stops: [NSRange] = []
    private var stopIndex = 0

    /// Replaces everything as one undoable change (used by Format).
    func replaceAll(with newText: String) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: newText) else { return }
        replaceCharacters(in: full, with: newText)
        didChangeText()
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76) && flags.contains(.command) {
            coordinator?.run(all: flags.contains(.shift))
            return
        }
        if event.keyCode == 48 && (flags.isEmpty || flags == .shift) {  // Tab
            if !stops.isEmpty { moveToStop(flags == .shift ? -1 : 1); return }
            if flags.isEmpty, expandSnippet() { return }
            if flags.isEmpty { insertText("  ", replacementRange: NSRange(location: NSNotFound, length: 0)); return }
        }
        if event.keyCode == 53 {  // Esc: one cursor again, snippet done
            stops = []
            if selectedRanges.count > 1 { setSelectedRange(selectedRanges[0].rangeValue); return }
        }
        if event.charactersIgnoringModifiers == "d" && flags == .command { addNextMatch(); return }
        super.keyDown(with: event)
    }

    // MARK: Snippets

    private func expandSnippet() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, selectedRanges.count == 1 else { return false }
        let wordRange = rangeForUserCompletion
        guard wordRange.length > 0 else { return false }
        let ns = string as NSString
        let word = ns.substring(with: wordRange).lowercased()
        guard let snippet = (coordinator?.parent.snippets ?? []).first(where: { $0.trigger.lowercased() == word }) else { return false }
        let lineStart = ns.lineRange(for: NSRange(location: wordRange.location, length: 0)).location
        let indent = String(ns.substring(with: NSRange(location: lineStart, length: wordRange.location - lineStart)).prefix { $0 == " " || $0 == "\t" })
        let expanded = SnippetText.expand(snippet.body, indent: indent)
        insertSnippet(expanded, replacing: wordRange)
        return true
    }

    /// Puts an expanded snippet in place of a range and selects its first placeholder.
    func insertSnippet(_ expanded: SnippetText.Expanded, replacing range: NSRange) {
        guard shouldChangeText(in: range, replacementString: expanded.text) else { return }
        stops = []
        replaceCharacters(in: range, with: expanded.text)
        didChangeText()
        stops = expanded.stops.map { NSRange(location: $0.location + range.location, length: $0.length) }
        stopIndex = -1
        moveToStop(1)
    }

    private func moveToStop(_ step: Int) {
        let next = stopIndex + step
        guard next >= 0, next < stops.count else { stops = []; return }
        stopIndex = next
        setSelectedRange(stops[next])
        scrollRangeToVisible(stops[next])
        if next == stops.count - 1 { stops = [] }  // the last stop ends the snippet
    }

    /// Keeps snippet placeholders in place while text changes around and inside them.
    func trackEdit(range: NSRange, replacement: String) {
        guard !stops.isEmpty else { return }
        let delta = (replacement as NSString).length - range.length
        let current = stopIndex >= 0 && stopIndex < stops.count ? stops[stopIndex] : nil
        if let current, range.location >= current.location, NSMaxRange(range) <= NSMaxRange(current) {
            stops[stopIndex].length += delta
            for i in stops.indices where i != stopIndex && stops[i].location >= NSMaxRange(current) { stops[i].location += delta }
        } else if let current, range.location >= NSMaxRange(current) || NSMaxRange(range) <= current.location {
            for i in stops.indices where stops[i].location >= NSMaxRange(range) { stops[i].location += delta }
        } else {
            stops = []
        }
    }

    // MARK: Several cursors

    override func mouseDown(with event: NSEvent) {
        let before = selectedRanges
        super.mouseDown(with: event)
        // ⌥-click without dragging: add a cursor (⌥-drag still selects a column of text).
        if event.modifierFlags.contains(.option), selectedRanges.count == 1, selectedRange().length == 0 {
            let added = selectedRange()
            var ranges = before.map(\.rangeValue).filter { $0.location != added.location }
            ranges.append(added)
            setSelectedRanges(ranges.sorted { $0.location < $1.location }.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        }
    }

    /// ⌘D: select the word at the cursor, then each next occurrence.
    private func addNextMatch() {
        let ns = string as NSString
        var ranges = selectedRanges.map(\.rangeValue)
        guard let last = ranges.last else { return }
        if last.length == 0 {
            let word = selectionRange(forProposedRange: last, granularity: .selectByWord)
            if word.length > 0 { ranges[ranges.count - 1] = word }
            setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
            return
        }
        let needle = ns.substring(with: last)
        var found = ns.range(of: needle, options: [], range: NSRange(location: NSMaxRange(last), length: ns.length - NSMaxRange(last)))
        if found.location == NSNotFound { found = ns.range(of: needle, options: [], range: NSRange(location: 0, length: last.location)) }
        guard found.location != NSNotFound, !ranges.contains(found) else { NSSound.beep(); return }
        ranges.append(found)
        setSelectedRanges(ranges.sorted { $0.location < $1.location }.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        scrollRangeToVisible(found)
    }

    /// Applies an edit at every cursor. Returns false when there's only one (normal editing).
    private func editAll(_ edit: (NSRange) -> (range: NSRange, text: String)?) -> Bool {
        let ranges = selectedRanges.map(\.rangeValue)
        guard ranges.count > 1 else { return false }
        let edits = ranges.compactMap(edit).sorted { $0.range.location < $1.range.location }
        guard !edits.isEmpty, shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map(\.text)) else { return true }
        textStorage?.beginEditing()
        for e in edits.reversed() { textStorage?.replaceCharacters(in: e.range, with: e.text) }
        textStorage?.endEditing()
        didChangeText()
        var shift = 0
        var carets: [NSRange] = []
        for e in edits {
            let len = (e.text as NSString).length
            carets.append(NSRange(location: e.range.location + shift + len, length: 0))
            shift += len - e.range.length
        }
        setSelectedRanges(carets.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        return true
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if replacementRange.location == NSNotFound, editAll({ ($0, text) }) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        if editAll({ ($0, "\n") }) { return }
        // Keep the indentation of the line above.
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let indent = ns.substring(with: line).prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { super.insertText(String(indent), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    override func deleteBackward(_ sender: Any?) {
        if editAll({ r in r.length > 0 ? (r, "") : r.location > 0 ? (NSRange(location: r.location - 1, length: 1), "") : nil }) { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let length = (string as NSString).length
        if editAll({ r in r.length > 0 ? (r, "") : r.location < length ? (NSRange(location: r.location, length: 1), "") : nil }) { return }
        super.deleteForward(sender)
    }

    override var rangeForUserCompletion: NSRange {
        let sel = selectedRange()
        guard sel.length == 0 else { return super.rangeForUserCompletion }
        let ns = string as NSString
        var start = sel.location
        while start > 0 {
            let c = ns.character(at: start - 1)
            guard let scalar = Unicode.Scalar(c), CharacterSet.alphanumerics.contains(scalar) || c == 95 else { break }
            start -= 1
        }
        return NSRange(location: start, length: sel.location - start)
    }
}

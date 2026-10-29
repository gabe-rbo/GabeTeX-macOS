import AppKit
import TeXCore

/// One replacement of an edit transaction (range in the text *before* the edit).
nonisolated struct TextEdit: Equatable {
    var range: NSRange
    var text: String
}

/// Editing behaviours: auto-pairing, Enter (auto-indent, `\begin` auto-close), Tab/⇧Tab, comment
/// toggling, completion/snippet insertion with tab-stop sessions.
extension LaTeXTextView {
    // MARK: - Edit transactions

    /// Applies non-overlapping replacements as **one** undoable user edit (one `noteEdit`), then sets
    /// `selection` (in post-edit coordinates). Returns false when the text view refused the change.
    @discardableResult
    func performEdit(_ edits: [TextEdit], selection: NSRange? = nil, actionName: String? = nil) -> Bool {
        guard let storage = textStorage, !edits.isEmpty else { return false }
        let sorted = edits.map { TextEdit(range: $0.range.clamped(to: storage.length), text: $0.text) }
            .sorted { $0.range.location < $1.range.location }
        for i in sorted.indices.dropFirst() where sorted[i].range.location < sorted[i - 1].range.end {
            return false // overlapping edits are a programming error; refuse rather than corrupt the text
        }
        breakUndoCoalescing()
        let ranges = sorted.map { NSValue(range: $0.range) }
        guard shouldChangeText(inRanges: ranges, replacementStrings: sorted.map(\.text)) else { return false }
        storage.beginEditing()
        for edit in sorted.reversed() {
            storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.text, attributes: baseAttributes))
        }
        storage.endEditing()
        if let selection {
            setSelectedRange(selection.clamped(to: storage.length))
        }
        didChangeText()
        if let actionName { undoManager?.setActionName(actionName) }
        breakUndoCoalescing()
        return true
    }

    /// Maps an offset of the pre-edit text through `edits` (sorted, non-overlapping).
    /// `stickToStart`: an insertion exactly at `offset` leaves it before the inserted text.
    static func map(_ offset: Int, through edits: [TextEdit], stickToStart: Bool) -> Int {
        var shift = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            let r = edit.range
            let newLength = edit.text.utf16.count
            if offset < r.location { break }
            if offset > r.end || (offset == r.end && r.length > 0) {
                shift += newLength - r.length
                continue
            }
            if r.length == 0 {
                // insertion exactly at offset
                if !stickToStart { shift += newLength }
                continue
            }
            // offset strictly inside a replaced range → its start
            return r.location + shift
        }
        return offset + shift
    }

    /// The line terminator used by the current text (`\n`, `\r\n` or `\r`).
    var lineEnding: String {
        guard let storage = textStorage else { return "\n" }
        return TextScan.lineEnding(of: storage.mutableString)
    }

    /// Leading whitespace of the 0-based line `index`.
    func indentation(ofLine index: Int) -> String {
        guard let storage = textStorage else { return "" }
        let text = storage.mutableString
        let content = lineTable.contentsRange(ofLine: index, in: text)
        let length = TextScan.leadingWhitespaceLength(in: content, of: text)
        return text.substring(with: NSRange(location: content.location, length: length))
    }

    /// 0-based indexes of the lines touched by the selection (a selection ending at column 0 of a line
    /// does not include that line).
    func selectedLineIndexes() -> ClosedRange<Int> {
        let selection = selectedRange()
        let first = lineTable.lineIndex(containing: selection.location)
        var last = lineTable.lineIndex(containing: selection.end)
        if selection.length > 0, last > first, selection.end == lineTable.startOfLine(last) { last -= 1 }
        return first...last
    }

    // MARK: - Auto-pairing

    static let pairs: [unichar: unichar] = [
        TextScan.openBrace: TextScan.closeBrace,
        TextScan.openBracket: TextScan.closeBracket,
        TextScan.openParen: TextScan.closeParen,
        TextScan.dollar: TextScan.dollar,
    ]
    static let closers: Set<unichar> = [TextScan.closeBrace, TextScan.closeBracket, TextScan.closeParen, TextScan.dollar]

    func adjustAutoClosers(editedRange: NSRange, delta: Int) {
        guard !autoClosers.isEmpty else { return }
        let oldEnd = editedRange.end - delta
        autoClosers = autoClosers.compactMap { p in
            if p >= oldEnd { return p + delta }
            if p < editedRange.location { return p }
            return nil
        }
    }

    /// Auto-inserted closers stay "live" only on the caret's line, after the caret.
    func pruneAutoClosers(for selection: NSRange) {
        guard !autoClosers.isEmpty else { return }
        guard selection.length == 0 else { autoClosers = []; return }
        let line = lineTable.lineIndex(containing: selection.location)
        let lineEnd = lineTable.endOfLineIncludingTerminator(line)
        autoClosers.removeAll { $0 < selection.location || $0 >= lineEnd }
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed: String
        if let s = string as? String { typed = s } else if let a = string as? NSAttributedString { typed = a.string } else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        userTyping {
            if !handleTyped(typed, replacementRange: replacementRange) {
                super.insertText(typed, replacementRange: replacementRange)
            }
        }
    }

    /// Auto-pair / type-over / wrap-selection for a single typed character. Returns true when handled.
    private func handleTyped(_ typed: String, replacementRange: NSRange) -> Bool {
        guard configuration.autoPairBrackets, !hasMarkedText(), let storage = textStorage else { return false }
        let units = Array(typed.utf16)
        guard units.count == 1 else { return false }
        let c = units[0]
        let selection = selectedRange()
        if replacementRange.location != NSNotFound, replacementRange != selection { return false }
        guard selectedRanges.count == 1 else { return false }
        let text = storage.mutableString
        let caret = selection.location

        // Type over an auto-inserted closer.
        if Self.closers.contains(c), selection.length == 0, caret < text.length, text.character(at: caret) == c,
           autoClosers.contains(caret) {
            autoClosers.removeAll { $0 == caret }
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return true
        }
        guard let closer = Self.pairs[c] else { return false }
        if TextScan.isEscaped(caret, in: text) { return false }   // \{ \[ \( \$ are literal
        let open = String(utf16CodeUnits: [c], count: 1)
        let close = String(utf16CodeUnits: [closer], count: 1)

        // Wrap a (single-line) selection.
        if selection.length > 0 {
            let selected = text.substring(with: selection)
            guard !selected.contains("\n"), !selected.contains("\r") else { return false }
            let wrapped = open + selected + close
            return performEdit([TextEdit(range: selection, text: wrapped)],
                               selection: NSRange(location: selection.location + 1, length: selection.length))
        }

        // Only pair when the next character makes it sensible.
        if caret < text.length, !TextScan.allowsAutoCloseBefore(text.character(at: caret)) { return false }
        if c == TextScan.dollar {
            if highlighter.isMath(at: caret) { return false }
            if caret > 0 {
                let previous = text.character(at: caret - 1)
                if TextScan.isASCIILetter(previous) || TextScan.isDigit(previous) || previous == TextScan.dollar { return false }
            }
        }
        if TextScan.isInComment(caret, in: text) { return false }
        super.insertText(open + close, replacementRange: selection)
        setSelectedRange(NSRange(location: caret + 1, length: 0))
        autoClosers.append(caret + 1)
        return true
    }

    public override func deleteBackward(_ sender: Any?) {
        guard let storage = textStorage, !hasMarkedText(), selectedRanges.count == 1 else {
            super.deleteBackward(sender)
            return
        }
        let selection = selectedRange()
        let text = storage.mutableString
        let caret = selection.location
        if selection.length == 0, caret > 0 {
            // Empty auto-inserted pair: delete both characters.
            if configuration.autoPairBrackets, caret < text.length, autoClosers.contains(caret),
               let closer = Self.pairs[text.character(at: caret - 1)], text.character(at: caret) == closer,
               !TextScan.isEscaped(caret - 1, in: text) {
                autoClosers.removeAll { $0 == caret }
                setSelectedRange(NSRange(location: caret - 1, length: 2))
                super.deleteBackward(sender)
                return
            }
            // Soft tabs: in leading spaces, delete back to the previous indentation stop.
            if configuration.insertSpaces, configuration.indentWidth > 1 {
                let line = lineTable.lineIndex(containing: caret)
                let start = lineTable.startOfLine(line)
                let column = caret - start
                if column > 0, TextScan.isBlank(NSRange(location: start, length: column), in: text),
                   text.character(at: caret - 1) == TextScan.space {
                    let width = configuration.indentWidth
                    var count = column % width == 0 ? width : column % width
                    var k = 0
                    while k < count, text.character(at: caret - 1 - k) == TextScan.space { k += 1 }
                    count = max(1, k)
                    if count > 1 {
                        setSelectedRange(NSRange(location: caret - count, length: count))
                        super.deleteBackward(sender)
                        return
                    }
                }
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: - Enter

    public override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage, !hasMarkedText(), selectedRanges.count == 1 else {
            super.insertNewline(sender)
            return
        }
        let text = storage.mutableString
        let selection = selectedRange()
        let lineIndex = lineTable.lineIndex(containing: selection.location)
        let content = lineTable.contentsRange(ofLine: lineIndex, in: text)
        let headLength = max(0, min(selection.location, content.end) - content.location)
        let head = text.substring(with: NSRange(location: content.location, length: headLength)) as NSString
        let indentLength = min(TextScan.leadingWhitespaceLength(in: content, of: text), headLength)
        let indent = text.substring(with: NSRange(location: content.location, length: indentLength))
        let unit = configuration.indentUnit
        let newline = lineEnding
        let selectionEndLine = lineTable.lineIndex(containing: selection.end)
        let tailRange: NSRange
        if selectionEndLine == lineIndex, selection.end <= content.end {
            tailRange = NSRange(location: selection.end, length: content.end - selection.end)
        } else {
            tailRange = NSRange(location: selection.end, length: 0)
        }

        // \begin{env} + Enter → body line + \end{env} (only an indented body line when auto-close is off
        // or the environment is already closed).
        if let env = TextScan.environmentOpened(atEndOf: head) {
            if configuration.autoCloseEnvironments, environmentNeedsClosing(env, in: text) {
                let tailText = text.substring(with: tailRange).trimmingCharacters(in: .whitespaces)
                let body = newline + indent + unit
                let inserted = body + tailText + newline + indent + "\\end{\(env)}"
                let replace = NSRange(location: selection.location, length: tailRange.end - selection.location)
                let caret = selection.location + body.utf16.count
                performEdit([TextEdit(range: replace, text: inserted)], selection: NSRange(location: caret, length: 0),
                            actionName: String(localized: "Close Environment"))
                return
            }
            super.insertText(newline + indent + unit, replacementRange: selection)
            return
        }

        // Enter between an opener and its closer: {|} → {\n  |\n}
        if selection.length == 0, headLength > 0, tailRange.length > 0 {
            let before = head.character(at: headLength - 1)
            let after = text.character(at: selection.location)
            if let closer = Self.pairs[before], closer == after, before != TextScan.dollar,
               !TextScan.isEscaped(selection.location - 1, in: text) {
                let first = newline + indent + unit
                let inserted = first + newline + indent
                performEdit([TextEdit(range: selection, text: inserted)],
                            selection: NSRange(location: selection.location + first.utf16.count, length: 0))
                return
            }
        }

        // A whitespace-only line: don't leave trailing whitespace behind.
        if selection.length == 0, headLength > 0, indentLength == headLength, tailRange.length == 0 {
            performEdit([TextEdit(range: NSRange(location: content.location, length: headLength), text: newline + indent)],
                        selection: NSRange(location: content.location + (newline + indent).utf16.count, length: 0))
            return
        }

        // Auto-indent: copy the indentation; one level deeper after an opening brace at the end of the line.
        var newIndent = indent
        if headLength > indentLength {
            var k = headLength
            while k > 0, TextScan.isHorizontalSpace(head.character(at: k - 1)) { k -= 1 }
            if k > 0, head.character(at: k - 1) == TextScan.openBrace, !TextScan.isEscaped(k - 1, in: head),
               TextScan.commentStart(in: NSRange(location: 0, length: k), of: head) == nil {
                newIndent += unit
            }
        }
        super.insertText(newline + newIndent, replacementRange: selection)
    }

    /// True when the document has more `\begin{env}` than `\end{env}` (outside comments).
    func environmentNeedsClosing(_ env: String, in text: NSString) -> Bool {
        let balance = TextScan.environmentBalance(env, in: text)
        return balance.begins > balance.ends
    }

    // MARK: - Tab / ⇧Tab

    /// Tab: accepts the open completion popup (when Tab is an accept key), completes the prefix before the caret
    /// ("Tab completes", see `EditorConfiguration.tabCompletes`), else moves to the next snippet field or indents.
    public override func insertTab(_ sender: Any?) {
        let triggerPending = completion.isTriggerPending
        completion.cancelPendingTrigger()   // a debounced popup for the text before Tab is stale now
        if completion.isVisible {
            // Normally intercepted by `doCommand(by:)`; this is the direct (programmatic) path.
            if configuration.completionAcceptKeys.acceptsTab {
                completion.acceptWithTab()
                return
            }
            completion.dismiss()
        } else if !tabCompletionDeclined, completesWithTab(triggerPending: triggerPending) {
            return
        }
        insertPlainTab()
    }

    /// Whether Tab completion applies here and did something: a single empty selection in an editable buffer,
    /// no marked text, Vim (if on) in insert mode, and no snippet whose fields are mirrored (completing inside
    /// `\begin{$1}…\end{$1}` would duplicate the `\end`).
    func completesWithTab(triggerPending: Bool = false) -> Bool {
        guard configuration.tabCompletes, buffer != nil, isEditable, !hasMarkedText(), selectedRanges.count == 1,
              selectedRange().length == 0, vim?.isInsertLike ?? true, snippetSession?.hasMirrors != true else {
            return false
        }
        return completion.tabComplete(triggerPending: triggerPending)
    }

    /// Tab without completion: next snippet field, indent the selected lines, or insert indentation.
    func insertPlainTab() {
        if snippetSession != nil {
            advanceSnippet()
            return
        }
        guard let storage = textStorage, !hasMarkedText() else {
            super.insertTab(nil)
            return
        }
        let selection = selectedRange()
        if selection.length > 0 {
            shiftSelectedLines(outdent: false)
            return
        }
        if configuration.insertSpaces {
            let line = lineTable.lineIndex(containing: selection.location)
            let column = visualColumn(of: selection.location, lineStart: lineTable.startOfLine(line), in: storage.mutableString)
            let width = max(1, configuration.indentWidth)
            let count = width - (column % width)
            super.insertText(String(repeating: " ", count: count), replacementRange: selection)
        } else {
            super.insertText("\t", replacementRange: selection)
        }
    }

    public override func insertBacktab(_ sender: Any?) {
        if snippetSession != nil {
            retreatSnippet()
            return
        }
        shiftSelectedLines(outdent: true)
    }

    /// Display column (tabs expanded to the indent width) of `offset`.
    private func visualColumn(of offset: Int, lineStart: Int, in text: NSString) -> Int {
        let width = max(1, configuration.indentWidth)
        var column = 0
        var i = lineStart
        while i < offset {
            if text.character(at: i) == TextScan.tab { column += width - (column % width) } else { column += 1 }
            i += 1
        }
        return column
    }

    /// Indents (or outdents) every selected line by one indent unit. Blank lines are not indented.
    func shiftSelectedLines(outdent: Bool) {
        guard let storage = textStorage else { return }
        let text = storage.mutableString
        let selection = selectedRange()
        let lines = selectedLineIndexes()
        let unit = configuration.indentUnit
        let width = max(1, configuration.indentWidth)
        var edits: [TextEdit] = []
        for line in lines {
            let content = lineTable.contentsRange(ofLine: line, in: text)
            if outdent {
                guard content.length > 0 else { continue }
                if text.character(at: content.location) == TextScan.tab {
                    edits.append(TextEdit(range: NSRange(location: content.location, length: 1), text: ""))
                } else {
                    var count = 0
                    while count < width, count < content.length, text.character(at: content.location + count) == TextScan.space {
                        count += 1
                    }
                    if count > 0 { edits.append(TextEdit(range: NSRange(location: content.location, length: count), text: "")) }
                }
            } else {
                guard !TextScan.isBlank(content, in: text) else { continue }
                edits.append(TextEdit(range: NSRange(location: content.location, length: 0), text: unit))
            }
        }
        guard !edits.isEmpty else { return }
        let start = Self.map(selection.location, through: edits, stickToStart: selection.length > 0)
        let end = Self.map(selection.end, through: edits, stickToStart: false)
        performEdit(edits, selection: NSRange(location: start, length: max(0, end - start)),
                    actionName: outdent ? String(localized: "Outdent") : String(localized: "Indent"))
    }

    // MARK: - Comments

    /// Toggles `% ` comments on the selected lines: if every non-blank line is commented, removes the
    /// comment markers; otherwise comments all non-blank lines at their common indentation.
    public func toggleComment() {
        guard let storage = textStorage, buffer != nil, isEditable else { return }
        let text = storage.mutableString
        let selection = selectedRange()
        let lines = selectedLineIndexes()
        var contents: [NSRange] = []
        for line in lines {
            let content = lineTable.contentsRange(ofLine: line, in: text)
            if !TextScan.isBlank(content, in: text) { contents.append(content) }
        }
        var edits: [TextEdit] = []
        if contents.isEmpty {
            // Blank line(s): start a comment at the caret line's indentation.
            let line = lineTable.lineIndex(containing: selection.location)
            let content = lineTable.contentsRange(ofLine: line, in: text)
            let lead = TextScan.leadingWhitespaceLength(in: content, of: text)
            edits.append(TextEdit(range: NSRange(location: content.location + lead, length: 0), text: "% "))
        } else {
            let allCommented = contents.allSatisfy { content in
                let lead = TextScan.leadingWhitespaceLength(in: content, of: text)
                return text.character(at: content.location + lead) == TextScan.percent
            }
            if allCommented {
                for content in contents {
                    let lead = TextScan.leadingWhitespaceLength(in: content, of: text)
                    let percent = content.location + lead
                    var length = 1
                    if percent + 1 < content.end, text.character(at: percent + 1) == TextScan.space { length = 2 }
                    edits.append(TextEdit(range: NSRange(location: percent, length: length), text: ""))
                }
            } else {
                let column = contents.map { TextScan.leadingWhitespaceLength(in: $0, of: text) }.min() ?? 0
                for content in contents {
                    edits.append(TextEdit(range: NSRange(location: content.location + column, length: 0), text: "% "))
                }
            }
        }
        let start = Self.map(selection.location, through: edits, stickToStart: selection.length > 0 && isAtLineStart(selection.location))
        let end = Self.map(selection.end, through: edits, stickToStart: false)
        performEdit(edits, selection: NSRange(location: start, length: max(0, end - start)),
                    actionName: String(localized: "Toggle Comment"))
    }

    private func isAtLineStart(_ offset: Int) -> Bool {
        lineTable.startOfLine(lineTable.lineIndex(containing: offset)) == offset
    }

    @objc public func toggleComment(_ sender: Any?) {
        toggleComment()
    }

    // MARK: - Completion & snippets

    /// Replaces `range` with the item's snippet (newlines re-indented to the line's indentation, tabs →
    /// indent unit) as one undoable edit, then starts a tab-stop session when the snippet has stops.
    public func insertCompletion(_ item: CompletionItem, replacing range: NSRange) {
        guard let storage = textStorage, buffer != nil else { return }
        let r = range.clamped(to: storage.length)
        let snippet = Snippet(parsing: item.insertText)
        let line = lineTable.lineIndex(containing: r.location)
        let lineStart = lineTable.startOfLine(line)
        let indent = indentation(ofLine: line)
        let indentPrefix = String(indent.utf16.prefix(max(0, r.location - lineStart))) ?? indent
        let expanded = ExpandedSnippet(snippet, indent: indentPrefix, indentUnit: configuration.indentUnit,
                                       lineEnding: lineEnding)
        endSnippetSession()
        completion.dismiss()
        let firstSelection: NSRange
        if let first = expanded.tabStops.first {
            firstSelection = NSRange(location: r.location + first.location, length: first.length)
        } else {
            firstSelection = NSRange(location: r.location + expanded.finalCursor, length: 0)
        }
        // A single replacement = a single undo action (the selection change is not undoable).
        let applied = performEdit([TextEdit(range: r, text: expanded.text)], selection: firstSelection,
                                  actionName: String(localized: "Completion"))
        guard applied else { return }
        if !expanded.tabStops.isEmpty {
            func shifted(_ x: NSRange) -> NSRange { NSRange(location: r.location + x.location, length: x.length) }
            snippetSession = SnippetSession(stops: expanded.tabStops.map(shifted),
                                            mirrors: expanded.mirrors.map { $0.map(shifted) },
                                            finalPosition: r.location + expanded.finalCursor,
                                            span: NSRange(location: r.location, length: expanded.text.utf16.count))
            setNeedsDisplay(visibleRect)
        }
        scrollRangeToVisible(selectedRange())
    }

    /// Copies the text of the tab stop being edited into its mirrors. Runs inside the edit that changed
    /// the stop (called from `didChangeText`), so it is reported and undone together with it.
    func syncSnippetMirrors() {
        guard let session = snippetSession, session.hasMirrors, let stop = session.currentStop,
              let storage = textStorage else { return }
        if let undo = undoManager, undo.isUndoing || undo.isRedoing {
            // Undo/redo restores mirrors itself; ranges can no longer be trusted afterwards.
            endSnippetSession()
            return
        }
        let text = storage.mutableString
        guard stop.end <= text.length else { return }
        let edits = session.mirrorEdits(value: text.substring(with: stop), in: text)
        guard !edits.isEmpty else { return }
        let selection = selectedRange()
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        let start = SnippetSession.map(selection.location, through: sorted, stickToStart: true)
        let end = SnippetSession.map(selection.end, through: sorted, stickToStart: true)
        snippetSession = nil   // ranges are updated below, not by the storage notifications
        let applied = performEdit(edits, selection: NSRange(location: start, length: max(0, end - start)))
        snippetSession = session
        if applied {
            session.didApplyMirrorEdits(edits)
            setNeedsDisplay(visibleRect)
        }
    }

    /// Tab inside a snippet: next stop, or the final position (ending the session).
    func advanceSnippet() {
        guard let session = snippetSession else { return }
        if let next = session.advance() {
            setSelectedRange(next)
            scrollRangeToVisible(next)
        } else {
            let position = session.finalPosition
            endSnippetSession()
            setSelectedRange(NSRange(location: position, length: 0))
        }
        setNeedsDisplay(visibleRect)
    }

    /// ⇧Tab inside a snippet: previous stop.
    func retreatSnippet() {
        guard let session = snippetSession, let previous = session.retreat() else { return }
        setSelectedRange(previous)
        scrollRangeToVisible(previous)
        setNeedsDisplay(visibleRect)
    }

    func endSnippetSession() {
        guard snippetSession != nil else { return }
        snippetSession = nil
        setNeedsDisplay(visibleRect)
    }

    /// The tab stop being edited, while a snippet session is active.
    public var activeSnippetStop: NSRange? { snippetSession?.currentStop }

    /// The completions currently offered, best first (empty when the popup is closed).
    public var completionItems: [CompletionItem] { completion.items }

    // MARK: - Esc / completion commands

    public override func cancelOperation(_ sender: Any?) {
        if completion.isVisible {
            completion.dismiss()
            return
        }
        if snippetSession != nil {
            endSnippetSession()
            return
        }
        // Do not fall back to NSTextView's word completion on Esc.
    }

    /// ⌥⎋ / F5: our completion instead of the system word completion.
    public override func complete(_ sender: Any?) {
        completion.trigger(manual: true)
    }

    public override func doCommand(by selector: Selector) {
        if completion.isVisible, completion.handleCommand(selector) { return }
        super.doCommand(by: selector)
    }
}

import AppKit
import TeXCore

/// Commands whose brace argument is a bibliography key. ⌘-click on such a key is not "ordinary text":
/// it must never trigger Show in PDF (a bibliography jump is reserved for it).
private let citationCommands = Set<String>([
    "cite", "Cite", "citep", "Citep", "citet", "Citet", "citealp", "Citealp", "citealt", "Citealt",
    "citeauthor", "Citeauthor", "citeyear", "citeyearpar", "citenum", "citetext", "nocite", "fullcite",
    "parencite", "Parencite", "textcite", "Textcite", "autocite", "Autocite", "smartcite", "Smartcite",
    "footcite", "Footcite", "footcitetext", "footfullcite", "supercite", "cites", "Cites", "parencites",
    "Parencites", "textcites", "Textcites", "autocites", "Autocites", "smartcites", "Smartcites",
    "footcites", "volcite", "Volcite", "pvolcite", "Pvolcite", "svolcite", "Svolcite", "avolcite",
    "Avolcite", "fvolcite", "Fvolcite", "notecite", "Notecite", "pnotecite", "Pnotecite", "fnotecite",
    "citefield", "citetitle", "citeurl", "citedate",
])

/// Source → PDF: "Show in PDF" from ⌘-click and from the contextual menu (both end in `onShowInPDF`).
extension LaTeXTextView {
    // MARK: - Position & word

    /// 1-based line and UTF-16 column of an offset.
    func sourcePosition(at offset: Int) -> SourcePosition {
        let clamped = max(0, min(offset, textStorage?.length ?? 0))
        let line = lineTable.lineIndex(containing: clamped)
        return SourcePosition(line: line + 1, column: clamped - lineTable.startOfLine(line) + 1)
    }

    /// Reports `offset` (position + word there) to `onShowInPDF`.
    func fireShowInPDF(at offset: Int) {
        guard let handler = controller?.onShowInPDF, let storage = textStorage else { return }
        let clamped = max(0, min(offset, storage.length))
        handler(sourcePosition(at: clamped), word(at: clamped)?.word)
    }

    /// The caret position nearest to a point of the view (composed-character aligned).
    func insertionOffset(atViewPoint point: NSPoint) -> Int {
        guard let storage = textStorage else { return 0 }
        let raw = characterIndexForInsertion(at: point)
        guard raw != NSNotFound else { return storage.length }
        let clamped = max(0, min(raw, storage.length))
        if clamped > 0, clamped < storage.length {
            return storage.mutableString.rangeOfComposedCharacterSequence(at: clamped).location
        }
        return clamped
    }

    // MARK: - ⌘-click

    /// The cite key under `index` inside `\cite{a,b}` and friends (nil elsewhere). ⌘-click on it is left
    /// alone (it does not trigger Show in PDF).
    public func citationKey(at index: Int) -> String? {
        guard let storage = textStorage else { return nil }
        let text = storage.mutableString
        let line = lineTable.lineIndex(containing: index)
        let content = lineTable.contentsRange(ofLine: line, in: text)
        guard let argument = TextScan.enclosingArgument(at: index, in: text, lineRange: content),
              citationCommands.contains(argument.command),
              let (key, _) = TextScan.listItem(at: index, in: argument.content, of: text) else { return nil }
        return key
    }

    /// ⌘-click on ordinary text: take focus, move the caret to the click and report it. Does nothing
    /// (returns false) without an `onShowInPDF` handler, so the click then behaves like any other.
    func showInPDFFromClick(at point: NSPoint) -> Bool {
        guard controller?.onShowInPDF != nil, buffer != nil else { return false }
        let caret = insertionOffset(atViewPoint: point)
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: caret, length: 0))
        vim?.mouseSelectionDidChange()
        fireShowInPDF(at: caret)
        return true
    }

    // MARK: - Contextual menu

    /// The standard text menu with "Show in PDF" (⇧⌘J) on top — it reports the position that was
    /// right-clicked (AppKit's own right-click handling may select the word under the pointer; the item
    /// does not move the caret). The item exists while `onShowInPDF` is set.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        guard buffer != nil, controller?.onShowInPDF != nil else { return base }
        let menu = base ?? NSMenu()
        let action = #selector(showInPDFFromMenu(_:))
        // AppKit may hand back a cached menu: never stack a second copy.
        while let existing = menu.items.firstIndex(where: { $0.action == action }) {
            menu.removeItem(at: existing)
            if existing < menu.items.count, menu.items[existing].isSeparatorItem { menu.removeItem(at: existing) }
        }
        let item = NSMenuItem(title: String(localized: "Show in PDF"), action: action, keyEquivalent: "j")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.representedObject = insertionOffset(atViewPoint: convert(event.locationInWindow, from: nil))
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc func showInPDFFromMenu(_ sender: NSMenuItem) {
        fireShowInPDF(at: (sender.representedObject as? Int) ?? selectedRange().location)
    }
}

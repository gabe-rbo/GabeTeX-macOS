import AppKit
import TeXCore

/// Commands whose brace argument is a label key (⌘-click → `onOpenLabel`).
private let labelReferenceCommands: Set<String> = [
    "ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "vref", "Vref", "cpageref", "Cpageref",
    "labelcref", "crefrange", "Crefrange", "hyperref", "subref", "label",
]

/// Mouse behaviours: ⌘-click on references and ordinary text ("Show in PDF"), diagnostic hover popovers,
/// keyboard routing (Vim, completion), scroll-wheel housekeeping.
extension LaTeXTextView {
    // MARK: - Keyboard routing

    public override func keyDown(with event: NSEvent) {
        hover.dismiss()
        if completion.isVisible, completion.handleKeyDown(event) { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 49, flags == .control {   // ⌃Space
            completion.trigger(manual: true)
            return
        }
        if let vim, !hasMarkedText() {
            if vim.handleKeyDown(event) { return }
        }
        super.keyDown(with: event)
    }

    // MARK: - ⌘-click

    public override func mouseDown(with event: NSEvent) {
        hover.dismiss()
        completion.dismiss()
        swallowsMouseUntilUp = false
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, event.clickCount == 1, handleCommandClick(at: convert(event.locationInWindow, from: nil)) {
            // A consumed ⌘-click never reaches NSTextView's tracking loop: make sure the drag and the
            // mouse-up that follow cannot start or extend a selection either.
            swallowsMouseUntilUp = true
            return
        }
        super.mouseDown(with: event)
        vim?.mouseSelectionDidChange()
    }

    public override func mouseDragged(with event: NSEvent) {
        if swallowsMouseUntilUp { return }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if swallowsMouseUntilUp {
            swallowsMouseUntilUp = false
            return
        }
        super.mouseUp(with: event)
    }

    /// Character index under a point (view coordinates), only when the point is over a glyph.
    func characterIndex(atViewPoint point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: containerPoint, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let bounds = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard bounds.insetBy(dx: -1, dy: -2).contains(containerPoint) else { return nil }
        let char = lm.characterIndexForGlyph(at: glyph)
        return char < storage.length ? char : nil
    }

    /// Resolves a ⌘-click: include argument → `onOpenReference`, `\ref`-family key → `onOpenLabel`; a
    /// `\cite`-family key is left alone (reserved for a bibliography jump); anything else is ordinary text →
    /// the caret moves there and `onShowInPDF` fires. Returns true when the click was consumed; when it
    /// returns false the caller lets the click through to `NSTextView`. `point` is in view coordinates.
    public func handleCommandClick(at point: NSPoint) -> Bool {
        guard let index = characterIndex(atViewPoint: point) else { return false }
        if let reference = includeReference(at: index) {
            guard let handler = controller?.onOpenReference else { return false }
            handler(reference)
            return true
        }
        if let key = labelKey(at: index) {
            guard let handler = controller?.onOpenLabel else { return false }
            handler(key)
            return true
        }
        if citationKey(at: index) != nil { return false }
        return showInPDFFromClick(at: point)
    }

    /// The include reference (`\input{…}`, `\includegraphics{…}` …) whose argument contains `index`.
    public func includeReference(at index: Int) -> IncludeReference? {
        guard let storage = textStorage else { return nil }
        let text = storage.mutableString
        let line = lineTable.lineIndex(containing: index)
        // Scan a small window of lines around the click (arguments rarely span lines).
        let firstLine = max(0, line - 2)
        let lastLine = min(lineTable.lineCount - 1, line + 2)
        let start = lineTable.startOfLine(firstLine)
        let end = lineTable.endOfLineIncludingTerminator(lastLine)
        let window = text.substring(with: NSRange(location: start, length: end - start))
        for reference in LaTeXScanner.includes(in: window) {
            let r = NSRange(location: reference.range.location + start, length: reference.range.length)
            if index >= r.location, index <= r.end {
                var adjusted = reference
                adjusted.range = r
                adjusted.line = reference.line + firstLine
                return adjusted
            }
        }
        return nil
    }

    /// The label key under `index` inside `\ref{…}` / `\eqref{…}` / `\cref{a,b}` ….
    public func labelKey(at index: Int) -> String? {
        guard let storage = textStorage else { return nil }
        let text = storage.mutableString
        let line = lineTable.lineIndex(containing: index)
        let content = lineTable.contentsRange(ofLine: line, in: text)
        guard let argument = TextScan.enclosingArgument(at: index, in: text, lineRange: content),
              labelReferenceCommands.contains(argument.command),
              let (key, _) = TextScan.listItem(at: index, in: argument.content, of: text) else { return nil }
        return key
    }

    // MARK: - Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea, trackingAreas.contains(hoverTrackingArea) { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover.mouseMoved(to: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover.mouseExited()
    }

    public override func scrollWheel(with event: NSEvent) {
        hover.dismiss()
        super.scrollWheel(with: event)
    }

    // MARK: - Find

    /// Shows the find bar (or find & replace).
    public func showFindBar(replace: Bool) {
        let item = NSMenuItem()
        item.tag = replace ? NSTextFinder.Action.showReplaceInterface.rawValue : NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }
}

/// Shows the messages of the diagnostic under the mouse after a short delay.
final class HoverController {
    unowned let textView: LaTeXTextView
    private let presenter = DiagnosticPopoverPresenter()
    private var pending: Task<Void, Never>?
    private var shownRange: NSRange?
    private var candidate: NSRange?
    var delay: Duration = .milliseconds(450)

    init(textView: LaTeXTextView) {
        self.textView = textView
    }

    func mouseMoved(to point: NSPoint) {
        guard let index = textView.characterIndex(atViewPoint: point) else {
            candidate = nil
            pending?.cancel()
            if presenter.isShown, !presenter.anchorRect.insetBy(dx: -8, dy: -8).contains(point) { dismiss() }
            return
        }
        let anchors = textView.diagnosticsRenderer.diagnostics(at: index)
        guard let first = anchors.first else {
            candidate = nil
            pending?.cancel()
            if presenter.isShown { dismiss() }
            return
        }
        let range = first.range
        if presenter.isShown, shownRange == range { return }
        if candidate == range, pending != nil { return }
        candidate = range
        pending?.cancel()
        let wait = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.show(anchors.map(\.diagnostic), range: range, index: index)
        }
    }

    func mouseExited() {
        pending?.cancel()
        pending = nil
        candidate = nil
    }

    private func show(_ diagnostics: [Diagnostic], range: NSRange, index: Int) {
        guard textView.window != nil, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        // Anchor on the part of the range that lies on the hovered line fragment.
        let glyph = lm.glyphIndexForCharacter(at: index)
        var fragmentGlyphs = NSRange(location: 0, length: 0)
        lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
        let rangeGlyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let onLine = NSIntersectionRange(rangeGlyphs, fragmentGlyphs)
        var rect = lm.boundingRect(forGlyphRange: onLine.length > 0 ? onLine : NSRange(location: glyph, length: 1), in: tc)
        rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        shownRange = range
        presenter.show(diagnostics, relativeTo: rect, of: textView, transient: false, edge: .maxY)
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        candidate = nil
        shownRange = nil
        if presenter.isShown { presenter.close(animated: false) }
    }
}

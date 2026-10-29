import AppKit
import TeXCore

/// Programmatic navigation: `reveal` (caret + vertical centering + the soft "flash" highlight) and
/// the centering helpers shared with `EditorController.goTo`.
extension LaTeXTextView {
    // MARK: - Public API

    /// Moves the caret to the start of `range`, scrolls it to the vertical center of the editor and, if
    /// `flash` is true, shows a soft accent-colored rounded highlight behind `range` that fades out in
    /// ~1.2 s (shown ~0.8 s without animation when Reduce Motion is on).
    ///
    /// - The text, the undo history and the buffer's dirty state are never touched; the highlight is
    ///   pure drawing and follows scrolling and re-layout while it fades.
    /// - Only one flash exists at a time: a new `reveal`, `goTo`, a buffer swap, any character edit or
    ///   removing the view from its window cancels the running one.
    /// - The range is clamped to the text. Leading/trailing whitespace and line breaks are not
    ///   highlighted. An empty range highlights the content of its line instead; a range that starts
    ///   past the end of the text only moves the caret to the end (nothing sensible to highlight).
    /// - The horizontal scroll offset is preserved (macOS 26 offsets the clip view for the floating
    ///   line-number ruler); only a target outside the visible columns of a non-wrapping editor moves it.
    public func reveal(_ range: NSRange, flash: Bool = true) {
        guard buffer != nil, let storage = textStorage else { return }
        let clamped = range.clamped(to: storage.length)
        var target: NSRange?
        if flash, range.location <= storage.length {
            target = clamped.length > 0 ? flashRange(trimming: clamped) : flashRange(forLineContaining: clamped.location)
        }
        reveal(caret: clamped.location, flashRange: target)
    }

    /// The range currently highlighted by the reveal flash (including while it fades), nil when none.
    public var flashedRange: NSRange? { revealFlash.range }

    /// Strength of the running flash: 1 while held, easing to 0 as it fades; 0 when there is none.
    public var flashIntensity: Double { revealFlash.intensity }

    /// The word (letters, digits, combining marks) at or right before a UTF-16 offset of the shown buffer,
    /// with its range; `\command` gives the command name without the backslash. See `EditorController.word(at:)`.
    public func word(at offset: Int) -> (word: String, range: NSRange)? {
        guard buffer != nil, let storage = textStorage else { return nil }
        return TextScan.word(at: offset, in: storage.mutableString)
    }

    // MARK: - Shared implementation

    /// Caret + centering + optional flash. `flashRange` must already be clamped/trimmed.
    func reveal(caret: Int, flashRange: NSRange?) {
        guard buffer != nil, let storage = textStorage else { return }
        revealFlash.cancel()
        var offset = max(0, min(caret, storage.length))
        if offset > 0, offset < storage.length {
            offset = storage.mutableString.rangeOfComposedCharacterSequence(at: offset).location
        }
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: offset, length: 0))
        centerLine(containing: offset)
        revealSerial &+= 1
        if let flashRange, flashRange.length > 0 { revealFlash.start(range: flashRange) }
        scheduleRevealSettle(serial: revealSerial, caret: offset)
    }

    /// `range` without leading/trailing whitespace and line breaks (nil if nothing is left).
    func flashRange(trimming range: NSRange) -> NSRange? {
        guard let text = textStorage?.mutableString else { return nil }
        let clamped = range.clamped(to: text.length)
        var start = clamped.location
        var end = clamped.end
        while start < end, TextScan.isWhitespace(text.character(at: start)) { start += 1 }
        while end > start, TextScan.isWhitespace(text.character(at: end - 1)) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// The content (without indentation, trailing blanks and terminator) of the line holding `offset`.
    func flashRange(forLineContaining offset: Int) -> NSRange? {
        guard let text = textStorage?.mutableString else { return nil }
        let line = lineTable.lineIndex(containing: offset)
        return flashRange(trimming: lineTable.contentsRange(ofLine: line, in: text))
    }

    /// A moment after a jump the geometry may still change (the split view settling, a just-attached
    /// buffer): if the caret ended up out of sight and nobody moved it, center it again.
    private func scheduleRevealSettle(serial: Int, caret: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, self.revealSerial == serial, self.buffer != nil,
                  self.selectedRange() == NSRange(location: caret, length: 0) else { return }
            if !self.isLineVisible(containing: caret) { self.centerLine(containing: caret) }
        }
    }

    // MARK: - Centering

    /// The rect (text container coordinates) of the line fragment holding `offset`.
    private func lineFragmentRect(containing offset: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        if offset >= storage.length, lm.extraLineFragmentTextContainer != nil || storage.length == 0 {
            lm.ensureLayout(for: tc)
            return lm.extraLineFragmentRect
        }
        guard storage.length > 0 else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: min(offset, storage.length - 1))
        lm.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(glyph + 1, lm.numberOfGlyphs)))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Scrolls so that the line containing `offset` is vertically centered in the unobscured part of the
    /// clip view (honouring content insets such as a toolbar or the floating ruler). The clip view's
    /// horizontal origin is kept — it is negative on macOS 26 when the ruler floats over the text — and a
    /// caret outside the visible columns of a non-wrapping editor is brought into view.
    func centerLine(containing offset: Int) {
        guard let scroll = enclosingScrollView, let rect = lineFragmentRect(containing: offset) else {
            scrollRangeToVisible(NSRange(location: offset, length: 0))
            return
        }
        let origin = textContainerOrigin
        let lineRect = rect.offsetBy(dx: origin.x, dy: origin.y)
        if lineRect.maxY + textContainerInset.height > frame.height { sizeToFitContent() }

        let clip = scroll.contentView
        let visible = clip.bounds
        let insets = clip.contentInsets
        let target = lineRect.midY - (visible.height + insets.top - insets.bottom) / 2
        let proposed = clip.constrainBoundsRect(NSRect(x: visible.origin.x, y: target, width: visible.width, height: visible.height))
        clip.scroll(to: NSPoint(x: visible.origin.x, y: proposed.origin.y))
        scroll.reflectScrolledClipView(clip)

        if !configuration.wrapLines, let columnRect = characterColumnRect(at: offset) {
            // Keep clear of the line-number ruler that may float over the left edge of the text.
            let margin: CGFloat = 24
            let ruler = scroll.hasVerticalRuler && scroll.rulersVisible ? (scroll.verticalRulerView?.requiredThickness ?? 0) : 0
            let left = max(insets.left, ruler)
            scrollToVisible(NSRect(x: columnRect.minX - margin - left, y: lineRect.minY,
                                   width: columnRect.width + margin * 2 + left, height: lineRect.height))
        }
    }

    /// Horizontal extent (view coordinates) of the character at `offset` (the end of the text → its end).
    private func characterColumnRect(at offset: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let char = min(offset, storage.length - 1)
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: char, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var bounds = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        if offset >= storage.length { bounds.origin.x = bounds.maxX; bounds.size.width = 0 }
        return bounds.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// True when the line holding `offset` lies fully inside the unobscured part of the clip view
    /// (vertically; the horizontal position does not matter here).
    private func isLineVisible(containing offset: Int) -> Bool {
        guard let scroll = enclosingScrollView, let rect = lineFragmentRect(containing: offset) else { return true }
        let clip = scroll.contentView
        let insets = clip.contentInsets
        let visible = clip.bounds
        let line = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return line.minY >= visible.minY + insets.top && line.maxY <= visible.maxY - insets.bottom
    }
}

import AppKit
import TeXCore
import VimKit

/// Completion injection point: (text, caret, project symbols) → what to offer.
public typealias CompletionProviding = (NSString, Int, ProjectSymbols) -> CompletionResult?

/// The LaTeX source editor: an `NSTextView` on an explicit **TextKit 1** stack
/// (`NSTextStorage` → `LaTeXLayoutManager` → `NSTextContainer`). It never touches `textLayoutManager`.
///
/// It shows one `SourceBuffer` at a time; `attach(_:)` swaps the buffer's text storage into the layout
/// manager, so each buffer keeps its own text, undo stack (`undoManager` is the buffer's), selection and
/// scroll position. Highlighting and diagnostics are drawn with layout-manager temporary attributes, so
/// they never register undo or make the buffer dirty.
///
/// Usually embedded through `LaTeXEditorView`; it can also be used directly (e.g. headless checks).
public final class LaTeXTextView: NSTextView {
    // MARK: Public state

    /// The buffer being edited (nil until `attach(_:)`).
    public private(set) var buffer: SourceBuffer?
    /// The applied configuration (change it with `apply(_:)`).
    public private(set) var configuration: EditorConfiguration
    /// Called after every user edit (typing, paste, undo/redo, completion, Vim command), right after
    /// `buffer.noteEdit()`. Exactly once per edit, also for multi-range edits.
    public var onTextChange: ((SourceBuffer) -> Void)?
    /// Called when the selection settles (not while dragging).
    public var onSelectionChange: ((NSRange) -> Void)?
    /// Labels, bib keys, custom commands … for completion.
    public var symbols: ProjectSymbols = .empty
    /// The pasteboard behind Vim's unnamed, `"+` and `"*` registers (default: the general pasteboard).
    public var vimPasteboard: NSPasteboard = .general
    /// Timing of the highlight shown by `reveal(_:flash:)` / `goTo(…highlight:)`. The defaults are the
    /// product behaviour (≈1.2 s fade, ≈0.8 s without animation under Reduce Motion).
    public var revealFlashOptions = RevealFlashOptions()

    // MARK: Internal state

    let tokenizer: LaTeXTokenizing
    let completionProvider: CompletionProviding
    var metrics: EditorMetrics
    private(set) var lineTable = LineTable()
    private var placeholderStorage: NSTextStorage?
    private let ownedLayoutManager: LaTeXLayoutManager
    weak var controller: EditorController?
    weak var gutter: EditorGutterView?

    lazy var highlighter = SyntaxHighlighter(textView: self, tokenize: tokenizer)
    lazy var diagnosticsRenderer = DiagnosticsRenderer(textView: self)
    lazy var completion = CompletionController(textView: self)
    lazy var hover = HoverController(textView: self)
    lazy var revealFlash = RevealFlashController(textView: self)
    /// Bumped by every `reveal` and every buffer swap; delayed follow-ups of a reveal check it.
    var revealSerial = 0
    /// True between a consumed ⌘-click (Show in PDF, open reference…) and its mouse-up: the drag that
    /// follows must not start a selection.
    var swallowsMouseUntilUp = false
    var vim: VimAdapter?
    var snippetSession: SnippetSession?
    /// Offsets of closing characters inserted by auto-pairing (type-over / pair-delete only applies to them).
    var autoClosers: [Int] = []
    var hoverTrackingArea: NSTrackingArea?

    /// Edits inside `batchEdits` are reported once at the end.
    private var batchDepth = 0
    private var batchHadEdit = false
    private var lastCurrentLineRect: NSRect = .zero
    private var tokenCache: [UUID: CachedTokens] = [:]
    /// Edit-tracked diagnostic anchors of buffers that are not shown (see `DiagnosticsSnapshot`).
    private var diagnosticsCache: [UUID: DiagnosticsSnapshot] = [:]
    private var scrollAnchors: [UUID: ScrollAnchor] = [:]
    private var lastReportedSelection = NSRange(location: NSNotFound, length: 0)
    private var userTypingDepth = 0

    private struct CachedTokens {
        var changeCount: Int
        var length: Int
        var tokens: [LaTeXToken]
    }

    private struct ScrollAnchor {
        var changeCount: Int
        var characterIndex: Int
        var offsetFromLineTop: CGFloat
    }

    // MARK: Defaults

    /// The default tokenizer (`TeXCore.LaTeXTokenizer`).
    public nonisolated static let defaultTokenizer: LaTeXTokenizing = { LaTeXTokenizer().tokenize($0) }
    /// The default completion provider (`TeXCore.CompletionEngine`).
    public static let defaultCompletionProvider: CompletionProviding = { text, caret, symbols in
        CompletionEngine.complete(text: text, cursor: caret, symbols: symbols)
    }

    // MARK: Init

    /// Creates an editor with its own TextKit 1 stack. `tokenizer` and `completionProvider` are
    /// injectable for tests.
    public init(
        configuration: EditorConfiguration = EditorConfiguration(),
        tokenizer: @escaping LaTeXTokenizing = LaTeXTextView.defaultTokenizer,
        completionProvider: @escaping CompletionProviding = LaTeXTextView.defaultCompletionProvider
    ) {
        let storage = NSTextStorage()
        let layoutManager = LaTeXLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 6
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        self.configuration = configuration
        self.metrics = EditorMetrics(configuration: configuration)
        self.tokenizer = tokenizer
        self.completionProvider = completionProvider
        self.ownedLayoutManager = layoutManager
        self.placeholderStorage = storage
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        commonSetup()
        applyConfiguration(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LaTeXTextView is not decodable")
    }

    private func commonSetup() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        allowsDocumentBackgroundColorChange = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 2, height: 10)
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isGrammarCheckingEnabled = false
        displaysLinkToolTips = false
        layoutManager?.allowsNonContiguousLayout = true
        delegate = spellingDelegate
        setAccessibilityLabel(String(localized: "LaTeX source"))
    }

    private lazy var spellingDelegate = TextViewDelegateProxy(textView: self)

    // MARK: - Undo

    /// Each buffer has its own undo stack.
    public override var undoManager: UndoManager? {
        buffer?.undoManager ?? super.undoManager
    }

    // MARK: - Typing attributes

    /// Uniform attributes of the whole text (font, paragraph style, color). Colors from highlighting are
    /// temporary attributes on top.
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: metrics.font, .paragraphStyle: metrics.paragraphStyle, .foregroundColor: NSColor.textColor]
    }

    public override var typingAttributes: [NSAttributedString.Key: Any] {
        get { baseAttributes }
        set { /* plain-text editor: attributes are uniform */ }
    }

    // MARK: - Buffers

    /// Shows `buffer`: saves the selection/scroll of the current one, swaps the text storage into the
    /// layout manager, restores the new buffer's selection and scroll position and re-highlights.
    /// `diagnostics` must already be filtered for `buffer.url`.
    public func attach(_ newBuffer: SourceBuffer, diagnostics: [Diagnostic] = []) {
        if newBuffer === buffer {
            setDiagnostics(diagnostics)
            return
        }
        detachCurrentBuffer()
        guard let layoutManager else { return }
        buffer = newBuffer
        let storage = newBuffer.textStorage
        layoutManager.replaceTextStorage(storage)
        placeholderStorage = nil
        storage.delegate = self
        lineTable.rebuild(storage.mutableString)
        applyBaseAttributes()
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.setTemporaryAttributes([:], forCharacterRange: full)

        var cached: [LaTeXToken]?
        if let entry = tokenCache[newBuffer.id], entry.changeCount == newBuffer.changeCount, entry.length == storage.length {
            cached = entry.tokens
        }
        tokenCache[newBuffer.id] = nil
        highlighter.reset(cachedTokens: cached)
        diagnosticsRenderer.reset()
        // Same text as when it was detached: its underlines keep the places they were tracked to (the
        // diagnostics' own line/column went stale with every edit made meanwhile).
        if let snapshot = diagnosticsCache.removeValue(forKey: newBuffer.id),
           snapshot.changeCount == newBuffer.changeCount, snapshot.length == storage.length {
            diagnosticsRenderer.restore(snapshot)
        }
        diagnosticsRenderer.setDiagnostics(diagnostics)

        let selection = newBuffer.savedSelection.clamped(to: storage.length)
        super.setSelectedRanges([NSValue(range: selection)], affinity: .downstream, stillSelecting: false)
        restoreScroll(for: newBuffer)
        lastCurrentLineRect = .zero
        lastReportedSelection = NSRange(location: NSNotFound, length: 0)
        selectionDidSettle()
        gutter?.lineCountDidChange()
        gutter?.needsDisplay = true
        needsDisplay = true
    }

    /// Stops showing the current buffer (saving its selection and scroll position).
    public func detachCurrentBuffer() {
        guard let old = buffer else { return }
        if hasMarkedText() { unmarkText() }
        breakUndoCoalescing()
        completion.dismiss()
        hover.dismiss()
        endSnippetSession()
        autoClosers = []
        revealFlash.cancel()
        revealSerial &+= 1
        old.savedSelection = selectedRange()
        old.savedScrollY = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        if let anchor = currentScrollAnchor() {
            scrollAnchors[old.id] = ScrollAnchor(changeCount: old.changeCount, characterIndex: anchor.0,
                                                 offsetFromLineTop: anchor.1)
        }
        if !highlighter.isTokenizingInBackground {
            tokenCache[old.id] = CachedTokens(changeCount: old.changeCount, length: old.textStorage.length,
                                              tokens: highlighter.tokens)
        }
        if tokenCache.count > 24, let victim = tokenCache.keys.first(where: { $0 != old.id }) {
            tokenCache[victim] = nil
        }
        diagnosticsCache[old.id] = diagnosticsRenderer.snapshot(changeCount: old.changeCount, length: old.textStorage.length)
        if diagnosticsCache.count > 24, let victim = diagnosticsCache.keys.first(where: { $0 != old.id }) {
            diagnosticsCache[victim] = nil
        }
        if old.textStorage.delegate === self { old.textStorage.delegate = nil }
        let blank = NSTextStorage()
        placeholderStorage = blank
        layoutManager?.replaceTextStorage(blank)
        buffer = nil
        lineTable.rebuild(blank.mutableString)
        highlighter.reset(cachedTokens: [])
        diagnosticsRenderer.reset()
    }

    /// Forgets cached state of a buffer that was closed.
    public func forget(_ closed: SourceBuffer) {
        tokenCache[closed.id] = nil
        scrollAnchors[closed.id] = nil
        diagnosticsCache[closed.id] = nil
    }

    private func applyBaseAttributes() {
        guard let storage = textStorage, storage.length > 0 else { return }
        // Re-attaching a buffer whose attributes are already uniform must not invalidate its layout.
        let full = NSRange(location: 0, length: storage.length)
        var run = NSRange(location: 0, length: 0)
        let current = storage.attributes(at: 0, longestEffectiveRange: &run, in: full)
        if run == full, current.count == 3, (current[.font] as? NSFont) == metrics.font,
           (current[.paragraphStyle] as? NSParagraphStyle) == metrics.paragraphStyle,
           (current[.foregroundColor] as? NSColor) == NSColor.textColor {
            return
        }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    // MARK: - Scroll position

    private func currentScrollAnchor() -> (Int, CGFloat)? {
        guard let scroll = enclosingScrollView, let lm = layoutManager, let tc = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let top = scroll.contentView.bounds.origin.y - textContainerOrigin.y
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, top)), in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        let lineStart = lineTable.startOfLine(lineTable.lineIndex(containing: char))
        let lineGlyph = lm.glyphIndexForCharacter(at: lineStart)
        let rect = lm.lineFragmentRect(forGlyphAt: lineGlyph, effectiveRange: nil)
        return (lineStart, top - rect.minY)
    }

    private func restoreScroll(for buffer: SourceBuffer) {
        guard let scroll = enclosingScrollView, let lm = layoutManager, let tc = textContainer,
              let storage = textStorage else { return }
        var y = buffer.savedScrollY
        if let anchor = scrollAnchors[buffer.id], anchor.changeCount == buffer.changeCount,
           anchor.characterIndex <= storage.length {
            let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: anchor.characterIndex, length: 0),
                                           actualCharacterRange: nil)
            lm.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(glyphRange.location + 1, lm.numberOfGlyphs)))
            if anchor.characterIndex < storage.length {
                let rect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                y = rect.minY + textContainerOrigin.y + anchor.offsetFromLineTop
            }
        } else {
            let visibleHeight = scroll.contentView.bounds.height
            lm.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: tc.size.width, height: y + visibleHeight * 2), in: tc)
        }
        sizeToFitContent()
        let maxY = max(0, frame.height - scroll.contentView.bounds.height)
        // Keep the clip view's horizontal origin: on macOS 26+ the vertical ruler floats over the content
        // and AppKit offsets the clip bounds (negative x) to make room for it; forcing x = 0 slid the text
        // under the gutter after every buffer switch.
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: max(0, min(y, maxY))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func sizeToFitContent() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let used = lm.usedRect(for: tc)
        let height = ceil(used.maxY + textContainerInset.height * 2)
        let minHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let newHeight = max(height, minHeight)
        if abs(frame.height - newHeight) > 0.5 { setFrameSize(NSSize(width: frame.width, height: newHeight)) }
    }

    // MARK: - Configuration

    /// Applies a configuration (font, metrics, wrapping, spell checking, Vim …). Cheap when unchanged.
    public func apply(_ newConfiguration: EditorConfiguration) {
        guard newConfiguration != configuration else { return }
        let old = configuration
        configuration = newConfiguration
        applyConfiguration(force: false, previous: old)
    }

    private func applyConfiguration(force: Bool, previous: EditorConfiguration? = nil) {
        let layoutChanged = force || (previous.map { configuration.affectsLayout(comparedTo: $0) } ?? true)
        if layoutChanged {
            metrics = EditorMetrics(configuration: configuration)
            ownedLayoutManager.metrics.lineHeight = metrics.lineHeight
            ownedLayoutManager.metrics.baselineOffset = metrics.baselineOffset
            font = metrics.font
            applyBaseAttributes()
            applyWrapping()
            gutter?.metricsDidChange()
        }
        isContinuousSpellCheckingEnabled = configuration.spellChecking
        isGrammarCheckingEnabled = false
        if force || previous?.vimMode != configuration.vimMode {
            setVimEnabled(configuration.vimMode)
        }
        vim?.engine.indentUnit = configuration.indentUnit
        if !configuration.autoCompletion { completion.cancelPendingTrigger() }
        gutter?.configurationDidChange()
        needsDisplay = true
    }

    private func applyWrapping() {
        guard let tc = textContainer else { return }
        if configuration.wrapLines {
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            tc.widthTracksTextView = true
            let width = enclosingScrollView?.contentSize.width ?? frame.width
            setFrameSize(NSSize(width: width, height: frame.height))
            tc.size = NSSize(width: max(1, width - textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
            enclosingScrollView?.hasHorizontalScroller = false
        } else {
            tc.widthTracksTextView = false
            tc.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            isHorizontallyResizable = true
            autoresizingMask = []
            enclosingScrollView?.hasHorizontalScroller = true
        }
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyWrapping()
    }

    /// Re-applies the geometry that depends on the enclosing scroll view.
    func applyLayoutAfterEmbedding() {
        applyWrapping()
        gutter?.metricsDidChange()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Dynamic colors resolve at draw time; only cached CGColors (none) would need refreshing.
        gutter?.needsDisplay = true
        needsDisplay = true
    }

    // MARK: - Edit batching & notification

    /// Runs `body`; text changes made inside are reported (`noteEdit` + `onTextChange`) once at the end.
    func batchEdits(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        if batchDepth == 0, batchHadEdit {
            batchHadEdit = false
            reportEdit()
        }
    }

    public override func didChangeText() {
        super.didChangeText()
        isInsideTextViewEdit = false
        if snippetSession?.hasMirrors == true {
            // Mirror updates belong to this edit: report them together with it.
            let outerDepth = batchDepth
            batchDepth += 1
            syncSnippetMirrors()
            batchDepth -= 1
            if outerDepth == 0 { batchHadEdit = false }
        }
        highlighter.flush()
        if batchDepth > 0 {
            batchHadEdit = true
        } else {
            reportEdit()
        }
        completion.textDidChange(byTyping: userTypingDepth > 0)
    }

    private func reportEdit() {
        guard let buffer else { return }
        buffer.noteEdit()
        onTextChange?(buffer)
    }

    /// Marks the duration of a keystroke typed by the user (enables completion auto-trigger).
    func userTyping(_ body: () -> Void) {
        userTypingDepth += 1
        body()
        userTypingDepth -= 1
    }

    // MARK: - Storage edits

    /// Called from the text storage delegate for every character edit (user, undo, programmatic, reload).
    fileprivate func storageDidEdit(range editedRange: NSRange, delta: Int) {
        guard let storage = textStorage else { return }
        let text = storage.mutableString
        let oldLineCount = lineTable.lineCount
        lineTable.update(text, editedRange: editedRange, delta: delta)
        let firstLine = lineTable.lineIndex(containing: editedRange.location)
        let lastLine = lineTable.lineIndex(containing: editedRange.end)
        let dirtyStart = lineTable.startOfLine(firstLine)
        let dirtyEnd = lineTable.endOfLineIncludingTerminator(lastLine)
        highlighter.noteEdit(editedRange: editedRange, delta: delta,
                             dirtyLines: NSRange(location: dirtyStart, length: dirtyEnd - dirtyStart))
        diagnosticsRenderer.noteEdit(editedRange: editedRange, delta: delta)
        // The flash highlights text that no longer exists in that form; it only draws, so just drop it
        // (rects are remembered, no layout is touched inside the storage callback).
        if revealFlash.isActive { revealFlash.cancel() }
        if let session = snippetSession, !session.noteEdit(editedRange: editedRange, delta: delta) {
            snippetSession = nil
        }
        adjustAutoClosers(editedRange: editedRange, delta: delta)
        if lineTable.lineCount != oldLineCount { gutter?.lineCountDidChange() }
        gutter?.needsDisplay = true
        if batchDepth == 0, userTypingDepth == 0, !isInsideTextViewEdit {
            // An edit that did not go through the text view (e.g. `SourceBuffer.reload`): finish it later.
            scheduleExternalEditFlush()
        }
    }

    /// True between `shouldChangeText` and `didChangeText` (edits made through the text view).
    private var isInsideTextViewEdit = false
    private var externalFlushScheduled = false

    public override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let allowed = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if allowed { isInsideTextViewEdit = true }
        return allowed
    }

    private func scheduleExternalEditFlush() {
        guard !externalFlushScheduled else { return }
        externalFlushScheduled = true
        breakUndoCoalescing()
        Task { [weak self] in
            guard let self else { return }
            self.externalFlushScheduled = false
            self.highlighter.flush()
            self.diagnosticsRenderer.remap()
            self.selectionDidSettle()
        }
    }

    // MARK: - Selection

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateCurrentLineHighlight()
        if !stillSelecting { selectionDidSettle() }
    }

    private func selectionDidSettle() {
        let selection = selectedRange()
        guard selection != lastReportedSelection else { return }
        lastReportedSelection = selection
        if let session = snippetSession, !session.contains(selection) { endSnippetSession() }
        pruneAutoClosers(for: selection)
        completion.selectionDidChange()
        hover.dismiss()
        if let controller, buffer != nil {
            let line = lineTable.lineIndex(containing: selection.location)
            let column = selection.location - lineTable.startOfLine(line) + 1
            let position = SourcePosition(line: line + 1, column: column)
            if controller.cursor != position { controller.cursor = position }
            if controller.selectionLength != selection.length { controller.selectionLength = selection.length }
        }
        gutter?.needsDisplay = true
        onSelectionChange?(selection)
    }

    // MARK: - Drawing: current line & snippet placeholders

    /// The rect (view coordinates) of the logical line holding the caret, or nil.
    func currentLineRect() -> NSRect? {
        guard configuration.highlightCurrentLine, let lm = layoutManager, let storage = textStorage else { return nil }
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let lineIndex = lineTable.lineIndex(containing: selection.location)
        let content = lineTable.contentsRange(ofLine: lineIndex, in: storage.mutableString)
        let origin = textContainerOrigin
        var rect: NSRect
        if content.location >= storage.length {
            // empty last line
            if lm.extraLineFragmentTextContainer != nil {
                rect = lm.extraLineFragmentRect
            } else if storage.length == 0 {
                rect = NSRect(x: 0, y: 0, width: bounds.width, height: metrics.lineHeight)
            } else {
                return nil
            }
        } else {
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: content.location, length: max(1, content.length)),
                                       actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            let first = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil, withoutAdditionalLayout: true)
            let last = lm.lineFragmentRect(forGlyphAt: glyphs.location + glyphs.length - 1, effectiveRange: nil,
                                           withoutAdditionalLayout: true)
            rect = first.union(last)
        }
        guard rect.height > 0 else { return nil }
        return NSRect(x: 0, y: rect.minY + origin.y, width: bounds.width, height: rect.height)
    }

    private func updateCurrentLineHighlight() {
        let newRect = currentLineRect() ?? .zero
        guard newRect != lastCurrentLineRect else { return }
        if !lastCurrentLineRect.isEmpty { setNeedsDisplay(lastCurrentLineRect, avoidAdditionalLayout: true) }
        if !newRect.isEmpty { setNeedsDisplay(newRect, avoidAdditionalLayout: true) }
        lastCurrentLineRect = newRect
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let line = currentLineRect(), line.intersects(rect) {
            EditorTheme.currentLine.setFill()
            line.intersection(rect).fill(using: .sourceOver)
            if lastCurrentLineRect != line { lastCurrentLineRect = line }
        }
        revealFlash.draw(in: rect)
        drawSnippetPlaceholders(in: rect)
    }

    private func drawSnippetPlaceholders(in dirtyRect: NSRect) {
        guard let session = snippetSession, let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        var ranges = session.stops.enumerated().filter { $0.offset != session.currentIndex }.map(\.element)
        ranges += session.mirrors.flatMap { $0 }
        let length = textStorage?.length ?? 0
        for stop in ranges where stop.length > 0 && stop.end <= length {
            let glyphs = lm.glyphRange(forCharacterRange: stop, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: tc) { rect, _ in
                var r = rect.offsetBy(dx: origin.x, dy: origin.y)
                r = r.insetBy(dx: -1, dy: 1)
                guard r.intersects(dirtyRect) else { return }
                EditorTheme.snippetPlaceholder.setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    // MARK: - Drawing: block caret (Vim)

    var usesBlockCaret: Bool { vim?.wantsBlockCaret ?? false }

    public override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard usesBlockCaret else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        let block = blockCaretRect(baseRect: rect)
        if flag {
            EditorTheme.blockCaret.setFill()
            NSBezierPath(roundedRect: block, xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            setNeedsDisplay(block.insetBy(dx: -1, dy: -1), avoidAdditionalLayout: true)
        }
    }

    private func blockCaretRect(baseRect: NSRect) -> NSRect {
        var width = metrics.spaceWidth
        if let lm = layoutManager, let tc = textContainer, let storage = textStorage {
            let caret = selectedRange().location
            if caret < storage.length {
                let c = storage.mutableString.character(at: caret)
                if !TextScan.isLineBreak(c) {
                    let composed = storage.mutableString.rangeOfComposedCharacterSequence(at: caret)
                    let glyphs = lm.glyphRange(forCharacterRange: composed, actualCharacterRange: nil)
                    let bounds = lm.boundingRect(forGlyphRange: glyphs, in: tc)
                    if bounds.width > 1 { width = bounds.width }
                    if c == TextScan.tab { width = max(width, metrics.spaceWidth) }
                }
            }
        }
        let font = metrics.font
        let height = ceil(font.ascender - font.descender) + 2
        let y = baseRect.midY - height / 2
        return NSRect(x: baseRect.minX, y: y.rounded(.down), width: ceil(width), height: height)
    }

    public override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        if usesBlockCaret, rect.width < metrics.font.pointSize * 3 {
            rect.size.width += metrics.font.pointSize * 2.5
        }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    // MARK: - Highlighting support

    public override func viewWillDraw() {
        if highlighter.hasDirtyRegions, let visible = visibleCharacterRange(marginScreens: 0.5) {
            highlighter.ensureColored(visible)
        }
        super.viewWillDraw()
    }

    /// Characters in the visible rect extended by `marginScreens` screen heights above and below.
    func visibleCharacterRange(marginScreens: CGFloat) -> NSRange? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var rect = visibleRect
        if rect.isEmpty || rect.height > 4_000 {
            // headless or not yet in a scroll view: a reasonable window from the top of the visible area
            rect = NSRect(x: rect.minX, y: rect.minY, width: max(rect.width, 400), height: min(max(rect.height, 600), 4_000))
        }
        let margin = rect.height * marginScreens
        rect = rect.insetBy(dx: 0, dy: -margin)
        rect.origin.x = 0
        rect.size.width = max(tc.size.width < 1e7 ? tc.size.width : bounds.width, 1)
        rect.origin.y -= textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        var chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if chars.length == 0 { return nil }
        let firstLine = lineTable.lineIndex(containing: chars.location)
        let lastLine = lineTable.lineIndex(containing: chars.end)
        let start = lineTable.startOfLine(firstLine)
        chars = NSRange(location: start, length: lineTable.endOfLineIncludingTerminator(lastLine) - start)
        return chars
    }

    /// Re-colors after the diagnostics changed (gutter markers).
    func diagnosticsDidChange() {
        gutter?.needsDisplay = true
    }

    /// Brings highlighting fully up to date synchronously (tests, export).
    public func flushHighlighting() {
        highlighter.flushCompletely()
    }

    /// The current syntax tokens (UTF-16 ranges into the text).
    public var syntaxTokens: [LaTeXToken] { highlighter.tokens }

    // MARK: - Diagnostics

    /// Shows diagnostics (already filtered for the current buffer) as underlines + gutter markers.
    public func setDiagnostics(_ diagnostics: [Diagnostic]) {
        diagnosticsRenderer.setDiagnostics(diagnostics)
    }

    /// Diagnostics whose underlined range contains `offset`.
    public func diagnostics(at offset: Int) -> [Diagnostic] {
        diagnosticsRenderer.diagnostics(at: offset).map(\.diagnostic)
    }

    /// The text ranges currently underlined, with their diagnostics (follows edits).
    public var diagnosticRanges: [(diagnostic: Diagnostic, range: NSRange)] {
        diagnosticsRenderer.anchors.map { ($0.diagnostic, $0.range) }
    }

    // MARK: - Focus

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            completion.dismiss()
            hover.dismiss()
        }
        return resigned
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            completion.dismiss()
            hover.dismiss()
            revealFlash.cancel()
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

// MARK: - Text storage delegate

extension LaTeXTextView: NSTextStorageDelegate {
    public nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            self.storageDidEdit(range: editedRange, delta: delta)
        }
    }
}

/// The text view's delegate: suppresses spell checking inside LaTeX markup (commands, math,
/// references, comments, verbatim) so only prose is checked.
final class TextViewDelegateProxy: NSObject, NSTextViewDelegate {
    unowned let textView: LaTeXTextView

    init(textView: LaTeXTextView) {
        self.textView = textView
    }

    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0 else { return value }
        for token in self.textView.highlighter.tokens(intersecting: affectedCharRange) {
            switch token.kind {
            case .command, .structureCommand, .environmentName, .math, .mathCommand, .mathDelimiter,
                 .referenceArgument, .verbatim, .magicComment, .specialCharacter:
                return 0
            case .comment, .brace, .bracket:
                continue
            }
        }
        return value
    }

    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
                  toCharacterRanges newSelectedCharRanges: [NSValue]) -> [NSValue] {
        newSelectedCharRanges
    }
}

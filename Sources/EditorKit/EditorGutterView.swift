import AppKit
import TeXCore

/// The editor gutter: an `NSRulerView` with line numbers (first fragment of wrapped lines only,
/// current line emphasized, width adapting to the digit count) and diagnostic markers (one SF Symbol
/// per line, maximum severity). Clicking a marker lists the line's messages in a popover; clicking
/// (or dragging over) line numbers selects lines.
final class EditorGutterView: NSRulerView {
    weak var editor: LaTeXTextView?
    private let popover = DiagnosticPopoverPresenter()
    private var digitCount = 0
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var currentNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private var markerImages: [DiagnosticSeverity: NSImage] = [:]
    private var dragAnchorLine: Int?

    /// Width of the diagnostic marker column (always reserved so the text never shifts when
    /// diagnostics appear or disappear).
    private var markerColumnWidth: CGFloat { max(14, (editor?.metrics.font.pointSize ?? 13) + 2) }
    private let leadingPadding: CGFloat = 4
    private let trailingPadding: CGFloat = 10

    init(scrollView: NSScrollView, editor: LaTeXTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // Since macOS 14 `clipsToBounds` defaults to false and `draw(_:)` may receive a dirty rect larger
        // than the view: the ruler sits above the clip view, so without clipping its background fill
        // painted over the whole text (verified on macOS 27 — the editor showed only line numbers).
        clipsToBounds = true
        metricsDidChange()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not decodable")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var requiredThickness: CGFloat { ceil(ruleThickness) }

    // MARK: - Geometry

    func metricsDidChange() {
        let size = max(9, (editor?.metrics.font.pointSize ?? 13) - 2)
        numberFont = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        currentNumberFont = .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        markerImages = [:]
        digitCount = 0
        lineCountDidChange()
        needsDisplay = true
    }

    func configurationDidChange() {
        digitCount = 0
        lineCountDidChange()
        needsDisplay = true
    }

    /// Re-computes the thickness when the number of digits changes.
    func lineCountDidChange() {
        guard let editor else { return }
        let showNumbers = editor.configuration.showLineNumbers
        let digits = showNumbers ? max(3, String(editor.lineTable.lineCount).count) : 0
        guard digits != digitCount || ruleThickness <= 1 else { return }
        digitCount = digits
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: currentNumberFont]).width
        var thickness = leadingPadding + markerColumnWidth
        if showNumbers {
            thickness += ceil(digitWidth * CGFloat(digits)) + trailingPadding
        } else {
            thickness += 4
        }
        if abs(ruleThickness - thickness) > 0.5 {
            ruleThickness = thickness
            scrollView?.tile()
        }
    }

    // MARK: - Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        guard let editor else { return }
        let background = editor.backgroundColor
        background.setFill()
        dirtyRect.intersection(bounds).fill()

        let scale = window?.backingScaleFactor ?? 2
        let hairline = 1 / scale
        EditorTheme.gutterSeparator.setFill()
        NSRect(x: bounds.maxX - hairline, y: dirtyRect.minY, width: hairline, height: dirtyRect.height).fill()

        if let line = editor.currentLineRect() {
            let r = convert(line, from: editor)
            EditorTheme.currentLine.setFill()
            NSRect(x: 0, y: r.minY, width: bounds.width - hairline, height: r.height).fill(using: .sourceOver)
        }
        drawLines(in: dirtyRect, editor: editor, scale: scale)
    }

    private func drawLines(in dirtyRect: NSRect, editor: LaTeXTextView, scale: CGFloat) {
        guard let lm = editor.layoutManager, let tc = editor.textContainer, let storage = editor.textStorage else { return }
        let lines = editor.lineTable
        let showNumbers = editor.configuration.showLineNumbers
        let selection = editor.selectedRange()
        let selFirst = lines.lineIndex(containing: selection.location)
        var selLast = lines.lineIndex(containing: selection.end)
        if selection.length > 0, selLast > selFirst, selection.end == lines.startOfLine(selLast) { selLast -= 1 }
        let containerOrigin = editor.textContainerOrigin
        let offsetY = convert(NSPoint(x: 0, y: containerOrigin.y), from: editor).y
        let metrics = editor.metrics

        // Visible part of the text, in container coordinates.
        let visibleInEditor = convert(dirtyRect, to: editor)
        var containerRect = visibleInEditor.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        containerRect.origin.x = 0
        containerRect.size.width = max(1, min(tc.size.width, 1e6))

        var drawn: [(line: Int, top: CGFloat)] = []
        if storage.length > 0 {
            let glyphRange = lm.glyphRange(forBoundingRect: containerRect, in: tc)
            if glyphRange.length > 0 {
                lm.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, fragmentGlyphs, _ in
                    let charIndex = lm.characterIndexForGlyph(at: fragmentGlyphs.location)
                    let line = lines.lineIndex(containing: charIndex)
                    guard lines.startOfLine(line) == charIndex else { return } // wrapped continuation
                    drawn.append((line, rect.minY + offsetY))
                }
            }
        }
        if lm.extraLineFragmentTextContainer != nil {
            drawn.append((lines.lineCount - 1, lm.extraLineFragmentRect.minY + offsetY))
        } else if storage.length == 0 {
            drawn.append((0, offsetY))
        }
        guard !drawn.isEmpty else { return }
        let lowest = drawn.map(\.line).min() ?? 0
        let highest = drawn.map(\.line).max() ?? 0
        let severities = editor.diagnosticsRenderer.maxSeverityByLine(in: lowest...highest)

        let numberRight = bounds.maxX - trailingPadding
        for (line, top) in drawn {
            let baseline = align(top + metrics.baselineOffset, scale)
            if showNumbers {
                let isCurrent = line >= selFirst && line <= selLast
                let font = isCurrent ? currentNumberFont : numberFont
                let color = isCurrent ? EditorTheme.currentLineNumber : EditorTheme.lineNumber
                let string = String(line + 1) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let width = string.size(withAttributes: attributes).width
                string.draw(at: NSPoint(x: align(numberRight - width, scale), y: baseline - font.ascender),
                            withAttributes: attributes)
            }
            if let severity = severities[line], let image = markerImage(for: severity) {
                let size = image.size
                let centerY = top + metrics.lineHeight / 2
                let rect = NSRect(x: align(leadingPadding + (markerColumnWidth - size.width) / 2, scale),
                                  y: align(centerY - size.height / 2, scale),
                                  width: size.width, height: size.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    private func align(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    private func markerImage(for severity: DiagnosticSeverity) -> NSImage? {
        if let cached = markerImages[severity] { return cached }
        let pointSize = max(9, (editor?.metrics.font.pointSize ?? 13) - 2.5)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: EditorTheme.color(for: severity)))
        let image = NSImage(systemSymbolName: EditorTheme.symbolName(for: severity), accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        markerImages[severity] = image
        return image
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        markerImages = [:]
        needsDisplay = true
    }

    // MARK: - Mouse

    /// 0-based line under a point of the gutter, with its rect in gutter coordinates.
    private func line(at point: NSPoint) -> (Int, NSRect)? {
        guard let editor, let lm = editor.layoutManager, let tc = editor.textContainer, let storage = editor.textStorage else { return nil }
        let lines = editor.lineTable
        let inEditor = convert(point, to: editor)
        let containerPoint = NSPoint(x: 0, y: inEditor.y - editor.textContainerOrigin.y)
        if lm.extraLineFragmentTextContainer != nil, containerPoint.y >= lm.extraLineFragmentRect.minY {
            let r = convert(lm.extraLineFragmentRect.offsetBy(dx: 0, dy: editor.textContainerOrigin.y), from: editor)
            return (lines.lineCount - 1, r)
        }
        guard storage.length > 0 else { return (0, NSRect(x: 0, y: 0, width: bounds.width, height: editor.metrics.lineHeight)) }
        let glyph = lm.glyphIndex(for: containerPoint, in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        let line = lines.lineIndex(containing: char)
        let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: lines.startOfLine(line)), effectiveRange: nil)
        let r = convert(fragment.offsetBy(dx: 0, dy: editor.textContainerOrigin.y), from: editor)
        return (line, NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let (line, rect) = line(at: point) else { return }
        let diagnostics = editor.diagnosticsRenderer.diagnostics(onLine: line)
        if !diagnostics.isEmpty, point.x <= leadingPadding + markerColumnWidth + 4 || !editor.configuration.showLineNumbers {
            let marker = NSRect(x: leadingPadding, y: rect.minY, width: markerColumnWidth, height: rect.height)
            popover.show(diagnostics, relativeTo: marker, of: self, transient: true, edge: .maxX)
            return
        }
        popover.close(animated: false)
        if event.modifierFlags.contains(.shift) {
            let selection = editor.selectedRange()
            let anchorLine = editor.lineTable.lineIndex(containing: selection.location)
            dragAnchorLine = anchorLine
            selectLines(from: anchorLine, to: line)
        } else {
            dragAnchorLine = line
            selectLines(from: line, to: line)
        }
        editor.window?.makeFirstResponder(editor)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchorLine else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let (line, _) = line(at: point) else { return }
        selectLines(from: anchor, to: line)
        editor?.autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchorLine = nil
    }

    private func selectLines(from a: Int, to b: Int) {
        guard let editor else { return }
        let lines = editor.lineTable
        let first = min(a, b), last = max(a, b)
        let start = lines.startOfLine(first)
        let end = lines.endOfLineIncludingTerminator(last)
        editor.setSelectedRange(NSRange(location: start, length: end - start))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

import AppKit

extension NSAttributedString.Key {
    /// Temporary attribute marking a diagnostic underline; value: `DiagnosticSeverity.rawValue` (Int).
    nonisolated static let editorDiagnosticSeverity = NSAttributedString.Key("io.github.gabe-rbo.GabeTeX.diagnosticSeverity")
}

/// TextKit 1 layout manager of the editor.
///
/// - Draws real wavy underlines ("squiggles") for ranges carrying the `.editorDiagnosticSeverity`
///   temporary attribute (errors/warnings), and a soft dotted line for info/bad-box diagnostics.
/// - Owns the `LineMetricsDelegate` that gives every line fragment the same height with the text
///   vertically centered, so lines never jump when an emoji or fallback glyph appears and the gutter
///   numbers align on exact baselines.
nonisolated final class LaTeXLayoutManager: NSLayoutManager {
    let metrics = LineMetricsDelegate()

    override init() {
        super.init()
        delegate = metrics
        allowsNonContiguousLayout = true
        usesFontLeading = false
        showsInvisibleCharacters = false
        showsControlCharacters = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func drawUnderline(
        forGlyphRange glyphRange: NSRange,
        underlineType: NSUnderlineStyle,
        baselineOffset: CGFloat,
        lineFragmentRect: NSRect,
        lineFragmentGlyphRange: NSRange,
        containerOrigin: NSPoint
    ) {
        let charIndex = characterIndexForGlyph(at: glyphRange.location)
        guard let severityValue = temporaryAttribute(.editorDiagnosticSeverity, atCharacterIndex: charIndex,
                                                     effectiveRange: nil) as? Int,
              let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else {
            super.drawUnderline(forGlyphRange: glyphRange, underlineType: underlineType, baselineOffset: baselineOffset,
                                lineFragmentRect: lineFragmentRect, lineFragmentGlyphRange: lineFragmentGlyphRange,
                                containerOrigin: containerOrigin)
            return
        }
        let color = (temporaryAttribute(.underlineColor, atCharacterIndex: charIndex, effectiveRange: nil) as? NSColor)
            ?? .systemRed
        // Horizontal extent of the run, without a trailing line terminator.
        var range = glyphRange
        while range.length > 0, let text = textStorage?.mutableString {
            let lastChar = characterIndexForGlyph(at: range.location + range.length - 1)
            guard lastChar < text.length else { break }
            let c = text.character(at: lastChar)
            if c == 10 || c == 13 { range.length -= 1 } else { break }
        }
        guard range.length > 0 else { return }
        let bounds = boundingRect(forGlyphRange: range, in: container)
        let minX = bounds.minX + containerOrigin.x
        let maxX = max(minX + 2, bounds.maxX + containerOrigin.x)
        let baseline = lineFragmentRect.minY + location(forGlyphAt: range.location).y + containerOrigin.y
        let bottom = lineFragmentRect.maxY + containerOrigin.y
        let amplitude: CGFloat = 1.3
        let y = min(baseline + 2.6, bottom - amplitude - 0.5)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        color.setStroke()
        let path = NSBezierPath()
        if severityValue >= 2 {
            // squiggle
            let halfPeriod: CGFloat = 2.25
            var x = minX
            var up = true
            path.move(to: NSPoint(x: x, y: y))
            while x < maxX {
                let next = min(x + halfPeriod, maxX)
                let peak = up ? y - amplitude : y + amplitude
                path.curve(to: NSPoint(x: next, y: y),
                           controlPoint1: NSPoint(x: x + (next - x) * 0.35, y: peak),
                           controlPoint2: NSPoint(x: x + (next - x) * 0.65, y: peak))
                x = next
                up.toggle()
            }
            path.lineWidth = 1.1
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
        } else {
            path.move(to: NSPoint(x: minX, y: y))
            path.line(to: NSPoint(x: maxX, y: y))
            path.lineWidth = 1.2
            path.lineCapStyle = .round
            path.setLineDash([0.01, 3], count: 2, phase: 0)
        }
        path.stroke()
    }
}

/// Uniform line fragments: fixed height, centered baseline (see `EditorMetrics`).
nonisolated final class LineMetricsDelegate: NSObject, NSLayoutManagerDelegate {
    /// 0 disables the adjustment.
    var lineHeight: CGFloat = 0
    var baselineOffset: CGFloat = 0

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard lineHeight > 0 else { return false }
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = self.baselineOffset
        return true
    }
}

import AppKit
import TeXCore

/// Maps a `Diagnostic` (1-based line, optional 1-based UTF-16 column/length) to a range of the text.
public enum DiagnosticRangeMapper {
    /// The text range a diagnostic underlines:
    /// - with `column` and `length`: exactly that span (snapped to composed characters);
    /// - with `column` only: the token at the column (a `\command`, a word, or one character);
    ///   a column past the end of the line underlines the line's last character;
    /// - without `column`: the whole line without leading/trailing whitespace.
    ///
    /// Returns nil when the line does not exist; an empty range (at the line start) for blank lines.
    public static func range(for diagnostic: Diagnostic, in text: NSString) -> NSRange? {
        range(for: diagnostic, in: text, lines: LineTable(text))
    }

    static func range(for diagnostic: Diagnostic, in text: NSString, lines: LineTable) -> NSRange? {
        guard let line = diagnostic.line, line >= 1, line <= lines.lineCount else { return nil }
        let content = lines.contentsRange(ofLine: line - 1, in: text)
        guard let column = diagnostic.column, column >= 1 else {
            let lead = TextScan.leadingWhitespaceLength(in: content, of: text)
            var end = content.end
            while end > content.location + lead, TextScan.isHorizontalSpace(text.character(at: end - 1)) { end -= 1 }
            return NSRange(location: content.location + lead, length: end - content.location - lead)
        }
        var start = min(content.location + column - 1, content.end)
        if start < content.end {
            start = max(content.location, text.rangeOfComposedCharacterSequence(at: start).location)
        }
        if let length = diagnostic.length, length > 0 {
            let end = min(start + length, text.length)
            guard end > start else { return NSRange(location: start, length: 0) }
            let snapped = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
            return snapped.clamped(to: text.length)
        }
        if start >= content.end {
            guard content.length > 0 else { return NSRange(location: content.location, length: 0) }
            return text.rangeOfComposedCharacterSequence(at: content.end - 1)
        }
        return TextScan.tokenExtent(at: start, in: text, limit: content.end)
    }
}

/// A diagnostic pinned to a text range that follows subsequent edits.
struct DiagnosticAnchor {
    var diagnostic: Diagnostic
    var range: NSRange
}

/// What a renderer knew about a buffer that is no longer shown, so its underlines keep following the
/// text when the buffer comes back (the producer's line/column go stale with every edit).
struct DiagnosticsSnapshot {
    var anchors: [DiagnosticAnchor]
    var input: [Diagnostic]
    /// `SourceBuffer.changeCount` and text length when the snapshot was taken; the snapshot is only
    /// valid while the text is still the one the anchors were tracked through.
    var changeCount: Int
    var length: Int
}

extension Diagnostic {
    /// True when `other` reports the same place (line, column, length) as this diagnostic.
    fileprivate func reportsSamePlace(as other: Diagnostic) -> Bool {
        line == other.line && column == other.column && length == other.length
    }
}

/// Renders diagnostics of the current buffer: squiggles via temporary attributes (no undo, no
/// dirtiness), anchors for the gutter markers and hover lookups.
///
/// Diagnostics carry the line/column of the moment their producer ran (TeX log, chktex, structure
/// lint). The renderer pins each one to a text range **once** and from then on moves that anchor with
/// the user's edits; later updates only map diagnostics it has not seen yet (by `id`).
final class DiagnosticsRenderer {
    unowned let textView: LaTeXTextView
    private(set) var anchors: [DiagnosticAnchor] = []
    private var input: [Diagnostic] = []
    private var hasInput = false

    init(textView: LaTeXTextView) {
        self.textView = textView
    }

    /// Replaces the diagnostics (already filtered for the current buffer). Cheap when unchanged.
    ///
    /// A diagnostic whose `id` is already anchored keeps its edit-tracked anchor (unless its producer
    /// moved it: different line/column/length); new ids are mapped from their line/column; ids that are
    /// gone lose their anchor.
    func setDiagnostics(_ diagnostics: [Diagnostic]) {
        if hasInput, diagnostics == input { return }
        var previousInput: [UUID: Diagnostic] = [:]
        for d in input { previousInput[d.id] = d }
        var kept: [UUID: NSRange] = [:]
        for anchor in anchors where kept[anchor.diagnostic.id] == nil {
            kept[anchor.diagnostic.id] = anchor.range
        }
        for d in diagnostics {
            // Producer moved the diagnostic (or never reported it before): map it afresh.
            if let old = previousInput[d.id], old.reportsSamePlace(as: d) { continue }
            kept[d.id] = nil
        }
        input = diagnostics
        hasInput = true
        rebuild(keeping: kept)
    }

    /// Forgets everything (buffer swap).
    func reset() {
        clearAttributes()
        anchors = []
        input = []
        hasInput = false
    }

    /// The tracked state, for `restore(_:)` when the buffer is shown again (nil without diagnostics).
    func snapshot(changeCount: Int, length: Int) -> DiagnosticsSnapshot? {
        guard hasInput, !anchors.isEmpty else { return nil }
        return DiagnosticsSnapshot(anchors: anchors, input: input, changeCount: changeCount, length: length)
    }

    /// Reinstates a snapshot of the same, unchanged text (call after `reset()`).
    func restore(_ snapshot: DiagnosticsSnapshot) {
        guard let storage = textView.textStorage, storage.length == snapshot.length else { return }
        clearAttributes()
        anchors = snapshot.anchors
        input = snapshot.input
        hasInput = true
        applyAttributes()
        textView.diagnosticsDidChange()
    }

    /// Re-maps **all** current diagnostics from their line/column against the current text and re-applies
    /// the underlines (after the text changed behind the editor's back, e.g. a reload from disk).
    func remap() {
        rebuild(keeping: [:])
    }

    /// Re-anchors `input`: ids in `kept` keep their (edit-tracked) range, everything else is mapped from
    /// line/column.
    private func rebuild(keeping kept: [UUID: NSRange]) {
        clearAttributes()
        guard let storage = textView.textStorage else { anchors = []; return }
        let text = storage.mutableString as NSString
        let lines = textView.lineTable
        anchors = input.compactMap { d in
            if let range = kept[d.id] { return DiagnosticAnchor(diagnostic: d, range: range.clamped(to: text.length)) }
            return DiagnosticRangeMapper.range(for: d, in: text, lines: lines).map { DiagnosticAnchor(diagnostic: d, range: $0) }
        }
        anchors.sort { ($0.range.location, $0.diagnostic.severity) < ($1.range.location, $1.diagnostic.severity) }
        applyAttributes()
        textView.diagnosticsDidChange()
    }

    private func clearAttributes() {
        guard let lm = textView.layoutManager, let storage = textView.textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        lm.removeTemporaryAttribute(.editorDiagnosticSeverity, forCharacterRange: full)
    }

    private func applyAttributes() {
        guard let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        // Lower severities first so errors win where ranges overlap.
        for anchor in anchors.sorted(by: { $0.diagnostic.severity < $1.diagnostic.severity }) {
            let r = anchor.range.clamped(to: storage.length)
            guard r.length > 0 else { continue }
            let severity = anchor.diagnostic.severity
            lm.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: EditorTheme.color(for: severity),
                .editorDiagnosticSeverity: severity.rawValue,
            ], forCharacterRange: r)
        }
    }

    /// Moves anchors through an edit (the temporary attributes move by themselves).
    func noteEdit(editedRange: NSRange, delta: Int) {
        guard !anchors.isEmpty else { return }
        let editLoc = editedRange.location
        let oldEnd = editedRange.location + editedRange.length - delta
        for i in anchors.indices {
            anchors[i].range = SnippetSession.adjust(anchors[i].range, editLoc: editLoc, oldEnd: oldEnd,
                                                     newLen: editedRange.length, delta: delta, grows: true)
        }
    }

    // MARK: - Queries

    /// Diagnostics whose underlined range contains `offset`.
    func diagnostics(at offset: Int) -> [DiagnosticAnchor] {
        anchors.filter { $0.range.length > 0 && offset >= $0.range.location && offset < $0.range.end }
    }

    /// Diagnostics whose anchor starts on the 0-based line `lineIndex`.
    func diagnostics(onLine lineIndex: Int) -> [Diagnostic] {
        let lines = textView.lineTable
        return anchors.filter { lines.lineIndex(containing: $0.range.location) == lineIndex }
            .map(\.diagnostic)
            .sorted { $0.severity > $1.severity }
    }

    /// Maximum severity per 0-based line, for lines in `lineRange`.
    func maxSeverityByLine(in lineRange: ClosedRange<Int>) -> [Int: DiagnosticSeverity] {
        var result: [Int: DiagnosticSeverity] = [:]
        let lines = textView.lineTable
        for anchor in anchors {
            let line = lines.lineIndex(containing: anchor.range.location)
            guard lineRange.contains(line) else { continue }
            if let existing = result[line], existing >= anchor.diagnostic.severity { continue }
            result[line] = anchor.diagnostic.severity
        }
        return result
    }
}

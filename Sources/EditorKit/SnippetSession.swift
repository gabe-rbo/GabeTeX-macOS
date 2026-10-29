import Foundation
import TeXCore

/// A snippet ready to be inserted: indentation applied, tab stops remapped to the expanded text.
nonisolated struct ExpandedSnippet: Equatable {
    var text: String
    /// Tab stops relative to the start of `text`, in visiting order.
    var tabStops: [NSRange]
    /// Final caret offset relative to the start of `text`.
    var finalCursor: Int
    /// For each tab stop (same order), its mirrors relative to the start of `text`.
    var mirrors: [[NSRange]]

    /// Applies the editor's indentation rules to a parsed snippet:
    /// every `\n` becomes `lineEnding + indent` (the indentation of the line where the snippet is
    /// inserted) and every `\t` becomes one `indentUnit`. Tab stops and the final cursor are remapped.
    init(_ snippet: Snippet, indent: String, indentUnit: String, lineEnding: String = "\n") {
        let source = Array(snippet.text.utf16)
        let newline = Array((lineEnding + indent).utf16)
        let tab = Array(indentUnit.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(source.count + 16)
        var map = [Int](repeating: 0, count: source.count + 1)
        for (i, c) in source.enumerated() {
            map[i] = output.count
            switch c {
            case 10: output.append(contentsOf: newline)
            case 9: output.append(contentsOf: tab)
            default: output.append(c)
            }
        }
        map[source.count] = output.count
        func mapOffset(_ o: Int) -> Int { map[max(0, min(o, source.count))] }
        self.text = String(decoding: output, as: UTF16.self)
        func mapRange(_ r: NSRange) -> NSRange? {
            guard r.location >= 0, r.location <= source.count else { return nil }
            let start = mapOffset(r.location)
            let end = mapOffset(r.location + r.length)
            return NSRange(location: start, length: max(0, end - start))
        }
        var stops: [NSRange] = []
        var mirrors: [[NSRange]] = []
        for (index, stop) in snippet.tabStops.enumerated() {
            guard let mapped = mapRange(stop) else { continue }
            stops.append(mapped)
            let own = snippet.mirrors.indices.contains(index) ? snippet.mirrors[index] : []
            mirrors.append(own.compactMap(mapRange))
        }
        self.tabStops = stops
        self.mirrors = mirrors
        self.finalCursor = snippet.finalCursor.map(mapOffset) ?? output.count
    }
}

/// Tracks the tab stops of an inserted snippet while the user fills them in.
/// Tab / ⇧Tab move between stops; the session ends on Esc, after the last stop, or when the caret
/// leaves the inserted text.
final class SnippetSession {
    private(set) var stops: [NSRange]
    /// For each stop, the ranges of its mirrors (kept equal to the stop's text while it is edited).
    private(set) var mirrors: [[NSRange]]
    private(set) var finalPosition: Int
    /// The whole inserted snippet (grows/shrinks with edits inside it).
    private(set) var span: NSRange
    private(set) var currentIndex: Int

    init(stops: [NSRange], mirrors: [[NSRange]] = [], finalPosition: Int, span: NSRange) {
        self.stops = stops
        self.mirrors = stops.indices.map { mirrors.indices.contains($0) ? mirrors[$0] : [] }
        self.finalPosition = finalPosition
        self.span = span
        self.currentIndex = 0
    }

    var currentStop: NSRange? { stops.indices.contains(currentIndex) ? stops[currentIndex] : nil }
    /// Mirrors of the stop being edited.
    var currentMirrors: [NSRange] { mirrors.indices.contains(currentIndex) ? mirrors[currentIndex] : [] }
    var hasMirrors: Bool { mirrors.contains { !$0.isEmpty } }
    var isOnLastStop: Bool { currentIndex >= stops.count - 1 }

    /// Moves to the next stop; nil means "go to the final position and end the session".
    func advance() -> NSRange? {
        guard currentIndex + 1 < stops.count else { return nil }
        currentIndex += 1
        return stops[currentIndex]
    }

    /// Moves to the previous stop (stays on the first one).
    func retreat() -> NSRange? {
        guard !stops.isEmpty else { return nil }
        currentIndex = max(0, currentIndex - 1)
        return stops[currentIndex]
    }

    /// Adjusts the stops for an edit (`editedRange` in new coordinates, `delta` = change in length).
    /// Returns false when the edit invalidated the session (it reached outside the snippet).
    func noteEdit(editedRange: NSRange, delta: Int) -> Bool {
        let editLoc = editedRange.location
        let newLen = editedRange.length
        let oldEnd = editLoc + newLen - delta
        // span: edits must stay within it
        if editLoc >= span.location && oldEnd <= span.end {
            span.length += delta
        } else if oldEnd <= span.location {
            span.location += delta
        } else if editLoc >= span.end {
            // after the snippet — unaffected
        } else {
            return false
        }
        for i in stops.indices {
            stops[i] = Self.adjust(stops[i], editLoc: editLoc, oldEnd: oldEnd, newLen: newLen, delta: delta,
                                   grows: i == currentIndex)
            for j in mirrors[i].indices {
                mirrors[i][j] = Self.adjust(mirrors[i][j], editLoc: editLoc, oldEnd: oldEnd, newLen: newLen,
                                            delta: delta, grows: false)
            }
        }
        if oldEnd <= finalPosition {
            finalPosition += delta
        } else if editLoc < finalPosition {
            finalPosition = editLoc + newLen
        }
        finalPosition = max(span.location, min(finalPosition, span.end))
        return true
    }

    static func adjust(_ r: NSRange, editLoc: Int, oldEnd: Int, newLen: Int, delta: Int, grows: Bool) -> NSRange {
        if grows, editLoc >= r.location, oldEnd <= r.end {
            return NSRange(location: r.location, length: max(0, r.length + delta))
        }
        if oldEnd <= r.location {
            return NSRange(location: r.location + delta, length: r.length)
        }
        if editLoc >= r.end {
            return r
        }
        if editLoc >= r.location, oldEnd <= r.end {
            return NSRange(location: r.location, length: max(0, r.length + delta))
        }
        // partial overlap: clip to what survives
        let start = editLoc < r.location ? editLoc + newLen : r.location
        let end = oldEnd > r.end ? editLoc : r.end + delta
        return NSRange(location: start, length: max(0, end - start))
    }

    /// True when `selection` lies within the snippet.
    func contains(_ selection: NSRange) -> Bool {
        selection.location >= span.location && selection.end <= span.end
    }

    /// Replacements that make every mirror of the current stop equal to `value` (the stop's text).
    func mirrorEdits(value: String, in text: NSString) -> [TextEdit] {
        guard let stop = currentStop else { return [] }
        return currentMirrors.compactMap { m in
            guard m.end <= text.length, NSIntersectionRange(m, stop).length == 0,
                  !(m.length == 0 && m.location > stop.location && m.location < stop.end),
                  text.substring(with: m) != value else { return nil }
            return TextEdit(range: m, text: value)
        }
    }

    /// Updates every range after `edits` (from `mirrorEdits`) were applied to the text.
    func didApplyMirrorEdits(_ edits: [TextEdit]) {
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        func mapRange(_ r: NSRange) -> NSRange {
            let start = Self.map(r.location, through: sorted, stickToStart: false)
            let end = max(start, Self.map(r.end, through: sorted, stickToStart: true))
            return NSRange(location: start, length: end - start)
        }
        let replaced = Set(sorted.map { $0.range.location })
        for i in stops.indices {
            stops[i] = mapRange(stops[i])
            for j in mirrors[i].indices {
                let m = mirrors[i][j]
                if i == currentIndex, replaced.contains(m.location), let edit = sorted.first(where: { $0.range == m }) {
                    let start = Self.map(m.location, through: sorted, stickToStart: true)
                    mirrors[i][j] = NSRange(location: start, length: edit.text.utf16.count)
                } else {
                    mirrors[i][j] = mapRange(m)
                }
            }
        }
        finalPosition = Self.map(finalPosition, through: sorted, stickToStart: false)
        let spanStart = Self.map(span.location, through: sorted, stickToStart: true)
        let spanEnd = Self.map(span.end, through: sorted, stickToStart: false)
        span = NSRange(location: spanStart, length: max(0, spanEnd - spanStart))
    }

    /// Maps an offset through sorted, non-overlapping replacements (see `LaTeXTextView.map`).
    nonisolated static func map(_ offset: Int, through edits: [TextEdit], stickToStart: Bool) -> Int {
        var shift = 0
        for edit in edits {
            let r = edit.range
            let newLength = edit.text.utf16.count
            if offset < r.location { break }
            if offset > r.end || (offset == r.end && r.length > 0) {
                shift += newLength - r.length
                continue
            }
            if r.length == 0 {
                if !stickToStart { shift += newLength }
                continue
            }
            return r.location + shift
        }
        return offset + shift
    }
}

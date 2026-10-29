import Foundation

// Operators applied to a `Region`: d c y > < gu gU g~.

extension VimEngine {

    /// The text of a region as stored in a register (linewise text always ends with a line break).
    func regionText(_ d: Doc, _ r: Region) -> String {
        var t = d.sub(r.start, r.end)
        if r.linewise && !t.endsWithLineBreak { t += "\n" }
        return t
    }

    /// Applies `op` to `region`. `count` is the shift amount for visual `>` `<`.
    func applyOperator(_ op: VimOperator, _ region: Region, register: Character?, count: Int?,
                       visual: Bool = false, forceNumbered: Bool = false) {
        let d = doc
        var r = region
        r.start = max(0, min(r.start, d.length))
        r.end = max(r.start, min(r.end, d.length))
        // Like Vim, the cursor sits at the start of the region when the edit begins; undo restores it there.
        if op != .yank && !r.linewise { cursor = r.start }
        switch op {
        case .yank:
            storeYank(regionText(d, r), linewise: r.linewise, register: register)
            cursor = d.clampNormal(r.yankCursor ?? r.start)
        case .delete:
            // A multi-line characterwise delete that covers whole lines becomes linewise.
            if !visual && !r.linewise && r.end > r.start {
                let lastChar = d.prevCharStart(r.end)
                if d.lineStart(lastChar) != d.lineStart(r.start) {
                    var p = r.end
                    while p < d.length, d.unit(p) == 32 || d.unit(p) == 9 { p += 1 }
                    if (p >= d.length || d.isBreak(at: p)) && d.inIndent(r.start, extra: 0) {
                        r = Region(start: d.lineStart(r.start), end: d.lineEnd(lastChar), linewise: true, yankCursor: nil)
                    }
                }
            }
            deleteRegion(d, r, register: register, forceNumbered: forceNumbered)
        case .change:
            changeRegion(d, r, register: register, forceNumbered: forceNumbered)
        case .shiftRight, .shiftLeft:
            let first = d.lineStart(r.start)
            let lastPos = r.end > r.start ? r.end - 1 : r.start
            let last = d.lineStart(d.clusterStart(lastPos))
            shiftLines(from: first, to: last, right: op == .shiftRight, times: max(1, count ?? 1))
            let nd = doc
            cursor = nd.clampNormal(nd.firstNonBlank(first))
        case .lowercase, .uppercase, .toggleCase:
            let old = d.sub(r.start, r.end)
            let new = mapCase(old, op)
            if new != old { replace(NSRange(location: r.start, length: r.end - r.start), with: new) }
            cursor = doc.clampNormal(r.yankCursor ?? r.start)
        }
        desiredCol = nil
    }

    func mapCase(_ s: String, _ op: VimOperator) -> String {
        switch op {
        case .lowercase: return s.lowercased()
        case .uppercase: return s.uppercased()
        default:
            var out = ""
            for ch in s {
                let str = String(ch)
                let up = str.uppercased(), lo = str.lowercased()
                if up == lo { out += str } else if str == up { out += lo } else { out += up }
            }
            return out
        }
    }

    // MARK: Delete

    private func deleteRegion(_ d: Doc, _ r: Region, register: Character?, forceNumbered: Bool) {
        guard r.end > r.start else { return }
        let text = regionText(d, r)
        storeDelete(text, linewise: r.linewise, register: register, forceNumbered: forceNumbered)
        if r.linewise {
            var from = r.start
            // Deleting the last line (no terminator after it) also removes the break before it.
            let extended = r.end >= d.length && !d.endsWithBreak && from > 0
            if extended { from -= d.terminatorLength(endingAt: from) }
            replace(NSRange(location: from, length: r.end - from), with: "")
            let nd = doc
            let pos = extended ? nd.lastLineStart : min(from, nd.length)
            cursor = nd.clampNormal(nd.firstNonBlank(nd.lineStart(nd.clampNormal(pos))))
        } else {
            replace(NSRange(location: r.start, length: r.end - r.start), with: "")
            cursor = doc.clampNormal(r.start)
        }
    }

    // MARK: Change

    private func changeRegion(_ d: Doc, _ r: Region, register: Character?, forceNumbered: Bool) {
        if r.linewise {
            guard r.end > r.start || d.length == 0 else { return }
            if r.end > r.start {
                storeDelete(regionText(d, r), linewise: true, register: register, forceNumbered: forceNumbered)
            }
            let first = d.lineStart(r.start)
            let lastLineStart = d.lineStart(max(first, r.end - d.terminatorLength(endingAt: r.end)))
            let contentEnd = d.contentEnd(lastLineStart)
            var indent = ""
            if autoIndent {
                let fnb = d.firstNonBlankOffset(first)
                indent = d.sub(first, fnb)
            }
            replace(NSRange(location: first, length: contentEnd - first), with: indent)
            cursor = first + indent.u16
        } else {
            if r.end > r.start {
                storeDelete(regionText(d, r), linewise: false, register: register, forceNumbered: forceNumbered)
                replace(NSRange(location: r.start, length: r.end - r.start), with: "")
            }
            cursor = r.start
        }
        beginInsertSession(kind: .before, count: 1, records: true)
    }

    // MARK: Shift

    /// Shifts the lines whose starts lie in `from...to` (both line-start offsets).
    func shiftLines(from first: Int, to last: Int, right: Bool, times: Int) {
        let d = doc
        var starts: [Int] = []
        var ls = d.lineStart(first)
        let lastStart = d.lineStart(last)
        while true {
            starts.append(ls)
            if ls >= lastStart { break }
            guard let nx = d.nextLineStart(after: ls) else { break }
            ls = nx
        }
        let unit = indentUnit.isEmpty ? "  " : indentUnit
        for s in starts.reversed() {
            let ce = d.contentEnd(s)
            if right {
                if ce == s { continue }
                replace(NSRange(location: s, length: 0), with: String(repeating: unit, count: max(1, times)))
            } else {
                var remove = 0
                var p = s
                for _ in 0..<max(1, times) {
                    if d.sub(p, min(ce, p + unit.u16)) == unit {
                        p += unit.u16
                        remove = p - s
                        continue
                    }
                    var k = 0
                    var q = p
                    while q < ce, k < unit.u16, d.unit(q) == 32 { q += 1; k += 1 }
                    if k == 0, q < ce, d.unit(q) == 9 { q += 1 }
                    p = q
                    remove = p - s
                }
                if remove > 0 { replace(NSRange(location: s, length: remove), with: "") }
            }
        }
    }
}

extension Doc {
    /// Offset of the first non-blank character of the line starting at `ls` (the line end for a blank line).
    func firstNonBlankOffset(_ ls: Int) -> Int {
        var i = lineStart(ls)
        let ce = contentEnd(i)
        while i < ce, unit(i) == 32 || unit(i) == 9 { i += 1 }
        return i
    }
}

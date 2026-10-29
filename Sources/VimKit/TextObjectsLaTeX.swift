import Foundation

// LaTeX text objects (`i$ a$`, `ie ae`), the object dispatcher and visual-mode object selection.

private enum MathKind { case dollar, doubleDollar, parenOpen, parenClose, bracketOpen, bracketClose }

private struct MathToken {
    var pos: Int
    var len: Int
    var kind: MathKind
}

private struct MathPair {
    var openStart: Int, openLen: Int, closeStart: Int, closeLen: Int
    var size: Int { closeStart + closeLen - openStart }
}

struct EnvPair {
    var beginStart: Int
    var beginEnd: Int
    var endStart: Int
    var endEnd: Int
    var name: String
}

/// Environments whose `\begin{name}` is followed by mandatory arguments that are not part of the body.
private let environmentsWithArguments: Set<String> = [
    "tabular", "tabular*", "tabularx", "array", "minipage", "longtable", "multicols", "tabu",
    "wrapfigure", "wraptable", "subfigure", "multicols*",
]

extension VimEngine {

    // MARK: Dispatcher

    /// The region of a text object around `pos` (the cursor when nil). Nil when the object does not exist.
    func objectRegion(_ obj: VimTextObject, count: Int, at pos: Int? = nil, visual: Bool = false) -> Region? {
        let d = doc
        let c = max(0, min(pos ?? cursor, d.length))
        let n = max(1, count)
        switch obj {
        case .word(let big, let around):
            return wordObjectRegion(d, at: c, count: n, big: big, around: around)
        case .paragraph(let around):
            return paragraphObjectRegion(d, at: c, count: n, around: around)
        case .pair(let open, let close, let around):
            return pairObjectRegion(d, at: c, open: open, close: close, count: n, around: around, visual: visual)
        case .quote(let q, let around):
            return quoteObjectRegion(d, at: c, quote: q, count: n, around: around)
        case .math(let around):
            return mathObjectRegion(d, at: c, count: n, around: around)
        case .environment(let around):
            return environmentObjectRegion(d, at: c, count: n, around: around, visual: visual)
        }
    }

    // MARK: Math: $…$  $$…$$  \(…\)  \[…\]

    func mathObjectRegion(_ d: Doc, at c: Int, count: Int, around: Bool) -> Region? {
        // Math never spans a blank line: restrict the scan to the paragraph around the cursor.
        var ps = d.lineStart(c)
        while let pv = d.prevLineStart(before: ps), !d.isBlankLine(at: pv) { ps = pv }
        var lastLine = d.lineStart(c)
        while let nx = d.nextLineStart(after: lastLine), !d.isBlankLine(at: nx) { lastLine = nx }
        let pe = d.contentEnd(lastLine)

        var tokens: [MathToken] = []
        var i = ps
        while i < pe {
            let u = d.unit(i)
            if u == 37 {                       // % comment
                i = d.contentEnd(i)
                continue
            }
            if u == 92 {                       // backslash
                switch d.unit(i + 1) {
                case 40: tokens.append(MathToken(pos: i, len: 2, kind: .parenOpen))
                case 41: tokens.append(MathToken(pos: i, len: 2, kind: .parenClose))
                case 91: tokens.append(MathToken(pos: i, len: 2, kind: .bracketOpen))
                case 93: tokens.append(MathToken(pos: i, len: 2, kind: .bracketClose))
                default: break
                }
                i += 2
                continue
            }
            if u == 36 {
                if d.unit(i + 1) == 36 {
                    tokens.append(MathToken(pos: i, len: 2, kind: .doubleDollar))
                    i += 2
                } else {
                    tokens.append(MathToken(pos: i, len: 1, kind: .dollar))
                    i += 1
                }
                continue
            }
            i += 1
        }
        var pairs: [MathPair] = []
        var openDollar: MathToken?
        var openDouble: MathToken?
        var parens: [MathToken] = []
        var brackets: [MathToken] = []
        for t in tokens {
            switch t.kind {
            case .dollar:
                if let o = openDollar {
                    pairs.append(MathPair(openStart: o.pos, openLen: o.len, closeStart: t.pos, closeLen: t.len))
                    openDollar = nil
                } else { openDollar = t }
            case .doubleDollar:
                if let o = openDouble {
                    pairs.append(MathPair(openStart: o.pos, openLen: o.len, closeStart: t.pos, closeLen: t.len))
                    openDouble = nil
                } else { openDouble = t }
            case .parenOpen: parens.append(t)
            case .bracketOpen: brackets.append(t)
            case .parenClose:
                if let o = parens.popLast() {
                    pairs.append(MathPair(openStart: o.pos, openLen: o.len, closeStart: t.pos, closeLen: t.len))
                }
            case .bracketClose:
                if let o = brackets.popLast() {
                    pairs.append(MathPair(openStart: o.pos, openLen: o.len, closeStart: t.pos, closeLen: t.len))
                }
            }
        }
        let containing = pairs.filter { $0.openStart <= c && c < $0.closeStart + $0.closeLen }.sorted { $0.size < $1.size }
        var chosen: MathPair?
        if !containing.isEmpty {
            guard count - 1 < containing.count else { return nil }
            chosen = containing[count - 1]
        } else {
            // Like quotes: use the next pair that starts on the cursor line.
            let ce = d.contentEnd(c)
            chosen = pairs.filter { $0.openStart > c && $0.openStart < ce }.min { $0.openStart < $1.openStart }
        }
        guard let p = chosen else { return nil }
        if around { return Region(start: p.openStart, end: p.closeStart + p.closeLen, linewise: false) }
        return Region(start: p.openStart + p.openLen, end: p.closeStart, linewise: false)
    }

    // MARK: Environments

    private func isCommented(_ d: Doc, at pos: Int) -> Bool {
        var i = d.lineStart(pos)
        while i < pos {
            let u = d.unit(i)
            if u == 92 { i += 2; continue }
            if u == 37 { return true }
            i += 1
        }
        return false
    }

    /// All matched `\begin{x}…\end{x}` pairs (comments ignored).
    func environmentPairs(_ d: Doc) -> [EnvPair] {
        var found: [(pos: Int, isBegin: Bool)] = []
        for (needle, isBegin) in [("\\begin{", true), ("\\end{", false)] {
            var from = 0
            while from < d.length {
                let r = d.t.range(of: needle, options: .literal, range: NSRange(location: from, length: d.length - from))
                if r.location == NSNotFound { break }
                found.append((r.location, isBegin))
                from = r.location + r.length
            }
        }
        found.sort { $0.pos < $1.pos }
        var stack: [(start: Int, end: Int, name: String)] = []
        var pairs: [EnvPair] = []
        for m in found {
            if isCommented(d, at: m.pos) { continue }
            let nameStart = m.pos + (m.isBegin ? 7 : 5)
            var j = nameStart
            while j < d.length, d.unit(j) != 125, !d.isBreak(at: j) { j += 1 }
            guard j < d.length, d.unit(j) == 125 else { continue }
            let name = d.sub(nameStart, j)
            if m.isBegin {
                stack.append((m.pos, j + 1, name))
            } else if let idx = stack.lastIndex(where: { $0.name == name }) {
                let b = stack[idx]
                stack.removeSubrange(idx...)
                pairs.append(EnvPair(beginStart: b.start, beginEnd: b.end, endStart: m.pos, endEnd: j + 1, name: name))
            }
        }
        return pairs
    }

    /// End of `\begin{name}` including optional/mandatory arguments on the same line.
    private func environmentOpenerEnd(_ d: Doc, _ p: EnvPair) -> Int {
        var e = p.beginEnd
        let limit = d.contentEnd(e)
        func skipGroup(_ open: unichar, _ close: unichar) -> Bool {
            guard e < limit, d.unit(e) == open else { return false }
            var depth = 0
            var i = e
            while i < limit {
                let u = d.unit(i)
                if u == open && !d.isEscaped(at: i) { depth += 1 }
                else if u == close && !d.isEscaped(at: i) {
                    depth -= 1
                    if depth == 0 {
                        e = i + 1
                        return true
                    }
                }
                i += 1
            }
            return false
        }
        _ = skipGroup(91, 93)
        if environmentsWithArguments.contains(p.name) {
            var groups = 0
            while groups < 3, skipGroup(123, 125) || skipGroup(91, 93) { groups += 1 }
        }
        return e
    }

    func environmentObjectRegion(_ d: Doc, at c: Int, count: Int, around: Bool, visual: Bool = false) -> Region? {
        let containing = environmentPairs(d)
            .filter { $0.beginStart <= c && c < $0.endEnd }
            .sorted { ($0.endEnd - $0.beginStart) < ($1.endEnd - $1.beginStart) }
        guard count - 1 < containing.count else { return nil }
        let p = containing[count - 1]
        if around { return Region(start: p.beginStart, end: p.endEnd, linewise: false) }
        return innerBlockRegion(d, openEnd: environmentOpenerEnd(d, p), closeStart: p.endStart, visual: visual)
    }

    // MARK: Visual mode

    /// `viw`, `vi(`, `vap` …: selects the object, or grows an existing selection.
    func applyVisualObject(_ obj: VimTextObject, count: Int?) {
        let d = doc
        let n = max(1, count ?? 1)
        let lo = min(visualAnchor, cursor), hi = max(visualAnchor, cursor)
        let hiEnd = min(d.length, hi + d.cursorCharLength(at: hi))
        let trivial = visualAnchor == cursor
        var region: Region?
        var keepAnchor = false
        if trivial {
            region = objectRegion(obj, count: n, at: cursor, visual: true)
        } else {
            switch obj {
            case .word(let big, let around):
                region = wordObjectExtension(d, after: hi, count: n, big: big, around: around)
                keepAnchor = true
            case .paragraph(let around):
                if let nx = d.nextLineStart(after: hi) {
                    region = paragraphObjectRegion(d, at: nx, count: n, around: around)
                    keepAnchor = true
                }
            default:
                var tries = 0
                while tries < 6 {
                    if let r = objectRegion(obj, count: n + tries, at: lo, visual: true) {
                        if r.start < lo || r.end > hiEnd { region = r; break }
                    } else { break }
                    tries += 1
                }
            }
        }
        guard let r = region, r.end > r.start else { return }
        if r.linewise {
            switchMode(.visualLine)
            if !keepAnchor { visualAnchor = r.start }
            let lastStart = d.lineStart(max(r.start, r.end - d.terminatorLength(endingAt: r.end)))
            cursor = lastStart
        } else {
            if mode == .visualLine { switchMode(.visual) }
            if !keepAnchor { visualAnchor = r.start } else { visualAnchor = lo }
            var e = r.end
            // A region that ends in a line terminator selects the terminator itself.
            e = max(r.start, e)
            cursor = d.prevCharStart(e)
            if e > 0, d.isBreak(at: e - 1) {
                cursor = d.t.rangeOfComposedCharacterSequence(at: e - 1).location
                if d.terminatorLength(endingAt: e) == 2 { cursor = e - 2 }
            }
        }
        desiredCol = nil
    }
}

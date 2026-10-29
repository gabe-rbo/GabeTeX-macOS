import Foundation

// Text objects: words, paragraphs, bracket pairs, quotes. (LaTeX objects live in TextObjectsLaTeX.swift.)

extension WordCursor {
    /// Vim `incl()`: like `inc()` but skips the end-of-line position.
    mutating func incl() -> Int {
        var r = inc()
        if r >= 1 && i != d.lineStart(i) { r = inc() }
        return r
    }

    /// Vim `decl()`: like `dec()` but skips the end-of-line position.
    mutating func decl() -> Int {
        var r = dec()
        if r == 1 && i != d.lineStart(i) { r = dec() }
        return r
    }
}

extension Doc {
    /// Vim `inindent(extra)`: only white space before (and including `extra` characters from) the position.
    func inIndent(_ pos: Int, extra: Int) -> Bool {
        let ls = lineStart(pos)
        var i = ls
        var ws = 0
        while i < length, unit(i) == 32 || unit(i) == 9 {
            i += 1
            ws += 1
        }
        return ws >= (pos - ls) + extra
    }

    /// Exclusive end offset for an inclusive character position (never swallows a line terminator).
    func inclusiveEnd(_ i: Int) -> Int {
        (i >= length || isBreak(at: i)) ? min(i, length) : clusterEnd(i)
    }

    /// True when the character at `i` is preceded by an odd number of backslashes.
    func isEscaped(at i: Int) -> Bool {
        var n = 0
        var p = i - 1
        while p >= 0 && unit(p) == 92 { n += 1; p -= 1 }
        return n % 2 == 1
    }
}

extension VimEngine {

    // MARK: Words (iw aw iW aW) — a port of Vim's current_word()

    func wordObjectRegion(_ d: Doc, at c: Int, count: Int, big: Bool, around: Bool) -> Region? {
        var cur = WordCursor(d, c, big: big)
        func backInLine(_ w: inout WordCursor) {
            let sclass = w.cls
            while true {
                if w.i == d.lineStart(w.i) { break }
                _ = w.dec()
                if w.cls != sclass {
                    _ = w.inc()
                    break
                }
            }
        }
        backInLine(&cur)
        var startPos = cur.i
        var includeWhite = false
        var inclusive = true
        if (cur.cls == 0) == around {
            let r = WordMotion.end(d, from: cur.i, count: 1, big: big, stop: true, empty: true)
            if !r.ok { return nil }
            cur.i = r.pos
        } else {
            let r = WordMotion.forward(d, from: cur.i, count: 1, big: big, eol: true)
            cur.i = r.pos
            if cur.i == d.lineStart(cur.i) { _ = cur.decl() } else { cur.i = d.prevCharStart(cur.i) }
            if around { includeWhite = true }
        }
        var remaining = count - 1
        while remaining > 0 {
            inclusive = true
            if cur.incl() == -1 { return nil }
            if around != (cur.cls == 0) {
                let r = WordMotion.forward(d, from: cur.i, count: 1, big: big, eol: true)
                if !r.ok && remaining > 1 { return nil }
                cur.i = r.pos
                if cur.i == d.lineStart(cur.i) { inclusive = false } else { cur.i = d.prevCharStart(cur.i) }
            } else {
                let r = WordMotion.end(d, from: cur.i, count: 1, big: big, stop: true, empty: true)
                if !r.ok { return nil }
                cur.i = r.pos
            }
            remaining -= 1
        }
        if includeWhite && (cur.cls != 0 || (cur.i == d.lineStart(cur.i) && !inclusive)) {
            // No trailing white space was included: take the white space before the word instead (not the indent).
            if startPos > d.lineStart(startPos) {
                var b = WordCursor(d, d.prevCharStart(startPos), big: big)
                backInLine(&b)
                if b.cls == 0 && b.i > d.lineStart(b.i) { startPos = b.i }
            }
        }
        let end = inclusive ? d.inclusiveEnd(cur.i) : cur.i
        return Region(start: startPos, end: max(end, startPos), linewise: false)
    }

    /// Extends a visual selection ending at `hi` by another word object.
    func wordObjectExtension(_ d: Doc, after hi: Int, count: Int, big: Bool, around: Bool) -> Region? {
        var w = WordCursor(d, hi, big: big)
        if w.incl() == -1 { return nil }
        return wordObjectRegion(d, at: w.i, count: count, big: big, around: around)
    }

    // MARK: Paragraphs (ip ap)

    func paragraphObjectRegion(_ d: Doc, at c: Int, count: Int, around: Bool) -> Region? {
        var starts: [Int] = []
        var off = 0
        while true {
            starts.append(off)
            guard let nx = d.nextLineStart(after: off) else { break }
            off = nx
        }
        let n = starts.count
        let cur = d.lineIndex(of: c)
        guard cur < n else { return nil }
        func white(_ i: Int) -> Bool { d.isBlankLine(at: starts[i]) }
        let startWhite = white(cur)
        var s = cur
        while s > 0 && white(s - 1) == startWhite { s -= 1 }
        var last = s - 1
        var t = startWhite
        let groups = count * (around ? 2 : 1)
        var done = 0
        while done < groups {
            guard last + 1 < n else {
                // `ap` on the last paragraph without trailing blank lines is fine; anything else fails.
                if around && done == groups - 1 && !startWhite { break }
                return nil
            }
            var j = last + 1
            while j < n && white(j) == t { j += 1 }
            last = j - 1
            t.toggle()
            done += 1
        }
        if around && !startWhite && !white(last) {
            // No blank lines after the paragraph: include the blank lines before it.
            while s > 0 && white(s - 1) { s -= 1 }
        }
        let lastStart = starts[last]
        return Region(start: starts[s], end: d.lineEnd(lastStart), linewise: true)
    }

    // MARK: Brackets (i( a( i{ a{ i[ a[ i< a<)

    func pairObjectRegion(_ d: Doc, at c: Int, open: Character, close: Character, count: Int,
                          around: Bool, visual: Bool = false) -> Region? {
        guard let o = open.utf16.first, let cl = close.utf16.first else { return nil }
        func scanBack(_ p: Int) -> Int? {
            var depth = 0
            var i = p - 1
            while i >= 0 {
                let u = d.unit(i)
                if u == cl && !d.isEscaped(at: i) { depth += 1 }
                else if u == o && !d.isEscaped(at: i) {
                    if depth == 0 { return i }
                    depth -= 1
                }
                i -= 1
            }
            return nil
        }
        func scanForward(_ p: Int) -> Int? {
            var depth = 0
            var i = p
            while i < d.length {
                let u = d.unit(i)
                if u == o && !d.isEscaped(at: i) { depth += 1 }
                else if u == cl && !d.isEscaped(at: i) {
                    if depth == 0 { return i }
                    depth -= 1
                }
                i += 1
            }
            return nil
        }
        var openPos: Int
        if d.unit(c) == o && !d.isEscaped(at: c) {
            openPos = c
        } else if let p = scanBack(c) {
            openPos = p
        } else {
            return nil
        }
        var k = 1
        while k < count {
            guard let p = scanBack(openPos) else { return nil }
            openPos = p
            k += 1
        }
        guard let closePos = scanForward(openPos + 1) else { return nil }
        if around { return Region(start: openPos, end: closePos + 1, linewise: false) }
        return innerBlockRegion(d, openEnd: openPos + 1, closeStart: closePos, visual: visual)
    }

    /// The inside of a block that opens right before `openEnd` and closes at `closeStart` (Vim's `current_block`).
    /// A block whose opener ends its line and whose closer starts its line selects just the lines in between.
    func innerBlockRegion(_ d: Doc, openEnd: Int, closeStart: Int, visual: Bool = false) -> Region {
        var s = WordCursor(d, d.prevCharStart(openEnd), big: false)
        _ = s.incl()
        let startPos = min(s.i, closeStart)
        var sol = closeStart == d.lineStart(closeStart)
        var e = WordCursor(d, closeStart, big: false)
        _ = e.decl()
        while d.inIndent(e.i, extra: 1) {
            sol = true
            if e.decl() != 0 { break }
        }
        if visual {
            if startPos > e.i { return Region(start: startPos, end: startPos, linewise: false) }
            if sol && !d.isBreak(at: e.i) && e.i < d.length { return Region(start: startPos, end: d.lineEnd(e.i), linewise: false) }
            return Region(start: startPos, end: d.inclusiveEnd(e.i), linewise: false)
        }
        var endExclusive: Int
        if sol {
            _ = e.incl()
            endExclusive = e.i
        } else if startPos <= e.i {
            endExclusive = d.inclusiveEnd(e.i)
        } else {
            endExclusive = startPos
        }
        endExclusive = max(endExclusive, startPos)
        // Exclusive region ending in column 0 over several lines: the end moves back, and an indented start makes it linewise.
        if sol, endExclusive > startPos, endExclusive == d.lineStart(endExclusive), d.lineStart(startPos) != d.lineStart(endExclusive) {
            if d.inIndent(startPos, extra: 0) {
                return Region(start: d.lineStart(startPos), end: endExclusive, linewise: true)
            }
            return Region(start: startPos, end: endExclusive - d.terminatorLength(endingAt: endExclusive), linewise: false)
        }
        return Region(start: startPos, end: endExclusive, linewise: false)
    }

    // MARK: Quotes (i" a" i' a' i` a`)

    func quoteObjectRegion(_ d: Doc, at c: Int, quote: Character, count: Int, around: Bool) -> Region? {
        guard let q = quote.utf16.first else { return nil }
        let ls = d.lineStart(c)
        let ce = d.contentEnd(c)
        var qs: [Int] = []
        var i = ls
        while i < ce {
            if d.unit(i) == q && !d.isEscaped(at: i) { qs.append(i) }
            i += 1
        }
        var pair: (Int, Int)
        if let k = qs.firstIndex(of: c) {
            pair = k % 2 == 0 ? (k, k + 1) : (k - 1, k)
        } else {
            // Not on a quote (Vim's current_quote): the nearest quote before the cursor and the next one after it;
            // with no quote before the cursor, the first pair after it.
            let m = qs.filter { $0 < c }.count
            pair = m > 0 ? (m - 1, m) : (0, 1)
        }
        guard pair.0 >= 0, pair.1 < qs.count else { return nil }
        let o = qs[pair.0], cl = qs[pair.1]
        if !around {
            if count >= 2 { return Region(start: o, end: cl + 1, linewise: false) }
            return Region(start: o + 1, end: cl, linewise: false)
        }
        var end = cl + 1
        var start = o
        while end < ce, d.unit(end) == 32 || d.unit(end) == 9 { end += 1 }
        if end == cl + 1 {
            while start > ls, d.unit(start - 1) == 32 || d.unit(start - 1) == 9 { start -= 1 }
        }
        return Region(start: start, end: end, linewise: false)
    }
}

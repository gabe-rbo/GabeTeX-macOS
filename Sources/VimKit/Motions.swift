import Foundation

extension VimEngine {

    var isVisual: Bool { mode == .visual || mode == .visualLine }

    /// Moves `n` lines from the line starting at `ls`; returns the new line start and how many lines were moved.
    private func moveLines(_ d: Doc, from ls: Int, by n: Int, down: Bool) -> (ls: Int, moved: Int) {
        var cur = ls
        var moved = 0
        while moved < n {
            guard let nx = down ? d.nextLineStart(after: cur) : d.prevLineStart(before: cur) else { break }
            cur = nx
            moved += 1
        }
        return (cur, moved)
    }

    /// Evaluates a motion from the current cursor. `op` is the pending operator (it changes `l`, `w`, `cw` …).
    /// Returns nil when the motion fails.
    func evalMotion(_ m: VimMotion, count: Int?, op: VimOperator?) -> MotionResult? {
        let d = doc
        let c = max(0, min(cursor, d.length))
        let n = max(1, count ?? 1)
        let opPending = op != nil

        switch m {
        case .left:
            let ls = d.lineStart(c)
            guard c > ls else { return nil }
            var p = c
            var k = n
            while k > 0 && p > ls { p = d.prevCharStart(p); k -= 1 }
            return MotionResult(offset: p)

        case .right:
            let ce = d.contentEnd(c)
            var p = c
            var k = n
            if opPending {
                guard c < ce else { return nil }
                while k > 0 && p < ce { p = d.clusterEnd(p); k -= 1 }
                return MotionResult(offset: p)
            }
            let last = d.lastCharStart(inLineAt: c)
            guard c < last else { return nil }
            while k > 0 && p < last { p = d.clusterEnd(p); k -= 1 }
            return MotionResult(offset: p)

        case .wrapRight:
            var p = c
            var k = n
            while k > 0 {
                let ce = d.contentEnd(p)
                let last = d.lastCharStart(inLineAt: p)
                if p < last { p = d.clusterEnd(p) }
                else if opPending && p < ce { p = ce }
                else if let nx = d.nextLineStart(after: p) { p = nx }
                else { break }
                k -= 1
            }
            guard p != c else { return nil }
            return MotionResult(offset: p)

        case .wrapLeft:
            var p = c
            var k = n
            while k > 0 {
                let ls = d.lineStart(p)
                if p > ls { p = d.prevCharStart(p) }
                else if let pv = d.prevLineStart(before: p) {
                    p = opPending ? d.contentEnd(pv) : d.lastCharStart(inLineAt: pv)
                } else { break }
                k -= 1
            }
            guard p != c else { return nil }
            return MotionResult(offset: p)

        case .up, .down:
            let down = m == .down
            let col = desiredCol ?? d.column(of: c)
            let (ls, moved) = moveLines(d, from: d.lineStart(c), by: n, down: down)
            guard moved > 0 else { return nil }
            let off = d.offset(lineStart: ls, column: col, allowEnd: isVisual && col == Int.max)
            return MotionResult(offset: off, linewise: true, column: col)

        case .lineStart:
            return MotionResult(offset: d.lineStart(c))

        case .firstNonBlank:
            return MotionResult(offset: d.firstNonBlank(c))

        case .lineEnd:
            var ls = d.lineStart(c)
            if n > 1 {
                let r = moveLines(d, from: ls, by: n - 1, down: true)
                guard r.moved > 0 else { return nil }
                ls = r.ls
            }
            let off = isVisual ? d.contentEnd(ls) : d.lastCharStart(inLineAt: ls)
            return MotionResult(offset: off, inclusive: true, column: Int.max)

        case .lastNonBlank:
            var ls = d.lineStart(c)
            if n > 1 {
                let r = moveLines(d, from: ls, by: n - 1, down: true)
                guard r.moved > 0 else { return nil }
                ls = r.ls
            }
            return MotionResult(offset: d.lastNonBlank(ls), inclusive: true)

        case .column:
            let ls = d.lineStart(c)
            return MotionResult(offset: d.offset(lineStart: ls, column: n - 1))

        case .nextLineFirstNonBlank, .prevLineFirstNonBlank:
            let r = moveLines(d, from: d.lineStart(c), by: n, down: m == .nextLineFirstNonBlank)
            guard r.moved > 0 else { return nil }
            return MotionResult(offset: d.firstNonBlank(r.ls), linewise: true)

        case .currentLineFirstNonBlank:
            var ls = d.lineStart(c)
            if n > 1 {
                let r = moveLines(d, from: ls, by: n - 1, down: true)
                guard r.moved > 0 else { return nil }
                ls = r.ls
            }
            return MotionResult(offset: d.firstNonBlank(ls), linewise: true)

        case .wordForward(let big):
            if op == .change && d.charClass(at: c) != 0 {
                // "cw" on a word behaves like "ce" (but stays on a one-character word).
                let r = WordMotion.end(d, from: c, count: n, big: big, stop: true, empty: false)
                return MotionResult(offset: r.pos, inclusive: true)
            }
            let r = WordMotion.forward(d, from: c, count: n, big: big, eol: opPending)
            if !r.ok && r.pos == c { return nil }
            return MotionResult(offset: r.pos)

        case .wordBackward(let big):
            let r = WordMotion.backward(d, from: c, count: n, big: big)
            if !r.ok && r.pos == c { return nil }
            return MotionResult(offset: r.pos)

        case .wordEnd(let big):
            let r = WordMotion.end(d, from: c, count: n, big: big, stop: false, empty: false)
            if !r.ok && r.pos == c { return nil }
            return MotionResult(offset: r.pos, inclusive: true)

        case .wordEndBackward(let big):
            let r = WordMotion.endBackward(d, from: c, count: n, big: big)
            if !r.ok && r.pos == c { return nil }
            return MotionResult(offset: r.pos, inclusive: true)

        case .fileTop, .fileBottom:
            let target: Int
            if let cnt = count {
                target = d.offset(ofLine: max(0, cnt - 1)) ?? d.lastLineStart
            } else {
                target = m == .fileTop ? 0 : d.lastLineStart
            }
            return MotionResult(offset: d.firstNonBlank(target), linewise: true, isJump: true)

        case .paragraphForward, .paragraphBackward:
            return paragraphMotion(d, from: c, count: n, forward: m == .paragraphForward)

        case .matchPair:
            guard let p = matchingBracket(d, from: c) else { return nil }
            return MotionResult(offset: p, inclusive: true, isJump: true)

        case .find(let kind, let text):
            lastFind = LastFind(kind: kind, text: text)
            return findChar(d, from: c, kind: kind, text: text, count: n, repeating: false)

        case .repeatFind(let reverse):
            guard let lf = lastFind else { return nil }
            return findChar(d, from: c, kind: reverse ? lf.kind.reversed : lf.kind, text: lf.text, count: n, repeating: true)

        case .screenTop, .screenMiddle, .screenBottom:
            let total = d.lineCount
            var top = 1
            var bottom = total
            if let vis = buf.vimVisibleLines {
                top = max(1, min(vis.lowerBound, total))
                bottom = max(top, min(vis.upperBound, total))
            }
            let line: Int
            switch m {
            case .screenTop: line = min(top + n - 1, bottom)
            case .screenBottom: line = max(bottom - n + 1, top)
            default: line = top + (bottom - top) / 2
            }
            let ls = d.offset(ofLine: line - 1) ?? d.lastLineStart
            return MotionResult(offset: d.firstNonBlank(ls), linewise: true, isJump: true)

        case .halfPageDown, .halfPageUp, .pageDown, .pageUp:
            var height = 20
            if let vis = buf.vimVisibleLines { height = max(1, vis.count) }
            let down = m == .halfPageDown || m == .pageDown
            var amount: Int
            if m == .halfPageDown || m == .halfPageUp {
                amount = count ?? max(1, height / 2)
            } else {
                amount = n * max(1, height - 2)
            }
            amount = max(1, amount)
            let r = moveLines(d, from: d.lineStart(c), by: amount, down: down)
            guard r.moved > 0 else { return nil }
            return MotionResult(offset: d.firstNonBlank(r.ls), linewise: true)

        case .searchWord(let forward):
            return searchWordMotion(d, from: c, forward: forward, count: n)

        case .searchNext(let reverse):
            guard let ls = lastSearch else {
                notify("E35: No previous regular expression")
                return nil
            }
            let fwd = reverse ? !ls.forward : ls.forward
            guard let r = findMatch(pattern: ls.pattern, forward: fwd, from: c, count: n) else { return nil }
            return searchResult(d, match: r, offset: ls.offset)

        case .searchCommand:
            return nil

        case .searchPattern(let pattern, let forward):
            var offset = ""
            if let prev = lastSearch, prev.pattern == pattern { offset = prev.offset }
            lastSearch = LastSearch(pattern: pattern, forward: forward, offset: offset)
            guard let r = findMatch(pattern: pattern, forward: forward, from: c, count: n) else { return nil }
            return searchResult(d, match: r, offset: offset)

        case .mark(let ch, let linewise):
            guard let off = markOffset(ch) else {
                notify("E20: Mark not set")
                return nil
            }
            let pos = max(0, min(off, d.length))
            if linewise {
                return MotionResult(offset: d.firstNonBlank(d.lineStart(pos)), linewise: true, isJump: true)
            }
            return MotionResult(offset: d.clusterStart(pos), isJump: true)
        }
    }

    func markOffset(_ ch: Character) -> Int? {
        switch ch {
        case "'", "`": return marks["'"]
        default: return marks[ch]
        }
    }

    // MARK: f F t T

    private func findChar(_ d: Doc, from c: Int, kind: FindKind, text: String, count n: Int, repeating: Bool) -> MotionResult? {
        let ls = d.lineStart(c)
        let ce = d.contentEnd(c)
        let first = text.utf16.first ?? 0
        func matches(_ p: Int) -> Bool {
            guard d.unit(p) == first else { return false }
            return d.sub(p, d.clusterEnd(p)) == text
        }
        let skipAdjacent = repeating && kind.isTill && n == 1
        var k = n
        if kind.isForward {
            var p = d.clusterEnd(c)
            if skipAdjacent { p = d.clusterEnd(p) }
            while p < ce {
                if matches(p) {
                    k -= 1
                    if k == 0 {
                        let off = kind.isTill ? d.prevCharStart(p) : p
                        return MotionResult(offset: off, inclusive: true)
                    }
                }
                p = d.clusterEnd(p)
            }
            return nil
        }
        guard c > ls else { return nil }
        var p = d.prevCharStart(c)
        if skipAdjacent && p > ls { p = d.prevCharStart(p) } else if skipAdjacent { return nil }
        while true {
            if matches(p) {
                k -= 1
                if k == 0 {
                    return MotionResult(offset: kind.isTill ? d.clusterEnd(p) : p)
                }
            }
            if p <= ls { break }
            p = d.prevCharStart(p)
        }
        return nil
    }

    // MARK: } {

    private func paragraphMotion(_ d: Doc, from c: Int, count: Int, forward: Bool) -> MotionResult? {
        var cur = d.lineStart(c)
        var remaining = count
        while remaining > 0 {
            remaining -= 1
            var didSkip = false
            var first = true
            while true {
                let empty = d.isEmptyLine(at: cur)
                if !empty { didSkip = true }
                if !first && didSkip && empty { break }
                first = false
                guard let nx = forward ? d.nextLineStart(after: cur) : d.prevLineStart(before: cur) else {
                    if remaining > 0 { return nil }
                    break
                }
                cur = nx
            }
        }
        if forward && d.nextLineStart(after: cur) == nil {
            let ce = d.contentEnd(cur)
            if ce > cur {
                return MotionResult(offset: d.prevCharStart(ce), inclusive: true, isJump: true)
            }
        }
        return MotionResult(offset: cur, isJump: true)
    }

    // MARK: %

    private func isEscaped(_ d: Doc, at i: Int) -> Bool {
        var n = 0
        var p = i - 1
        while p >= 0 && d.unit(p) == 92 { n += 1; p -= 1 }
        return n % 2 == 1
    }

    func matchingBracket(_ d: Doc, from c: Int) -> Int? {
        let ce = d.contentEnd(c)
        var i = c
        func info(_ u: unichar) -> (open: unichar, close: unichar, forward: Bool)? {
            switch u {
            case 40: return (40, 41, true)
            case 91: return (91, 93, true)
            case 123: return (123, 125, true)
            case 41: return (40, 41, false)
            case 93: return (91, 93, false)
            case 125: return (123, 125, false)
            default: return nil
            }
        }
        while i < ce && info(d.unit(i)) == nil { i += 1 }
        guard i < ce, let b = info(d.unit(i)) else { return nil }
        let startEscaped = isEscaped(d, at: i)
        var depth = 0
        if b.forward {
            var p = i + 1
            while p < d.length {
                let u = d.unit(p)
                if (u == b.open || u == b.close) && isEscaped(d, at: p) == startEscaped {
                    if u == b.open { depth += 1 } else {
                        if depth == 0 { return p }
                        depth -= 1
                    }
                }
                p += 1
            }
        } else {
            var p = i - 1
            while p >= 0 {
                let u = d.unit(p)
                if (u == b.open || u == b.close) && isEscaped(d, at: p) == startEscaped {
                    if u == b.close { depth += 1 } else {
                        if depth == 0 { return p }
                        depth -= 1
                    }
                }
                p -= 1
            }
        }
        return nil
    }

    // MARK: * #

    private func searchWordMotion(_ d: Doc, from c: Int, forward: Bool, count n: Int) -> MotionResult? {
        guard let w = wordUnderCursor(d, at: c) else {
            notify("E348: No string under cursor")
            return nil
        }
        var escaped = ""
        for ch in w.text {
            if "\\/.*$^~[]".contains(ch) || (!forward && ch == "?") { escaped.append("\\") }
            escaped.append(ch)
        }
        let pattern = w.keyword ? "\\<" + escaped + "\\>" : escaped
        lastSearch = LastSearch(pattern: pattern, forward: forward)
        let from = forward ? c : w.start
        guard let r = findMatch(pattern: pattern, forward: forward, from: from, count: n, useSmartCase: false) else { return nil }
        return MotionResult(offset: r.location, isJump: true)
    }

    /// The keyword under (or after) the cursor, or the non-blank sequence when there is no keyword.
    func wordUnderCursor(_ d: Doc, at c: Int) -> (text: String, start: Int, keyword: Bool)? {
        let ce = d.contentEnd(c)
        var i = c
        // first keyword character at or after the cursor
        var found: Int?
        while i < ce {
            if d.charClass(at: i) == 2 { found = i; break }
            i = d.clusterEnd(i)
        }
        if let f = found {
            var s = f
            while s > d.lineStart(c), d.charClass(at: d.prevCharStart(s)) == 2 { s = d.prevCharStart(s) }
            var e = f
            while e < ce, d.charClass(at: e) == 2 { e = d.clusterEnd(e) }
            return (d.sub(s, e), s, true)
        }
        // non-blank run
        i = c
        while i < ce && d.charClass(at: i) == 0 { i = d.clusterEnd(i) }
        guard i < ce else { return nil }
        var s = i
        while s > d.lineStart(c), d.charClass(at: d.prevCharStart(s)) == 1 { s = d.prevCharStart(s) }
        var e = i
        while e < ce, d.charClass(at: e) != 0 { e = d.clusterEnd(e) }
        return (d.sub(s, e), s, false)
    }
}

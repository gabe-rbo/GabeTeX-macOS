import Foundation

/// A cursor over a `Doc` that mirrors Vim's `inc()` / `dec()` semantics, including the "NUL" position at the
/// end of every line. Word motions are straight ports of Vim's `fwd_word`, `bck_word`, `end_word`, `bckend_word`.
struct WordCursor {
    let d: Doc
    var i: Int
    let big: Bool

    init(_ d: Doc, _ i: Int, big: Bool) {
        self.d = d
        self.i = max(0, min(i, d.length))
        self.big = big
    }

    /// 0: moved within the line; 2: moved onto the end-of-line position; 1: moved to the next line; -1: at the end.
    mutating func inc() -> Int {
        if i < d.length && !d.isBreak(at: i) {
            let n = d.clusterEnd(i)
            i = n
            return (n >= d.length || d.isBreak(at: n)) ? 2 : 0
        }
        if i >= d.length { return -1 }
        let e = d.lineEnd(i)
        if e < d.length {
            i = e
            return 1
        }
        return -1
    }

    /// 0: moved within the line; 1: moved to the end-of-line position of the previous line; -1: at the start.
    mutating func dec() -> Int {
        if i <= 0 { return -1 }
        let ls = d.lineStart(i)
        if i > ls {
            i = d.prevCharStart(i)
            return 0
        }
        i -= d.terminatorLength(endingAt: i)
        return 1
    }

    var cls: Int { d.charClass(at: i, big: big) }

    /// On an empty line (column 0 and nothing on the line).
    var onEmptyLine: Bool {
        (i >= d.length || d.isBreak(at: i)) && d.lineStart(i) == i
    }

    var onLastLine: Bool { d.nextLineStart(after: i) == nil }
}

enum WordMotion {
    /// Vim `fwd_word`. `eol`: stop at the end of the line in the last iteration (used with operators).
    static func forward(_ d: Doc, from start: Int, count: Int, big: Bool, eol: Bool) -> (pos: Int, ok: Bool) {
        var c = WordCursor(d, start, big: big)
        var n = count
        while n > 0 {
            n -= 1
            let sclass = c.cls
            let lastLine = c.onLastLine
            var r = c.inc()
            if r == -1 || (r >= 1 && lastLine) { return (c.i, false) }
            if r >= 1 && eol && n == 0 { return (c.i, true) }
            if sclass != 0 {
                while c.cls == sclass {
                    r = c.inc()
                    if r == -1 || (r >= 1 && eol && n == 0) { return (c.i, true) }
                }
            }
            while c.cls == 0 {
                if c.onEmptyLine { break }
                r = c.inc()
                if r == -1 || (r >= 1 && eol && n == 0) { return (c.i, true) }
            }
        }
        return (c.i, true)
    }

    /// Vim `bck_word`.
    static func backward(_ d: Doc, from start: Int, count: Int, big: Bool, stop: Bool = false) -> (pos: Int, ok: Bool) {
        var c = WordCursor(d, start, big: big)
        var stop = stop
        var n = count
        while n > 0 {
            n -= 1
            let sclass = c.cls
            if c.dec() == -1 { return (c.i, false) }
            var finished = false
            if !stop || sclass == c.cls || sclass == 0 {
                while c.cls == 0 {
                    if c.onEmptyLine { finished = true; break }
                    if c.dec() == -1 { return (c.i, true) }
                }
                if !finished {
                    let cc = c.cls
                    while c.cls == cc {
                        if c.dec() == -1 { return (c.i, true) }
                    }
                }
            }
            if !finished { _ = c.inc() }
            stop = false
        }
        return (c.i, true)
    }

    /// Vim `end_word`. `stop`: do not move when already on the last character of a word (used by `cw`).
    static func end(_ d: Doc, from start: Int, count: Int, big: Bool, stop: Bool, empty: Bool) -> (pos: Int, ok: Bool) {
        var c = WordCursor(d, start, big: big)
        var stop = stop
        var n = count
        while n > 0 {
            n -= 1
            let sclass = c.cls
            if c.inc() == -1 { return (c.i, false) }
            var finished = false
            if c.cls == sclass && sclass != 0 {
                while c.cls == sclass {
                    if c.inc() == -1 { return (c.i, false) }
                }
            } else if !stop || sclass == 0 {
                while c.cls == 0 {
                    if empty && c.onEmptyLine { finished = true; break }
                    if c.inc() == -1 { return (c.i, false) }
                }
                if !finished {
                    let cc = c.cls
                    while c.cls == cc {
                        if c.inc() == -1 { return (c.i, false) }
                    }
                }
            }
            if !finished { _ = c.dec() }
            stop = false
        }
        return (c.i, true)
    }

    /// Vim `bckend_word` (`ge`).
    static func endBackward(_ d: Doc, from start: Int, count: Int, big: Bool, eol: Bool = false) -> (pos: Int, ok: Bool) {
        var c = WordCursor(d, start, big: big)
        var n = count
        while n > 0 {
            n -= 1
            let sclass = c.cls
            var r = c.dec()
            if r == -1 { return (c.i, false) }
            if eol && r == 1 { return (c.i, true) }
            if sclass != 0 {
                while c.cls == sclass {
                    r = c.dec()
                    if r == -1 || (eol && r == 1) { return (c.i, true) }
                }
            }
            while c.cls == 0 {
                if c.onEmptyLine { break }
                r = c.dec()
                if r == -1 || (eol && r == 1) { return (c.i, true) }
            }
        }
        return (c.i, true)
    }
}

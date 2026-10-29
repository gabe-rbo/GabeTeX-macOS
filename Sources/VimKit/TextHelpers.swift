import Foundation

// MARK: - Doc: an NSString snapshot with line / character helpers

/// A thin wrapper over an `NSString` with the line and character helpers the Vim engine needs.
///
/// Conventions:
/// - All offsets are UTF-16 offsets.
/// - A *line* is a run of characters terminated by `\n`, `\r\n` or `\r`. A final terminator does not
///   start a new line for Vim purposes (Vim file semantics: `"a\nb\n"` has two lines). The offset just
///   after a final terminator (`length`) is therefore a "phantom" position the normal-mode cursor never rests on.
/// - A position at a line terminator (or at `length`) is the "NUL" position of that line, like in Vim.
struct Doc {
    let t: NSString
    let length: Int

    init(_ t: NSString) {
        self.t = t
        self.length = t.length
    }

    // MARK: Units

    /// The UTF-16 unit at `i`, or 0 when out of range.
    @inline(__always)
    func unit(_ i: Int) -> unichar {
        (i >= 0 && i < length) ? t.character(at: i) : 0
    }

    @inline(__always)
    func isBreak(at i: Int) -> Bool {
        guard i >= 0 && i < length else { return false }
        let u = t.character(at: i)
        return u == 10 || u == 13
    }

    /// Length of the line terminator that starts at `i` (0 when there is none).
    func terminatorLength(at i: Int) -> Int {
        guard i >= 0 && i < length else { return 0 }
        let u = t.character(at: i)
        if u == 13 { return (i + 1 < length && t.character(at: i + 1) == 10) ? 2 : 1 }
        if u == 10 { return 1 }
        return 0
    }

    /// Length of the terminator that ends right before `i` (0 when there is none).
    func terminatorLength(endingAt i: Int) -> Int {
        guard i > 0 && i <= length else { return 0 }
        let u = t.character(at: i - 1)
        if u == 10 { return (i >= 2 && t.character(at: i - 2) == 13) ? 2 : 1 }
        if u == 13 { return 1 }
        return 0
    }

    func sub(_ start: Int, _ end: Int) -> String {
        let s = max(0, min(start, length))
        let e = max(s, min(end, length))
        return t.substring(with: NSRange(location: s, length: e - s))
    }

    func sub(_ r: NSRange) -> String { sub(r.location, r.location + r.length) }

    // MARK: Lines

    /// True when the text ends with a line terminator (so the last position is a phantom line).
    var endsWithBreak: Bool { length > 0 && isBreak(at: length - 1) }

    func lineStart(_ off: Int) -> Int {
        var i = max(0, min(off, length))
        while i > 0 {
            let u = t.character(at: i - 1)
            if u == 10 || u == 13 { break }
            i -= 1
        }
        return i
    }

    /// Offset of the terminator of the line containing `off` (or `length`).
    func contentEnd(_ off: Int) -> Int {
        var i = max(0, min(off, length))
        while i < length {
            let u = t.character(at: i)
            if u == 10 || u == 13 { break }
            i += 1
        }
        return i
    }

    /// Offset just after the terminator of the line containing `off`.
    func lineEnd(_ off: Int) -> Int {
        let ce = contentEnd(off)
        return ce + terminatorLength(at: ce)
    }

    /// Start of the line after the one containing `off`, if it exists (a phantom line does not count).
    func nextLineStart(after off: Int) -> Int? {
        let e = lineEnd(off)
        return e < length ? e : nil
    }

    func prevLineStart(before off: Int) -> Int? {
        let ls = lineStart(off)
        if ls == 0 { return nil }
        return lineStart(ls - terminatorLength(endingAt: ls))
    }

    /// Start of the last real line.
    var lastLineStart: Int {
        guard length > 0 else { return 0 }
        if endsWithBreak { return lineStart(length - terminatorLength(endingAt: length)) }
        return lineStart(length)
    }

    func isEmptyLine(at off: Int) -> Bool {
        let ls = lineStart(off)
        return ls == contentEnd(ls)
    }

    /// True for a line containing only spaces and tabs (or nothing).
    func isBlankLine(at off: Int) -> Bool {
        var i = lineStart(off)
        let ce = contentEnd(i)
        while i < ce {
            let u = t.character(at: i)
            if u != 32 && u != 9 { return false }
            i += 1
        }
        return true
    }

    /// 0-based index of the line containing `off`.
    func lineIndex(of off: Int) -> Int {
        let end = max(0, min(off, length))
        var n = 0
        var i = 0
        while i < end {
            let u = t.character(at: i)
            if u == 10 { n += 1 } else if u == 13 {
                if i + 1 < length && t.character(at: i + 1) == 10 { i += 1; if i >= end { break } }
                n += 1
            }
            i += 1
        }
        return n
    }

    /// Number of real lines (at least 1).
    var lineCount: Int {
        guard length > 0 else { return 1 }
        var n = 1
        var i = 0
        while i < length {
            let tl = terminatorLength(at: i)
            if tl > 0 {
                i += tl
                if i < length { n += 1 }
            } else { i += 1 }
        }
        return n
    }

    /// Start offset of the 0-based line `n`; nil when the line does not exist.
    func offset(ofLine n: Int) -> Int? {
        if n < 0 { return nil }
        var off = 0
        var k = 0
        while k < n {
            guard let next = nextLineStart(after: off) else { return nil }
            off = next
            k += 1
        }
        return off
    }

    // MARK: Characters (composed character sequences)

    /// End of the composed character sequence containing `i` (never splits a surrogate pair / cluster).
    func clusterEnd(_ i: Int) -> Int {
        guard i < length else { return length }
        let r = t.rangeOfComposedCharacterSequence(at: max(0, i))
        return r.location + r.length
    }

    /// Start of the composed character sequence containing `i`.
    func clusterStart(_ i: Int) -> Int {
        if i <= 0 { return 0 }
        if i >= length { return length }
        return t.rangeOfComposedCharacterSequence(at: i).location
    }

    /// Start of the character before `i`.
    func prevCharStart(_ i: Int) -> Int {
        guard i > 0 else { return 0 }
        return t.rangeOfComposedCharacterSequence(at: min(i, length) - 1).location
    }

    /// Length of the character under a (visual-mode) cursor at `i`: a terminator when on a line end.
    func cursorCharLength(at i: Int) -> Int {
        guard i < length else { return 0 }
        if isBreak(at: i) { return terminatorLength(at: i) }
        return clusterEnd(i) - i
    }

    /// Start of the last character of the line containing `off` (the line start for an empty line).
    func lastCharStart(inLineAt off: Int) -> Int {
        let ls = lineStart(off)
        let ce = contentEnd(ls)
        return ce > ls ? prevCharStart(ce) : ls
    }

    /// First non-blank position on the line starting at `ls` (the last character for an all-blank line).
    func firstNonBlank(_ ls: Int) -> Int {
        let start = lineStart(ls)
        let ce = contentEnd(start)
        var i = start
        while i < ce {
            let u = t.character(at: i)
            if u != 32 && u != 9 { return i }
            i += 1
        }
        return ce > start ? prevCharStart(ce) : start
    }

    /// Position of the last non-blank character of the line (the line start when empty / blank).
    func lastNonBlank(_ off: Int) -> Int {
        let ls = lineStart(off)
        var i = contentEnd(ls)
        while i > ls {
            let p = prevCharStart(i)
            let u = t.character(at: p)
            if u != 32 && u != 9 { return p }
            i = p
        }
        return ls
    }

    // MARK: Columns

    /// Number of characters between the start of the line and `off`.
    func column(of off: Int) -> Int {
        let ls = lineStart(off)
        var i = ls
        var n = 0
        let target = min(off, contentEnd(ls))
        while i < target {
            i = clusterEnd(i)
            n += 1
        }
        return n
    }

    /// Offset of character column `col` on the line starting at `ls`; clamps to the last character
    /// (or to the NUL position when `allowEnd`).
    func offset(lineStart ls: Int, column col: Int, allowEnd: Bool = false) -> Int {
        let ce = contentEnd(ls)
        if col == Int.max { return allowEnd || ce == ls ? ce : prevCharStart(ce) }
        var i = ls
        var n = 0
        while n < col && i < ce {
            i = clusterEnd(i)
            n += 1
        }
        if i >= ce { return allowEnd || ce == ls ? ce : prevCharStart(ce) }
        return i
    }

    // MARK: Normal-mode cursor clamping

    /// Clamps an offset to a valid normal-mode cursor position: inside the text, on a character boundary,
    /// never on a line terminator (except on empty lines) and never on the phantom line.
    func clampNormal(_ off: Int) -> Int {
        guard length > 0 else { return 0 }
        var o = max(0, min(off, length))
        if o == length && endsWithBreak { o = length - terminatorLength(endingAt: length) }
        // Between the CR and the LF of a CRLF: step back to the CR so the offset names a real position.
        if o > 0 && o < length && t.character(at: o) == 10 && t.character(at: o - 1) == 13 { o -= 1 }
        let ls = lineStart(o)
        let ce = contentEnd(o)
        if o >= ce { return ce > ls ? prevCharStart(ce) : ls }
        return clusterStart(o)
    }

    // MARK: Character classes (for w, b, e, iw …)

    static func scalarClass(_ s: UInt32) -> Int {
        if s < 0x80 {
            switch s {
            case 0, 9, 10, 13, 32: return 0
            case 48...57, 65...90, 97...122, 95: return 2
            default: return 1
            }
        }
        guard let sc = Unicode.Scalar(s) else { return 1 }
        let p = sc.properties
        if p.isWhitespace { return 0 }
        if p.isAlphabetic || p.numericType != nil { return 2 }
        switch p.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return 2
        default: break
        }
        if p.isEmojiPresentation { return 3 }
        return 1
    }

    func scalar(at i: Int) -> UInt32 {
        let u = unit(i)
        if UTF16.isLeadSurrogate(u), i + 1 < length {
            let l = t.character(at: i + 1)
            if UTF16.isTrailSurrogate(l) {
                return 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(l) - 0xDC00)
            }
        }
        return UInt32(u)
    }

    /// Vim character class at `i`: 0 blank / end of line, 1 punctuation, 2 keyword, 3 emoji.
    /// With `big` every non-blank counts as one class (WORD motions).
    func charClass(at i: Int, big: Bool = false) -> Int {
        guard i >= 0 && i < length else { return 0 }
        let c = Doc.scalarClass(scalar(at: i))
        return big ? (c == 0 ? 0 : 1) : c
    }
}

// MARK: - Misc string helpers

extension String {
    /// UTF-16 length.
    var u16: Int { (self as NSString).length }

    /// True when the last UTF-16 unit is a line terminator. (`"a\r\n".hasSuffix("\n")` is false in Swift because
    /// CR LF is a single `Character`, so line-break tests always go through UTF-16.)
    var endsWithLineBreak: Bool {
        let u = utf16.last
        return u == 10 || u == 13
    }

    /// True when the string contains LF or CR.
    var containsLineBreak: Bool { utf16.contains(10) || utf16.contains(13) }

    /// The string without one trailing line terminator (LF, CR or CRLF).
    var droppingTrailingBreak: String {
        let u = Array(utf16)
        var n = u.count
        if n > 0, u[n - 1] == 10 {
            n -= 1
            if n > 0, u[n - 1] == 13 { n -= 1 }
        } else if n > 0, u[n - 1] == 13 {
            n -= 1
        }
        return String(decoding: u[0..<n], as: UTF16.self)
    }
}

extension NSRange {
    var end: Int { location + length }
}

func clampRange(_ r: NSRange, length: Int) -> NSRange {
    let s = max(0, min(r.location, length))
    let e = max(s, min(r.location + r.length, length))
    return NSRange(location: s, length: e - s)
}

// MARK: - VimKey helpers

extension VimKey {
    /// True for the plain (non-control, non-special) key producing exactly `c`.
    func isChar(_ c: String) -> Bool { !control && special == nil && character == c }

    /// The produced text for a plain printable key.
    var plain: String? { (control || special != nil) ? nil : character }

    /// True for Ctrl+`c` (case-insensitive).
    func isCtrl(_ c: String) -> Bool {
        control && special == nil && character?.lowercased() == c
    }

    func isSpecial(_ s: Special) -> Bool { special == s }

    /// Short human readable form for the status bar.
    var display: String {
        if let s = special {
            switch s {
            case .escape: return "<Esc>"
            case .enter: return "<CR>"
            case .backspace: return "<BS>"
            case .tab: return "<Tab>"
            case .delete: return "<Del>"
            case .left: return "<Left>"
            case .right: return "<Right>"
            case .up: return "<Up>"
            case .down: return "<Down>"
            case .home: return "<Home>"
            case .end: return "<End>"
            case .pageUp: return "<PageUp>"
            case .pageDown: return "<PageDown>"
            }
        }
        let c = character ?? ""
        return control ? "^" + c.uppercased() : c
    }
}

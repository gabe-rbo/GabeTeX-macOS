import Foundation

/// A UTF-16 snapshot of a LaTeX source together with a "masked" copy in which everything that must not
/// be interpreted as TeX is blanked out with spaces (line breaks are kept, so offsets and line numbers
/// are identical in both copies):
///   - comments (`%` to end of line, but not `\%`),
///   - bodies of verbatim-like environments (`verbatim`, `lstlisting`, `minted`, `comment`, ...),
///   - `\verb|...|` / `\lstinline|...|` / `\mintinline{..}|...|` contents,
///   - raw `\url{...}` / `\href{...}` first arguments (they may contain `%` and `#`),
///   - `\iffalse ... \fi` blocks that start a line (the common block-comment idiom).
///
/// The scanner, the structure linter and the completion engine all work on `masked`.
struct MaskedSource {
    let original: [UInt16]
    private(set) var masked: [UInt16]
    /// Blanked comment ranges (excluding the line terminator), in order.
    private(set) var comments: [Range<Int>] = []
    /// UTF-16 offset of the first character of each line (`\n`, `\r\n` and `\r` terminators).
    private(set) var lineStarts: [Int] = [0]
    /// True when the source changes category codes (`\catcode`): structural checks become unreliable.
    private(set) var hasCatcode = false

    var count: Int { original.count }

    init(_ text: NSString) {
        let length = text.length
        var units = [unichar](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&units, range: NSRange(location: 0, length: length)) }
        self.init(units: units)
    }

    init(_ text: String) {
        self.init(units: Array(text.utf16))
    }

    init(units: [UInt16]) {
        self.original = units
        self.masked = units
        build()
    }

    // MARK: Queries

    /// 1-based line containing `offset`.
    func line(at offset: Int) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        let target = max(0, offset)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// 1-based (line, column) of `offset`.
    func position(at offset: Int) -> (line: Int, column: Int) {
        let l = line(at: offset)
        return (l, offset - lineStarts[l - 1] + 1)
    }

    /// Text of a range taken from the masked copy.
    func maskedString(_ r: Range<Int>) -> String { utf16String(masked, r) }

    /// Text of a range taken from the original, with comments replaced by a single space (so titles that
    /// span a comment still read naturally) but verbatim contents kept.
    func textWithoutComments(_ r: Range<Int>) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(r.count)
        var pos = r.lowerBound
        // First comment that ends after r.lowerBound.
        var lo = 0
        var hi = comments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if comments[mid].upperBound <= r.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        var idx = lo
        while idx < comments.count && comments[idx].lowerBound < r.upperBound {
            let c = comments[idx]
            if c.lowerBound > pos { out.append(contentsOf: original[pos..<c.lowerBound]) }
            out.append(32)
            pos = max(pos, c.upperBound)
            idx += 1
        }
        if pos < r.upperBound { out.append(contentsOf: original[pos..<r.upperBound]) }
        return out
    }

    /// True when the line break at `index` (a `\n` or `\r`) is followed by a whitespace-only line in the
    /// *original* text, i.e. a paragraph break. A line holding only a comment is not blank.
    func isParagraphBreak(afterLineBreakAt index: Int) -> Bool {
        let n = original.count
        var j = index + 1
        if original[index] == 13 && j < n && original[j] == 10 { j += 1 }
        while j < n && isHSpace(original[j]) { j += 1 }
        return j < n && isLineBreak(original[j])
    }

    // MARK: Construction

    private mutating func build() {
        let n = original.count
        var i = 0
        while i < n {
            switch original[i] {
            case 10:
                lineStarts.append(i + 1)
                i += 1
            case 13:
                if i + 1 < n && original[i + 1] == 10 { i += 1 }
                lineStarts.append(i + 1)
                i += 1
            case 37:
                var j = i + 1
                while j < n && original[j] != 10 && original[j] != 13 { j += 1 }
                blank(i, j)
                comments.append(i..<j)
                i = j
            case 92:
                i = command(at: i)
            default:
                i += 1
            }
        }
    }

    private mutating func blank(_ a: Int, _ b: Int) {
        var k = a
        while k < b { masked[k] = 32; k += 1 }
    }

    /// Blanks a multi-line range, keeping line terminators and registering the line starts inside.
    private mutating func blankBody(_ a: Int, _ b: Int) {
        let n = original.count
        var k = a
        while k < b {
            let c = original[k]
            if c == 10 {
                lineStarts.append(k + 1)
            } else if c == 13 {
                // "\r\n" registers its line start at the "\n".
                if !(k + 1 < n && original[k + 1] == 10) { lineStarts.append(k + 1) }
            } else {
                masked[k] = 32
            }
            k += 1
        }
    }

    /// Handles a backslash at `i` and returns where scanning continues.
    private mutating func command(at i: Int) -> Int {
        let n = original.count
        guard i + 1 < n else { return i + 1 }
        let d = original[i + 1]
        guard isCommandLetter(d) else {
            if isLineBreak(d) { return i + 1 }
            if isHighSurrogate(d) && i + 2 < n && isLowSurrogate(original[i + 2]) { return i + 3 }
            return i + 2
        }
        var j = i + 2
        while j < n && isCommandLetter(original[j]) { j += 1 }
        let length = j - i - 1
        guard length >= 3 && length <= 10 else { return j }
        // Cheap pre-filter on the first letter: b(egin) v/V(erb) l(stinline) m(intinline) u(rl) h(ref) i(ffalse) c(atcode)
        switch d {
        case 98, 118, 86, 108, 109, 117, 104, 105, 99: break
        default: return j
        }
        let name = utf16String(original, (i + 1)..<j)
        switch name {
        case "begin": return maskVerbatimEnvironment(afterBegin: j)
        case "verb", "Verb": return maskDelimited(from: j, allowStar: true) ?? j
        case "lstinline": return maskLstinline(from: j) ?? j
        case "mintinline": return maskMintinline(from: j) ?? j
        case "url", "href": return maskRawGroup(from: j) ?? j
        case "iffalse": return maskIffalse(commandStart: i, nameEnd: j) ?? j
        case "catcode":
            hasCatcode = true
            return j
        default: return j
        }
    }

    private mutating func maskVerbatimEnvironment(afterBegin j: Int) -> Int {
        let n = original.count
        var k = j
        while k < n && isHSpace(original[k]) { k += 1 }
        guard let parsed = LaTeXSyntax.environmentName(original, open: k) else { return j }
        let name = utf16String(original, parsed.name)
        guard LaTeXSyntax.verbatimEnvironments.contains(name) else { return j }
        let opening = LaTeXSyntax.verbatimOpening(original, name: name, from: parsed.end)
        let end = LaTeXSyntax.verbatimEnd(original, name: name, from: opening.bodyStart)
        if end > opening.bodyStart { blankBody(opening.bodyStart, end) }
        return max(end, parsed.end)
    }

    /// `\verb|...|`: blanks the delimiters and content (and the star). Returns the next scan position.
    private mutating func maskDelimited(from j: Int, allowStar: Bool) -> Int? {
        let n = original.count
        var k = j
        if allowStar && k < n && original[k] == 42 { k += 1 }
        guard k < n else { return nil }
        let delimiter = original[k]
        if isTeXWhitespace(delimiter) { return nil }
        var m = k + 1
        while m < n && original[m] != delimiter && !isLineBreak(original[m]) { m += 1 }
        guard m < n, original[m] == delimiter else { return nil }
        blank(j, m + 1)
        return m + 1
    }

    private mutating func maskLstinline(from j: Int) -> Int? {
        let n = original.count
        var k = j
        if k < n, original[k] == 91, let close = LaTeXSyntax.closingBracketOnLine(original, open: k) { k = close + 1 }
        guard k < n, original[k] != 123 else { return nil }
        return maskDelimited(from: k, allowStar: false)
    }

    private mutating func maskMintinline(from j: Int) -> Int? {
        let n = original.count
        var k = j
        if k < n, original[k] == 91, let close = LaTeXSyntax.closingBracketOnLine(original, open: k) { k = close + 1 }
        guard k < n, original[k] == 123, let langClose = LaTeXSyntax.closingBraceOnLine(original, open: k) else { return nil }
        k = langClose + 1
        guard k < n, original[k] != 123 else { return nil }
        return maskDelimited(from: k, allowStar: false)
    }

    /// `\url{...}`, `\href{...}`: blank the content of the first braced group.
    private mutating func maskRawGroup(from j: Int) -> Int? {
        let n = original.count
        var k = j
        while k < n && isHSpace(original[k]) { k += 1 }
        guard k < n, original[k] == 123 else { return nil }
        var depth = 0
        var m = k
        let stop = min(n, k + 2000)
        while m < stop {
            let c = original[m]
            if c == 123 { depth += 1 } else if c == 125 {
                depth -= 1
                if depth == 0 {
                    blankBody(k + 1, m)
                    return m + 1
                }
            } else if isLineBreak(c) {
                var t = m + 1
                if c == 13 && t < n && original[t] == 10 { t += 1 }
                while t < n && isHSpace(original[t]) { t += 1 }
                if t >= n || isLineBreak(original[t]) { return nil }
            }
            m += 1
        }
        return nil
    }

    private static let primitiveFreeConditionals: Set<String> = ["iff", "ifthenelse"]

    private static func opensConditional(_ name: String) -> Bool {
        guard name.hasPrefix("if"), name.count > 2 else { return false }
        if primitiveFreeConditionals.contains(name) { return false }
        for prefix in ["ifdef", "ifundef", "ifstr", "ifbool", "ifblank", "ifnumcomp", "ifnumequal", "ifnumgreater",
                       "ifnumless", "ifdimcomp", "ifdimequal", "ifdimgreater", "ifdimless", "ifcsdef", "ifcsundef",
                       "ifcsstring", "ifcsempty", "iffontchar"] where name.hasPrefix(prefix) {
            return false
        }
        return true
    }

    /// Blanks `\iffalse ... \fi` when `\iffalse` is the first thing on its line.
    private mutating func maskIffalse(commandStart i: Int, nameEnd j: Int) -> Int? {
        let n = original.count
        var k = i - 1
        while k >= 0 && isHSpace(original[k]) { k -= 1 }
        if k >= 0 && !isLineBreak(original[k]) { return nil }
        var depth = 1
        var m = j
        while m < n {
            let c = original[m]
            if c == 37 {
                while m < n && !isLineBreak(original[m]) { m += 1 }
                continue
            }
            if c == 92 {
                guard m + 1 < n else { break }
                let d = original[m + 1]
                if isCommandLetter(d) {
                    var e = m + 2
                    while e < n && isCommandLetter(original[e]) { e += 1 }
                    let name = utf16String(original, (m + 1)..<e)
                    if name == "fi" {
                        depth -= 1
                        if depth == 0 {
                            blankBody(j, m)
                            // Comments inside the blanked block no longer count as comments.
                            return m
                        }
                    } else if Self.opensConditional(name) {
                        depth += 1
                    }
                    m = e
                } else {
                    m += 2
                }
                continue
            }
            m += 1
        }
        return nil
    }
}

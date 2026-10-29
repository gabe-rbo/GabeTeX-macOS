import Foundation
import TeXCore

// Finds, in LaTeX source text, the place that produced a word of the typeset PDF (and the reverse:
// describes the typeset word at a source offset). Pure Foundation, no UI, unit-tested by a local harness.
//
// SyncTeX only knows the *line*; these helpers narrow it down to the exact word:
//  - the source is read the way TeX typesets it: comments, command names and the arguments of
//    `\label`, `\ref`, `\cite`, `\begin`, … are skipped; LaTeX accents (`\'e`, `\~a`, `{\c c}`, `\"o`,
//    `\"{\i}`) and letters (`\ss`, `\ae`, `\o`, `\aa`) are decoded; `\-`, braces and `'` do not split a word;
//  - words are compared case-insensitively, without diacritics and with ligatures expanded
//    (compatibility normalization, ß → ss, æ → ae, …);
//  - a ≥ 4-letter prefix/suffix match is accepted when the PDF word is only a fragment of a hyphenated word;
//  - several candidates are ranked by context similarity (the words around the click), the distance to the
//    reported line and, when SyncTeX reports one, the column.

// MARK: - Model

/// One word of the typeset text, located in the source.
nonisolated struct SourceWord: Equatable, Sendable {
    /// The decoded word (original case, accents composed: `Poincar{\'e}` → "Poincaré").
    var display: String
    /// Lowercased, accent-free, letters and digits only ("poincare").
    var folded: String
    /// UTF-16 range in the source, from the first to the last character that contributes to the word.
    var range: NSRange
    /// 1-based line and column (UTF-16) of `range.location`.
    var line: Int
    var column: Int
}

/// What the PDF reported for a click.
nonisolated struct SourceWordQuery: Equatable, Sendable {
    var word: String
    var contextBefore: String = ""
    var contextAfter: String = ""
}

/// The word found in the source.
nonisolated struct SourceWordMatch: Equatable, Sendable {
    var range: NSRange
    var line: Int
    var score: Int
    /// The folded words are equal (not just a fragment).
    var isExact: Bool
}

/// The typeset word at a source offset, with the text around it (for matching it in the PDF).
nonisolated struct SourceWordTarget: Equatable, Sendable {
    var display: String
    var range: NSRange
    var contextBefore: String
    var contextAfter: String
}

// MARK: - Scanner

/// Reads LaTeX source the way it is typeset and returns its words.
nonisolated enum SourceWordScanner {
    nonisolated struct Entry: Sendable {
        var word: SourceWord
        /// Indices into `Result.sequence` of the first and last plain word this entry spans (equal for a plain
        /// word; a hyphen-joined compound such as "well-known" spans several).
        var first: Int
        var last: Int
    }

    nonisolated struct Result: Sendable {
        /// The plain words in document order.
        var sequence: [SourceWord] = []
        /// `sequence` plus hyphen-joined compounds.
        var entries: [Entry] = []
    }

    /// Words of the 1-based inclusive `lines` of `text`.
    static func scan(_ text: NSString, lineIndex: LineIndex, lines: ClosedRange<Int>) -> Result {
        let lo = min(max(1, lines.lowerBound), lineIndex.lineCount)
        let hi = min(max(lo, lines.upperBound), lineIndex.lineCount)
        let start = lineIndex.lineStarts[lo - 1]
        let end = lineIndex.lineEnds[hi - 1]
        guard end > start else { return Result() }
        var buffer = [unichar](repeating: 0, count: end - start)
        text.getCharacters(&buffer, range: NSRange(location: start, length: end - start))
        var scanner = Reader(buffer: buffer, base: start, lineIndex: lineIndex)
        scanner.run()
        return scanner.finish()
    }

    // MARK: Tables

    /// Accents written as a control symbol: `\'e` → é.
    private static let accentSymbols: [unichar: unichar] = [
        0x27: 0x301,    // '  acute
        0x60: 0x300,    // `  grave
        0x5E: 0x302,    // ^  circumflex
        0x22: 0x308,    // "  diaeresis
        0x7E: 0x303,    // ~  tilde
        0x3D: 0x304,    // =  macron
        0x2E: 0x307,    // .  dot above
    ]

    /// Accents written as a control word: `\c c` → ç.
    private static let accentWords: [String: unichar] = [
        "c": 0x327, "v": 0x30C, "u": 0x306, "H": 0x30B, "k": 0x328, "r": 0x30A, "d": 0x323, "b": 0x331,
    ]

    /// Letters written as a control word.
    private static let specialLetters: [String: String] = [
        "ss": "ß", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "o": "ø", "O": "Ø", "aa": "å", "AA": "Å",
        "l": "ł", "L": "Ł", "i": "i", "j": "j",
    ]

    /// Commands whose (optional arguments and) first mandatory argument is never typeset as text.
    private static let silentArgumentCommands: Set<String> = [
        "label", "ref", "eqref", "pageref", "autoref", "cref", "Cref", "vref", "nameref",
        "cite", "citep", "citet", "citealp", "citeauthor", "citeyear", "parencite", "textcite", "autocite",
        "footcite", "nocite", "bibitem",
        "input", "include", "subfile", "includegraphics", "includepdf", "lstinputlisting", "inputminted",
        "usepackage", "RequirePackage", "documentclass", "bibliography", "bibliographystyle", "addbibresource",
        "url", "href", "begin", "end",
        "newtheorem", "theoremstyle", "setlength", "setcounter", "addtocounter", "pagestyle", "thispagestyle",
        "pagenumbering", "hypersetup", "geometry", "definecolor", "colorlet", "color", "textcolor",
        "hspace", "vspace",
    ]

    // MARK: Character classes

    @inline(__always) static func isASCIILetter(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    static func isLetter(_ c: unichar) -> Bool {
        if c < 128 { return isASCIILetter(c) }
        guard let scalar = Unicode.Scalar(c) else { return false }
        return scalar.properties.isAlphabetic
    }

    @inline(__always) static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) static func isCombiningMark(_ c: unichar) -> Bool { c >= 0x300 && c <= 0x36F }
    @inline(__always) static func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 }
    @inline(__always) static func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 }

    private static func string(_ c: unichar) -> String {
        Unicode.Scalar(c).map { String($0) } ?? ""
    }

    private static func compose(_ base: String, _ mark: unichar) -> String {
        (base + string(mark)).precomposedStringWithCanonicalMapping
    }

    // MARK: The scanning state machine

    private nonisolated struct Reader {
        let buffer: [unichar]
        let base: Int
        let lineIndex: LineIndex
        let count: Int

        var words: [SourceWord] = []
        var joinedToPrevious: [Bool] = []
        var display = ""
        var start = -1
        var end = -1
        var startJoined = false
        var pendingJoin = false

        init(buffer: [unichar], base: Int, lineIndex: LineIndex) {
            self.buffer = buffer
            self.base = base
            self.lineIndex = lineIndex
            self.count = buffer.count
        }

        var hasWord: Bool { start >= 0 }

        mutating func append(_ piece: String, from: Int, to: Int) {
            if start < 0 {
                start = base + from
                startJoined = pendingJoin
                pendingJoin = false
            }
            display += piece
            end = base + to
        }

        mutating func flush() {
            defer { display = ""; start = -1; end = -1; startJoined = false }
            guard start >= 0 else { return }
            let folded = SourceWordLocator.fold(display)
            guard !folded.isEmpty else { return }
            let position = lineIndex.position(ofOffset: start)
            words.append(SourceWord(display: display, folded: folded, range: NSRange(location: start, length: max(0, end - start)),
                                    line: position.line, column: position.column))
            joinedToPrevious.append(startJoined)
        }

        mutating func breakWord() {
            flush()
            pendingJoin = false
        }

        mutating func run() {
            var i = 0
            while i < count {
                let c = buffer[i]
                switch c {
                case 0x25:                                  // % starts a comment
                    breakWord()
                    while i < count, !SourceWordScanner.isNewline(buffer[i]) { i += 1 }
                case 0x5C:                                  // backslash
                    i = backslash(at: i)
                case 0x7B, 0x7D:                            // { } are transparent: `Poincar{\'e}` is one word
                    i += 1
                case 0x2D:                                  // - joins "well-known" (single hyphen between letters)
                    if hasWord, i + 1 < count, SourceWordScanner.isLetter(buffer[i + 1]),
                       buffer[i + 1] != 0x2D, i == 0 || buffer[i - 1] != 0x2D {
                        flush()
                        pendingJoin = true
                    } else {
                        breakWord()
                    }
                    i += 1
                case 0x27, 0x2019, 0x2BC:                   // apostrophe inside a word: don't
                    if hasWord, i + 1 < count, SourceWordScanner.isLetter(buffer[i + 1]) {
                        append("\u{2019}", from: i, to: i + 1)
                    } else {
                        breakWord()
                    }
                    i += 1
                default:
                    if SourceWordScanner.isLetter(c) || SourceWordScanner.isDigit(c) {
                        append(SourceWordScanner.string(c), from: i, to: i + 1)
                    } else if SourceWordScanner.isCombiningMark(c), hasWord {
                        append(SourceWordScanner.string(c), from: i, to: i + 1)
                    } else {
                        breakWord()
                    }
                    i += 1
                }
            }
            breakWord()
        }

        // MARK: Backslash

        /// Handles the construct starting at `i` (a backslash); returns the index to continue from.
        private mutating func backslash(at i: Int) -> Int {
            guard i + 1 < count else {
                breakWord()
                return count
            }
            let d = buffer[i + 1]
            if SourceWordScanner.isASCIILetter(d) || d == 0x40 {
                var j = i + 1
                while j < count, SourceWordScanner.isASCIILetter(buffer[j]) || buffer[j] == 0x40 { j += 1 }
                let name = String(utf16CodeUnits: Array(buffer[(i + 1)..<j]), count: j - i - 1)
                return controlWord(name, start: i, after: j)
            }
            // Control symbol.
            if let mark = SourceWordScanner.accentSymbols[d] {
                if let (letter, next) = accentArgument(at: i + 2, allowSpaces: false) {
                    append(SourceWordScanner.compose(letter, mark), from: i, to: next)
                    return next
                }
                breakWord()
                return i + 2
            }
            if d == 0x2D || d == 0x2F { return i + 2 }      // \- (discretionary hyphen) and \/ are invisible
            breakWord()
            return i + 2
        }

        private mutating func controlWord(_ name: String, start i: Int, after j: Int) -> Int {
            if let mark = SourceWordScanner.accentWords[name] {
                if let (letter, next) = accentArgument(at: j, allowSpaces: true) {
                    append(SourceWordScanner.compose(letter, mark), from: i, to: next)
                    return next
                }
                breakWord()
                return j
            }
            if let letters = SourceWordScanner.specialLetters[name] {
                append(letters, from: i, to: j)
                return skipBlanks(j)        // TeX swallows the spaces after a control word: Stra\ss e → Straße
            }
            if name == "verb" {
                breakWord()
                var k = j
                if k < count, buffer[k] == 0x2A { k += 1 }
                guard k < count else { return count }
                let delimiter = buffer[k]
                k += 1
                while k < count, buffer[k] != delimiter, !SourceWordScanner.isNewline(buffer[k]) { k += 1 }
                return min(count, k + 1)
            }
            if SourceWordScanner.silentArgumentCommands.contains(name) {
                breakWord()
                return skipArguments(after: j)
            }
            breakWord()
            return j
        }

        private func skipBlanks(_ index: Int) -> Int {
            var k = index
            while k < count, SourceWordScanner.isBlank(buffer[k]) { k += 1 }
            return k
        }

        /// The letter of an accent's argument — `e`, `{e}`, `\i`, `{\i}` — and the index after it.
        private func accentArgument(at index: Int, allowSpaces: Bool) -> (String, Int)? {
            var k = index
            if allowSpaces { k = skipBlanks(k) }
            guard k < count else { return nil }
            if buffer[k] == 0x7B {
                k = skipBlanks(k + 1)
                guard let (letter, next) = baseLetter(at: k) else { return nil }
                k = skipBlanks(next)
                guard k < count, buffer[k] == 0x7D else { return nil }
                return (letter, k + 1)
            }
            return baseLetter(at: k)
        }

        private func baseLetter(at k: Int) -> (String, Int)? {
            guard k < count else { return nil }
            let c = buffer[k]
            if SourceWordScanner.isLetter(c) { return (SourceWordScanner.string(c), k + 1) }
            if c == 0x5C, k + 1 < count, buffer[k + 1] == 0x69 || buffer[k + 1] == 0x6A,
               k + 2 >= count || !SourceWordScanner.isASCIILetter(buffer[k + 2]) {
                // \i \j (dotless); TeX swallows the blanks after a control word: na\"\i ve → naïve
                return (buffer[k + 1] == 0x69 ? "i" : "j", skipBlanks(k + 2))
            }
            return nil
        }

        /// Skips `*`, `[optional]` arguments and one `{mandatory}` argument.
        private func skipArguments(after index: Int) -> Int {
            var k = skipBlanks(index)
            if k < count, buffer[k] == 0x2A { k = skipBlanks(k + 1) }
            while k < count, buffer[k] == 0x5B {
                guard let next = skipBalanced(from: k, open: 0x5B, close: 0x5D) else { return index }
                k = skipBlanks(next)
            }
            if k < count, buffer[k] == 0x7B, let next = skipBalanced(from: k, open: 0x7B, close: 0x7D) { return next }
            return index
        }

        /// The index after the delimiter that closes the one at `from`, or nil (unbalanced, > 600 characters or
        /// across a blank line — a half-typed argument must not swallow the rest of the paragraph).
        private func skipBalanced(from: Int, open: unichar, close: unichar) -> Int? {
            var depth = 0
            var k = from
            var newlines = 0
            let limit = min(count, from + 600)
            while k < limit {
                let c = buffer[k]
                if c == 0x5C { k += 2; continue }
                if SourceWordScanner.isNewline(c) {
                    let secondHalfOfCRLF = c == 10 && k > 0 && buffer[k - 1] == 13
                    if !secondHalfOfCRLF {
                        newlines += 1
                        if newlines >= 2 { return nil }      // a blank line ends the paragraph
                    }
                } else if !SourceWordScanner.isBlank(c) {
                    newlines = 0
                }
                if c == open { depth += 1 }
                if c == close {
                    depth -= 1
                    if depth == 0 { return k + 1 }
                }
                k += 1
            }
            return nil
        }

        // MARK: Result

        mutating func finish() -> Result {
            var result = Result()
            result.sequence = words
            // Plain words, then compounds for runs joined by single hyphens.
            for (index, word) in words.enumerated() {
                result.entries.append(Entry(word: word, first: index, last: index))
            }
            var index = 0
            while index < words.count {
                var last = index
                while last + 1 < words.count, joinedToPrevious[last + 1] { last += 1 }
                if last > index {
                    let parts = words[index...last]
                    let merged = SourceWord(
                        display: parts.map(\.display).joined(separator: "-"),
                        folded: parts.map(\.folded).joined(),
                        range: NSRange(location: words[index].range.location,
                                       length: NSMaxRange(words[last].range) - words[index].range.location),
                        line: words[index].line, column: words[index].column
                    )
                    result.entries.append(Entry(word: merged, first: index, last: last))
                }
                index = last + 1
            }
            return result
        }
    }
}

// MARK: - Locator

nonisolated enum SourceWordLocator {
    // MARK: Folding

    /// Lowercase, diacritic-free, ligature-free form of `text`, keeping only letters and digits.
    static func fold(_ text: String) -> String {
        var out = ""
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            guard scalar.value != 0xAD else { continue }         // soft hyphen
            let isDigit = scalar.properties.generalCategory == .decimalNumber
            guard scalar.properties.isAlphabetic || isDigit else { continue }
            let lower = scalar.properties.lowercaseMapping
            switch lower {
            case "ß": out += "ss"
            case "æ": out += "ae"
            case "œ": out += "oe"
            case "ø": out += "o"
            case "ł": out += "l"
            case "đ", "ð": out += "d"
            case "þ": out += "th"
            case "ı": out += "i"
            default: out += lower
            }
        }
        return out
    }

    /// The folded words of a context string, in order.
    static func contextWords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { fold($0) }
            .filter { !$0.isEmpty }
    }

    // MARK: PDF → source

    /// Finds the word `query` near the 1-based `line` (SyncTeX's answer) and `column` (nil when unknown).
    /// Searches `radius` lines around `line`; returns nil when the word is not found (callers then fall back
    /// to the whole line) or is too short to be told apart from its neighbours.
    static func locate(_ query: SourceWordQuery, in text: NSString, lineIndex: LineIndex,
                       line: Int, column: Int? = nil, radius: Int = 3) -> SourceWordMatch? {
        let folded = fold(query.word)
        guard !folded.isEmpty, lineIndex.lineCount > 0 else { return nil }
        let line = min(max(1, line), lineIndex.lineCount)
        let lowest = max(1, line - radius)
        let highest = min(lineIndex.lineCount, line + radius)
        let scan = SourceWordScanner.scan(text, lineIndex: lineIndex,
                                          lines: max(1, lowest - 4)...min(lineIndex.lineCount, highest + 4))

        // PDF context, nearest word first.
        let pdfBefore = Array(contextWords(query.contextBefore).suffix(6).reversed())
        let pdfAfter = Array(contextWords(query.contextAfter).prefix(6))

        struct Candidate {
            var entry: SourceWordScanner.Entry
            var score: Int
            var exact: Bool
            var context: Int
            var lineDistance: Int
            var columnDistance: Int
        }
        var candidates: [Candidate] = []
        for entry in scan.entries {
            let word = entry.word
            guard word.line >= lowest, word.line <= highest,
                  let (strength, exact) = matchStrength(query: folded, candidate: word.folded) else { continue }
            let before = Array(scan.sequence[max(0, entry.first - 8)..<entry.first].reversed().map(\.folded))
            let afterStart = min(scan.sequence.count, entry.last + 1)
            let after = scan.sequence[afterStart..<min(scan.sequence.count, afterStart + 8)].map(\.folded)
            let context = contextScore(pdfBefore, before) + contextScore(pdfAfter, after)
            let lineDistance = abs(word.line - line)
            var columnDistance = Int.max
            var columnBonus = 0
            if let column, word.line == line {
                columnDistance = abs(word.column - column)
                columnBonus = max(0, 12 - columnDistance / 3)
            }
            let score = strength - 10 * lineDistance + context + columnBonus
            candidates.append(Candidate(entry: entry, score: score, exact: exact, context: context,
                                        lineDistance: lineDistance, columnDistance: columnDistance))
        }
        guard !candidates.isEmpty else { return nil }

        let best = candidates.min { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.lineDistance != b.lineDistance { return a.lineDistance < b.lineDistance }
            if a.columnDistance != b.columnDistance { return a.columnDistance < b.columnDistance }
            return a.entry.word.range.location < b.entry.word.range.location
        }
        guard let best else { return nil }
        // A one- or two-letter word ("a", "of", a math variable) with nothing to tell the occurrences apart.
        if folded.count <= 2, best.context == 0, candidates.filter(\.exact).count > 1, column == nil { return nil }
        return SourceWordMatch(range: best.entry.word.range, line: best.entry.word.line, score: best.score, isExact: best.exact)
    }

    /// How well `candidate` (a folded source word) explains `query` (the folded PDF word).
    private static func matchStrength(query q: String, candidate c: String) -> (Int, Bool)? {
        if c == q { return (100, true) }
        if q.count >= 4 {
            if c.hasPrefix(q) { return (60, false) }         // the PDF word is the first part of a hyphenated word
            if c.hasSuffix(q) { return (50, false) }         // … or the last part
        }
        if c.count >= 4, q.count > c.count {
            // The PDF word carries a footnote mark or exponent glued to the word: "footnote1", "1footnote".
            let extra = q.count - c.count
            if (q.hasPrefix(c) && q.suffix(extra).allSatisfy(\.isNumber))
                || (q.hasSuffix(c) && q.prefix(extra).allSatisfy(\.isNumber)) {
                return (40, false)
            }
        }
        return nil
    }

    /// How well two context word lists (nearest word first) agree: words that line up with the click count most
    /// (12 for the first, 6 for each further one), words found further out in the same order count 3 each.
    private static func contextScore(_ pdf: [String], _ source: [String]) -> Int {
        var aligned = 0
        while aligned < min(pdf.count, source.count), similar(pdf[aligned], source[aligned]) { aligned += 1 }
        let alignedBonus = aligned == 0 ? 0 : 12 + 6 * (aligned - 1)
        return alignedBonus + 3 * commonCount(pdf, source)
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return min(a.count, b.count) >= 4 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    /// Length of the longest common subsequence of two word lists (nearest word first).
    private static func commonCount(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = similar(a[i - 1], b[j - 1]) ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table[a.count][b.count]
    }

    // MARK: Source → PDF

    /// The typeset word touching `offset` (inside it, or right after it) with ~`contextCharacters` of decoded
    /// text on each side. Nil in a comment, a command name, an ignored argument or between words.
    static func target(at offset: Int, in text: NSString, lineIndex: LineIndex, contextCharacters: Int = 40) -> SourceWordTarget? {
        guard lineIndex.lineCount > 0 else { return nil }
        let line = lineIndex.line(ofOffset: offset)
        let scan = SourceWordScanner.scan(text, lineIndex: lineIndex,
                                          lines: max(1, line - 4)...min(lineIndex.lineCount, line + 4))
        let words = scan.sequence
        guard let index = words.firstIndex(where: { offset >= $0.range.location && offset < NSMaxRange($0.range) })
                ?? words.firstIndex(where: { NSMaxRange($0.range) == offset }) else { return nil }

        var before: [String] = []
        var total = 0
        var k = index - 1
        while k >= 0, total < contextCharacters {
            before.append(words[k].display)
            total += words[k].display.count + 1
            k -= 1
        }
        var after: [String] = []
        total = 0
        k = index + 1
        while k < words.count, total < contextCharacters {
            after.append(words[k].display)
            total += words[k].display.count + 1
            k += 1
        }
        return SourceWordTarget(
            display: words[index].display,
            range: words[index].range,
            contextBefore: String(before.reversed().joined(separator: " ").suffix(contextCharacters)),
            contextAfter: String(after.joined(separator: " ").prefix(contextCharacters))
        )
    }

    /// True when `range` starts in ordinary text: not right after a backslash (a command name) and not behind
    /// an unescaped `%` on its line.
    static func isPlainText(_ range: NSRange, in text: NSString, lineIndex: LineIndex) -> Bool {
        guard range.location >= 0, range.location <= text.length else { return false }
        if range.location > 0, text.character(at: range.location - 1) == 0x5C { return false }
        let line = lineIndex.line(ofOffset: range.location)
        let lineStart = lineIndex.lineStarts[line - 1]
        var k = lineStart
        while k < range.location {
            let c = text.character(at: k)
            if c == 0x5C { k += 2; continue }
            if c == 0x25 { return false }
            k += 1
        }
        return true
    }

    /// The line `line` without its leading blanks (what to highlight when the word cannot be found).
    static func lineRange(_ line: Int, in text: NSString, lineIndex: LineIndex) -> NSRange {
        let content = lineIndex.contentsRange(ofLine: line)
        var start = content.location
        let end = NSMaxRange(content)
        while start < end, [0x20, 0x09].contains(text.character(at: start)) { start += 1 }
        return NSRange(location: start, length: end - start)
    }
}

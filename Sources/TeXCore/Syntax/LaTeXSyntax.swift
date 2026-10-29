import Foundation

// MARK: - UTF-16 helpers shared by the tokenizer, scanner, linter and completion engine

@inline(__always) func isASCIILetter(_ c: UInt16) -> Bool { (c &- 65) < 26 || (c &- 97) < 26 }
@inline(__always) func isASCIIDigit(_ c: UInt16) -> Bool { (c &- 48) < 10 }
/// Letters allowed in a control word (`@` is a letter inside packages and is accepted everywhere).
@inline(__always) func isCommandLetter(_ c: UInt16) -> Bool { isASCIILetter(c) || c == 64 }
@inline(__always) func isHSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
@inline(__always) func isLineBreak(_ c: UInt16) -> Bool { c == 10 || c == 13 }
@inline(__always) func isTeXWhitespace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
@inline(__always) func isHighSurrogate(_ c: UInt16) -> Bool { (c & 0xFC00) == 0xD800 }
@inline(__always) func isLowSurrogate(_ c: UInt16) -> Bool { (c & 0xFC00) == 0xDC00 }

@inline(__always) func utf16String(_ u: [UInt16], _ r: Range<Int>) -> String {
    String(decoding: u[r], as: UTF16.self)
}

@inline(__always) func nsRange(_ r: Range<Int>) -> NSRange {
    NSRange(location: r.lowerBound, length: r.upperBound - r.lowerBound)
}

/// ASCII-lowercased copy of a code unit (non-ASCII untouched).
@inline(__always) func asciiLower(_ c: UInt16) -> UInt16 {
    (c &- 65) < 26 ? c &+ 32 : c
}

// MARK: - Static knowledge about LaTeX

/// What the tokenizer / scanner need to know about a control word.
struct CommandInfo: Sendable {
    enum Special: Sendable { case none, begin, end, verb, url }
    var special: Special = .none
    var isStructure = false
    var allowsStar = false
    var takesReference = false
}

enum LaTeXSyntax {
    // MARK: Environments

    /// Environments whose body is copied verbatim (no commands, no comments).
    static let verbatimEnvironments: Set<String> = [
        "verbatim", "verbatim*", "Verbatim", "Verbatim*", "BVerbatim", "BVerbatim*",
        "LVerbatim", "LVerbatim*", "lstlisting", "minted", "comment",
        "filecontents", "filecontents*", "spverbatim", "verbatimtab",
    ]

    /// Verbatim-like environments that accept an `[options]` argument right after `\begin{name}`.
    static let verbatimWithOptions: Set<String> = [
        "Verbatim", "Verbatim*", "BVerbatim", "BVerbatim*", "LVerbatim", "LVerbatim*",
        "lstlisting", "minted",
    ]

    /// Environments that switch the document into math mode.
    static let mathEnvironments: Set<String> = {
        var set = Set<String>()
        for base in ["equation", "align", "alignat", "flalign", "gather", "multline",
                     "eqnarray", "math", "displaymath", "dmath"] {
            set.insert(base)
            set.insert(base + "*")
        }
        return set
    }()

    /// Environments that only make sense inside math (used to rank `\begin{` suggestions).
    static let innerMathEnvironments: Set<String> = [
        "aligned", "alignedat", "gathered", "split", "cases", "dcases", "rcases", "matrix",
        "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "array", "subarray",
    ]

    /// Commands whose braced argument is typeset in text mode even inside math.
    static let textModeCommands: Set<String> = [
        "text", "mbox", "hbox", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal",
        "textup", "textsl", "textsc", "intertext", "shortintertext", "emph", "fbox", "parbox",
    ]

    // MARK: Sectioning

    static let sectioningKinds: [String: OutlineEntry.Kind] = [
        "part": .part, "chapter": .chapter, "section": .section, "subsection": .subsection,
        "subsubsection": .subsubsection, "paragraph": .paragraph, "subparagraph": .subparagraph,
    ]

    // MARK: Command classification (tokenizer)

    private static let referenceNames: [String] = [
        "label", "ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "vref", "Vref",
        "labelcref", "cpageref", "Cpageref", "input", "include", "subfile", "includegraphics",
        "includepdf", "usepackage", "RequirePackage", "documentclass", "LoadClass", "bibliography",
        "addbibresource", "bibliographystyle", "lstinputlisting", "bibitem", "includesvg",
    ]

    private static let structureNames: [String] = [
        "begin", "end", "documentclass", "usepackage", "RequirePackage", "input", "include",
        "subfile", "maketitle", "tableofcontents", "appendix", "frontmatter", "mainmatter",
        "backmatter", "bibliography", "printbibliography",
    ]

    private static let commandTable: [String: CommandInfo] = {
        var table: [String: CommandInfo] = [:]
        for name in referenceNames { table[name, default: CommandInfo()].takesReference = true }
        for name in structureNames { table[name, default: CommandInfo()].isStructure = true }
        for name in sectioningKinds.keys {
            table[name, default: CommandInfo()].isStructure = true
            table[name, default: CommandInfo()].allowsStar = true
        }
        table["begin", default: CommandInfo()].special = .begin
        table["end", default: CommandInfo()].special = .end
        table["verb", default: CommandInfo()].special = .verb
        table["Verb", default: CommandInfo()].special = .verb
        table["lstinline", default: CommandInfo()].special = .verb
        table["url", default: CommandInfo()].special = .url
        table["href", default: CommandInfo()].special = .url
        return table
    }()

    private static let citeInfo = CommandInfo(special: .none, isStructure: false, allowsStar: false, takesReference: true)

    /// Classification of a control word, or nil for an ordinary command.
    static func commandInfo(_ name: String) -> CommandInfo? {
        if let info = commandTable[name] { return info }
        return isCiteLike(name) ? citeInfo : nil
    }

    /// `\cite`, `\citep`, `\Citet`, `\parencite`, `\textcite`, `\autocite`, `\footcite`, `\nocite` ...
    static func isCiteLike(_ name: String) -> Bool {
        let bytes = name.utf8
        guard bytes.count >= 4, let first = bytes.first, let last = bytes.last else { return false }
        if first == 99 || first == 67 { // c C
            let lower = name.lowercased()
            return lower.hasPrefix("cite") && lower != "citestyle"
        }
        if last == 101 { // e
            return name.lowercased().hasSuffix("cite")
        }
        return false
    }

    // MARK: Verbatim helpers (shared by tokenizer and source mask)

    struct VerbatimOpening {
        /// Offset where the verbatim body starts.
        var bodyStart: Int
        /// `[options]` including brackets.
        var options: Range<Int>?
        /// `{language}` of minted including braces.
        var language: Range<Int>?
    }

    /// Finds the end of a `[...]` group starting at `open` on the same line (brace aware). Returns the
    /// index of the closing `]`.
    static func closingBracketOnLine(_ u: [UInt16], open: Int, limit: Int = 300) -> Int? {
        let n = u.count
        guard open < n, u[open] == 91 else { return nil }
        var depth = 0
        var k = open + 1
        let stop = min(n, open + limit)
        while k < stop {
            let c = u[k]
            if isLineBreak(c) { return nil }
            if c == 92 { k += 2; continue }
            if c == 123 { depth += 1 } else if c == 125 { depth -= 1 } else if c == 93 && depth <= 0 { return k }
            k += 1
        }
        return nil
    }

    /// Index of the closing `}` of a `{...}` group starting at `open` that stays on one line.
    static func closingBraceOnLine(_ u: [UInt16], open: Int, limit: Int = 200) -> Int? {
        let n = u.count
        guard open < n, u[open] == 123 else { return nil }
        var depth = 0
        var k = open
        let stop = min(n, open + limit)
        while k < stop {
            let c = u[k]
            if isLineBreak(c) { return nil }
            if c == 92 { k += 2; continue }
            if c == 123 { depth += 1 } else if c == 125 { depth -= 1; if depth == 0 { return k } }
            k += 1
        }
        return nil
    }

    static func verbatimOpening(_ u: [UInt16], name: String, from p: Int) -> VerbatimOpening {
        var opening = VerbatimOpening(bodyStart: p, options: nil, language: nil)
        guard verbatimWithOptions.contains(name) else { return opening }
        let n = u.count
        if opening.bodyStart < n, u[opening.bodyStart] == 91,
           let close = closingBracketOnLine(u, open: opening.bodyStart) {
            opening.options = opening.bodyStart..<(close + 1)
            opening.bodyStart = close + 1
        }
        if name == "minted" {
            var k = opening.bodyStart
            while k < n && isHSpace(u[k]) { k += 1 }
            if k < n, u[k] == 123, let close = closingBraceOnLine(u, open: k) {
                opening.language = k..<(close + 1)
                opening.bodyStart = close + 1
            }
        }
        return opening
    }

    /// Offset of the `\` of `\end{name}` searching from `from`; `u.count` when unterminated.
    static func verbatimEnd(_ u: [UInt16], name: String, from: Int) -> Int {
        let pattern = Array("\\end{\(name)}".utf16)
        let m = pattern.count
        let n = u.count
        var k = from
        while k + m <= n {
            if u[k] == 92 {
                var t = 1
                while t < m && u[k + t] == pattern[t] { t += 1 }
                if t == m { return k }
            }
            k += 1
        }
        return n
    }

    /// Reads an environment name inside `{...}` starting at `open` (a `{`). Returns the name range (without
    /// braces) and the offset just after the closing brace.
    static func environmentName(_ u: [UInt16], open: Int) -> (name: Range<Int>, end: Int)? {
        let n = u.count
        guard open < n, u[open] == 123 else { return nil }
        var k = open + 1
        let stop = min(n, open + 120)
        while k < stop {
            let c = u[k]
            if c == 125 { return ((open + 1)..<k, k + 1) }
            if c == 123 || c == 92 || c == 37 || isLineBreak(c) { return nil }
            k += 1
        }
        return nil
    }
}

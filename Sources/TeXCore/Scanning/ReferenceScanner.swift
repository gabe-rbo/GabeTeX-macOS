import Foundation

/// A key written in the source with the exact place of the key text: the argument of a reference
/// (`\ref{key}`), a citation (`\cite{key}`), a `\label{key}` or a `\bibitem{key}`.
///
/// `line` and `column` are 1-based and `column` / `length` / `offset` count UTF-16 units, so
/// `NSRange(location: offset, length: length)` is exactly the key in the file's `NSString`.
public struct KeyOccurrence: Hashable, Sendable {
    /// The key as written, without surrounding whitespace.
    public var key: String
    public var fileURL: URL
    public var line: Int
    public var column: Int
    /// Length of `key` in UTF-16 units.
    public var length: Int
    /// UTF-16 offset of the first character of the key in its file.
    public var offset: Int
    /// The control word that carries the key, without the backslash (`"cref"`, `"parencite"`, `"label"`,
    /// `"bibitem"`; `"begin"` / `"lstinputlisting"` / `"newlabel"` for labels defined through an option).
    public var command: String
    /// The key sits between a TeX `\if…` and its `\fi` (so it may be one of several alternatives).
    public var isConditional: Bool

    public init(key: String, fileURL: URL, line: Int, column: Int, length: Int, offset: Int, command: String,
                isConditional: Bool = false) {
        self.key = key
        self.fileURL = fileURL
        self.line = line
        self.column = column
        self.length = length
        self.offset = offset
        self.command = command
        self.isConditional = isConditional
    }

    /// The key's range in the file's UTF-16 text.
    public var range: NSRange { NSRange(location: offset, length: length) }
}

/// Everything the reference scan of one file yields.
public struct ReferenceScan: Hashable, Sendable {
    /// Every `\label{key}` (not deduplicated).
    public var labels: [KeyOccurrence] = []
    /// Labels defined without `\label`: a `label=key` option of `\begin{…}[…]` / `\lstinputlisting[…]`
    /// (listings, thmtools …) and a hand-written `\newlabel{key}{…}`. They count as defined but are never
    /// reported as duplicates (an option named `label` is often a format, not a key).
    public var optionLabels: [KeyOccurrence] = []
    /// Every key of a reference command (`\ref \eqref \cref{a,b} \crefrange{a}{b} \hyperref[key]{…}` …).
    public var references: [KeyOccurrence] = []
    /// Every key of a citation command (`\cite \citep \parencite{a,b}` …); `\nocite{*}` is skipped.
    public var citations: [KeyOccurrence] = []
    /// Every `\bibitem[label]{key}`.
    public var bibItems: [KeyOccurrence] = []
    /// Prefixes of label keys a macro builds at run time (`\label{sec:#1}` → `"sec:"`; `\label{#1}` → `""`).
    /// A reference that starts with such a prefix cannot be proven undefined.
    public var dynamicLabelPrefixes: [String] = []
    /// `\externaldocument` (xr, xr-hyper, zref-xr) or one of those packages: labels may live in another document.
    public var usesExternalDocuments = false
    /// `\externalcitedocument` (xcite): citations may be defined by another document.
    public var usesExternalCitations = false

    public init() {}
}

/// Finds every use of a reference or citation key, and every label / bibitem definition, in one source.
///
/// Comments, verbatim bodies and `\iffalse` blocks are ignored (the scan runs on a `MaskedSource`). Keys
/// that contain `#`, `\`, braces or a line break cannot be compared statically and are not recorded; for
/// `\label` they are remembered as `dynamicLabelPrefixes` instead.
public enum ReferenceScanner {
    // MARK: Public tables (the checks iterate them)

    /// Commands whose mandatory argument is a comma list of label keys.
    public static let referenceCommands: Set<String> = [
        "ref", "eqref", "pageref", "autoref", "nameref", "vref", "Vref", "cref", "Cref", "cpageref", "Cpageref",
        "labelcref", "labelcpageref", "subref", "autopageref", "fref", "Fref", "namecref", "nameCref",
        "lcnamecref", "namecrefs", "nameCrefs", "lcnamecrefs",
    ]

    /// Commands with two mandatory label arguments (`\crefrange{first}{last}`).
    public static let referenceRangeCommands: Set<String> = [
        "crefrange", "Crefrange", "cpagerefrange", "Cpagerefrange", "vrefrange", "Vrefrange",
    ]

    /// Commands whose first mandatory argument is a comma list of citation keys.
    public static let citationCommands: Set<String> = [
        // LaTeX / natbib
        "cite", "citep", "citet", "citealp", "citealt", "citeauthor", "citeyear", "citeyearpar", "citenum",
        "Citep", "Citet", "Citealp", "Citealt", "Citeauthor", "citetalias", "citepalias", "Citetalias", "Citepalias",
        // biblatex
        "Cite", "parencite", "Parencite", "textcite", "Textcite", "autocite", "Autocite", "footcite", "footcitetext",
        "smartcite", "Smartcite", "supercite", "citetitle", "Citetitle", "citedate", "citeurl", "fullcite",
        "footfullcite", "citefield", "nocite",
        // biblatex multicites: only the first key group is read
        "cites", "Cites", "parencites", "Parencites", "textcites", "Textcites", "autocites", "Autocites",
        "footcites", "smartcites", "Smartcites", "supercites",
    ]

    // MARK: Scan

    /// Scans `text`. Positions refer to `text` as given (line endings `\n`, `\r\n` and `\r` are all handled).
    public static func scan(_ text: String, fileURL: URL) -> ReferenceScan {
        scan(MaskedSource(text), fileURL: fileURL)
    }

    private enum Kind {
        case reference, referenceRange, hyperref, citation, label, newLabel, bibItem, begin, listing
        case externalDocument, externalCitations, package, newIf
    }

    private static let table: [String: Kind] = {
        var table: [String: Kind] = [:]
        for name in referenceCommands { table[name] = .reference }
        for name in referenceRangeCommands { table[name] = .referenceRange }
        for name in citationCommands { table[name] = .citation }
        table["hyperref"] = .hyperref
        table["label"] = .label
        table["newlabel"] = .newLabel
        table["bibitem"] = .bibItem
        table["begin"] = .begin
        table["lstinputlisting"] = .listing
        table["externaldocument"] = .externalDocument
        table["zexternaldocument"] = .externalDocument
        table["externalcitedocument"] = .externalCitations
        table["newif"] = .newIf
        table["usepackage"] = .package
        table["RequirePackage"] = .package
        return table
    }()

    private static let externalDocumentPackages: Set<String> = ["xr", "xr-hyper", "zref-xr"]

    /// Prefixes of names that start with `if` but take their branches as braced arguments (etoolbox, ifthen,
    /// ifdraft …): they are not closed by `\fi`.
    private static let bracedConditionalPrefixes = [
        "ifdef", "ifundef", "ifstr", "ifbool", "ifblank", "ifnumcomp", "ifnumequal", "ifnumgreater", "ifnumless",
        "ifnumodd", "ifdimcomp", "ifdimequal", "ifdimgreater", "ifdimless", "ifdimodd", "ifcsdef", "ifcsundef",
        "ifcsstring", "ifcsempty", "ifcsvoid", "iftoggle", "ifpackage", "ifclass", "ifdraft", "ifinlist", "ifrmnum",
        "ifpatchable",
    ]

    /// `\ifx`, `\iftrue`, `\ifdefined`, `\ifmmode`, the `\iffoo` a `\newif` made …: closed by a `\fi`.
    private static func opensConditional(_ name: String) -> Bool {
        guard name.hasPrefix("if") else { return false }
        if name == "if" || name == "ifdefined" || name == "ifcsname" || name == "iffontchar" { return true }
        if name == "iff" || name == "ifthenelse" { return false }     // the arrow; ifthen takes arguments
        for prefix in bracedConditionalPrefixes where name.hasPrefix(prefix) { return false }
        return true
    }

    private static let labelWord: [UInt16] = Array("label".utf16)

    static func scan(_ src: MaskedSource, fileURL: URL) -> ReferenceScan {
        var result = ReferenceScan()
        let u = src.masked
        let n = u.count
        var prefixes = Set<String>()
        var conditionalDepth = 0

        /// The key at `range` (already trimmed), or nil when it cannot be compared statically.
        func occurrence(_ range: Range<Int>, _ command: String) -> KeyOccurrence? {
            guard !range.isEmpty else { return nil }
            var k = range.lowerBound
            while k < range.upperBound {
                let c = u[k]
                if c == 35 || c == 92 || c == 123 || c == 125 || isLineBreak(c) { return nil }
                k += 1
            }
            let position = src.position(at: range.lowerBound)
            return KeyOccurrence(key: utf16String(u, range), fileURL: fileURL, line: position.line,
                                 column: position.column, length: range.count, offset: range.lowerBound,
                                 command: command, isConditional: conditionalDepth > 0)
        }

        func addList(_ group: Range<Int>, _ command: String, to keep: inout [KeyOccurrence], skipStar: Bool = false) {
            for item in TeXArguments.splitList(u, group) {
                if skipStar && item.count == 1 && u[item.lowerBound] == 42 { continue }
                if let found = occurrence(item, command) { keep.append(found) }
            }
        }

        /// `label=key` entries of an option list.
        func addOptionLabels(_ options: Range<Int>, _ command: String) {
            for item in TeXArguments.splitList(u, options) where item.count > 6 {
                var p = item.lowerBound
                var matches = true
                for (offset, letter) in labelWord.enumerated() where u[p + offset] != letter {
                    matches = false
                    break
                }
                guard matches else { continue }
                p += labelWord.count
                while p < item.upperBound && isTeXWhitespace(u[p]) { p += 1 }
                guard p < item.upperBound, u[p] == 61 else { continue }
                var value = TeXArguments.trimmed(u, (p + 1)..<item.upperBound)
                if value.count >= 2, u[value.lowerBound] == 123, u[value.upperBound - 1] == 125 {
                    value = TeXArguments.trimmed(u, (value.lowerBound + 1)..<(value.upperBound - 1))
                }
                if let found = occurrence(value, command) { result.optionLabels.append(found) }
            }
        }

        /// `[options]` right after `from`, if any.
        func options(after from: Int) -> Range<Int>? {
            let p = TeXArguments.skipWhitespace(u, from)
            guard p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p) else { return nil }
            return group.content
        }

        var i = 0
        while i < n {
            guard u[i] == 92 else { i += 1; continue }
            guard i + 1 < n else { break }
            let d = u[i + 1]
            guard isCommandLetter(d) else {
                if isLineBreak(d) { i += 1 }
                else if isHighSurrogate(d) && i + 2 < n && isLowSurrogate(u[i + 2]) { i += 3 }
                else { i += 2 }
                continue
            }
            var j = i + 2
            while j < n && isCommandLetter(u[j]) { j += 1 }
            let length = j - i - 1
            if length == 2, d == 102, u[i + 2] == 105 {            // \fi
                conditionalDepth = max(0, conditionalDepth - 1)
                i = j
                continue
            }
            if length == 2, d == 105, u[i + 2] == 102 {            // \if
                conditionalDepth += 1
                i = j
                continue
            }
            guard length >= 3, length <= 20 else { i = j; continue }
            let name = String(decoding: u[(i + 1)..<j], as: UTF16.self)
            if d == 105, u[i + 2] == 102, opensConditional(name) {   // \ifx, \iftrue …
                conditionalDepth += 1
                i = j
                continue
            }
            guard let kind = table[name] else { i = j; continue }
            i = j

            switch kind {
            case .reference:
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1), let list = call.mandatory.first
                else { break }
                addList(list, name, to: &result.references)

            case .referenceRange:
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 2), call.mandatory.count == 2
                else { break }
                for group in call.mandatory { addList(group, name, to: &result.references) }

            case .hyperref:
                // `\hyperref[label]{text}`; the older `\hyperref{url}{category}{name}{text}` has no label.
                guard let group = options(after: j) else { break }
                if let found = occurrence(TeXArguments.trimmed(u, group), name) { result.references.append(found) }

            case .citation:
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1), let list = call.mandatory.first
                else { break }
                addList(list, name, to: &result.citations, skipStar: true)

            case .label:
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1, allowStar: false),
                      let group = call.mandatory.first else { break }
                let r = TeXArguments.trimmed(u, group)
                guard !r.isEmpty else { break }
                if let found = occurrence(r, name) {
                    result.labels.append(found)
                } else if !r.contains(where: { isLineBreak(u[$0]) }) {
                    // `\label{sec:#1}`, `\label{fig:\thechapter}` …: the macro builds the key at run time.
                    var k = r.lowerBound
                    while k < r.upperBound, ![35, 92, 123, 125].contains(u[k]) { k += 1 }
                    prefixes.insert(utf16String(u, r.lowerBound..<k))
                }

            case .newLabel:
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1, allowStar: false),
                      let group = call.mandatory.first else { break }
                if let found = occurrence(TeXArguments.trimmed(u, group), name) { result.optionLabels.append(found) }

            case .bibItem:
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1, allowStar: false),
                      let group = call.mandatory.first else { break }
                if let found = occurrence(TeXArguments.trimmed(u, group), name) { result.bibItems.append(found) }

            case .begin:
                var k = j
                while k < n && isHSpace(u[k]) { k += 1 }
                guard let parsed = LaTeXSyntax.environmentName(u, open: k) else { break }
                i = parsed.end
                if let group = options(after: parsed.end) { addOptionLabels(group, name) }

            case .listing:
                if let group = options(after: j) { addOptionLabels(group, name) }

            case .externalDocument:
                result.usesExternalDocuments = true

            case .externalCitations:
                result.usesExternalCitations = true

            case .newIf:
                // `\newif\iffoo` declares a conditional: the `\iffoo` that follows does not open one.
                let p = TeXArguments.skipWhitespace(u, j)
                if p < n, u[p] == 92, let sequence = TeXArguments.controlSequence(u, at: p) { i = sequence.end }

            case .package:
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1, allowStar: false),
                      let list = call.mandatory.first else { break }
                for item in TeXArguments.splitList(u, list)
                where externalDocumentPackages.contains(utf16String(u, item)) {
                    result.usesExternalDocuments = true
                }
            }
        }
        result.dynamicLabelPrefixes = prefixes.sorted()
        return result
    }
}

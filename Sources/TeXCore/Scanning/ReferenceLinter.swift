import Foundation

/// One warning of `ReferenceLinter` with what it is about.
public struct ReferenceFinding: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case undefinedReference
        case duplicateLabel
        case missingCitation
    }

    public var kind: Kind
    /// The label or citation key the warning is about.
    public var key: String
    public var diagnostic: Diagnostic

    public init(kind: Kind, key: String, diagnostic: Diagnostic) {
        self.kind = kind
        self.key = key
        self.diagnostic = diagnostic
    }
}

/// Live checks of cross-references and citations over a whole project, from the data `ProjectIndex`
/// records (`labelSites`, `referenceUses`, `citationUses`, `bibEntries`, `bibItems` …). Pure and fast: no
/// file access, linear in the number of keys.
///
/// - **Undefined reference** — a warning on the key of every `\ref`-like use whose label is defined nowhere
///   in the project. Skipped entirely when the project uses `xr` / `xr-hyper` (`\externaldocument`), because
///   the label may live in another document. A label can also be defined by a `label=` option (listings,
///   thmtools …) or built by a macro (`\label{sec:#1}`); references that such a definition could satisfy are
///   not reported; `LastPage` and `TotPages` (lastpage, totpages) are always defined.
/// - **Duplicate label** — a warning on the key of *every* definition of a label that is defined more than
///   once; `detail` names the other places (`file:line`). Definitions that sit between a TeX `\if…` and its
///   `\fi` may be alternatives of one another, so a label is only reported when at least two of its
///   definitions are unconditional.
/// - **Missing citation** — a warning on the key of every citation that is neither an entry of the project's
///   `.bib` files nor a `\bibitem`. Nothing is reported when the project has no bibliography source at all
///   (the user may not be done yet), when a bibliography file cannot be found or read (its keys are unknown),
///   or when the project uses `\externalcitedocument`. `.bib` keys match case-insensitively, as BibTeX does;
///   `\bibitem` keys match exactly.
///
/// Every diagnostic has `severity: .warning`, `source: .structure`, and `line` / `column` / `length` of the
/// key (UTF-16), so an editor that underlines `column ..< column + length` underlines exactly the key.
/// Messages are localized with `String(localized:)`. The result is ordered by file (document order of the
/// index) and then by position.
public enum ReferenceLinter {
    /// The warnings for `index`; see the type's documentation.
    public static func diagnostics(index: ProjectIndex) -> [Diagnostic] {
        findings(index: index).map(\.diagnostic)
    }

    /// The same warnings together with what each one is about (kind and key).
    public static func findings(index: ProjectIndex) -> [ReferenceFinding] {
        var found: [(file: Int, offset: Int, finding: ReferenceFinding)] = []
        var order: [URL: Int] = [:]
        for (position, file) in index.files.enumerated() where order[file] == nil { order[file] = position }

        func add(_ kind: ReferenceFinding.Kind, _ use: KeyOccurrence, message: String, detail: String? = nil) {
            let diagnostic = Diagnostic(severity: .warning, source: .structure, message: message, detail: detail,
                                        fileURL: use.fileURL, line: use.line, column: use.column,
                                        length: max(1, use.length))
            found.append((order[use.fileURL] ?? Int.max, use.offset,
                          ReferenceFinding(kind: kind, key: use.key, diagnostic: diagnostic)))
        }

        // MARK: Duplicate labels

        if index.labelSites.count > 1 {
            var groups: [String: [KeyOccurrence]] = [:]
            for site in index.labelSites { groups[site.key, default: []].append(site) }
            let root = index.rootFile.deletingLastPathComponent().path
            for sites in groups.values where sites.count > 1 {
                // Alternatives of one `\if…\else…\fi` (`\ifenglish \label{intro} \else \label{intro} \fi`) define
                // the label on purpose: report only when at least two definitions always run.
                if sites.reduce(0, { $0 + ($1.isConditional ? 0 : 1) }) < 2 { continue }
                let ordered = sites.sorted { a, b in
                    let fa = order[a.fileURL] ?? Int.max
                    let fb = order[b.fileURL] ?? Int.max
                    return fa != fb ? fa < fb : a.offset < b.offset
                }
                for site in ordered {
                    var places: [String] = []
                    for other in ordered {
                        if places.count >= maxListedPlaces { break }
                        if other.fileURL == site.fileURL && other.offset == site.offset { continue }
                        places.append("\(displayPath(other.fileURL, root: root)):\(other.line)")
                    }
                    let shown = places.joined(separator: ", ")
                    let hidden = ordered.count - 1 - places.count
                    let detail = hidden > 0
                        ? String(localized: "Also defined at \(shown) and \(hidden) more")
                        : String(localized: "Also defined at \(shown)")
                    add(.duplicateLabel, site, message: String(localized: "Label ‘\(site.key)’ is defined more than once"), detail: detail)
                }
            }
        }

        // MARK: Undefined references

        if !index.usesExternalDocuments && !index.referenceUses.isEmpty {
            var defined = automaticLabels
            for site in index.labelSites { defined.insert(site.key) }
            for site in index.optionLabels { defined.insert(site.key) }
            let prefixes = index.dynamicLabelPrefixes
            for use in index.referenceUses where !defined.contains(use.key) {
                if prefixes.contains(where: { use.key.hasPrefix($0) }) { continue }
                add(.undefinedReference, use, message: String(localized: "Reference ‘\(use.key)’ is not defined"))
            }
        }

        // MARK: Missing citations

        let hasBibliography = !index.bibFiles.isEmpty || !index.bibItems.isEmpty
        if hasBibliography && !index.hasUnknownBibliographySource && !index.usesExternalCitations
            && !index.citationUses.isEmpty {
            var entryKeys = Set<String>()
            for entry in index.bibEntries { entryKeys.insert(entry.key.lowercased()) }
            var itemKeys = Set<String>()
            for item in index.bibItems { itemKeys.insert(item.key) }
            for use in index.citationUses where !itemKeys.contains(use.key) && !entryKeys.contains(use.key.lowercased()) {
                add(.missingCitation, use, message: String(localized: "Citation ‘\(use.key)’ is not in the bibliography"))
            }
        }

        found.sort { a, b in
            if a.file != b.file { return a.file < b.file }
            return a.offset < b.offset
        }
        return found.map(\.finding)
    }

    /// Recognizes the warnings LaTeX itself prints about the same problems —
    /// ``Reference `k' on page 3 undefined``, ``Citation `k' on page 3 undefined`` and
    /// ``Label `k' multiply defined`` (trailing period optional, any quote style) — so a host can hide them
    /// while it shows the live warning for the same key.
    public static func texWarning(_ message: String) -> (kind: ReferenceFinding.Kind, key: String)? {
        var text = message.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".") { text.removeLast() }
        let kind: ReferenceFinding.Kind
        let head: String
        if text.hasSuffix(" multiply defined") {
            kind = .duplicateLabel
            head = "Label "
            text.removeLast(" multiply defined".count)
        } else if text.hasSuffix(" undefined"), let r = text.range(of: " on page ", options: .backwards) {
            text.removeSubrange(r.lowerBound...)
            if text.hasPrefix("Reference ") {
                kind = .undefinedReference
                head = "Reference "
            } else if text.hasPrefix("Citation ") {
                kind = .missingCitation
                head = "Citation "
            } else {
                return nil
            }
        } else {
            return nil
        }
        // What is left is the word, then the key between two quotes.
        guard text.hasPrefix(head) else { return nil }
        let quoted = text.dropFirst(head.count)
        let quotes: Set<Character> = ["`", "'", "\u{2018}", "\u{2019}", "\""]
        guard quoted.count >= 3, let first = quoted.first, let last = quoted.last,
              quotes.contains(first), quotes.contains(last) else { return nil }
        return (kind, String(quoted.dropFirst().dropLast()))
    }

    /// Labels that packages define by themselves: `\pageref{LastPage}` (lastpage), `\pageref{TotPages}` (totpages).
    public static let automaticLabels: Set<String> = ["LastPage", "TotPages"]

    /// At most this many other definitions are named in a duplicate label's `detail`.
    static let maxListedPlaces = 5

    /// `url` relative to the root file's directory (`sections/intro.tex`), or just its file name.
    private static func displayPath(_ url: URL, root: String) -> String {
        let path = url.path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return url.lastPathComponent
    }
}

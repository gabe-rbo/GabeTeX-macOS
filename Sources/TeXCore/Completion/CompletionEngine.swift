import Foundation

/// Context-aware completion. Pure function of (text, cursor, symbols).
///
/// Contexts (see ARCHITECTURE.md §Completion):
///   `\fr|`             → commands (catalog + project custom commands), prefix "\fr"
///   `\begin{ite|`      → environments (catalog + custom); accepting inserts the whole environment
///   `\end{|`           → the innermost unclosed environment first
///   `\ref{|` `\eqref{` `\cref{` `\Cref{` `\autoref{` `\pageref{` `\nameref{` → labels
///   `\cite{a,|` and natbib/biblatex variants → bib keys (the current comma-separated item only)
///   `\usepackage{|` / `\RequirePackage{` → packages
///   `\input{|` `\include{` `\subfile{` → .tex files (without extension for \include)
///   `\includegraphics{|` → image/pdf files
/// Ranking: exact prefix > case-insensitive prefix > subsequence (fuzzy); ties broken by catalog order.
///
/// Additional rules:
/// - Nothing is offered inside comments, verbatim bodies, `\verb` and other masked regions.
/// - After a bare `\` the most common commands are offered (project commands first, then a curated list of
///   the commands people type most, then the catalog order). Ties between equally good matches are broken the
///   same way, so `\su` offers `\subsection` in text and `\sum` in math. Inside math mode (`$…$`, `\[…\]`, `equation`, `align`, …, but not inside `\text{…}`)
///   math commands rank before text commands, outside math the other way round.
/// - `replacementRange` covers the typed prefix (for list arguments such as `\cite{a,b|}` only the current
///   item). For `\begin{` / `\end{` the inserted text carries the closing brace, so an existing `}` after
///   the name (typically auto-inserted by the editor) is included in the range.
/// - At most 200 items are returned.
public enum CompletionEngine {
    /// How many commands a bare `\` shows.
    static let bareBackslashLimit = 80

    public static func complete(text: NSString, cursor: Int, symbols: ProjectSymbols) -> CompletionResult? {
        guard cursor >= 0, cursor <= text.length else { return nil }
        let src = MaskedSource(text)
        let u = src.masked
        guard let context = CompletionContext.detect(u, cursor: cursor) else { return nil }

        switch context {
        case .command(let start):
            let typed = utf16String(u, start..<cursor)
            let walk = StructureWalker.walk(src, upTo: start)
            let items = commandItems(typed: typed, inMath: walk.isInMath, symbols: symbols,
                                     innermostEnvironment: walk.openEnvironments.last?.name)
            return result(range: start..<cursor, prefix: typed, items: items)

        case .environment(let isEnd, let itemStart):
            let typed = utf16String(u, itemStart..<cursor)
            let walk = StructureWalker.walk(src, upTo: itemStart)
            let items = isEnd
                ? endEnvironmentItems(typed: typed, walk: walk, src: src, symbols: symbols)
                : beginEnvironmentItems(typed: typed, inMath: walk.isInMath, symbols: symbols)
            // The inserted text ends with the closing brace: swallow an existing one (and the rest of the name).
            var end = cursor
            var k = cursor
            while k < u.count && (isCommandLetter(u[k]) || isASCIIDigit(u[k]) || u[k] == 42) { k += 1 }
            if k < u.count && u[k] == 125 { end = k + 1 }
            return result(range: itemStart..<end, prefix: typed, items: items, replacementEnd: end)

        case .label(let itemStart):
            let typed = utf16String(u, itemStart..<cursor)
            let items = labelItems(typed: typed, symbols: symbols)
            return result(range: itemStart..<cursor, prefix: typed, items: items)

        case .citation(let itemStart):
            let typed = utf16String(u, itemStart..<cursor)
            let items = citationItems(typed: typed, symbols: symbols)
            return result(range: itemStart..<cursor, prefix: typed, items: items)

        case .package(let itemStart):
            let typed = utf16String(u, itemStart..<cursor)
            let items = packageItems(typed: typed, symbols: symbols)
            return result(range: itemStart..<cursor, prefix: typed, items: items)

        case .file(let kind, let itemStart):
            let typed = utf16String(u, itemStart..<cursor)
            let items = fileItems(typed: typed, kind: kind, symbols: symbols)
            return result(range: itemStart..<cursor, prefix: typed, items: items)
        }
    }

    public static func complete(text: String, cursor: Int, symbols: ProjectSymbols) -> CompletionResult? {
        complete(text: text as NSString, cursor: cursor, symbols: symbols)
    }

    private static func result(range: Range<Int>, prefix: String, items: [CompletionItem], replacementEnd: Int? = nil) -> CompletionResult? {
        guard !items.isEmpty else { return nil }
        let upper = replacementEnd ?? range.upperBound
        return CompletionResult(
            replacementRange: NSRange(location: range.lowerBound, length: upper - range.lowerBound),
            prefix: prefix,
            items: Array(items.prefix(CompletionRanking.maxItems))
        )
    }

    // MARK: Commands

    private static let mathLabels: Set<String> = Set(CompletionCatalog.mathCommands.map(\.label))
    private static let textLabels: Set<String> = Set(CompletionCatalog.commands.map(\.label))

    /// The most frequently typed text-mode commands, best first (they win ties and fill a bare `\`).
    static let commonTextCommands: [String] = [
        "\\begin", "\\end", "\\section", "\\subsection", "\\subsubsection", "\\textbf", "\\textit", "\\emph", "\\label", "\\ref",
        "\\cite", "\\item", "\\usepackage", "\\documentclass", "\\includegraphics", "\\caption", "\\footnote", "\\input",
        "\\include", "\\newcommand", "\\chapter", "\\paragraph", "\\title", "\\author", "\\date", "\\maketitle",
        "\\tableofcontents", "\\bibliography", "\\bibliographystyle", "\\texttt", "\\underline", "\\centering", "\\hline",
        "\\hspace", "\\vspace", "\\url", "\\href", "\\eqref", "\\cref", "\\autoref", "\\newpage", "\\noindent", "\\textsc",
        "\\textsf", "\\textrm", "\\printbibliography", "\\addbibresource", "\\newtheorem", "\\newenvironment",
        "\\renewcommand", "\\providecommand", "\\def", "\\tiny", "\\small", "\\large", "\\Large", "\\today",
    ]

    /// The most frequently typed commands inside math, best first.
    static let commonMathCommands: [String] = [
        "\\frac", "\\sum", "\\int", "\\alpha", "\\beta", "\\gamma", "\\delta", "\\epsilon", "\\varepsilon", "\\theta", "\\lambda",
        "\\mu", "\\pi", "\\sigma", "\\phi", "\\omega", "\\infty", "\\partial", "\\nabla", "\\mathbb", "\\mathcal", "\\mathbf",
        "\\mathrm", "\\left", "\\right", "\\cdot", "\\cdots", "\\ldots", "\\leq", "\\geq", "\\neq", "\\approx", "\\in", "\\subset",
        "\\subseteq", "\\cup", "\\cap", "\\to", "\\mapsto", "\\rightarrow", "\\Rightarrow", "\\sqrt", "\\lim", "\\prod",
        "\\forall", "\\exists", "\\text", "\\times", "\\otimes", "\\oplus", "\\langle", "\\rangle", "\\hat", "\\bar", "\\vec",
        "\\tilde", "\\dot", "\\operatorname", "\\quad", "\\qquad", "\\begin", "\\end", "\\label",
    ]

    private static let commonTextRank: [String: Int] = Dictionary(
        commonTextCommands.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    private static let commonMathRank: [String: Int] = Dictionary(
        commonMathCommands.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

    /// `\begin` and `\end` are environment openers handled by the environment completion; the catalog
    /// tables do not list them, so the engine supplies them.
    private static func coreCommands(innermostEnvironment: String?) -> [CompletionItem] {
        var end = CompletionItem(kind: .command, label: "\\end", insertText: "\\end{${1:environment}}",
                                 detail: String(localized: "End an environment"))
        if let name = innermostEnvironment, !name.isEmpty {
            end.insertText = "\\end{\(name)}"
            end.detail = String(localized: "Close the environment “\(name)”")
        }
        return [
            CompletionItem(kind: .command, label: "\\begin", insertText: "\\begin{${1:environment}}",
                           detail: String(localized: "Begin an environment")),
            end,
        ]
    }

    static func commandItems(typed: String, inMath: Bool, symbols: ProjectSymbols,
                             innermostEnvironment: String? = nil) -> [CompletionItem] {
        var custom: [CompletionItem] = []
        var customLabels = Set<String>()
        for item in symbols.customCommands where customLabels.insert(item.label).inserted { custom.append(item) }

        let core = coreCommands(innermostEnvironment: innermostEnvironment).filter { !customLabels.contains($0.label) }
        let coreLabels = Set(core.map(\.label))
        let text = CompletionCatalog.commands.filter { !customLabels.contains($0.label) && !coreLabels.contains($0.label) }
        let math = CompletionCatalog.mathCommands.filter { !customLabels.contains($0.label) && !coreLabels.contains($0.label) }
        let ordered: [CompletionItem]
        if inMath {
            ordered = custom + core + math + text.filter { !mathLabels.contains($0.label) }
        } else {
            ordered = custom + core + text + math.filter { !textLabels.contains($0.label) }
        }

        let commonRank = inMath ? commonMathRank : commonTextRank
        let body = String(typed.dropFirst())
        return CompletionRanking.rank(
            ordered, typed: body, allowFuzzy: body.count >= 2,
            limit: body.isEmpty ? bareBackslashLimit : CompletionRanking.maxItems,
            key: { String($0.label.dropFirst()) },
            priority: { customLabels.contains($0.label) ? -1 : (commonRank[$0.label] ?? 100_000) }
        )
    }

    // MARK: Environments

    private static func environmentCandidates(symbols: ProjectSymbols) -> [CompletionItem] {
        var custom: [CompletionItem] = []
        var names = Set<String>()
        for name in symbols.customEnvironments where names.insert(name).inserted {
            custom.append(CompletionItem(
                kind: .environment, label: name,
                insertText: "\(name)}\n\t$0\n\\end{\(name)}",
                detail: ScannerDefinitions.detail
            ))
        }
        return custom + CompletionCatalog.environments.filter { !names.contains($0.label) }
    }

    /// Environments people open most often, best first.
    static let commonEnvironments: [String] = [
        "document", "itemize", "enumerate", "equation", "align", "figure", "table", "tabular", "center", "theorem", "lemma",
        "proof", "abstract", "description", "verbatim", "minipage", "cases", "matrix", "frame",
    ]
    private static let commonEnvironmentRank: [String: Int] = Dictionary(
        commonEnvironments.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

    static func beginEnvironmentItems(typed: String, inMath: Bool, symbols: ProjectSymbols) -> [CompletionItem] {
        let candidates = environmentCandidates(symbols: symbols)
        let custom = Set(symbols.customEnvironments)
        return CompletionRanking.rank(candidates, typed: typed, key: { $0.label }, priority: { item in
            let common = commonEnvironmentRank[item.label] ?? 500
            if custom.contains(item.label) { return -1 }
            // Inside math, environments that only make sense there (aligned, cases, matrices…) come first.
            return inMath && !LaTeXSyntax.innerMathEnvironments.contains(item.label) ? 1_000 + common : common
        })
    }

    static func endEnvironmentItems(typed: String, walk: StructureWalk, src: MaskedSource, symbols: ProjectSymbols) -> [CompletionItem] {
        var seen = Set<String>()
        var unclosed: [CompletionItem] = []
        for open in walk.openEnvironments.reversed() where seen.insert(open.name).inserted {
            let line = src.line(at: open.offset)
            unclosed.append(CompletionItem(
                kind: .environment, label: open.name, insertText: "\(open.name)}",
                detail: String(localized: "Opened on line \(line)")
            ))
        }
        let ranked = CompletionRanking.rank(unclosed, typed: typed, key: { $0.label })
        if !ranked.isEmpty { return ranked }
        // Nothing open matches what was typed: fall back to every known environment name.
        let all = environmentCandidates(symbols: symbols).map {
            CompletionItem(kind: .environment, label: $0.label, insertText: "\($0.label)}", detail: $0.detail, package: $0.package)
        }
        return CompletionRanking.rank(all, typed: typed, key: { $0.label })
    }

    // MARK: Labels, citations, packages, files

    static func labelItems(typed: String, symbols: ProjectSymbols) -> [CompletionItem] {
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for label in symbols.labels where seen.insert(label.key).inserted {
            let detail = label.context ?? "\(label.fileURL.lastPathComponent):\(label.line)"
            items.append(CompletionItem(kind: .label, label: label.key, insertText: label.key, detail: detail))
        }
        return CompletionRanking.rank(items, typed: typed, key: { $0.label })
    }

    static func citationItems(typed: String, symbols: ProjectSymbols) -> [CompletionItem] {
        var seen = Set<String>()
        var items: [CompletionItem] = []
        var metadata: [String: String] = [:]
        for entry in symbols.bibEntries where seen.insert(entry.key).inserted {
            var summary = ""
            if let author = entry.author, !author.isEmpty { summary = author }
            if let year = entry.year, !year.isEmpty { summary += summary.isEmpty ? "(\(year))" : " (\(year))" }
            if let title = entry.title, !title.isEmpty { summary += summary.isEmpty ? title : " — \(title)" }
            items.append(CompletionItem(kind: .citation, label: entry.key, insertText: entry.key,
                                        detail: summary.isEmpty ? entry.type : summary))
            metadata[entry.key] = summary
        }
        return CompletionRanking.rank(items, typed: typed, key: { $0.label }, secondary: { metadata[$0.label] })
    }

    static func packageItems(typed: String, symbols: ProjectSymbols) -> [CompletionItem] {
        var items = CompletionCatalog.packages
        let known = Set(items.map(\.label))
        for path in symbols.projectFiles where path.hasSuffix(".sty") {
            let name = String(path.dropLast(4))
            if !known.contains(name) {
                items.insert(CompletionItem(kind: .package, label: name, insertText: name,
                                            detail: String(localized: "Local package")), at: 0)
            }
        }
        return CompletionRanking.rank(items, typed: typed, key: { $0.label })
    }

    static func fileItems(typed: String, kind: CompletionContext.FileKind, symbols: ProjectSymbols) -> [CompletionItem] {
        func hasExtension(_ path: String, _ extensions: [String]) -> Bool {
            let lower = path.lowercased()
            return extensions.contains { lower.hasSuffix("." + $0) }
        }
        var items: [CompletionItem] = []
        for path in symbols.projectFiles {
            let insert: String
            switch kind {
            case .texWithExtension:
                guard hasExtension(path, ["tex"]) else { continue }
                insert = path
            case .texWithoutExtension:
                guard hasExtension(path, ["tex"]) else { continue }
                insert = String(path.dropLast(4))
            case .image:
                guard hasExtension(path, ["pdf", "png", "jpg", "jpeg", "eps"]) else { continue }
                insert = path
            case .pdf:
                guard hasExtension(path, ["pdf"]) else { continue }
                insert = path
            case .bibliography:
                guard hasExtension(path, ["bib"]) else { continue }
                insert = String(path.dropLast(4))
            case .bibResource:
                guard hasExtension(path, ["bib"]) else { continue }
                insert = path
            }
            items.append(CompletionItem(kind: .file, label: insert, insertText: insert))
        }
        return CompletionRanking.rank(items, typed: typed, key: { $0.label })
    }
}

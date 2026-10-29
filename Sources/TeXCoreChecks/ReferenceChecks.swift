import Foundation
import CheckKit
import TeXCore

// Checks for reference & citation tracking (ReferenceScanner, ProjectIndex additions, ReferenceLinter).

/// In-memory project: relative path → contents (all under /proj).
private struct RefProject {
    var files: [String: String]

    func url(_ path: String) -> URL { fileURL(path) }
    func read(_ url: URL) -> String? {
        let prefix = "/proj/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return files[String(url.path.dropFirst(prefix.count))]
    }
    func exists(_ url: URL) -> Bool { read(url) != nil }
    func index(root: String = "main.tex") -> ProjectIndex {
        ProjectIndex.build(rootFile: url(root), read: read, fileExists: exists)
    }
    func lint(root: String = "main.tex") -> [Diagnostic] { ReferenceLinter.diagnostics(index: index(root: root)) }

    /// The text a diagnostic underlines (line / column / length in UTF-16 units; `\n`, `\r\n`, `\r` lines).
    func underlined(_ d: Diagnostic) -> String? {
        guard let url = d.fileURL, let text = read(url), let line = d.line, let column = d.column, let length = d.length
        else { return nil }
        let ns = text as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 10 {
                starts.append(i + 1)
            } else if c == 13 {
                if i + 1 < ns.length && ns.character(at: i + 1) == 10 { i += 1 }
                starts.append(i + 1)
            }
            i += 1
        }
        guard line >= 1, line <= starts.count else { return nil }
        let location = starts[line - 1] + column - 1
        guard location >= 0, location + length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: location, length: length))
    }
}

private func refKeys(_ occurrences: [KeyOccurrence]) -> [String] { occurrences.map(\.key) }

private func refScan(_ text: String) -> ReferenceScan {
    ReferenceScanner.scan(text, fileURL: fileURL("main.tex"))
}

/// `path:line message` per diagnostic (path relative to /proj).
private func refDescribe(_ diagnostics: [Diagnostic]) -> [String] {
    diagnostics.map { d in
        let path = d.fileURL.map { String($0.path.dropFirst("/proj/".count)) } ?? "?"
        return "\(path):\(d.line ?? -1) \(d.message)"
    }
}

@MainActor
func runReferenceChecks() async {
    // MARK: Scanner

    await Check.suite("ReferenceScanner: reference macros, comma lists, ranges") {
        for name in ["ref", "eqref", "pageref", "autoref", "nameref", "vref", "cref", "Cref", "cpageref", "labelcref"] {
            Check.expect(ReferenceScanner.referenceCommands.contains(name), "\\\(name) is a reference command")
            let text = "See \\\(name){a, b ,c}."
            let found = refScan(text).references
            Check.equal(refKeys(found), ["a", "b", "c"], "\\\(name) comma list")
            Check.equal(found.map(\.command), [name, name, name], "\\\(name) command name")
            Check.expect(found.allSatisfy { substring(text, $0.range) == $0.key }, "\\\(name) ranges cover the keys")
            Check.equal(refScan("\\\(name)*{x}").references.map(\.key), ["x"], "\\\(name)* starred")
        }
        let ref = refScan("See \\ref{a, b ,c}.").references
        Check.equal(ref.map(\.column), [10, 13, 16])
        Check.equal(ref.map(\.offset), [9, 12, 15])
        Check.equal(ref.map(\.length), [1, 1, 1])
        Check.equal(ref.map(\.line), [1, 1, 1])

        for name in ["crefrange", "Crefrange", "cpagerefrange", "Cpagerefrange", "vrefrange", "Vrefrange"] {
            Check.expect(ReferenceScanner.referenceRangeCommands.contains(name), "\\\(name) is a range command")
            Check.equal(refKeys(refScan("\\\(name){eq:a}{eq:b}").references), ["eq:a", "eq:b"], "\\\(name) both keys")
        }
        Check.equal(refKeys(refScan("\\crefrange{ a }{\n b }").references), ["a", "b"], "range keys trimmed")
        Check.equal(refScan("\\crefrange{a}").references.count, 0, "a range without its second argument is ignored")

        // Other forms and arguments.
        Check.equal(refKeys(refScan("\\hyperref[sec:x]{the section}").references), ["sec:x"], "\\hyperref optional label")
        Check.equal(refKeys(refScan("\\hyperref{http://x.org}{cat}{name}{text}").references), [], "old \\hyperref form has no label")
        Check.equal(refKeys(refScan("\\subref{fig:a} \\Vref{x} \\Cpageref{y} \\namecref{z}").references), ["fig:a", "x", "y", "z"])
        let multiline = "\\cref{a,\n      b}"
        let lines = refScan(multiline).references
        Check.equal(lines.map(\.line), [1, 2])
        Check.equal(lines.map(\.column), [7, 7])
        Check.equal(refKeys(refScan("\\ref {spaced}").references), ["spaced"], "space before the brace")
        Check.equal(refKeys(refScan("\\ref\n{next}").references), ["next"], "line break before the brace")
        Check.equal(refKeys(refScan("\\ref{a}\\ref{b}\\eqref{c}").references), ["a", "b", "c"], "adjacent commands")
        Check.equal(refKeys(refScan("\\footnote{see \\ref{in:footnote}}").references), ["in:footnote"], "inside another argument")
        Check.equal(refKeys(refScan("$x = \\text{see \\eqref{eq:in:math}}$").references), ["eq:in:math"], "inside math")

        // Not references.
        Check.equal(refScan("\\crefname{section}{section}{sections} \\refstepcounter{x} \\refname \\reflectbox{x} \\labelformat{x}{y}")
                        .references.count, 0, "look-alikes are not references")
        Check.equal(refScan("\\ref \\ref} \\ref").references.count, 0, "no argument, no use")
    }

    await Check.suite("ReferenceScanner: citation macros") {
        let spec = ["cite", "citep", "citet", "citealp", "citeauthor", "citeyear", "parencite", "textcite", "autocite",
                    "footcite", "smartcite", "supercite", "nocite"]
        for name in spec {
            Check.expect(ReferenceScanner.citationCommands.contains(name), "\\\(name) is a citation command")
            let text = "As shown \\\(name){k1, k2,\n  k3}."
            let found = refScan(text).citations
            Check.equal(refKeys(found), ["k1", "k2", "k3"], "\\\(name) comma list over two lines")
            Check.equal(found.map(\.line), [1, 1, 2], "\\\(name) lines")
            Check.expect(found.allSatisfy { substring(text, $0.range) == $0.key }, "\\\(name) ranges cover the keys")
            Check.equal(refKeys(refScan("\\\(name)*{star}").citations), ["star"], "\\\(name)* starred")
            Check.equal(refKeys(refScan("\\\(name)[p.~5]{one}").citations), ["one"], "\\\(name) one optional argument")
            Check.equal(refKeys(refScan("\\\(name)[see][p.~5]{a, b}").citations), ["a", "b"], "\\\(name) two optional arguments")
            Check.equal(refKeys(refScan("\\\(name)[\\ref{x}]{c}").citations), ["c"], "\\\(name) optional argument with a macro")
        }
        for name in ["Citep", "Citet", "citealt", "citeyearpar", "citenum", "Parencite", "Textcite", "Autocite", "Cite",
                     "fullcite", "footfullcite", "citetitle"] {
            Check.equal(refKeys(refScan("\\\(name){k}").citations), ["k"], "\\\(name)")
        }
        let first = refScan("\\cite[x]{a}")
        Check.equal(first.citations.map(\.column), [10])
        Check.equal(first.citations.map(\.offset), [9])

        // \nocite{*} and friends.
        Check.equal(refScan("\\nocite{*}").citations.count, 0, "\\nocite{*} is skipped")
        Check.equal(refKeys(refScan("\\nocite{a, *, b}").citations), ["a", "b"], "only the star item is skipped")
        Check.equal(refKeys(refScan("\\nocite{a}").citations), ["a"])

        // Multicite: the first group.
        Check.equal(refKeys(refScan("\\parencites{a}{b}").citations), ["a"], "multicite reads its first group")
        Check.equal(refScan("\\parencites(pre)(post)[x][y]{a}").citations.count, 0, "parenthesised notes are not parsed")

        // Not citations.
        Check.equal(refScan("\\citestyle{authoryear} \\citetext{see x} \\citeindexfalse \\citepunct \\citeleft").citations.count, 0,
                    "commands that take no key")
        Check.equal(refScan("\\cite").citations.count, 0)
        Check.equal(refScan("\\cite{}").citations.count, 0, "empty argument")
    }

    await Check.suite("ReferenceScanner: comments, verbatim, macros bodies") {
        let text = #"""
        % \ref{commented} and \cite{commented}
        Real \ref{real} % trailing \ref{trail}
        \verb|\ref{verb}| and 50\% \ref{afterpercent}
        \begin{verbatim}
        \ref{inverb} \cite{inverb}
        \end{verbatim}
        \iffalse
        \ref{iffalse}
        \fi
        \\ref{doublebackslash}
        \ref{} \ref{ #1 } \ref{sec:#1} \cite{\mykey} \ref{a\b} \ref{x{y}}
        \newcommand{\myref}[1]{\ref{fig:#1}~\cite{#1}}
        \url{http://example.org/\ref{inurl}}
        """#
        let found = refScan(text)
        Check.equal(refKeys(found.references), ["real", "afterpercent"])
        Check.equal(refKeys(found.citations), [])
        let withLabels = refScan(#"% \label{c}"# + "\n" + #"\label{ok} \verb+\label{v}+"#)
        Check.equal(refKeys(withLabels.labels), ["ok"], "labels ignore comments and \\verb")
    }

    await Check.suite("ReferenceScanner: UTF-16 columns (accents, combining marks, astral characters, CRLF)") {
        let prefixes = [
            "\u{00C1}lgebra \u{1D538} ",            // precomposed accent + astral letter
            "A\u{0301}lgebra \u{1F600}\u{1F600} ",   // combining accent + emoji
            "Teoria dos n\u{00FA}meros \u{2014} ",
        ]
        for prefix in prefixes {
            let text = prefix + "\\ref{se\u{00E7}\u{00E3}o:\u{00E1}} e \\cite{a\u{00E7}\u{00E3}o,\u{1F600}}\n"
            let nsText = text as NSString
            let found = refScan(text)
            let all = found.references + found.citations
            Check.equal(refKeys(all), ["se\u{00E7}\u{00E3}o:\u{00E1}", "a\u{00E7}\u{00E3}o", "\u{1F600}"])
            Check.expect(all.allSatisfy { substring(text, $0.range) == $0.key }, "ranges are UTF-16 exact")
            Check.expect(all.allSatisfy { $0.length == $0.key.utf16.count }, "lengths are UTF-16 lengths")
            Check.equal(found.references.first?.column, nsText.range(of: "\\ref{").location + 5 + 1,
                        "column counts UTF-16 units")
            Check.equal(found.citations.last?.length, 2, "an emoji key is two units long")
            Check.equal(found.citations.last?.column, nsText.range(of: "\u{1F600}}").location + 1)
        }
        let second = "\u{1D538}\u{1D538} \\label{fig:\u{1F600}}"
        Check.equal(refScan(second).labels.first?.column, 4 + 1 + 7 + 1, "two astral letters (4 units), a space, \\label{")
        Check.equal(refScan(second).labels.first?.length, 6)

        let crlf = "a\r\n\\ref{x}\r\n\\ref{y}\rl4 \\ref{z}\n\\ref{w}"
        let found = refScan(crlf).references
        Check.equal(found.map(\.line), [2, 3, 4, 5], "CRLF, CR and LF all end lines")
        Check.equal(found.map(\.column), [6, 6, 9, 6])
        Check.expect(found.allSatisfy { substring(crlf, $0.range) == $0.key })
    }

    await Check.suite("ReferenceScanner: labels, option labels, bibitems, dynamic keys, xr") {
        let text = #"""
        \label{a} \label[equation]{b} \label {c}
        % \label{commented}
        \label{sec:#1} \label{fig:\thechapter-x} \label{#1}
        \begin{lstlisting}[language=C, label=lst:code]
        int x; \label{verbatim}
        \end{lstlisting}
        \begin{theorem}[name=Main, label = {thm:main}]
        \begin{enumerate}[label=(\alph*)]
        \begin{itemize}[leftmargin=*, labelsep=1em]
        \lstinputlisting[caption={x, y}, label=lst:file]{code.c}
        \newlabel{manual}{{1}{1}}
        \begin{thebibliography}{9}
        \bibitem{knuth} K.
        \bibitem[Lamport 1994]{lamport94} L.
        \end{thebibliography}
        """#
        let found = refScan(text)
        Check.equal(refKeys(found.labels), ["a", "b", "c"])
        Check.equal(refKeys(found.optionLabels), ["lst:code", "thm:main", "lst:file", "manual"])
        Check.equal(found.dynamicLabelPrefixes, ["", "fig:", "sec:"])
        Check.equal(refKeys(found.bibItems), ["knuth", "lamport94"])
        Check.expect((found.labels + found.optionLabels + found.bibItems).allSatisfy { substring(text, $0.range) == $0.key })

        Check.expect(refScan("\\externaldocument[ch2-]{chapter2}").usesExternalDocuments)
        Check.expect(refScan("\\usepackage{xr-hyper}").usesExternalDocuments)
        Check.expect(refScan("\\usepackage[opt]{amsmath, xr}").usesExternalDocuments)
        Check.expect(refScan("\\RequirePackage{xr}").usesExternalDocuments)
        Check.expect(!refScan("\\usepackage{xcolor,hyperref} \\usepackage{xrcolor}").usesExternalDocuments)
        Check.expect(!refScan("% \\externaldocument{x}").usesExternalDocuments, "commented out")
        Check.expect(refScan("\\externalcitedocument{x}").usesExternalCitations)
        Check.expect(!refScan("\\ref{a}").usesExternalCitations)
    }

    // MARK: Index

    await Check.suite("ProjectIndex: reference data across files") {
        let project = RefProject(files: [
            "main.tex": #"""
            \documentclass{article}
            \usepackage{hyperref}
            \begin{document}
            \section{Intro}\label{sec:intro}
            See \ref{sec:method} and \cite{knuth84,missing1}.
            \input{sections/method}
            \input{sections/results}
            \bibliographystyle{plain}
            \bibliography{refs}
            \end{document}
            """#,
            "sections/method.tex": #"""
            \section{Method}\label{sec:method}
            \begin{equation}\label{eq:a}x\end{equation}
            By \eqref{eq:a}, \cref{sec:intro,sec:results} and \ref{sec:nowhere}.
            """#,
            "sections/results.tex": #"""
            \section{Results}\label{sec:results}
            \label{eq:a}
            See \autoref{sec:method} and \cite{hatcher2002}.
            """#,
            "refs.bib": "@article{knuth84, title={T}}\n@book{hatcher2002, title={AT}}\n",
        ])
        let index = project.index()
        Check.equal(refKeys(index.labelSites), ["sec:intro", "sec:method", "eq:a", "sec:results", "eq:a"],
                    "every \\label, duplicates included, in file order")
        Check.equal(index.labelSites.map(\.fileURL.lastPathComponent), ["main.tex", "method.tex", "method.tex", "results.tex", "results.tex"])
        Check.equal(index.labels.map(\.key), refKeys(index.labelSites), "labels and labelSites agree")
        Check.equal(refKeys(index.referenceUses), ["sec:method", "eq:a", "sec:intro", "sec:results", "sec:nowhere", "sec:method"])
        Check.equal(refKeys(index.citationUses), ["knuth84", "missing1", "hatcher2002"])
        Check.expect(!index.usesExternalDocuments && !index.usesExternalCitations && !index.hasUnknownBibliographySource)
        Check.equal(index.bibEntries.map(\.key), ["knuth84", "hatcher2002"])

        // Not included from the root: not part of the project.
        var withOrphan = project
        withOrphan.files["orphan.tex"] = "\\label{orphan}\\ref{orphan2}"
        Check.equal(withOrphan.index().labelSites.count, 5, "files outside the include closure are not scanned")

        // A missing, unreadable or non-.bib bibliography makes the key set unknown.
        var missing = project
        missing.files["refs.bib"] = nil
        Check.expect(missing.index().hasUnknownBibliographySource, "\\bibliography file not found")
        let mainText = project.files["main.tex"] ?? ""
        var resource = project
        resource.files["main.tex"] = mainText.replacingOccurrences(of: "\\bibliography{refs}", with: "\\addbibresource{refs.json}")
        resource.files["refs.json"] = "[]"
        Check.expect(resource.index().hasUnknownBibliographySource, "a non-.bib resource")
        var fine = project
        fine.files["main.tex"] = mainText.replacingOccurrences(of: "\\bibliography{refs}", with: "\\addbibresource{refs.bib}")
        Check.expect(!fine.index().hasUnknownBibliographySource, "\\addbibresource of an existing .bib")
    }

    // MARK: Linter

    await Check.suite("ReferenceLinter: undefined references, duplicates and missing citations across files") {
        let project = RefProject(files: [
            "main.tex": #"""
            \documentclass{article}
            \begin{document}
            \section{Intro}\label{sec:intro}
            See \ref{sec:method} and \cite{knuth84,missing1}.
            \input{sections/method}
            \input{sections/results}
            \bibliography{refs}
            \end{document}
            """#,
            "sections/method.tex": #"""
            \section{Method}\label{sec:method}
            \begin{equation}\label{eq:a}x\end{equation}
            By \eqref{eq:a}, \cref{sec:intro,sec:results} and \ref{sec:nowhere}.
            """#,
            "sections/results.tex": #"""
            \section{Results}\label{sec:results}
            \label{eq:a}
            See \autoref{sec:method} and \cite{hatcher2002}.
            """#,
            "refs.bib": "@article{knuth84, title={T}}\n@book{hatcher2002, title={AT}}\n",
        ])
        let found = project.lint()
        Check.equal(refDescribe(found), [
            "main.tex:4 Citation ‘missing1’ is not in the bibliography",
            "sections/method.tex:2 Label ‘eq:a’ is defined more than once",
            "sections/method.tex:3 Reference ‘sec:nowhere’ is not defined",
            "sections/results.tex:2 Label ‘eq:a’ is defined more than once",
        ], "ordered by file (document order), then position")
        Check.equal(found.map { project.underlined($0) }, ["missing1", "eq:a", "sec:nowhere", "eq:a"],
                    "every diagnostic underlines exactly its key")
        Check.expect(found.allSatisfy { $0.severity == .warning && $0.source == .structure })
        Check.expect(found.allSatisfy { $0.fileURL?.isFileURL == true && $0.length == project.underlined($0)?.utf16.count })
        Check.equal(found[1].detail, "Also defined at sections/results.tex:2")
        Check.equal(found[3].detail, "Also defined at sections/method.tex:2")
        Check.equal(found[0].detail, nil)
        Check.equal(found[2].detail, nil)
        Check.equal(found.map(\.column), [40, 24, 56, 8])

        // The index is rebuilt from whatever text is current (unsaved buffers): fixing the text clears the warnings.
        var fixed = project
        fixed.files["sections/method.tex"] = "\\section{Method}\\label{sec:method}\n\\label{eq:b}\n\\ref{eq:b}"
        fixed.files["main.tex"] = (project.files["main.tex"] ?? "").replacingOccurrences(of: "missing1", with: "knuth84")
        Check.equal(refDescribe(fixed.lint()), [], "no warnings once everything is defined")
    }

    await Check.suite("ReferenceLinter: undefined references") {
        func lint(_ main: String, extra: [String: String] = [:]) -> [String] {
            var files = ["main.tex": main]
            for (path, text) in extra { files[path] = text }
            return refDescribe(RefProject(files: files).lint())
        }
        Check.equal(lint("\\label{a}\\ref{a}\\eqref{a}\\cref{a}"), [])
        Check.equal(lint("\\ref{a}\n\\ref{a}"), ["main.tex:1 Reference ‘a’ is not defined", "main.tex:2 Reference ‘a’ is not defined"],
                    "every use is reported")
        Check.equal(lint("\\cref{x,y}\\label{y}"), ["main.tex:1 Reference ‘x’ is not defined"], "a list reports its undefined keys")
        Check.equal(lint("\\crefrange{x}{y}\\label{y}"), ["main.tex:1 Reference ‘x’ is not defined"])
        Check.equal(lint("\\label{A}\\ref{a}"), ["main.tex:1 Reference ‘a’ is not defined"], "labels are case-sensitive")
        Check.equal(lint("% \\label{a}\n\\ref{a}"), ["main.tex:2 Reference ‘a’ is not defined"], "a commented-out label defines nothing")
        Check.equal(lint("% \\ref{a}\n\\begin{verbatim}\\ref{b}\\end{verbatim}"), [], "commented and verbatim uses are ignored")
        Check.equal(lint("\\input{o}\\ref{inc}", extra: ["o.tex": "\\label{inc}"]), [], "labels in included files")
        Check.equal(lint("\\ref{inc}", extra: ["o.tex": "\\label{inc}"]), ["main.tex:1 Reference ‘inc’ is not defined"],
                    "labels in files the root does not include")
        Check.equal(lint("\\ref{inc}\\input{o}", extra: ["o.tex": "\\ref{back}\\label{inc}"]), ["o.tex:1 Reference ‘back’ is not defined"],
                    "forward references are fine")

        // xr: skip the check entirely.
        Check.equal(lint("\\externaldocument{other}\\ref{a}"), [], "\\externaldocument")
        Check.equal(lint("\\usepackage{xr-hyper}\\ref{a}"), [], "xr-hyper")
        Check.equal(lint("\\usepackage{xr}\\ref{a}"), [], "xr")
        Check.equal(lint("\\input{o}\\ref{a}", extra: ["o.tex": "\\externaldocument[b-]{book}"]), [], "xr declared in an included file")
        Check.equal(lint("\\externaldocument{other}\\label{d}\\label{d}").count, 2, "duplicate labels are still reported with xr")

        // Labels that macros or options define.
        Check.equal(lint("\\newcommand{\\sectionlabel}[1]{\\label{sec:#1}}\\ref{sec:intro}\\ref{fig:x}"),
                    ["main.tex:1 Reference ‘fig:x’ is not defined"], "a label built from a macro argument keeps its prefix")
        Check.equal(lint("\\newcommand{\\mylabel}[1]{\\label{#1}}\\ref{anything}"), [], "a fully dynamic label disables the check")
        Check.equal(lint("\\newcommand{\\mylabel}{\\label{fig:\\thefigure}}\\ref{fig:7}\\ref{tab:7}"),
                    ["main.tex:1 Reference ‘tab:7’ is not defined"])
        Check.equal(lint("\\begin{lstlisting}[label=lst:a]\nx\n\\end{lstlisting}\\ref{lst:a}\\lstinputlisting[label={lst:b}]{c.py}\\ref{lst:b}"), [])
        Check.equal(lint("\\begin{theorem}[name=X, label=thm:x]\\end{theorem}\\ref{thm:x}\\newlabel{n}{{1}{1}}\\ref{n}"), [])
        Check.equal(lint("\\begin{enumerate}[label=(\\alph*)]\\end{enumerate}\\ref{(a)}").count, 1,
                    "an enumitem format is not a label")
        Check.equal(lint("\\hyperref[sec:x]{text}\\hyperref{url}{c}{n}{text}"), ["main.tex:1 Reference ‘sec:x’ is not defined"])
        // Labels that packages define by themselves.
        Check.equal(lint("\\pageref{LastPage} \\pageref*{TotPages} \\pageref{Other}"), ["main.tex:1 Reference ‘Other’ is not defined"],
                    "lastpage / totpages")
    }

    await Check.suite("ReferenceLinter: duplicate labels") {
        func lint(_ files: [String: String]) -> [Diagnostic] { RefProject(files: files).lint() }

        let twice = lint(["main.tex": "\\label{d}\n\\label{e}\n  \\label{ d }\n"])
        Check.equal(refDescribe(twice), ["main.tex:1 Label ‘d’ is defined more than once", "main.tex:3 Label ‘d’ is defined more than once"],
                    "a warning at every definition; keys are trimmed")
        Check.equal(twice.map(\.detail), ["Also defined at main.tex:3", "Also defined at main.tex:1"])
        Check.equal(twice.map(\.column), [8, 11])
        Check.equal(twice.map(\.length), [1, 1])

        let across = lint(["main.tex": "\\input{a}\\input{b/c}\\label{x}", "a.tex": "\\label{x}", "b/c.tex": "\\label{x}"])
        Check.equal(across.count, 3)
        Check.equal(across.map(\.detail), ["Also defined at a.tex:1, b/c.tex:1", "Also defined at main.tex:1, b/c.tex:1",
                                           "Also defined at main.tex:1, a.tex:1"],
                    "the other places, in document order, paths relative to the root file")
        Check.equal(across.compactMap(\.fileURL?.lastPathComponent), ["main.tex", "a.tex", "c.tex"])

        let many = lint(["main.tex": (1...8).map { _ in "\\label{d}" }.joined(separator: "\n")])
        Check.equal(many.count, 8)
        Check.equal(many.first?.detail, "Also defined at main.tex:2, main.tex:3, main.tex:4, main.tex:5, main.tex:6 and 2 more")
        Check.equal(many.last?.detail, "Also defined at main.tex:1, main.tex:2, main.tex:3, main.tex:4, main.tex:5 and 2 more")

        Check.equal(lint(["main.tex": "\\label{a}\\label{A}\\label{a }"]).count, 2, "case-sensitive; trimmed")
        Check.equal(lint(["main.tex": "\\label{a}\\begin{lstlisting}[label=a]\n\\end{lstlisting}"]).count, 0,
                    "an option label never makes a duplicate")
        Check.equal(lint(["main.tex": "\\label{x}\n% \\label{x}\n\\begin{verbatim}\\label{x}\\end{verbatim}"]).count, 0)

        // Alternatives of one conditional are not duplicates.
        func count(_ text: String) -> Int { lint(["main.tex": text]).count }
        Check.equal(count("\\newif\\ifenglish\\englishtrue\n\\ifenglish\\label{intro}\\else\\label{intro}\\fi\n"), 0,
                    "the two branches of \\if…\\else…\\fi")
        Check.equal(count("\\label{a}\\iftrue\\label{a}\\fi"), 0, "one always-defined and one conditional definition")
        Check.equal(count("\\label{a}\\ifx\\foo\\bar\\label{a}\\fi\\label{a}"), 3, "two unconditional definitions: all are reported")
        Check.equal(count("\\iftrue x\\fi\\label{a}\\label{a}"), 2, "after the \\fi")
        Check.equal(count("\\ifdefined\\foo\\label{a}\\fi\\label{a}"), 0, "\\ifdefined opens a conditional")
        Check.equal(count("$a \\iff b$ \\label{a}\\label{a}"), 2, "\\iff is not a conditional")
        Check.equal(count("\\ifthenelse{\\equal{a}{b}}{x}{y}\\label{a}\\label{a}"), 2, "\\ifthenelse is not closed by \\fi")
        Check.equal(count("\\ifdraft{x}{y}\\iftoggle{t}{a}{b}\\label{a}\\label{a}"), 2, "braced conditionals")
        Check.equal(count("\\newif\\iffoo \\label{a}\\label{a}"), 2, "\\newif declares, it does not open")
        Check.equal(count("\\fi\\fi\\label{a}\\label{a}"), 2, "stray \\fi")
        Check.equal(count("\\if aa\\label{a}\\fi\\label{a}"), 0, "\\if opens a conditional")
        let conditional = refScan("\\ifx\\a\\b\\ref{in}\\fi\\ref{out}").references
        Check.equal(conditional.map(\.isConditional), [true, false])
    }

    await Check.suite("ReferenceLinter: citations") {
        func lint(_ main: String, extra: [String: String] = [:]) -> [String] {
            var files = ["main.tex": main]
            for (path, text) in extra { files[path] = text }
            return refDescribe(RefProject(files: files).lint())
        }
        let bib = ["refs.bib": "@article{knuth84, title={T}}\n@book{Hatcher2002, title={AT}}\n@comment{ignored,}"]
        func missingMessage(_ key: String, line: Int = 1) -> String { "main.tex:\(line) Citation ‘\(key)’ is not in the bibliography" }

        Check.equal(lint("\\bibliography{refs}\\cite{knuth84}\\citep[p.~2]{Hatcher2002, knuth84}", extra: bib), [])
        Check.equal(lint("\\bibliography{refs}\\cite{nope}", extra: bib), [missingMessage("nope")])
        Check.equal(lint("\\bibliography{refs}\\cite{knuth84,nope,other}", extra: bib), [missingMessage("nope"), missingMessage("other")])
        Check.equal(lint("\\bibliography{refs}\\textcite{KNUTH84}\\cite{hatcher2002}", extra: bib), [],
                    "BibTeX compares keys case-insensitively")
        Check.equal(lint("\\bibliography{refs}\\cite{ignored}", extra: bib), [missingMessage("ignored")], "@comment is not an entry")
        Check.equal(lint("\\addbibresource{refs.bib}\\parencite{nope}\\autocite{knuth84}", extra: bib), [missingMessage("nope")])
        Check.equal(lint("\\bibliography{a,b}\\cite{x,y,z}", extra: ["a.bib": "@misc{x,}", "b.bib": "@misc{y,}"]), [missingMessage("z")],
                    "several .bib files")
        Check.equal(lint("\\input{ch}\\bibliography{refs}", extra: bib.merging(["ch.tex": "\\cite{inchapter}\\cite{knuth84}"]) { $1 }),
                    ["ch.tex:1 Citation ‘inchapter’ is not in the bibliography"])
        Check.equal(lint("\\bibliography{refs}\\nocite{*}\\nocite{nope}", extra: bib), [missingMessage("nope")], "\\nocite{*} is skipped")
        Check.equal(lint("\\bibliography{refs}\\cite{a}\n\\cite{a}", extra: bib), [missingMessage("a"), missingMessage("a", line: 2)],
                    "every use is reported")

        // \bibitem
        let items = "\\begin{thebibliography}{9}\\bibitem{knuth}K.\\bibitem[L 94]{lamport}L.\\end{thebibliography}"
        Check.equal(lint(items + "\\cite{knuth,lamport}"), [])
        Check.equal(lint(items + "\\cite{knuth,other}"), [missingMessage("other")])
        Check.equal(lint(items + "\\cite{Knuth}"), [missingMessage("Knuth")], "\\bibitem keys match exactly")
        Check.equal(lint(items + "\\bibliography{refs}\\cite{knuth,knuth84,nope}", extra: bib), [missingMessage("nope")],
                    "bib entries and bibitems together")

        // No bibliography source at all: say nothing.
        Check.equal(lint("\\cite{a}\\nocite{b}"), [], "no bibliography yet")
        Check.equal(lint("\\bibliographystyle{plain}\\cite{a}"), [], "a style alone is not a bibliography")
        // The keys cannot be known: say nothing.
        Check.equal(lint("\\bibliography{refs}\\cite{a}"), [], "\\bibliography file not found")
        Check.equal(lint("\\bibliography{refs,more}\\cite{a}", extra: bib), [], "one of the files not found")
        Check.equal(lint("\\addbibresource{refs.json}\\cite{a}", extra: ["refs.json": "[]"]), [], "not a .bib resource")
        Check.equal(lint("\\bibliography{refs}\\externalcitedocument{other}\\cite{a}", extra: bib), [], "xcite")
        // An empty bibliography is still a bibliography.
        Check.equal(lint("\\bibliography{refs}\\cite{a}", extra: ["refs.bib": "% nothing yet\n"]), [missingMessage("a")])
        Check.equal(lint("% \\bibliography{refs}\n\\cite{a}"), [], "a commented-out bibliography is no bibliography")
        Check.equal(lint("\\bibliography{refs}\n% \\cite{a}\n\\begin{verbatim}\\cite{b}\\end{verbatim}", extra: bib), [])
    }

    await Check.suite("ReferenceLinter: diagnostics are plain values") {
        let project = RefProject(files: ["main.tex": "\\ref{a}\\ref{b}"])
        let a = project.lint()
        let b = project.lint()
        Check.equal(a.count, 2)
        Check.equal(a.map(\.message), b.map(\.message))
        Check.equal(a.map(\.column), b.map(\.column), "deterministic")
        Check.expect(a[0].id != a[1].id)
        Check.equal(ReferenceLinter.diagnostics(index: ProjectIndex(rootFile: fileURL("main.tex"))).count, 0, "an empty index")
    }

    await Check.suite("ReferenceLinter: findings and LaTeX's own warnings") {
        let project = RefProject(files: ["main.tex": "\\label{d}\\label{d}\\ref{u}\\bibliography{r}\\cite{c}", "r.bib": "@misc{z,}"])
        let index = project.index()
        let findings = ReferenceLinter.findings(index: index)
        Check.equal(findings.map(\.key), ["d", "d", "u", "c"])
        Check.expect(findings.map(\.kind) == [.duplicateLabel, .duplicateLabel, .undefinedReference, .missingCitation])
        Check.equal(findings.map(\.diagnostic.message), ReferenceLinter.diagnostics(index: index).map(\.message),
                    "diagnostics(index:) is findings(index:) without the kinds")

        func tex(_ message: String) -> String {
            guard let found = ReferenceLinter.texWarning(message) else { return "-" }
            return "\(found.kind):\(found.key)"
        }
        Check.equal(tex("Reference `sec:a' on page 3 undefined"), "undefinedReference:sec:a")
        Check.equal(tex("Reference `sec:a' on page 3 undefined."), "undefinedReference:sec:a", "trailing period")
        Check.equal(tex("Citation 'knuth84' on page 1 undefined"), "missingCitation:knuth84", "plain apostrophes")
        Check.equal(tex("Citation \u{2018}x\u{2019} on page 12 undefined."), "missingCitation:x", "curly quotes")
        Check.equal(tex("Label `eq:a' multiply defined."), "duplicateLabel:eq:a")
        Check.equal(tex("Reference `my key' on page 1 undefined"), "undefinedReference:my key")
        Check.equal(tex("Reference `it's' on page 1 undefined"), "undefinedReference:it's", "a quote inside the key")
        for other in ["There were undefined references.", "Reference `a' on page 1 defined",
                      "Label(s) may have changed. Rerun to get cross-references right.",
                      "Reference on page 1 undefined", "Reference `' on page 1 undefined", "Overfull \\hbox (3.0pt too wide)",
                      "Citation `a' on page 1 undefined on input line 5", "hyperref: Token not allowed", ""] {
            Check.equal(tex(other), "-", "not a reference warning: \(other)")
        }
    }

    // MARK: Performance

    await Check.suite("ReferenceLinter: 200-file project lints within a few milliseconds") {
        #if DEBUG
        let scale = 40.0
        #else
        let scale = 1.0
        #endif
        var files: [String: String] = [:]
        var main = "\\documentclass{article}\n\\begin{document}\n"
        for f in 0..<200 {
            main += "\\input{s\(f)}\n"
            var body = "\\section{Section \(f)}\\label{sec:\(f)}\\label{dup}\n"
            body += "Ghost \\ref{missing\(f)} and \\cite{ghost\(f)}.\n"
            for k in 0..<10 {
                body += "Text \\ref{sec:\((f + k) % 200)} \\cite{key\((f * 7 + k) % 400)} \\eqref{eq:\(f)-\(k)}.\n"
                body += "\\begin{equation}\\label{eq:\(f)-\(k)} x \\end{equation}\n"
            }
            files["s\(f).tex"] = body
        }
        files["refs.bib"] = (0..<400).map { "@article{key\($0), title={Title \($0)}}" }.joined(separator: "\n")
        files["main.tex"] = main + "\\bibliography{refs}\n\\end{document}\n"
        let project = RefProject(files: files)

        let clock = ContinuousClock()
        let buildStart = clock.now
        let index = project.index()
        let buildTime = clock.now - buildStart
        Check.equal(index.files.count, 201)
        Check.equal(index.labelSites.count, 200 * 12)
        Check.equal(index.referenceUses.count, 200 * 21)
        Check.equal(index.citationUses.count, 200 * 11)

        var times: [Double] = []
        var count = 0
        for run in 0..<7 {
            let start = clock.now
            let found = ReferenceLinter.diagnostics(index: index)
            let c = (clock.now - start).components
            if run >= 2 { times.append(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15) }
            count = found.count
        }
        times.sort()
        let median = times[times.count / 2]
        // 200 duplicate "dup" labels + 200 undefined references + 200 missing citations.
        Check.equal(count, 600)
        let b = buildTime.components
        print("  TIMING reference lint (200 files, \(index.referenceUses.count) refs, \(index.citationUses.count) cites): "
              + String(format: "%.2f ms; index build %.1f ms", median, Double(b.seconds) * 1000 + Double(b.attoseconds) / 1e15))
        Check.expect(median < 30 * scale, "lint took \(median) ms (bound \(30 * scale) ms)")
    }
}

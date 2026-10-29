import Foundation
import CheckKit
import TeXCore

private let testSymbols: ProjectSymbols = {
    let main = fileURL("main.tex")
    return ProjectSymbols(
        labels: [
            LabelDefinition(key: "sec:intro", fileURL: main, line: 3, context: "Introduction"),
            LabelDefinition(key: "eq:main", fileURL: main, line: 10, context: "equation"),
            LabelDefinition(key: "eq:other", fileURL: fileURL("sections/a.tex"), line: 4, context: "align"),
            LabelDefinition(key: "fig:one", fileURL: main, line: 20, context: nil),
        ],
        bibEntries: [
            BibEntry(key: "knuth1984", type: "book", title: "The Art of Computer Programming", author: "Knuth, Donald", year: "1984",
                     fileURL: fileURL("refs.bib"), line: 1),
            BibEntry(key: "lamport94", type: "book", title: "LaTeX: A Document Preparation System", author: "Lamport, Leslie", year: "1994",
                     fileURL: fileURL("refs.bib"), line: 9),
            BibEntry(key: "hatcher2002", type: "book", title: "Algebraic Topology", author: "Hatcher, Allen", year: "2002",
                     fileURL: fileURL("refs.bib"), line: 17),
            BibEntry(key: "bare", type: "misc", fileURL: fileURL("refs.bib"), line: 25),
        ],
        customCommands: [
            CompletionItem(kind: .command, label: "\\R", insertText: "\\R", detail: "Defined in project"),
            CompletionItem(kind: .command, label: "\\norm", insertText: "\\norm{${1:arg}}", detail: "Defined in project"),
            CompletionItem(kind: .command, label: "\\vec", insertText: "\\vec{${1:arg}}", detail: "Defined in project"),
        ],
        customEnvironments: ["myenv"],
        projectFiles: ["main.tex", "sections/intro.tex", "sections/methods.tex", "figs/plot.pdf", "figs/photo.png",
                       "refs.bib", "extra/more.bib", "mystyle.sty"]
    )
}()

private func complete(_ marked: String, _ symbols: ProjectSymbols = testSymbols) -> (result: CompletionResult?, text: String, cursor: Int) {
    let (text, cursor) = splitCursor(marked)
    return (CompletionEngine.complete(text: text as NSString, cursor: cursor, symbols: symbols), text, cursor)
}

/// Index of the first label that equals `label`, or nil.
private func position(of label: String, in result: CompletionResult?) -> Int? {
    result?.items.firstIndex { $0.label == label }
}

@MainActor
func runCompletionChecks() async {
    await Check.suite("Completion: commands") {
        let a = complete("Some text \\fr‸")
        Check.equal(a.result?.prefix, "\\fr")
        Check.equal(a.result?.replacementRange, NSRange(location: 10, length: 3))
        let items = a.result?.items ?? []
        Check.expect(!items.isEmpty)
        let firstOther = items.firstIndex { !$0.label.lowercased().hasPrefix("\\fr") } ?? items.count
        Check.expect(items.prefix(firstOther).allSatisfy { $0.label.hasPrefix("\\fr") }, "prefix matches first")
        Check.expect(items[firstOther...].allSatisfy { !$0.label.lowercased().hasPrefix("\\fr") }, "no prefix match after a fuzzy one")
        Check.expect(items.contains { $0.label == "\\frametitle" } && items.contains { $0.label == "\\frac" })
        Check.expect(items.allSatisfy { $0.kind == .command })
        Check.expect(items.count <= 200)

        // Exact match first, then case-sensitive prefix, then case-insensitive prefix.
        let exact = complete("\\section‸").result
        Check.equal(exact?.items.first?.label, "\\section")
        if let star = position(of: "\\section*", in: exact), let sub = position(of: "\\subsection", in: exact) {
            Check.expect(star < sub, "prefix match \\section* before the fuzzy match \\subsection")
        }
        let caseInsensitive = complete("\\TEXTB‸").result
        Check.expect(caseInsensitive?.items.first?.label == "\\textbf", "case-insensitive prefix: \(labels(caseInsensitive).prefix(3))")

        // Fuzzy (subsequence) needs two letters.
        let fuzzy = complete("\\tbf‸").result
        Check.expect(fuzzy?.items.contains { $0.label == "\\textbf" } == true, "subsequence match for \\tbf")
        Check.equal(complete("\\zzzzqq‸").result, nil, "no match → nil")
        let one = complete("\\q‸").result
        Check.expect(one?.items.allSatisfy { $0.label.lowercased().hasPrefix("\\q") } ?? true, "one typed letter: no fuzzy noise")

        // Project commands first and with their snippet.
        let custom = complete("\\no‸").result
        Check.equal(custom?.items.first?.label, "\\norm")
        Check.equal(custom?.items.first?.insertText, "\\norm{${1:arg}}")
        Check.equal(complete("\\R‸").result?.items.first?.label, "\\R", "exact match of a project command")
        let vec = complete("a \\vec‸").result
        Check.equal(vec?.items.filter { $0.label == "\\vec" }.count, 1, "a project command replaces the catalog entry")
        Check.equal(vec?.items.first?.detail, "Defined in project")

        // Cursor in the middle of text: replacement covers only what precedes the cursor.
        let mid = complete("\\fr‸ac and more")
        Check.equal(mid.result?.replacementRange, NSRange(location: 0, length: 3))

        // UTF-16 offsets.
        Check.equal(complete("ação é \\fr‸").result?.replacementRange, NSRange(location: 7, length: 3))
        Check.equal(complete("😀 \\fr‸").result?.replacementRange, NSRange(location: 3, length: 3))
        Check.equal(complete("a\r\nb \\fr‸").result?.replacementRange, NSRange(location: 5, length: 3))

        // Star and digits are not part of the name being typed.
        Check.equal(complete("\\section*‸").result, nil, "after a star there is nothing to complete")
        Check.equal(complete("x\\\\fr‸").result, nil, "\\\\ is a line break, not a command start")
        Check.equal(complete("x\\\\\\fr‸").result?.replacementRange, NSRange(location: 3, length: 3), "\\\\\\fr is \\\\ + \\fr")
        Check.equal(complete("Plain wor‸").result, nil)
        Check.equal(complete("‸").result, nil)
        Check.equal(CompletionEngine.complete(text: "abc" as NSString, cursor: 10, symbols: .empty), nil)
        Check.equal(CompletionEngine.complete(text: "abc" as NSString, cursor: -1, symbols: .empty), nil)
        Check.equal(CompletionEngine.complete(text: "\\fr", cursor: 3, symbols: .empty)?.prefix, "\\fr", "String overload")
    }

    await Check.suite("Completion: bare backslash and common commands") {
        let bare = complete("\\‸").result
        Check.equal(bare?.prefix, "\\")
        Check.equal(bare?.replacementRange, NSRange(location: 0, length: 1))
        Check.equal(bare?.items.count, 80)
        Check.equal(bare?.items.first?.label, "\\R", "project commands come first")
        let bareLabels = labels(bare)
        Check.equal(Set(bareLabels).count, bareLabels.count, "no duplicates")
        for common in ["\\begin", "\\section", "\\textbf", "\\label", "\\ref", "\\cite", "\\item"] {
            Check.expect(bareLabels.contains(common), "bare \\ offers \(common)")
        }
        let plain = complete("\\‸", .empty).result
        Check.expect(plain != nil && plain!.items.count == 80)
        let mathBare = complete("$x = \\‸$", .empty).result
        for common in ["\\frac", "\\alpha", "\\sum", "\\int", "\\mathbb", "\\left"] {
            Check.expect(labels(mathBare).contains(common), "math bare \\ offers \(common)")
        }
        Check.expect(!labels(mathBare).contains("\\section"), "no \\section in math suggestions")
    }

    await Check.suite("Completion: math-aware ranking") {
        func rankOf(_ label: String, in marked: String) -> Int? { position(of: label, in: complete(marked, .empty).result) }
        for marked in ["$x = \\fr‸$", "\\[ \\fr‸ \\]", "\\begin{equation}\\fr‸\\end{equation}", "\\begin{align*} a &= \\fr‸ \\end{align*}",
                       "$$ \\fr‸ $$", "\\(\\fr‸\\)", "\\begin{gather}\\fr‸"] {
            let r = complete(marked, .empty).result
            Check.equal(r?.items.first?.label, "\\frac", "math: \(marked.replacingOccurrences(of: "\n", with: " "))")
        }
        for marked in ["\\fr‸", "$x$ \\fr‸", "\\begin{itemize}\\fr‸", "$x \\text{ \\fr‸}$", "\\[ x \\] \\fr‸", "% $\n\\fr‸",
                       "\\begin{equation}x\\end{equation} \\fr‸", "$x \\mbox{\\fr‸}$"] {
            let r = complete(marked, .empty).result
            let f = position(of: "\\frac", in: r), t = position(of: "\\frametitle", in: r)
            Check.expect(f != nil && t != nil && t! < f!, "text: \\frametitle before \\frac in \(marked.replacingOccurrences(of: "\n", with: " "))")
        }
        // Common commands win ties.
        Check.equal(complete("\\su‸", .empty).result?.items.first?.label, "\\subsection")
        Check.equal(complete("$\\su‸$", .empty).result?.items.first?.label, "\\sum")
        Check.equal(complete("\\te‸", .empty).result?.items.first?.label, "\\textbf")
        Check.equal(complete("$\\la‸$", .empty).result?.items.first?.label, "\\lambda")
        Check.equal(complete("$\\al‸$", .empty).result?.items.first?.label, "\\alpha")
        // Math-only commands are still available in text mode (after the text commands).
        Check.expect(rankOf("\\alpha", in: "\\alp‸") != nil)
    }

    await Check.suite("Completion: \\begin{ and \\end{") {
        let a = complete("\\begin{ite‸}")
        Check.equal(a.result?.prefix, "ite")
        Check.equal(a.result?.replacementRange, NSRange(location: 7, length: 4), "covers `ite}`")
        Check.equal(a.result?.items.first?.label, "itemize")
        Check.equal(a.result?.items.first?.insertText, "itemize}\n\t\\item $0\n\\end{itemize}")
        Check.expect(a.result?.items.allSatisfy { $0.kind == .environment } == true)

        let b = complete("\\begin{ite‸")
        Check.equal(b.result?.replacementRange, NSRange(location: 7, length: 3), "no closing brace to swallow")
        let c = complete("\\begin{ite‸ms}")
        Check.equal(c.result?.replacementRange, NSRange(location: 7, length: 6), "rest of the name and the brace")
        let d = complete("\\begin{ite‸} text } more")
        Check.equal(d.result?.replacementRange, NSRange(location: 7, length: 4), "only the first brace")
        let e = complete("\\begin{ite‸ \\foo}")
        Check.equal(e.result?.replacementRange, NSRange(location: 7, length: 3), "a brace after other text is not adjacent")
        let spaced = complete("\\begin {ite‸}")
        Check.equal(spaced.result?.items.first?.label, "itemize")
        Check.equal(spaced.result?.replacementRange, NSRange(location: 8, length: 4))

        let all = complete("\\begin{‸}")
        Check.equal(all.result?.prefix, "")
        Check.equal(all.result?.items.first?.label, "myenv", "project environments first")
        Check.equal(all.result?.items.first?.insertText, "myenv}\n\t$0\n\\end{myenv}")
        Check.expect((all.result?.items.count ?? 0) > 100)

        Check.equal(complete("\\begin{align‸}", .empty).result?.items.first?.label, "align", "exact match first")
        Check.expect(labels(complete("\\begin{align‸}", .empty).result).contains("align*"))
        Check.expect(labels(complete("\\begin{tbl‸", .empty).result).contains("table"), "fuzzy: tbl → table")

        // Math context: inner math environments first.
        let innerMath: Set<String> = ["aligned", "alignedat", "gathered", "split", "cases", "dcases", "rcases", "matrix", "pmatrix", "bmatrix",
                                      "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "array", "subarray"]
        let inMath = complete("\\[ \\begin{‸} \\]", .empty).result
        Check.expect(inMath?.items.first.map { innerMath.contains($0.label) } == true, "inside \\[ \\]: \(labels(inMath).prefix(3))")
        let outside = complete("\\begin{‸}", .empty).result
        Check.expect(outside?.items.first.map { !innerMath.contains($0.label) } == true, "outside math the catalog order is kept: \(labels(outside).prefix(3))")
        Check.equal(complete("\\begin{ite‸}", .empty).result?.items.first?.label, "itemize")

        // Masked contexts.
        Check.equal(complete("% \\begin{ite‸}").result, nil, "comment")
        Check.equal(complete("\\begin{verbatim}\n\\begin{ite‸}\n\\end{verbatim}").result, nil, "verbatim body")

        // \end{ — innermost unclosed first.
        let doc = """
        \\begin{document}
        \\begin{itemize}
        \\item x
        \\begin{center}
        \\end{center}
        \\end{‸}
        """
        let end = complete(doc, .empty)
        Check.equal(labels(end.result), ["itemize", "document"], "innermost first; closed environments are not offered")
        Check.equal(end.result?.items.first?.insertText, "itemize}")
        Check.equal(end.result?.items.first?.kind, .environment)
        Check.expect(end.result?.items.first?.detail?.contains("2") == true, "detail names the opening line: \(end.result?.items.first?.detail ?? "nil")")
        Check.equal(end.result?.replacementRange, NSRange(location: end.cursor, length: 1), "swallows the auto-paired brace")
        let endOpen = complete(String(doc.dropLast()), .empty)
        Check.equal(endOpen.result?.replacementRange, NSRange(location: endOpen.cursor, length: 0), "no brace to swallow")

        Check.equal(labels(complete("\\begin{a}\\begin{b}\\begin{c}\\end{‸", .empty).result), ["c", "b", "a"])
        Check.equal(labels(complete("\\begin{x}\\end{x}\\begin{y}\\end{‸", .empty).result), ["y"])
        Check.equal(labels(complete("\\begin{document}\\begin{theorem}\\end{doc‸}", .empty).result), ["document"], "typed prefix filters the open ones")
        Check.equal(complete("% \\begin{ghost}\n\\begin{real}\n\\end{‸}", .empty).result?.items.map(\.label), ["real"], "commented \\begin ignored")
        Check.equal(complete("\\begin{verbatim}\\begin{x}\\end{verbatim}\\begin{y}\\end{‸}", .empty).result?.items.map(\.label), ["y"])
        Check.equal(complete("\\begin{myenv}\n\\end{‸}").result?.items.map(\.label), ["myenv"])
        let none = complete("\\end{‸}", .empty).result
        Check.expect(none != nil && none!.items.count > 50, "nothing open: any environment name")
        Check.expect(none?.items.allSatisfy { $0.insertText.hasSuffix("}") && !$0.insertText.contains("\\end") } == true)
        Check.expect(labels(complete("\\begin{a}\\end{a}\\end{b‸", .empty).result).contains("bmatrix"), "no open match → catalog fallback")
        Check.equal(labels(complete("\\begin{a*}\\end{a‸", .empty).result), ["a*"], "starred environment names")
    }

    await Check.suite("Completion: labels") {
        let all = complete("\\ref{‸}")
        Check.equal(labels(all.result), ["sec:intro", "eq:main", "eq:other", "fig:one"])
        Check.equal(all.result?.replacementRange, NSRange(location: 5, length: 0))
        Check.equal(all.result?.items.map(\.detail), ["Introduction", "equation", "align", "main.tex:20"], "context or file:line")
        Check.expect(all.result?.items.allSatisfy { $0.kind == .label && $0.insertText == $0.label } == true)

        let eq = complete("see \\ref{eq:‸}")
        Check.equal(labels(eq.result), ["eq:main", "eq:other"])
        Check.equal(eq.result?.prefix, "eq:")
        Check.equal(eq.result?.replacementRange, NSRange(location: 9, length: 3), "no brace extension for labels")
        Check.equal(labels(complete("\\ref{eq‸}").result), ["eq:main", "eq:other"])
        Check.equal(labels(complete("\\ref{sin‸}").result), ["sec:intro"], "fuzzy")
        Check.equal(labels(complete("\\ref{intro‸}").result), ["sec:intro"], "word-start match after ':'")
        Check.equal(labels(complete("\\ref{EQ:M‸}").result), ["eq:main"], "case-insensitive")
        Check.equal(complete("\\ref{nothing‸}").result, nil)
        for command in ["ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "vref", "Vref"] {
            Check.equal(complete("\\\(command){fig‸}").result?.items.first?.label, "fig:one", "\\\(command)")
        }
        Check.equal(complete("\\ref*{fig‸}").result?.items.first?.label, "fig:one", "starred \\ref*")
        Check.equal(complete("\\ref [x] {fig‸}").result?.items.first?.label, "fig:one", "optional argument between")
        // Comma lists only for cleveref-style commands.
        let cref = complete("\\cref{eq:main,fi‸}")
        Check.equal(labels(cref.result), ["fig:one"])
        Check.equal(cref.result?.prefix, "fi")
        Check.equal(cref.result?.replacementRange, NSRange(location: 14, length: 2))
        Check.equal(labels(complete("\\cref{eq:main, ‸}").result).count, 4, "after a comma: all labels")
        Check.equal(complete("\\cref{eq:main, ‸}").result?.replacementRange, NSRange(location: 15, length: 0))
        // Many labels are capped at 200.
        var many = testSymbols
        many.labels = (0..<300).map { LabelDefinition(key: "lab\($0)", fileURL: fileURL("main.tex"), line: $0 + 1) }
        Check.equal(complete("\\ref{‸}", many).result?.items.count, 200)
        let lab29 = labels(complete("\\ref{lab29‸}", many).result)
        Check.expect(lab29.prefix(11).allSatisfy { $0.hasPrefix("lab29") } && lab29.count > 11, "prefix matches first (lab29, lab290…lab299), fuzzy matches after")
        // Duplicates collapse.
        var dup = testSymbols
        dup.labels += [LabelDefinition(key: "eq:main", fileURL: fileURL("b.tex"), line: 1)]
        Check.equal(labels(complete("\\ref{eq:m‸}", dup).result), ["eq:main"])
        // Contexts that must not complete.
        Check.equal(complete("\\label{‸}").result, nil, "defining a label")
        Check.equal(complete("\\ref{eq:main}‸").result, nil, "after the closing brace")
        Check.equal(complete("% \\ref{eq‸}").result, nil)
        Check.equal(complete("\\ref{\n\n‸").result, nil, "blank line ends the argument")
        Check.equal(complete("\\foo{eq‸}").result, nil, "unknown command")
        Check.equal(complete("\\textbf{eq‸}").result, nil)
        Check.equal(complete("\\ref{a\\foo‸}").result?.prefix, "\\foo", "a command inside the braces is a command context")
    }

    await Check.suite("Completion: citations") {
        let all = complete("\\cite{‸}")
        Check.equal(labels(all.result), ["knuth1984", "lamport94", "hatcher2002", "bare"])
        Check.equal(all.result?.items.first?.detail, "Knuth, Donald (1984) — The Art of Computer Programming")
        Check.equal(all.result?.items.last?.detail, "misc", "no metadata → entry type")
        Check.expect(all.result?.items.allSatisfy { $0.kind == .citation } == true)
        Check.equal(labels(complete("\\cite{kn‸}").result), ["knuth1984"])
        let list = complete("\\cite{knuth1984,la‸}")
        Check.equal(labels(list.result), ["lamport94"])
        Check.equal(list.result?.prefix, "la")
        Check.equal(list.result?.replacementRange, NSRange(location: 16, length: 2), "only the current item")
        Check.equal(complete("\\cite{knuth1984, la‸}").result?.replacementRange, NSRange(location: 17, length: 2), "space after the comma is skipped")
        Check.equal(complete("\\cite{knuth1984,\n  la‸}").result?.prefix, "la", "newline after the comma")
        Check.equal(complete("\\cite{a,b,‸}").result?.items.count, 4)
        Check.equal(labels(complete("\\citep[see][p.~3]{ha‸}").result), ["hatcher2002"], "two optional arguments")
        Check.equal(labels(complete("\\cite[p.~3]{ha‸}").result), ["hatcher2002"])
        let middle = complete("\\cite{kn‸uth1984}")
        Check.equal(middle.result?.replacementRange, NSRange(location: 6, length: 2), "the rest of the key is not replaced")
        for command in ["cite", "citep", "citet", "citeauthor", "citeyear", "Cite", "parencite", "textcite", "autocite", "footcite", "nocite",
                        "Citep", "supercite", "cites"] {
            Check.equal(complete("\\\(command){lam‸}").result?.items.first?.label, "lamport94", "\\\(command)")
        }
        Check.equal(complete("\\cite*{lam‸}").result?.items.first?.label, "lamport94", "starred")
        // Matching on author and title when the key does not match.
        Check.equal(labels(complete("\\cite{Allen‸}").result), ["hatcher2002"], "author")
        Check.equal(labels(complete("\\cite{Algebraic‸}").result), ["hatcher2002"], "title")
        Check.equal(complete("\\cite{zzzzz‸}").result, nil)
        Check.equal(complete("\\cite{kn‸}", .empty).result, nil, "no bibliography")
        Check.equal(complete("\\citestyle{kn‸}").result, nil, "\\citestyle is not a citation command")
    }

    await Check.suite("Completion: packages") {
        let ams = complete("\\usepackage{amsm‸}", .empty)
        Check.equal(ams.result?.items.first?.label, "amsmath")
        Check.equal(ams.result?.prefix, "amsm")
        Check.equal(ams.result?.replacementRange, NSRange(location: 12, length: 4))
        Check.expect(ams.result?.items.allSatisfy { $0.kind == .package } == true)
        Check.equal(complete("\\usepackage[utf8]{inpu‸}", .empty).result?.items.first?.label, "inputenc")
        let list = complete("\\usepackage{amsmath,tik‸}", .empty)
        Check.expect(labels(list.result).contains("tikz"))
        Check.equal(list.result?.prefix, "tik")
        Check.equal(list.result?.replacementRange, NSRange(location: 20, length: 3))
        Check.equal(complete("\\RequirePackage{xcol‸}", .empty).result?.items.first?.label, "xcolor")
        Check.equal(complete("\\usepackage[a=b,c=d]{geo‸}", .empty).result?.items.first?.label, "geometry")
        let local = complete("\\usepackage{mys‸}")
        Check.equal(local.result?.items.first?.label, "mystyle", "a local .sty comes first")
        Check.equal(local.result?.items.first?.detail, "Local package")
        Check.expect(complete("\\usepackage{‸}", .empty).result.map { $0.items.count == 200 } == true, "capped at 200")
        Check.equal(complete("\\documentclass{art‸}", .empty).result, nil, "\\documentclass is not completed")
    }

    await Check.suite("Completion: files") {
        func files(_ marked: String) -> [String] { labels(complete(marked).result) }
        Check.equal(files("\\input{sec‸}"), ["sections/intro.tex", "sections/methods.tex"])
        Check.equal(files("\\input{intro‸}"), ["sections/intro.tex"], "word-start after '/'")
        Check.equal(files("\\input{smth‸}"), ["sections/methods.tex"], "fuzzy")
        Check.equal(files("\\include{sec‸}"), ["sections/intro", "sections/methods"], "\\include drops the extension")
        Check.equal(files("\\subfile{‸}"), ["main.tex", "sections/intro.tex", "sections/methods.tex"])
        Check.equal(files("\\includegraphics[width=2cm]{fi‸}"), ["figs/plot.pdf", "figs/photo.png"])
        Check.equal(files("\\includegraphics*{‸}"), ["figs/plot.pdf", "figs/photo.png"])
        Check.equal(files("\\includepdf[pages=-]{‸}"), ["figs/plot.pdf"])
        Check.equal(files("\\bibliography{re‸}"), ["refs", "extra/more"], "prefix first, then the fuzzy match")
        Check.equal(files("\\bibliography{refs,‸}"), ["refs", "extra/more"], "list: second item")
        Check.equal(files("\\addbibresource{‸}"), ["refs.bib", "extra/more.bib"])
        let r = complete("\\input{sec‸}").result
        Check.equal(r?.replacementRange, NSRange(location: 7, length: 3))
        Check.expect(r?.items.allSatisfy { $0.kind == .file } == true)
        let listed = complete("\\bibliography{refs,ex‸}").result
        Check.equal(listed?.replacementRange, NSRange(location: 19, length: 2), "only the current item")
        Check.equal(complete("\\input{zzz‸}").result, nil)
        Check.equal(complete("\\input{sec‸}", .empty).result, nil)
        Check.equal(complete("\\input{ sec‸}").result?.replacementRange, NSRange(location: 8, length: 3), "leading space skipped")
    }

    await Check.suite("Completion: masked regions and robustness") {
        Check.equal(complete("% \\fr‸").result, nil, "comment")
        Check.equal(complete("text % comment \\fr‸").result, nil)
        Check.equal(complete("\\begin{verbatim}\n\\fr‸\n\\end{verbatim}").result, nil, "verbatim")
        Check.equal(complete("\\begin{lstlisting}[language=C]\n\\fr‸\n\\end{lstlisting}").result, nil)
        Check.equal(complete("\\verb|\\fr‸|").result, nil, "\\verb")
        Check.equal(complete("\\url{http://x/\\fr‸}").result, nil, "\\url")
        Check.equal(complete("\\iffalse\n\\fr‸\n\\fi").result, nil, "\\iffalse block")
        // Comment ends at the line end.
        Check.equal(complete("% c\n\\fr‸").result?.replacementRange, NSRange(location: 4, length: 3))
        Check.equal(complete("\\fr‸ % c").result?.replacementRange, NSRange(location: 0, length: 3))
        // Long unterminated input does not hang or crash.
        let long = String(repeating: "word \\alpha {x ", count: 6000) + "\\ref{eq‸"
        let started = Date()
        _ = complete(long)
        Check.expect(Date().timeIntervalSince(started) < 2.0, "completion in a 90 KB document stays fast")
        // Fuzz: random prefixes of a document never crash and the replacement range stays inside the text.
        let sample = "\\documentclass{article}\n\\usepackage{amsmath}\n\\begin{document}\n\\section{A \\ref{eq:main}}\n$x \\frac{a}{b}$ \\cite{knuth1984,}\n\\begin{itemize}\n\\item é😀\n\\end{itemize}\n\\input{sections/intro}\n\\end{document}\n"
        let ns = sample as NSString
        var bad = 0
        for cursor in 0...ns.length {
            guard let result = CompletionEngine.complete(text: ns, cursor: cursor, symbols: testSymbols) else { continue }
            let range = result.replacementRange
            if range.location < 0 || NSMaxRange(range) > ns.length || range.location > cursor || NSMaxRange(range) < cursor || result.items.isEmpty {
                bad += 1
            }
        }
        Check.equal(bad, 0, "replacement ranges valid at every cursor position")
    }
}

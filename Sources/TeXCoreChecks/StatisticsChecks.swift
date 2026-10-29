import Foundation
import CheckKit
import TeXCore

// Checks for DocumentStatistics (word and formula counts) and PageAttribution — owned by the stats agent.

/// In-memory project: relative path → contents.
private struct Project {
    var files: [String: String]

    func read(_ url: URL) -> String? {
        let prefix = "/proj/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return files[String(url.path.dropFirst(prefix.count))]
    }

    func exists(_ url: URL) -> Bool { read(url) != nil }
}

private func compute(_ files: [String: String], root: String = "main.tex") -> DocumentStatistics {
    let project = Project(files: files)
    return DocumentStatistics.compute(rootFile: fileURL(root), read: project.read, fileExists: project.exists)
}

/// A complete one-file document around `text`.
private func document(_ text: String) -> String {
    "\\documentclass{article}\n\\begin{document}\n" + text + "\n\\end{document}\n"
}

private func body(_ text: String) -> DocumentStatistics {
    compute(["main.tex": document(text)])
}

private func words(_ text: String) -> Int { body(text).totals.words }

/// Titles of the sections in order.
private func titles(_ stats: DocumentStatistics) -> [String] { stats.sections.map(\.title) }

/// Ids of the outline entries without labels, flattened in document order.
private func outlineIDs(_ nodes: [OutlineNode]) -> [String] {
    var ids: [String] = []
    for node in nodes {
        if node.entry.kind != .label { ids.append(node.id) }
        ids.append(contentsOf: outlineIDs(node.children ?? []))
    }
    return ids
}

@MainActor
func runStatisticsChecks() async {
    await Check.suite("Statistics: what is a word") {
        Check.equal(words("Hello world, this is a test."), 6, "plain prose")
        Check.equal(words(""), 0, "empty body")
        Check.equal(words("   \n\n  \t "), 0, "only blanks")
        Check.equal(words("state-of-the-art design"), 2, "hyphenated word is one")
        Check.equal(words("guarda-chuva e bem-vindo"), 3, "Portuguese compounds")
        Check.equal(words("pages 10--20"), 3, "an en dash separates")
        Check.equal(words("a---b"), 2, "an em dash separates")
        Check.equal(words("a - b"), 2, "a spaced hyphen is not a word")
        Check.equal(words("hy\\-phen"), 1, "discretionary hyphen")
        Check.equal(words("don't stop"), 2, "apostrophe inside a word")
        Check.equal(words("dogs' toys"), 2, "trailing apostrophe")
        Check.equal(words("d\u{2019}água clara"), 2, "typographic apostrophe")
        Check.equal(words("``quoted'' text"), 2, "TeX quotes are punctuation")
        Check.equal(words("He said \"hello\" to me"), 5, "straight quotes are punctuation")
        Check.equal(words("3.14 is pi, 1,5 too, and 1.000.000."), 7, "decimal numbers are one word")
        Check.equal(words("In 1990."), 2, "a number before the full stop")
        Check.equal(words("COVID-19 and 2nd"), 3, "letters and digits mix")
        Check.equal(words("a.b"), 2, "a dot between letters separates")
        Check.equal(words("3.a"), 2, "a dot between a digit and a letter separates")
        Check.equal(words("one~two"), 2, "non-breaking space")
        Check.equal(words("one\\,two"), 2, "thin space")
        Check.equal(words("wait\\ldots what"), 2, "a command ends the word")
        Check.equal(words("word\u{2014}another"), 2, "Unicode em dash")
        Check.equal(words("\u{2018}quoted\u{2019} words"), 2, "typographic single quotes")
        Check.equal(words("one\r\ntwo\rthree\nfour"), 4, "CR, LF and CRLF")
    }

    await Check.suite("Statistics: accents, Unicode and babel shorthands") {
        Check.equal(words("ação coração Brasília"), 3, "precomposed Portuguese accents")
        Check.equal(words("a\u{0303}c\u{0327}a\u{0303}o"), 1, "decomposed accents stay one word")
        Check.equal(words("Müller Straße naïve"), 3, "German, French")
        Check.equal(words("Poincar\\'e"), 1, "\\'e")
        Check.equal(words("Poincar{\\'e}"), 1, "{\\'e}")
        Check.equal(words("Poincar\\'{e}"), 1, "\\'{e}")
        Check.equal(words("\\c{c}\\~ao"), 1, "\\c{c}\\~ao")
        Check.equal(words("S\\~ao Paulo"), 2, "S\\~ao Paulo")
        Check.equal(words("na\\\"{\\i}ve"), 1, "\\\"{\\i}")
        Check.equal(words("\\\"Ubung \\`a la"), 3, "\\\" and \\`")
        Check.equal(words("\\v{S}koda \\H{o}"), 2, "\\v \\H")
        Check.equal(words("Stra\\ss e"), 1, "\\ss swallows the space after it, as TeX does")
        Check.equal(words("Stra\\ss{}e"), 1, "\\ss{}")
        Check.equal(words("Stra{\\ss}e"), 1, "{\\ss}")
        Check.equal(words("Bj\\o rn \\AA ngstr\\o m"), 2, "\\o and \\AA")
        Check.equal(words("Sch\"on"), 1, "babel \"o")
        Check.equal(words("Wort\"=Trenner"), 1, "babel \"=")
        Check.equal(words("Wort\"-Trenner"), 1, "babel \"-")
        Check.equal(words("\u{6F22}\u{5B57}\u{304B}\u{306A}"), 4, "Han and kana count per character")
        Check.equal(words("\u{6F22}\u{5B57} and \u{304B}\u{306A}"), 5, "mixed scripts")
        Check.equal(words("hello \u{1F600} world"), 2, "an emoji is not a word")
        Check.equal(words("\u{20000} x"), 2, "supplementary-plane ideograph")
        Check.equal(words("\\'"), 0, "a stray accent")
        Check.equal(words("\\"), 0, "a lone backslash")
    }

    await Check.suite("Statistics: commands versus text arguments") {
        Check.equal(words("\\textbf{bold} and \\emph{emphasis}"), 3, "text arguments count")
        Check.equal(words("See Section~\\ref{sec:intro} and \\cite{knuth84}."), 3, "ref and cite do not")
        Check.equal(words("See \\cite[p.~3]{x} now"), 2, "cite with an option")
        Check.equal(words("\\textcite{x} says \\autocite*[1]{y} more \\nocite{*}"), 2, "biblatex forms")
        Check.equal(words("\\citep{a,b} \\citet{c}"), 0, "natbib forms")
        Check.equal(words("\\label{eq:x}\\eqref{a}\\pageref{b}\\autoref{c}\\cref{d,e}\\crefrange{f}{g}"), 0, "references")
        Check.equal(words("before\\footnote{A note here.} after"), 5, "footnotes count")
        Check.equal(words("\\includegraphics[width=0.5\\textwidth]{fig.png}"), 0, "includegraphics")
        Check.equal(words("\\hspace{1cm}\\vspace*{2em} done"), 1, "lengths are not words")
        Check.equal(words("\\setlength{\\parindent}{0pt} word"), 1, "setlength")
        Check.equal(words("\\url{https://example.com/a-b} see"), 1, "url")
        Check.equal(words("\\href{https://x.org/a}{link text} end"), 3, "href counts the link text only")
        Check.equal(words("\\begin{figure}[h]\\centering\\includegraphics{a}\\caption{A nice figure}\\label{fig:a}\\end{figure}"),
                    3, "figure with a caption")
        Check.equal(words("\\begin{figure}\\caption[short]{Long caption here}\\end{figure}"), 3, "short caption title is dropped")
        Check.equal(words("see \\begin{tabular}{lcr} a & b & c \\\\ \\hline d & e & f \\\\ \\end{tabular} below"), 2,
                    "table cells are layout, not prose")
        Check.equal(words("\\begin{minipage}[t]{0.5\\textwidth} inside text \\end{minipage}"), 2, "minipage")
        Check.equal(words("\\begin{multicols}{2}[Wide title] body text \\end{multicols}"), 4, "multicols: the option is a title")
        Check.equal(words("\\begin{multicols*}{3} body \\end{multicols*}"), 1, "multicols*")
        Check.equal(words("\\begin{minted}[linenos]{python} print(1) \\end{minted} done"), 1, "minted: language and code")
        Check.equal(words("\\mintinline{python}{print(1)} and \\mintinline{c}|x = 1| done"), 2, "mintinline")
        Check.equal(words("\\textcolor{red}{red words} \\colorbox{yellow}{marked}"), 3, "color arguments")
        Check.equal(words("\\begin{itemize}\\item[Label] text \\item Next\\end{itemize}"), 3, "item labels are text")
        Check.equal(words("\\begin{itemize}[leftmargin=*]\\item First\\item Second\\end{itemize}"), 2, "list options")
        Check.equal(words("\\begin{enumerate}[label=(\\alph*)]\\item one\\end{enumerate}"), 1, "enumitem options")
        Check.equal(words("a\\\\[2pt] b"), 2, "line break with a length")
        Check.equal(words("a\\\\* b"), 2, "starred line break")
        Check.equal(words("\\foo[opt]{arg words}"), 2, "unknown command: option dropped, argument read")
        Check.equal(words("\\hyperref[sec:a]{see here}"), 2, "hyperref")
        Check.equal(words("\\texttt{code_name}"), 2, "texttt")
        Check.equal(words("\\newpage text"), 1, "newpage")
        Check.equal(words("\\LaTeX{} rocks"), 2, "a logo is a word; braces after a command")
        Check.equal(words("\\TeX\\ and \\LaTeXe{}"), 3, "logos")
        Check.equal(words("\\author{Ann Writer\\thanks{Funded.} \\and Bob Reader} \\date{May 2025} text"), 1, "author and date are not prose")
        var title = body("\\title{A Short Title} text")
        Check.equal(title.totals.headingWords, 3, "a \\title in the body is a heading")
        Check.equal(title.totals.textWords, 1)
        title = compute(["main.tex": "\\documentclass{article}\n\\title{Not Counted Here}\n\\author{Me}\n\\begin{document}\n\\maketitle\nBody.\n\\end{document}\n"])
        Check.equal(title.totals.words, 1, "title and author in the preamble")
        Check.equal(words("\\parbox{5cm}{some boxed words} \\raisebox{1ex}[2ex]{up} done"), 5, "parbox and raisebox: the first argument is a length")
        Check.equal(words("\\textbf{foo}bar"), 1, "braces never split a word")
        Check.equal(words("foo\\textbf{bar}"), 2, "a command splits a word")
        Check.equal(words("\\only<2>{shown text}"), 2, "overlay specification")
        Check.equal(words("\\begin{itemize}\\item<1-> point\\textbf<2>{bold}\\end{itemize}"), 2, "overlays on item and textbf")
        Check.equal(words("\\newcommand{\\foo}[1]{Some words #1} text"), 1, "newcommand body")
        Check.equal(words("\\renewcommand{\\arraystretch}{1.5} x"), 1, "renewcommand")
        Check.equal(words("\\newenvironment{myenv}{begin words}{end words} body"), 1, "newenvironment")
        Check.equal(words("\\def\\foo#1{ignored words} kept"), 1, "def")
        Check.equal(words("\\DeclareMathOperator{\\Hom}{Hom} ok"), 1, "DeclareMathOperator")
        Check.equal(words("\\NewDocumentCommand{\\mycmd}{m}{some words} ok"), 1, "NewDocumentCommand")
        Check.equal(words("\\begin{tikzpicture}\\draw (0,0) -- (1,1) node {label words};\\end{tikzpicture} after"), 1, "tikzpicture")
        Check.equal(words("\\begin{thebibliography}{9}\\bibitem{a} Some Author. A title.\\end{thebibliography} end"), 1, "bibliography")
        Check.equal(words("\\texorpdfstring{one two}{ignored three} four"), 3, "texorpdfstring keeps the TeX argument")
        Check.equal(words("\\foreignlanguage{portuguese}{olá mundo}"), 2, "foreignlanguage")
    }

    await Check.suite("Statistics: tables, floats, captions") {
        // Tables: the contents never count (texcount ignores tabular, tabbing and titlepage as well).
        Check.equal(words("\\begin{tabular}[t]{|l|r|} a & b \\end{tabular}"), 0, "tabular with [pos]")
        Check.equal(words("\\begin{tabular*}{\\textwidth}{@{}ll} a & b \\end{tabular*}"), 0, "tabular*")
        Check.equal(words("\\begin{tabularx}{\\textwidth}{XX} a & b \\end{tabularx} after"), 1, "tabularx")
        Check.equal(words("\\begin{tabulary}{\\linewidth}{LL} a & b \\end{tabulary} after"), 1, "tabulary")
        Check.equal(words("\\begin{tabular}{cc} \\multicolumn{2}{c}{Merged cell} \\\\ \\cmidrule(lr){1-2} x & y \\end{tabular}"),
                    0, "multicolumn and cmidrule")
        Check.equal(words("\\begin{tabular}{l} \\begin{tabular}{l} inner \\end{tabular} outer \\end{tabular} after"), 1, "nested tabular")
        Check.equal(words("\\begin{tabbing} a \\= b \\\\ c \\> d \\end{tabbing} after"), 1, "tabbing")
        Check.equal(words("\\begin{titlepage} University of Somewhere \\end{titlepage} Introduction text"), 2, "titlepage")
        Check.equal(words("\\begin{tabular}{l} a $x$ \\[\\y\\] \\end{tabular}"), 0, "words in a table")
        var stats = body("\\begin{tabular}{l} $x$ and $$y$$ \\end{tabular}")
        Check.equal(stats.totals.inlineMath + stats.totals.displayMath, 0, "formulas in a table are not counted")
        Check.equal(words("\\begin{longtable}{ll} \\caption{Long caption} \\\\ a & b \\\\ \\end{longtable} after"), 3, "longtable: caption and text after only")

        // Floats: only the captions.
        Check.equal(words("\\begin{figure}[htbp] \\centering \\includegraphics{a} \\caption{Five six} \\label{f} \\end{figure}"), 2, "figure")
        Check.equal(words("\\begin{figure*} stray words \\caption{Five six seven} \\end{figure*}"), 3, "figure*: stray words do not count")
        Check.equal(words("\\begin{figure} one two \\begin{minipage}{5cm} three four \\end{minipage} \\caption{five six} \\end{figure}"),
                    2, "minipage in a figure")
        Check.equal(words("\\begin{figure} one two \\begin{center} three four \\end{center} \\caption{five six} \\end{figure}"),
                    2, "center in a figure")
        Check.equal(words("\\begin{figure} one two\\footnote{foot note} \\caption[short opt]{five six} \\end{figure}"), 2,
                    "footnotes in a figure follow the figure")
        Check.equal(words("\\begin{table} \\begin{tabular}{ll} a & b \\end{tabular} \\caption{five six} \\end{table}"), 2, "table float")
        Check.equal(words("\\begin{table}[h] \\caption{Five} \\begin{tabularx}{\\textwidth}{lX} a & b \\end{tabularx} \\end{table}"), 1,
                    "caption above a tabularx")
        Check.equal(words("\\begin{wrapfigure}{r}{5cm} a b c \\caption{d e} \\end{wrapfigure} f"), 3, "wrapfigure")
        Check.equal(words("\\begin{sidewaystable} a b \\caption{c d e} \\end{sidewaystable}"), 3, "sidewaystable")
        Check.equal(words("\\begin{figure} \\begin{subfigure}{.5\\textwidth} a b \\caption{c d} \\end{subfigure} \\caption{e} \\end{figure}"),
                    3, "subfigure environments inside a figure")
        Check.equal(words("\\begin{figure} \\subfloat[sub cap]{\\includegraphics{x}} \\subfloat[list][other cap]{x y} \\end{figure}"),
                    4, "subfloat: the last option is the caption")
        Check.equal(words("\\begin{figure} \\subfigure[one two]{\\includegraphics{x}} \\caption{three} \\end{figure}"), 3, "subfigure command")
        Check.equal(words("\\begin{figure} \\includegraphics{x} \\captionof{table}{c d e} \\end{figure}"), 3, "captionof inside a float")
        Check.equal(words("before \\captionof{figure}{c d e} after"), 5, "captionof outside a float: the type is not text")
        Check.equal(words("\\captionof*{figure}[short]{Only this} z"), 3, "captionof with star and short title")
        Check.equal(words("\\caption*{Starred caption}"), 2, "caption*")
        Check.equal(words("\\begin{figure} \\begin{subfigure}{.3\\textwidth} x \\subcaption{Sub text} \\end{subfigure} \\end{figure}"), 2, "subcaption")
        Check.equal(words("\\begin{figure} \\caption{A \\emph{bold} claim\\footnote{with a note}} \\end{figure}"), 6, "markup and footnotes inside a caption")
        Check.equal(words("\\begin{figure} \\caption{Caption with $x^2$ inside} \\end{figure}"), 3, "formulas in a caption are formulas")
        stats = body("\\begin{figure} $a$ \\[ b \\] \\caption{With $x$} \\end{figure}")
        Check.equal(stats.totals.inlineMath, 1, "only the caption's formula")
        Check.equal(stats.totals.displayMath, 0)
        Check.equal(words("\\begin{figure} unclosed words \\caption{kept}"), 3, "a figure still being typed counts as text")
        Check.equal(words("\\begin{figure} \\caption{one} \\end{figure} \\begin{figure} \\caption{two three} \\end{figure} after"), 4, "two floats in a row")
        Check.equal(words("\\begin{figure}\\begin{figure} \\caption{inner} \\end{figure} \\caption{outer} \\end{figure} x"), 3, "nested floats")
        Check.equal(words("% \\begin{figure}\ntext\n% \\end{figure}\nmore"), 2, "commented float markers do nothing")
        Check.equal(words("\\begin{figure}\n\n\\caption{Across paragraphs}\n\n\\end{figure}"), 2, "blank lines inside a float")
        Check.equal(words("\\begin{tikzpicture} \\node {x}; \\end{tikzpicture} \\begin{figure} \\begin{tikzpicture} \\node {z}; \\end{tikzpicture} \\caption{Plot} \\end{figure}"),
                    1, "picture in a figure")

        // Captions sit in the section that is open, headings inside a float do not take text.
        stats = compute(["main.tex": document("\\section{One}\nText.\n\\begin{figure}\\caption{Cap}\\end{figure}\n\\section{Two}\nMore text.\n")])
        Check.equal(stats.sections.map(\.own.textWords), [2, 2], "the caption belongs to its section")

        // Includes inside a float are still walked in order: their text is figure material, but a caption in them counts.
        stats = compute([
            "main.tex": document("\\section{A}\n\\begin{figure}\\input{fig}\\end{figure}\n\\section{B}\nWord.\n"),
            "fig.tex": "\\includegraphics{x} stray \\caption{from the file}\n",
        ])
        Check.equal(stats.sections.map(\.own.textWords), [3, 1], "a caption in an included figure file")
        Check.equal(stats.files.count, 2)
    }

    await Check.suite("Statistics: comments, verbatim, escapes") {
        Check.equal(words("Hello % hidden words\nworld"), 2, "comments")
        Check.equal(words("% only a comment\n"), 0, "comment line")
        Check.equal(words("50\\% of cases"), 3, "escaped percent")
        Check.equal(words("\\begin{verbatim}\nlots of words\n\\end{verbatim}\nafter"), 1, "verbatim")
        Check.equal(words("\\verb|code here| done"), 1, "\\verb")
        Check.equal(words("\\begin{lstlisting}[language=C]\nint main() {}\n\\end{lstlisting}"), 0, "lstlisting")
        Check.equal(words("\\begin{comment}\nnot counted\n\\end{comment} yes"), 1, "comment environment")
        Check.equal(words("a \\& b \\_ c \\# d"), 4, "escaped specials separate")
        Check.equal(words("cost \\$5 here"), 3, "escaped dollar")
    }

    await Check.suite("Statistics: formulas") {
        var stats = body("The value $x^2 + y^2$ is positive")
        Check.equal(stats.totals.textWords, 4, "inline math is not text")
        Check.equal(stats.totals.inlineMath, 1)
        Check.equal(stats.totals.displayMath, 0)

        stats = body("Let $f\\colon X \\to Y$ be a map, $g$ too.")
        Check.equal(stats.totals.inlineMath, 2)
        Check.equal(stats.totals.textWords, 5)

        stats = body("before $$a+b$$ after \\[ c \\] and \\(d\\)")
        Check.equal(stats.totals.displayMath, 2, "$$ and \\[")
        Check.equal(stats.totals.inlineMath, 1, "\\(")
        Check.equal(stats.totals.textWords, 3, "before, after, and")

        stats = body("Text\n\\begin{equation}\\label{eq:1} E=mc^2 \\end{equation}\nmore")
        Check.equal(stats.totals.displayMath, 1, "equation")
        Check.equal(stats.totals.textWords, 2)

        stats = body("\\begin{align*} a &= b \\\\ c &= d \\end{align*} \\begin{gather} x \\end{gather}")
        Check.equal(stats.totals.displayMath, 2, "one per environment")
        Check.equal(stats.totals.words, 0)

        stats = body("\\begin{math} x \\end{math} \\begin{displaymath} y \\end{displaymath}")
        Check.equal(stats.totals.inlineMath, 1, "math environment is inline")
        Check.equal(stats.totals.displayMath, 1, "displaymath")

        stats = body("$x \\text{ if } y$")
        Check.equal(stats.totals.words, 0, "\\text inside a formula is not counted")
        Check.equal(stats.totals.inlineMath, 1)

        stats = body("$x \\text{if $y$} z$ after")
        Check.equal(stats.totals.inlineMath, 1, "a nested $ inside a text group")
        Check.equal(stats.totals.textWords, 1)

        stats = body("price $5 and more")
        Check.equal(stats.totals.inlineMath, 0, "an unclosed $ is not a formula")
        Check.equal(stats.totals.textWords, 4)

        stats = body("a $b\n\nc $d$ e")
        Check.equal(stats.totals.inlineMath, 1, "a blank line ends an unclosed $")
        Check.equal(stats.totals.textWords, 4)

        stats = body("\\begin{equation}\nfoo bar\n\nnext")
        Check.equal(stats.totals.displayMath, 0, "an environment still being typed")
        Check.equal(stats.totals.textWords, 3)

        stats = body("\\section{Area of $\\pi r^2$}")
        Check.equal(stats.totals.headingWords, 2)
        Check.equal(stats.totals.inlineMath, 1, "formula in a heading")

        stats = body("\\label{eq:$x$} ok")
        Check.equal(stats.totals.inlineMath, 0, "formulas in ignored arguments")
    }

    await Check.suite("Statistics: preamble and end of document") {
        let full = compute(["main.tex": """
        \\documentclass{article}
        \\usepackage{amsmath}
        \\title{My Title}
        \\author{A B}
        \\begin{document}
        Body words.
        \\end{document}
        These words come after.
        """])
        Check.equal(full.totals.words, 2, "preamble and trailing text are excluded")

        let noBegin = compute(["main.tex": "\\documentclass{article}\nJust some words\n"])
        Check.equal(noBegin.totals.words, 3, "without \\begin{document} everything counts")

        let fragment = compute(["main.tex": "Just text\n"])
        Check.equal(fragment.totals.words, 2, "a file without \\documentclass")

        let split = compute([
            "main.tex": """
            \\documentclass{article}
            \\input{pre}
            \\begin{document}
            \\begin{thm}[Named result] a b \\end{thm}
            \\begin{foo}[option] c \\end{foo}
            \\end{document}
            """,
            "pre.tex": "\\newtheorem{thm}{Theorem}\n\\title{Ignored here}\n",
        ])
        Check.equal(split.totals.words, 5, "preamble file excluded; \\newtheorem makes [Title] text, other options are dropped")
        Check.equal(split.files.map(\.path), ["/proj/main.tex", "/proj/pre.tex"])

        let declared = compute(["main.tex": """
        \\documentclass{article}
        \\usepackage{thmtools}
        \\declaretheorem[style=plain]{lemma, corollary}
        \\begin{document}
        \\begin{corollary}[Big one] x \\end{corollary}
        \\begin{proof}[Proof of x] y \\end{proof}
        \\end{document}
        """])
        Check.equal(declared.totals.words, 7, "\\declaretheorem and amsthm's proof")
    }

    await Check.suite("Statistics: sections and front matter") {
        var stats = body("\\maketitle\n\\begin{abstract}This is it.\\end{abstract}\n\\section{A}\ntext")
        Check.equal(stats.frontMatter.own.textWords, 3, "front matter")
        Check.equal(stats.frontMatter.isFrontMatter, true)
        Check.equal(titles(stats), ["A"])
        Check.equal(stats.sections[0].own, StatisticsCounts(textWords: 1, headingWords: 1))
        Check.equal(stats.totals.words, 5)

        stats = body("\\section*{Unnumbered Title}x\n\\section[Short]{Long Title Here}y z")
        Check.equal(titles(stats), ["Unnumbered Title", "Long Title Here"])
        Check.equal(stats.sections[0].isStarred, true)
        Check.equal(stats.sections[0].own.headingWords, 2)
        Check.equal(stats.sections[1].own.headingWords, 3, "the short title is ignored")
        Check.equal(stats.sections[1].own.textWords, 2)

        stats = body("\\section{The \\emph{great} idea}\\label{sec:i}")
        Check.equal(stats.sections[0].own.headingWords, 3)
        Check.equal(stats.sections[0].own.textWords, 0)

        stats = body("\\chapter{C1} a b \\section{S1} c \\subsection{SS1} d e \\section{S2} f \\chapter{C2} g")
        Check.equal(titles(stats), ["C1", "S1", "SS1", "S2", "C2"])
        Check.equal(stats.sections.map(\.own.words), [3, 2, 3, 2, 2])
        Check.equal(stats.sections.map(\.subtree.words), [10, 5, 3, 2, 2], "a section's subtree runs to the next heading of the same or a shallower level")
        Check.equal(stats.totals.words, 12)
        Check.equal(stats.sections.map(\.level), [1, 2, 3, 2, 1])

        stats = body("\\subsection{Skips} a \\section{Then} b")
        Check.equal(stats.sections.map(\.subtree.words), [2, 2], "a shallower heading closes the deeper one")

        stats = body("")
        Check.equal(stats.totals, StatisticsCounts.zero, "empty document")
        Check.equal(stats.sections.count, 0)
        Check.equal(compute(["main.tex": ""]).totals, StatisticsCounts.zero, "empty file")

        let ids = stats.allSections.map(\.id)
        Check.equal(ids, [SectionStatistics.frontMatterID])
        Check.equal(stats.section(withID: SectionStatistics.frontMatterID)?.isFrontMatter, true)
        Check.equal(stats.section(withID: "nope"), nil)
    }

    await Check.suite("Statistics: multi-file reading order") {
        let project: [String: String] = [
            "main.tex": """
            \\documentclass{article}
            \\begin{document}
            \\section{One}
            alpha beta
            \\input{b}
            gamma
            \\section{Two}
            delta
            \\end{document}
            """,
            "b.tex": "\\subsection{Sub}\nepsilon zeta eta\n",
        ]
        let stats = compute(project)
        Check.equal(titles(stats), ["One", "Sub", "Two"], "the included heading sits where \\input is")
        Check.equal(stats.sections.map(\.own.words), [3, 5, 2], "text after the \\input stays in the section the file ended in")
        Check.equal(stats.sections.map(\.subtree.words), [8, 5, 2])
        Check.equal(stats.totals.words, 10)
        Check.equal(stats.sections[1].fileURL.path, "/proj/b.tex")
        Check.equal(stats.sections[0].fileURL.path, "/proj/main.tex")
        Check.equal(stats.files.map(\.path), ["/proj/main.tex", "/proj/b.tex"])
        let sum = stats.sections.reduce(stats.frontMatter.own) { $0 + $1.own }
        Check.equal(sum, stats.totals, "per-section counts add up to the totals")

        // A section that continues in another file, a primitive \input, \include, \import, \subfile.
        let mixed = compute([
            "main.tex": """
            \\documentclass{article}
            \\begin{document}
            \\section{A}
            one \\input chapters/x
            two \\include{chapters/y} three
            \\import{chapters/}{z}
            \\subfile{chapters/w}
            end
            \\end{document}
            """,
            "chapters/x.tex": "x1 x2\n",
            "chapters/y.tex": "y1\n\\subsection{Why}\ny2\n",
            "chapters/z.tex": "z1\n",
            "chapters/w.tex": """
            \\documentclass[../main.tex]{subfiles}
            \\begin{document}
            w1 w2
            \\end{document}
            trailing words
            """,
        ])
        Check.equal(titles(mixed), ["A", "Why"])
        Check.equal(mixed.totals.textWords, 11, "one x1 x2 two y1 | y2 three z1 w1 w2 end; the subfile's trailing words are outside its document")
        Check.equal(mixed.sections[0].own.textWords, 5, "A: one x1 x2 two y1 (up to the subsection)")
        Check.equal(mixed.sections[1].own.textWords, 6, "Why: y2 three z1 w1 w2 end")
        Check.equal(mixed.files.count, 5, "all files walked")

        // Each file is counted once, cycles are safe.
        let cyclic = compute([
            "main.tex": document("\\input{a} \\input{a} main"),
            "a.tex": "one \\input{main} \\input{b}",
            "b.tex": "two \\input{a}",
        ])
        Check.equal(cyclic.totals.words, 3, "a, b and main once each (one two main)")
        Check.equal(cyclic.files.count, 3)

        // Missing and non-.tex files are not followed.
        let missing = compute(["main.tex": document("\\input{nothing} \\input{data.csv} \\input{pic.pgf} word"),
                               "data.csv": "a b c", "pic.pgf": "p q r"])
        Check.equal(missing.totals.words, 1)
    }

    await Check.suite("Statistics: headings the walk skips, subfiles, parity with the outline") {
        // An \input and a heading inside a definition: part of the outline, but not typeset.
        let hidden = compute([
            "main.tex": """
            \\documentclass{article}
            \\newcommand{\\x}{\\input{hidden}}
            \\newcommand{\\mysec}{\\section{Phantom}}
            \\begin{document}
            \\section{Real}
            real words
            \\end{document}
            """,
            "hidden.tex": "\\section{Hidden}\nsecret words here\n",
        ])
        Check.equal(titles(hidden), ["Hidden", "Phantom", "Real"], "same sections, same order as the outline")
        Check.equal(hidden.sections.map(\.own.words), [0, 0, 3], "skipped headings take no text, and do not steal the text after them")
        Check.equal(hidden.totals.words, 3)

        // Outline parity on a project with nesting, cycles and several files.
        let files: [String: String] = [
            "main.tex": """
            \\documentclass{book}
            \\begin{document}
            \\chapter{Intro}\\label{c:i}
            \\input{sections/intro}
            \\section{Methods}
            \\input{sections/methods}
            \\include{sections/results}
            \\end{document}
            """,
            "sections/intro.tex": "\\section{Background}\\label{s:b}\nword\n\\input{sections/deep}\n\\section{Goals}\ngoal\n",
            "sections/deep.tex": "\\subsection{Deep}\n\\input{sections/intro}\ndeep\n",
            "sections/methods.tex": "\\subsection{Setup}\nsetup\n\\input{sections/missing}\n",
            "sections/results.tex": "\\chapter{Results}\nres\n\\begin{frame}{Slide title}x\\end{frame}\n",
        ]
        let project = Project(files: files)
        let stats = compute(files)
        let index = ProjectIndex.build(rootFile: fileURL("main.tex"), read: project.read, fileExists: project.exists)
        Check.equal(stats.sections.map(\.id), outlineIDs(index.outline), "section ids equal the outline's node ids")
        Check.equal(stats.files, index.files, "same files in the same order")
        for section in stats.sections {
            Check.expect(stats.section(withID: section.id) != nil, "lookup by id: \(section.title)")
        }
        let sum = stats.sections.reduce(stats.frontMatter.own) { $0 + $1.own }
        Check.equal(sum, stats.totals, "sums equal totals")
        let keys = stats.sections.map(\.stableKey)
        Check.equal(Set(keys).count, keys.count, "stable keys are unique")

        // Same heading twice: stable keys keep them apart.
        let twice = body("\\section{Same} a \\section{Same} b c")
        Check.equal(twice.sections.map(\.stableKey).count, Set(twice.sections.map(\.stableKey)).count)
        Check.equal(twice.sections.map(\.own.textWords), [1, 2])

        // A subfile counts only between its \begin{document} and \end{document}.
        let subfiles = compute([
            "main.tex": """
            \\documentclass{article}
            \\usepackage{subfiles}
            \\begin{document}
            \\subfile{chap}
            after
            \\end{document}
            """,
            "chap.tex": """
            \\documentclass[main.tex]{subfiles}
            \\title{Not counted}
            \\begin{document}
            Chapter words.
            \\end{document}
            """,
        ])
        Check.equal(subfiles.totals.words, 3, "Chapter words + after")

        // Beamer frames are sections.
        let beamer = compute(["main.tex": """
        \\documentclass{beamer}
        \\begin{document}
        \\begin{frame}[t]{First slide}
        Some content here.
        \\end{frame}
        \\begin{frame}
        \\frametitle{Second one}
        More.
        \\end{frame}
        \\end{document}
        """])
        Check.equal(titles(beamer), ["First slide", "Second one"])
        Check.equal(beamer.sections.map(\.kind), [.frame, .frame])
        Check.equal(beamer.sections[0].own, StatisticsCounts(textWords: 3, headingWords: 2))
        Check.equal(beamer.sections[1].own, StatisticsCounts(textWords: 1, headingWords: 2))
        Check.equal(beamer.sections.map(\.level), [3, 3])
    }

    await Check.suite("Statistics: heading lines") {
        let stats = compute(["main.tex": "\\documentclass{article}\n\\begin{document}\n\\section{One line}\n\\section{Two\nlines}\n\\end{document}\n"])
        Check.equal(stats.sections.map(\.line), [3, 4])
        Check.equal(stats.sections.map(\.headingEndLine), [3, 5], "a heading that spans lines reports where it ends")
    }

    await Check.suite("Statistics: random input never breaks the invariants") {
        let pieces = [
            "\\section{", "\\subsection*{", "\\chapter[s]{", "}", "{", "$", "$$", "\\[", "\\]", "\\(", "\\)", "[", "]", "(", ")",
            "\\begin{equation}", "\\end{equation}", "\\begin{itemize}", "\\end{itemize}", "\\item ", "\\item[", "% c\n", "\n", "\n\n", " ", "  ",
            "word", "two words", "ação", "state-of-art", "x", "\\emph{", "\\textbf{x}", "\\verb|x|", "\\verb", "\\begin{verbatim}", "\\end{verbatim}",
            "\\input{b}", "\\include{b}", "\\label{a}", "\\ref{a}", "\\\\", "\\", "\"", "'", "-", "--", "3.14", "1,5", "\\'e", "\\c{c}", "\\ss ", "&",
            "\\newcommand{\\x}{", "\\def\\y#1{", "\\begin{document}", "\\end{document}", "\\documentclass{article}", "\u{1F600}", "e\u{0301}",
            "\\begin{tabular}{lc}", "\\end{tabular}", "\\caption{", "\\footnote{", "\\begin{frame}{T}", "\\end{frame}", "\\frametitle{",
            "\\begin{tikzpicture}", "\\end{tikzpicture}", "\\begin{align}", "\\end{align}", "\\only<2>{", "\\textcolor{red}{", "~", "\r\n",
        ]
        var random = LCG(seed: 20261028)
        func soup() -> String {
            var text = ""
            for _ in 0..<(5 + random.next() % 40) { text += pieces[random.next() % pieces.count] }
            return text
        }
        var checked = 0
        var mismatches = 0
        for round in 0..<1500 {
            let files = ["main.tex": soup(), "b.tex": soup()]
            let project = Project(files: files)
            let stats = compute(files)
            let again = compute(files)
            let index = ProjectIndex.build(rootFile: fileURL("main.tex"), read: project.read, fileExists: project.exists)
            let sum = stats.sections.reduce(stats.frontMatter.own) { $0 + $1.own }
            let valid = stats.totals.textWords >= 0 && stats.totals.headingWords >= 0 && stats.totals.inlineMath >= 0 && stats.totals.displayMath >= 0
                && stats.sections.allSatisfy { $0.own.words >= 0 && $0.subtree.words >= $0.own.words }
            if sum != stats.totals || !valid || stats != again || stats.sections.map(\.id) != outlineIDs(index.outline) {
                mismatches += 1
                if mismatches <= 3 {
                    Check.fail("round \(round): sums \(sum == stats.totals), valid \(valid), stable \(stats == again), "
                        + "outline parity \(stats.sections.map(\.id) == outlineIDs(index.outline)) for \(files["main.tex"] ?? "")")
                }
            }
            // Counting CRLF text gives the same counts as LF text.
            let crlf = compute(files.mapValues { $0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") })
            let lf = compute(files.mapValues { $0.replacingOccurrences(of: "\r\n", with: "\n") })
            if crlf.totals != lf.totals || crlf.sections.map(\.own) != lf.sections.map(\.own) {
                mismatches += 1
                if mismatches <= 3 { Check.fail("round \(round): CRLF and LF differ for \(files["main.tex"] ?? "")") }
            }
            // A selection of random text is fine too.
            _ = DocumentStatistics.counts(in: files["b.tex"] ?? "")
            checked += 1
        }
        Check.equal(mismatches, 0, "\(checked) random projects")
    }

    await Check.suite("Statistics: selections") {
        var counts = DocumentStatistics.counts(in: "some \\emph{words} here $x$")
        Check.equal(counts.textWords, 3)
        Check.equal(counts.inlineMath, 1)
        counts = DocumentStatistics.counts(in: "\\section{A B} text")
        Check.equal(counts.headingWords, 2)
        Check.equal(counts.words, 3)
        Check.equal(DocumentStatistics.counts(in: "").words, 0)
        Check.equal(DocumentStatistics.counts(in: "words}").words, 1, "a selection can start inside a group")
        Check.equal(DocumentStatistics.counts(in: "\\documentclass{article} the preamble is not special here").words, 6)
        Check.equal(DocumentStatistics.counts(in: "% comment only").words, 0)
        Check.equal(DocumentStatistics.counts(in: "ação, coração").words, 2)
        Check.equal(DocumentStatistics.counts(in: "a \\input{x} b").words, 2, "no includes in a selection")
    }

    await Check.suite("PageAttribution") {
        // front matter (p1), A (p1 mid), B (p3 top), C (p5 mid), unknown, D (p8 mid); 10 pages.
        let placements: [HeadingPlacement?] = [
            HeadingPlacement(page: 1, isAtPageTop: true), HeadingPlacement(page: 1), HeadingPlacement(page: 3, isAtPageTop: true),
            HeadingPlacement(page: 5), nil, HeadingPlacement(page: 8),
        ]
        let spans = PageAttribution.spans(placements: placements, totalPages: 10)
        Check.equal(spans.count, 6)
        Check.equal(spans[0], PageSpan(first: 1, last: 1, isApproximate: true), "shares its page with the next heading")
        Check.equal(spans[1], PageSpan(first: 1, last: 2), "the next heading starts a page: the section ends before it")
        Check.equal(spans[2], PageSpan(first: 3, last: 5), "the next heading is mid-page: the page is shared")
        Check.equal(spans[3], PageSpan(first: 5, last: 8), "an unknown heading in between is skipped")
        Check.equal(spans[4], nil, "no page, no span")
        Check.equal(spans[5], PageSpan(first: 8, last: 10), "the last section runs to the last page")
        Check.equal(spans[1]?.pageCount, 2)

        // Pages going backwards or past the end are ignored.
        let odd = PageAttribution.spans(placements: [HeadingPlacement(page: 2), HeadingPlacement(page: 1), HeadingPlacement(page: 3), HeadingPlacement(page: 9)],
                                        totalPages: 5)
        Check.equal(odd[0], PageSpan(first: 2, last: 3))
        Check.equal(odd[1], nil, "a page before the previous one")
        Check.equal(odd[2], PageSpan(first: 3, last: 5))
        Check.equal(odd[3], nil, "a page beyond the PDF")

        Check.equal(PageAttribution.spans(placements: placements, totalPages: 0).compactMap { $0 }.count, 0, "no PDF")
        Check.equal(PageAttribution.spans(placements: [], totalPages: 4).count, 0)
        Check.equal(PageAttribution.spans(placements: [HeadingPlacement(page: 1, isAtPageTop: true)], totalPages: 1),
                    [PageSpan(first: 1, last: 1)], "a single section")
        // The next heading at the top of the same page cannot make the span empty.
        Check.equal(PageAttribution.spans(placements: [HeadingPlacement(page: 4), HeadingPlacement(page: 4, isAtPageTop: true)], totalPages: 6)[0],
                    PageSpan(first: 4, last: 4, isApproximate: true))

        // A section's span reaches the last page of its sub-sections.
        let nested = PageAttribution.subtreeSpans(
            levels: [-1, 1, 2, 3, 2, 1],
            spans: [PageSpan(first: 1, last: 1, isApproximate: true), PageSpan(first: 1, last: 2), PageSpan(first: 2, last: 2),
                    PageSpan(first: 2, last: 4), PageSpan(first: 4, last: 5), PageSpan(first: 5, last: 7)]
        )
        Check.equal(nested, [PageSpan(first: 1, last: 1, isApproximate: true), PageSpan(first: 1, last: 5), PageSpan(first: 2, last: 4),
                             PageSpan(first: 2, last: 4), PageSpan(first: 4, last: 5), PageSpan(first: 5, last: 7)],
                    "chapter 1 reaches page 5, section 1 reaches page 4, the front matter stays")
        Check.equal(PageAttribution.subtreeSpans(levels: [1, 2, 2], spans: [nil, PageSpan(first: 1, last: 2), nil]),
                    [nil, PageSpan(first: 1, last: 2), nil], "no span, no change")
        Check.equal(PageAttribution.subtreeSpans(levels: [1, 2], spans: [PageSpan(first: 3, last: 3, isApproximate: true), PageSpan(first: 3, last: 4)]),
                    [PageSpan(first: 3, last: 4), PageSpan(first: 3, last: 4)], "a section that grows is no longer approximate")
        Check.equal(PageAttribution.subtreeSpans(levels: [1], spans: [PageSpan(first: 1, last: 2), PageSpan(first: 2, last: 3)]),
                    [PageSpan(first: 1, last: 2), PageSpan(first: 2, last: 3)], "fewer levels than spans")
        Check.equal(PageAttribution.subtreeSpans(levels: [], spans: []).count, 0)

        Check.equal(PageAttribution.isAtPageTop(maxY: 720, mediaMinY: 0, mediaHeight: 792), true)
        Check.equal(PageAttribution.isAtPageTop(maxY: 400, mediaMinY: 0, mediaHeight: 792), false)
        Check.equal(PageAttribution.isAtPageTop(maxY: 740, mediaMinY: 100, mediaHeight: 800), true, "a media box that does not start at 0")
        Check.equal(PageAttribution.isAtPageTop(maxY: 10, mediaMinY: 0, mediaHeight: 0), false, "degenerate media box")
    }

    await Check.suite("Statistics: speed") {
        #if DEBUG
        let limit = 3000.0
        #else
        let limit = 300.0
        #endif
        let block = """
        \\section{Introduction}\\label{sec:intro}
        Let $X$ be a topological space and $f\\colon X\\to Y$ a map; see \\cite[Thm.~2.1]{hatcher2002} and \\eqref{eq:main}.
        % a comment with \\command and $math
        \\begin{equation}\\label{eq:main}
          \\sum_{i=1}^{n} \\frac{\\partial f}{\\partial x_i}\\,dx_i = \\int_M \\omega \\quad \\text{for all } n\\ge 0
        \\end{equation}
        \\begin{itemize}
          \\item \\textbf{Bold} text with \\emph{emphasis}, 50\\% of cases, and \\verb|x % y|.
          \\item Another item \\ref{sec:intro}, see \\url{https://example.org/a%20b#c}.
        \\end{itemize}
        Plain prose without much markup, just words and more words to dilute the density of the commands in ação.

        """
        var text = "\\documentclass{article}\n\\begin{document}\n"
        while (text as NSString).length < 400_000 { text += block }
        text += "\\end{document}\n"
        let source = text
        let clock = ContinuousClock()
        let start = clock.now
        let stats = compute(["main.tex": source])
        let parts = (clock.now - start).components
        let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        print("  Statistics: \((source as NSString).length / 1000) KB, \(stats.sections.count) sections, \(stats.totals.words) words in \(String(format: "%.0f", milliseconds)) ms")
        Check.expect(milliseconds < limit, "counting 400 KB took \(milliseconds) ms (limit \(limit))")
        Check.expect(stats.totals.words > 10_000)

        let selectionStart = clock.now
        let selected = DocumentStatistics.counts(in: String(source.prefix(200_000)))
        let selectionParts = (clock.now - selectionStart).components
        let selectionMs = Double(selectionParts.seconds) * 1000 + Double(selectionParts.attoseconds) / 1e15
        Check.expect(selected.words > 1000)
        Check.expect(selectionMs < limit, "counting a 200 KB selection took \(selectionMs) ms")
    }

    // Tuning aid, not a check: GABETEX_STATS_SAMPLES=/path/to/list.txt (absolute .tex paths, one per line) prints
    // the counts of each file to compare with `texcount -inc -brief` (text+headers+captions (…/…/inline/display)).
    if let list = ProcessInfo.processInfo.environment["GABETEX_STATS_SAMPLES"],
       let names = try? String(contentsOfFile: list, encoding: .utf8) {
        await Check.suite("Statistics: sample files (informational)") {
            let manager = FileManager.default
            for path in names.split(separator: "\n").map(String.init) where !path.isEmpty {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                let read: (URL) -> String? = { file in
                    guard let data = manager.contents(atPath: file.path) else { return nil }
                    return String(decoding: data, as: UTF8.self)
                }
                let stats = DocumentStatistics.compute(rootFile: url, read: read, fileExists: { manager.fileExists(atPath: $0.path) })
                let totals = stats.totals
                print("STATS-SAMPLE\t\(path)\t\(totals.textWords)\t\(totals.headingWords)\t\(totals.inlineMath)\t\(totals.displayMath)\t\(stats.sections.count)")
            }
        }
    }
}

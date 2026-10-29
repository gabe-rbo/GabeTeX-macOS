import Foundation
import CheckKit
import TeXCore

@MainActor
func runTokenizerChecks() async {
    await Check.suite("Tokenizer: commands and escaped specials") {
        Check.equal(describeTokens("\\alpha text \\foo{bar}"),
                    ["command:\\alpha", "command:\\foo", "brace:{", "brace:}"])
        Check.equal(describeTokens("\\% \\{ \\} \\$ \\& \\\\ \\_ \\, x"),
                    ["command:\\%", "command:\\{", "command:\\}", "command:\\$", "command:\\&",
                     "command:\\\\", "command:\\_", "command:\\,"])
        Check.equal(describeTokens("50\\% sure % rest {"), ["command:\\%", "comment:% rest {"])
        Check.equal(describeTokens("cost \\$5 and \\$6"), ["command:\\$", "command:\\$"], "escaped dollars never open math")
        Check.equal(describeTokens("\\@ifnextchar and \\makeatletter"), ["command:\\@ifnextchar", "command:\\makeatletter"],
                    "@ is a letter in control words")
        Check.equal(describeTokens("Hello world. Plain prose, with commas; (parens) and [brackets] \"quotes\"."), [],
                    "plain prose yields no tokens")
        Check.equal(describeTokens("a & b ~ c ^ d _ e # f"),
                    Array(repeating: "specialCharacter", count: 5).enumerated().map { "\($0.element):" + ["&", "~", "^", "_", "#"][$0.offset] })
        Check.equal(describeTokens(""), [])
        Check.equal(describeTokens("\\"), ["command:\\"], "lone trailing backslash")
        Check.equal(describeTokens("\\)"), ["command:\\)"], "stray \\) is an ordinary command")
        Check.equal(describeTokens("x \\\ny"), ["command:\\"], "backslash before a line break")
    }

    await Check.suite("Tokenizer: structure commands, braces, brackets") {
        Check.equal(describeTokens("\\section*{A}"), ["structureCommand:\\section*", "brace:{", "brace:}"])
        Check.equal(describeTokens("\\section[short]{Long}"),
                    ["structureCommand:\\section", "bracket:[", "bracket:]", "brace:{", "brace:}"])
        for name in ["part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph"] {
            Check.equal(describeTokens("\\\(name){X}").first, "structureCommand:\\\(name)")
            Check.equal(describeTokens("\\\(name)*{X}").first, "structureCommand:\\\(name)*")
        }
        for name in ["documentclass", "usepackage", "RequirePackage", "input", "include", "subfile", "maketitle",
                     "tableofcontents", "appendix", "frontmatter", "mainmatter", "backmatter", "bibliography", "printbibliography"] {
            Check.equal(describeTokens("\\\(name)").first, "structureCommand:\\\(name)")
        }
        Check.equal(describeTokens("{a} [b] \\foo[c]{d}"),
                    ["brace:{", "brace:}", "command:\\foo", "bracket:[", "bracket:]", "brace:{", "brace:}"],
                    "prose brackets stay plain; brackets after a command are tokens")
        Check.equal(describeTokens("see [1] and [2]"), [])
        Check.equal(describeTokens("\\begin{itemize}\\item a\\end{itemize}"),
                    ["structureCommand:\\begin", "brace:{", "environmentName:itemize", "brace:}", "command:\\item",
                     "structureCommand:\\end", "brace:{", "environmentName:itemize", "brace:}"])
        Check.equal(describeTokens("\\begin{tabular}{cc}"),
                    ["structureCommand:\\begin", "brace:{", "environmentName:tabular", "brace:}", "brace:{", "brace:}"])
        Check.equal(describeTokens("\\begin{theorem}[Main result] x"),
                    ["structureCommand:\\begin", "brace:{", "environmentName:theorem", "brace:}", "bracket:[", "bracket:]"])
        Check.equal(describeTokens("\\begin {itemize}"),
                    ["structureCommand:\\begin", "brace:{", "environmentName:itemize", "brace:}"], "space before the brace")
    }

    await Check.suite("Tokenizer: comments and magic comments") {
        Check.equal(describeTokens("a % c1 $ { \\x\n\\y"), ["comment:% c1 $ { \\x", "command:\\y"])
        let magic = """
        % !TEX root = main.tex
        %!TEX program = xelatex
          % !TeX spellcheck = pt_BR
        % !BIB program = biber
        % just a comment
        text % !TEX root = nope
        """
        Check.equal(describeTokens(magic), [
            "magicComment:% !TEX root = main.tex",
            "magicComment:%!TEX program = xelatex",
            "magicComment:% !TeX spellcheck = pt_BR",
            "magicComment:% !BIB program = biber",
            "comment:% just a comment",
            "comment:% !TEX root = nope",
        ])
        Check.equal(describeTokens("% !TEXT not magic"), ["comment:% !TEXT not magic"])
        Check.equal(describeTokens("% c\r\n\\foo"), ["comment:% c", "command:\\foo"], "comment ends at CR")
        Check.equal(describeTokens("%"), ["comment:%"])
        Check.equal(describeTokens("% $ unbalanced\n$x$"),
                    ["comment:% $ unbalanced", "mathDelimiter:$", "math:x", "mathDelimiter:$"], "comment does not open math")
    }

    await Check.suite("Tokenizer: math modes") {
        Check.equal(describeTokens("$x^2$"),
                    ["mathDelimiter:$", "math:x", "specialCharacter:^", "math:2", "mathDelimiter:$"])
        Check.equal(describeTokens("$$a+b$$"), ["mathDelimiter:$$", "math:a+b", "mathDelimiter:$$"])
        Check.equal(describeTokens("\\(a\\)"), ["mathDelimiter:\\(", "math:a", "mathDelimiter:\\)"])
        Check.equal(describeTokens("\\[ \\alpha + 1 \\]"),
                    ["mathDelimiter:\\[", "mathCommand:\\alpha", "math:+ 1", "mathDelimiter:\\]"])
        Check.equal(describeTokens("$a$ and $b$"),
                    ["mathDelimiter:$", "math:a", "mathDelimiter:$", "mathDelimiter:$", "math:b", "mathDelimiter:$"])
        Check.equal(describeTokens("$\\text{if } x$"),
                    ["mathDelimiter:$", "mathCommand:\\text", "brace:{", "math:if", "brace:}", "math:x", "mathDelimiter:$"])
        Check.equal(describeTokens("$x + y"), ["mathDelimiter:$", "math:x + y"], "unterminated math flushes at EOF")
        Check.equal(describeTokens("\\begin{equation}x\\end{equation}"),
                    ["mathDelimiter:\\begin", "brace:{", "environmentName:equation", "brace:}", "math:x",
                     "mathDelimiter:\\end", "brace:{", "environmentName:equation", "brace:}"])
        Check.equal(describeTokens("\\begin{align*}a&b\\\\c\\end{align*}"),
                    ["mathDelimiter:\\begin", "brace:{", "environmentName:align*", "brace:}", "math:a", "specialCharacter:&",
                     "math:b", "mathCommand:\\\\", "math:c", "mathDelimiter:\\end", "brace:{", "environmentName:align*", "brace:}"])
        for name in ["equation", "equation*", "align", "align*", "alignat", "alignat*", "flalign", "flalign*", "gather",
                     "gather*", "multline", "multline*", "eqnarray", "eqnarray*", "math", "displaymath", "dmath"] {
            let t = describeTokens("\\begin{\(name)}\\alpha\\end{\(name)} \\alpha")
            Check.expect(t.contains("mathCommand:\\alpha"), "\(name): \\alpha inside is a math command")
            Check.expect(t.contains("mathDelimiter:\\begin"), "\(name): \\begin is a math delimiter")
            Check.expect(t.last == "command:\\alpha", "\(name): back to text mode after \\end")
        }
        // Text environments nested inside math keep math mode afterwards.
        let nested = describeTokens("\\begin{equation}\\begin{split}a\\end{split}b\\end{equation} c \\foo")
        Check.expect(nested.contains("math:b"), "math continues after a nested non-math environment: \(nested)")
        Check.equal(nested.last, "command:\\foo")
        // A non-math environment does not turn math on.
        Check.equal(describeTokens("\\begin{itemize}\\alpha\\end{itemize}").filter { $0.hasPrefix("math") }, [])
    }

    await Check.suite("Tokenizer: math nested in a group") {
        Check.equal(describeTokens("$a \\text{if $b$ then} c$"),
                    ["mathDelimiter:$", "math:a", "mathCommand:\\text", "brace:{", "math:if", "mathDelimiter:$", "math:b",
                     "mathDelimiter:$", "math:then", "brace:}", "math:c", "mathDelimiter:$"],
                    "$…$ inside \\text{…} does not close the outer formula")
        Check.equal(describeTokens("$a {b} c$ d"),
                    ["mathDelimiter:$", "math:a", "brace:{", "math:b", "brace:}", "math:c", "mathDelimiter:$"])
        Check.equal(describeTokens("$\\text{$b$}$ \\foo"),
                    ["mathDelimiter:$", "mathCommand:\\text", "brace:{", "mathDelimiter:$", "math:b", "mathDelimiter:$", "brace:}",
                     "mathDelimiter:$", "command:\\foo"])
        Check.equal(describeTokens("{ $x$ } $y$ \\foo").filter { $0.hasPrefix("command") }, ["command:\\foo"],
                    "a group opened before the formula does not confuse it")
        Check.equal(describeTokens("\\[ \\text{$x$} \\] \\foo").last, "command:\\foo")
    }

    await Check.suite("Tokenizer: blank line ends inline math") {
        Check.equal(describeTokens("$x\n\n\\alpha $y$"),
                    ["mathDelimiter:$", "math:x", "command:\\alpha", "mathDelimiter:$", "math:y", "mathDelimiter:$"])
        Check.equal(describeTokens("\\(x\n \t\n\\alpha"),
                    ["mathDelimiter:\\(", "math:x", "command:\\alpha"], "whitespace-only line also ends it")
        Check.equal(describeTokens("$x\r\n\r\n\\alpha"), ["mathDelimiter:$", "math:x", "command:\\alpha"], "CRLF blank line")
        Check.equal(describeTokens("$$a\n\nb$$"), ["mathDelimiter:$$", "math:a\n\nb", "mathDelimiter:$$"],
                    "display math survives blank lines")
        Check.equal(describeTokens("$x\ny$"), ["mathDelimiter:$", "math:x\ny", "mathDelimiter:$"], "single newline does not end it")
    }

    await Check.suite("Tokenizer: verbatim") {
        Check.equal(describeTokens("\\begin{verbatim}\\foo % $ { \\end{verbatim}"),
                    ["structureCommand:\\begin", "brace:{", "environmentName:verbatim", "brace:}", "verbatim:\\foo % $ { ",
                     "structureCommand:\\end", "brace:{", "environmentName:verbatim", "brace:}"])
        Check.equal(describeTokens("\\begin{verbatim*}x\\end{verbatim*}").filter { $0.hasPrefix("verbatim") }, ["verbatim:x"])
        Check.equal(describeTokens("\\begin{lstlisting}[language=C]\nint x;\n\\end{lstlisting}"),
                    ["structureCommand:\\begin", "brace:{", "environmentName:lstlisting", "brace:}", "bracket:[", "bracket:]",
                     "verbatim:\nint x;\n", "structureCommand:\\end", "brace:{", "environmentName:lstlisting", "brace:}"])
        Check.equal(describeTokens("\\begin{minted}{python}\nx = {1}\n\\end{minted}"),
                    ["structureCommand:\\begin", "brace:{", "environmentName:minted", "brace:}", "brace:{", "brace:}",
                     "verbatim:\nx = {1}\n", "structureCommand:\\end", "brace:{", "environmentName:minted", "brace:}"])
        Check.equal(describeTokens("\\begin{Verbatim}\n\\x\n\\end{Verbatim}").filter { $0.hasPrefix("verbatim") }, ["verbatim:\n\\x\n"])
        Check.equal(describeTokens("\\begin{comment}\n\\section{x}\n\\end{comment}\\foo").filter { $0.hasPrefix("verbatim") || $0 == "command:\\foo" },
                    ["verbatim:\n\\section{x}\n", "command:\\foo"], "comment environment")
        Check.equal(describeTokens("\\begin{verbatim}\nabc").last, "verbatim:\nabc", "unterminated verbatim runs to EOF")
        Check.equal(describeTokens("\\verb|a % b|"), ["command:\\verb", "verbatim:|a % b|"])
        Check.equal(describeTokens("\\verb*+x+"), ["command:\\verb*", "verbatim:+x+"])
        Check.equal(describeTokens("\\verb|x| \\foo"), ["command:\\verb", "verbatim:|x|", "command:\\foo"])
        Check.equal(describeTokens("\\verb|abc\nnext"), ["command:\\verb"], "no closing delimiter on the line")
        Check.equal(describeTokens("\\verb+$+ and $x$"),
                    ["command:\\verb", "verbatim:+$+", "mathDelimiter:$", "math:x", "mathDelimiter:$"], "$ inside \\verb is inert")
        Check.equal(describeTokens("\\url{http://a.b/c%d#e}"),
                    ["command:\\url", "brace:{", "verbatim:http://a.b/c%d#e", "brace:}"])
        Check.equal(describeTokens("\\href{http://x.org/a%20b}{text \\alpha}"),
                    ["command:\\href", "brace:{", "verbatim:http://x.org/a%20b", "brace:}", "brace:{", "command:\\alpha", "brace:}"])
    }

    await Check.suite("Tokenizer: reference arguments") {
        Check.equal(describeTokens("\\label{eq:1}"), ["command:\\label", "brace:{", "referenceArgument:eq:1", "brace:}"])
        Check.equal(describeTokens("\\cite[p. 3]{knuth}"),
                    ["command:\\cite", "bracket:[", "bracket:]", "brace:{", "referenceArgument:knuth", "brace:}"])
        Check.equal(describeTokens("\\input{sections/intro}"),
                    ["structureCommand:\\input", "brace:{", "referenceArgument:sections/intro", "brace:}"])
        Check.equal(describeTokens("\\usepackage[utf8]{inputenc}"),
                    ["structureCommand:\\usepackage", "bracket:[", "bracket:]", "brace:{", "referenceArgument:inputenc", "brace:}"])
        Check.equal(describeTokens("\\includegraphics[width=3cm]{fig.png}"),
                    ["command:\\includegraphics", "bracket:[", "bracket:]", "brace:{", "referenceArgument:fig.png", "brace:}"])
        Check.equal(describeTokens("\\cref{a,b}").dropFirst(2).first, "referenceArgument:a,b")
        Check.equal(describeTokens("\\ref{}"), ["command:\\ref", "brace:{", "brace:}"], "empty argument has no token")
        Check.equal(describeTokens("\\label{abc"), ["command:\\label", "brace:{"], "unclosed argument degrades gracefully")
        for name in ["label", "ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "cite", "citep", "citet", "citeauthor",
                     "parencite", "textcite", "autocite", "footcite", "nocite", "Cite", "supercite", "input", "include", "subfile",
                     "includegraphics", "includepdf", "usepackage", "documentclass", "bibliography", "addbibresource",
                     "bibliographystyle", "lstinputlisting"] {
            Check.expect(describeTokens("\\\(name){key}").contains("referenceArgument:key"), "\\\(name) takes a reference argument")
        }
        for name in ["textbf", "emph", "citestyle", "texttt", "hspace"] {
            Check.expect(!describeTokens("\\\(name){key}").contains("referenceArgument:key"), "\\\(name) does not")
        }
        Check.equal(describeTokens("\\label{a}\\ref{b}", only: [.referenceArgument]), ["referenceArgument:a", "referenceArgument:b"])
    }

    await Check.suite("Tokenizer: UTF-16 ranges") {
        let text = "ação \\alpha é $é$ 😀 \\beta \\😀 {é}"
        Check.equal(describeTokens(text),
                    ["command:\\alpha", "mathDelimiter:$", "math:é", "mathDelimiter:$", "command:\\beta", "command:\\😀",
                     "brace:{", "brace:}"])
        let tokens = LaTeXTokenizer().tokenize(text)
        Check.equal(tokens.first?.range, NSRange(location: 5, length: 6), "location after 'ação ' is 5")
        Check.equal(tokens.first(where: { $0.kind == .command && $0.range.length == 3 })?.range.length, 3, "\\ + emoji = 3 units")
        Check.equal(LaTeXTokenizer().tokenize("😀\\x").first?.range, NSRange(location: 2, length: 2), "emoji counts as two units")
        Check.equal(LaTeXTokenizer().tokenize("e\u{301}\\x").first?.range, NSRange(location: 2, length: 2), "combining accent counts")
        Check.equal(LaTeXTokenizer().tokenize("é%x").first?.range, NSRange(location: 1, length: 2))
        Check.equal(LaTeXTokenizer().tokenize(text as NSString), LaTeXTokenizer().tokenize(text), "NSString and String overloads agree")
        Check.equal(describeTokens("é\\foo ação % ção\n\\bar"), ["command:\\foo", "comment:% ção", "command:\\bar"])
    }

    await Check.suite("Tokenizer: invariants on fuzzed input") {
        let pieces = ["\\", "{", "}", "[", "]", "$", "$$", "%", "&", "~", "^", "_", "#", "a", "b", " ", "\n", "\n\n", "\r\n", "\\begin{equation}",
                      "\\end{equation}", "\\begin{verbatim}", "\\end{verbatim}", "\\verb|", "|", "\\label{", "\\cite[", "\\(", "\\)", "\\[", "\\]",
                      "é", "😀", "\\section{", "\\url{", "\\begin{minted}{c}", "% !TEX root = x", "*", "\\\\", "\\%", "\\$"]
        var rng = LCG(seed: 20260607)
        var violations = 0
        for _ in 0..<400 {
            var text = ""
            for _ in 0..<(1 + rng.next() % 60) { text += pieces[rng.next() % pieces.count] }
            let length = (text as NSString).length
            var previousEnd = 0
            for token in LaTeXTokenizer().tokenize(text) {
                if token.range.location < previousEnd || token.range.length <= 0 || NSMaxRange(token.range) > length {
                    violations += 1
                    if violations <= 3 { Check.fail("bad token \(token) for \(text.debugDescription)") }
                    break
                }
                previousEnd = NSMaxRange(token.range)
            }
        }
        Check.equal(violations, 0, "tokens sorted, non-overlapping, in bounds, non-empty")
    }

    await Check.suite("Tokenizer: performance on ~100 KB") {
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
        \\begin{verbatim}
        \\foo { % $ unbalanced
        \\end{verbatim}
        Plain prose without much markup, just words and more words to dilute the density of the commands in ação.

        """
        var doc = ""
        while (doc as NSString).length < 100_000 { doc += block }
        let ns = doc as NSString
        let tokenizer = LaTeXTokenizer()
        var count = 0
        for _ in 0..<5 { count = tokenizer.tokenize(ns).count }      // warm-up
        var timesNS: [Double] = []
        var timesString: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<30 {
            let start = clock.now
            count = tokenizer.tokenize(ns).count
            timesNS.append(milliseconds(clock.now - start))
        }
        for _ in 0..<10 {
            let start = clock.now
            _ = tokenizer.tokenize(doc).count
            timesString.append(milliseconds(clock.now - start))
        }
        timesNS.sort()
        timesString.sort()
        let median = timesNS[timesNS.count / 2]
        #if DEBUG
        let configuration = "debug"
        let limit = 400.0
        #else
        let configuration = "release"
        let limit = 10.0
        #endif
        print("  TIMING tokenizer (\(configuration)): \(ns.length) UTF-16 units, \(count) tokens — NSString min \(fmt(timesNS[0])) ms, median \(fmt(median)) ms; String median \(fmt(timesString[timesString.count / 2])) ms")
        Check.expect(count > 5_000, "document produced a plausible number of tokens (\(count))")
        Check.expect(median < limit, "100 KB tokenized in \(fmt(median)) ms (limit \(limit) ms, \(configuration))")
    }
}

private func milliseconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

private func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

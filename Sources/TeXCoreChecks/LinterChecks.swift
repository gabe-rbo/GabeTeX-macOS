import Foundation
import CheckKit
import TeXCore

@MainActor
func runLinterChecks() async {
    let url = fileURL("main.tex")
    func lint(_ text: String) -> [Diagnostic] { StructureLinter.diagnostics(in: text, fileURL: url) }
    func describe(_ diagnostics: [Diagnostic]) -> [String] {
        diagnostics.map { "\($0.severity)@\($0.line ?? -1):\($0.column ?? -1)+\($0.length ?? -1)" }
    }

    await Check.suite("StructureLinter: silent on valid documents") {
        let valid = """
        \\documentclass[11pt]{article}
        \\usepackage{amsmath,amssymb}
        \\usepackage{listings}
        \\newcommand{\\bra}[1]{\\left\\langle #1\\right|}
        \\newcommand{\\beginenv}{\\begin{equation}}
        \\newcommand{\\endenv}{\\end{equation}}
        \\newenvironment{myenv}{\\begin{center}}{\\end{center}}
        \\def\\half{\\frac{1}{2}}
        \\DeclareDocumentCommand{\\pair}{m m}{\\left\\{#1,#2\\right\\}}
        % A comment with unbalanced { and \\begin{foo} and $
        \\begin{document}
        \\title{A {nested {braces}} title}
        \\maketitle
        \\section{Sets \\& $\\{x \\mid x > 0\\}$}
        We write \\{a, b\\} for sets, \\$5 for dollars, 50\\% rates, \\verb|{ unbalanced| and \\verb+\\begin{x}+.
        Inline math $a$ and $b$, plus \\(c\\) and \\[ \\left\\{ x \\right\\} \\].
        $$ \\sum_{i=1}^n i = \\frac{n(n+1)}{2} $$
        \\begin{equation}
          \\left\\{ \\begin{matrix} a & b \\\\ c & d \\end{matrix} \\right\\}
          \\text{if } x \\in \\{ 1, 2 \\}
        \\end{equation}
        \\begin{align*}
          f(x) &= \\left\\lbrace x \\right\\rbrace \\\\[2pt]
          g(x) &= \\text{a $y$ inside text}
        \\end{align*}
        \\begin{itemize}
          \\item First \\begin{enumerate} \\item nested \\end{enumerate}
          \\item[$\\bullet$] Second
        \\end{itemize}
        \\begin{verbatim}
        unbalanced { and \\begin{nothing} and $ stuff \\end{itemize}
        \\end{verbatim}
        \\begin{lstlisting}[language=C]
        int main() { return 0;
        \\end{lstlisting}
        \\begin{tabular}{|c|c|}
          \\hline a & b \\\\ \\hline
        \\end{tabular}
        See \\url{http://example.org/a%20b#c} and \\href{http://x.org/%7Ey}{a link}.
        \\iffalse
        \\begin{broken}{
        \\fi
        Text with a footnote\\footnote{An {inner} note.} and a math group $a_{i}^{2}$.

        New paragraph with \\texttt{\\{} and \\texttt{\\}} and a lone \\% sign.
        \\end{document}
        garbage after the end } { \\begin{x}
        """
        Check.equal(lint(valid).map { "\($0.line ?? 0):\($0.column ?? 0) \($0.message)" }, [], "realistic valid document")
        Check.equal(lint("").count, 0)
        Check.equal(lint("plain text only").count, 0)

        // Section files (no \begin{document}) may open and close environments of the including file.
        Check.equal(lint("\\section{S}\n\\begin{itemize}\n\\item a\n").count, 0, "unclosed \\begin in a section file")
        Check.equal(lint("\\item b\n\\end{itemize}\n\\section{S}\n").count, 0, "stray \\end in a section file")
        Check.equal(lint("\\begin{document}\n\\end{document}\n").count, 0)
        Check.equal(lint("a % } stray in a comment\n\\% \\{ \\} \\$ \\\\\n").map(\.message), [])
        Check.equal(lint("\\catcode`\\{=12 } unbalanced on purpose").count, 0, "catcode changes disable brace checks")
        Check.equal(lint("$a$ and $$b$$ and $c$\n\n$d$").count, 0)
        Check.equal(lint("\\[ a \\]\\( b \\)").count, 0)
        Check.equal(lint("\\begin{equation} $ \\end{equation}").count, 0, "$ inside a math environment is inert")
        Check.equal(lint("\\newcommand{\\foo}{\\begin{itemize}}\n\\newcommand{\\bar}{\\end{itemize}}\n").count, 0, "definition bodies are not analysed")
        Check.equal(lint("\\begin{document}\n\\iffalse\n}\n\\fi\n\\end{document}").count, 0)
        Check.equal(lint("\\begin{comment}\n}{\n\\end{comment}\n").count, 0)
        Check.equal(lint("\\section{ação — é 😀}\n$é$\n").count, 0)
        // Hook commands carry code that may hold half an environment.
        let hooks = """
        \\documentclass{article}
        \\AtEndEnvironment{abstract}{\\end{center}}
        \\AtBeginEnvironment{abstract}{\\begin{center}}
        \\BeforeBeginEnvironment{tikzpicture}{\\begin{center}}
        \\AfterEndEnvironment{tikzpicture}{\\end{center}}
        \\AtBeginDocument{\\begin{center}}
        \\AtEndDocument{\\end{center}}
        \\AddToHook{begindocument}[label]{\\begin{center}}
        \\appto\\foo{\\end{center}}
        \\begin{document}
        x
        \\end{document}
        """
        Check.equal(lint(hooks).map(\.message), [], "hook arguments are not analysed")
        // A kitchen sink of valid constructs.
        let sink = """
        \\documentclass{beamer}
        \\begin{document}
        \\begin{frame}[fragile]{Title \\& $\\alpha$}
          \\begin{lstlisting}[caption={A {nested} caption}]
          if (x) { return; \\end{itemize}
          \\end{lstlisting}
          \\only<2->{Text with \\textbf{bold}}
        \\end{frame}
        \\begin{figure}[h]\\centering\\includegraphics[width=.5\\textwidth]{a}\\caption{A {B}}\\label{f}\\end{figure}
        \\begin{thebibliography}{99}\\bibitem{a} X.\\end{thebibliography}
        \\begin{tabular}{@{}l@{}} a \\\\[1ex] b \\end{tabular}
        \\item[\\textbf{a}] \\"{o} \\'{e} \\^{o} {\\"o} \\ldots{} 100\\% \\# \\_ \\& $\\{$ $\\}$ \\verb|\\| \\verb|{|
        \\renewcommand{\\labelenumi}{(\\alph{enumi})}
        \\setlength{\\parindent}{0pt}
        \\mintinline{python}{x = {1}} \\lstinline!{! \\lstinline[language=C]|}|
        \\begin{minted}[linenos]{python}
        d = {"a": [1, 2}
        \\end{minted}
        \\expandafter\\def\\csname foo\\endcsname{\\begin{center}}
        \\end{document}
        """
        Check.equal(lint(sink).map { "\($0.line ?? 0):\($0.column ?? 0) \($0.message)" }, [], "kitchen sink")
        // Every project template must lint clean.
        for template in ProjectTemplates.all {
            for (path, contents) in template.files where path.hasSuffix(".tex") {
                let problems = lint(contents)
                Check.equal(problems.map(\.message), [], "template \(template.id)/\(path)")
            }
        }
    }

    await Check.suite("StructureLinter: braces") {
        let stray = lint("\\documentclass{article}\n\\begin{document}\nHello } world\n\\end{document}\n")
        Check.equal(describe(stray), ["error@3:7+1"])
        Check.equal(stray.first?.source, .structure)
        Check.equal(stray.first?.fileURL, url)
        Check.expect(stray.first?.message.contains("}") == true)

        let missing = lint("\\documentclass{article}\n\\begin{document}\n\\textbf{bold text\nmore\n\\end{document}\n")
        Check.equal(describe(missing), ["error@3:8+1"], "reported at the opening brace")
        Check.equal(missing.first?.source, .structure)

        // Missing brace in a section file (EOF is the end of the file there).
        Check.equal(describe(lint("\\section{Title\nbody\n")), ["error@1:9+1"])
        // Two problems come back sorted by position.
        let two = lint("a } b\n\\textbf{c\n}}\n")
        Check.equal(describe(two), ["error@1:3+1", "error@3:2+1"])
        // Nested missing brace: both opening braces are reported, outermost first.
        Check.equal(describe(lint("{ { }\n")), ["error@1:1+1"])
        Check.equal(describe(lint("{{\n")), ["error@1:1+1", "error@1:2+1"])
        // Columns count UTF-16 units; CRLF does not shift lines.
        Check.equal(describe(lint("é😀 }")), ["error@1:5+1"])
        Check.equal(describe(lint("a\r\nb\r\nc }\r\n")), ["error@3:3+1"])
        Check.equal(describe(lint("a\rb\rc }\r")), ["error@3:3+1"])
        // Escaped / commented / verbatim braces do not count.
        Check.equal(lint("\\{ \\} \\verb|}| % }\n").count, 0)
        Check.equal(describe(lint("\\verb|}| }")), ["error@1:10+1"])
    }

    await Check.suite("StructureLinter: environments") {
        let mismatch = lint("\\begin{document}\n\\begin{itemize}\n\\item a\n\\end{enumerate}\n\\end{document}\n")
        Check.equal(describe(mismatch), ["error@4:1+15"])
        Check.expect(mismatch.first?.message.contains("itemize") == true && mismatch.first?.message.contains("enumerate") == true,
                     "mismatch message names both environments: \(mismatch.first?.message ?? "-")")
        Check.expect(mismatch.first?.message.contains("2") == true, "mismatch message mentions the \\begin line")

        // Mismatch is reported in section files as well.
        Check.equal(describe(lint("\\begin{a}\n x\n\\end{b}\n")), ["error@3:1+7"])
        // A skipped level: \begin{a}\begin{b}\end{a} is one mismatch and recovers.
        Check.equal(describe(lint("\\begin{a}\\begin{b}\n\\end{a}\n")), ["error@2:1+7"])
        // Unclosed environments at the end of a document.
        let unclosed = lint("\\begin{document}\n\\begin{itemize}\n\\item a\n")
        Check.equal(describe(unclosed), ["error@1:1+16", "error@2:1+15"], "document and itemize never closed")
        Check.expect(unclosed.last?.message.contains("itemize") == true)
        // An \end{document} that closes an open itemize is a mismatch on that line.
        Check.equal(describe(lint("\\begin{document}\n\\begin{itemize}\n\\item a\n\\end{document}\n")), ["error@4:1+14"])
        // Stray \end inside a document: exactly one error, document still closes.
        let strayEnd = lint("\\begin{document}\nx\n\\end{itemize}\n\\end{document}\n")
        Check.equal(describe(strayEnd), ["error@3:1+13"])
        Check.expect(strayEnd.first?.message.contains("itemize") == true)
        // Stray \end after everything is closed.
        Check.equal(describe(lint("\\begin{document}\n\\begin{a}\n\\end{a}\n\\end{a}\n\\end{document}\n")), ["error@4:1+7"])
        // Environments inside nested braces and with stars.
        Check.equal(lint("\\begin{document}\\begin{align*}x\\end{align*}\\end{document}").count, 0)
        Check.equal(describe(lint("\\begin{document}\\begin{align*}x\\end{align}\\end{document}")), ["error@1:32+11"])
        // Nothing is analysed after \end{document}.
        Check.equal(lint("\\begin{document}\n\\end{document}\n\\end{x}\n}\n").count, 0)
        // Environment names split across lines are not analysed.
        Check.equal(lint("\\begin{doc\nument}").count, 0)
        // Two independent problems, sorted.
        Check.equal(describe(lint("\\begin{document}\nA } B\n\\begin{x}\n\\end{y}\n\\end{document}\n")), ["error@2:3+1", "error@4:1+7"])
    }

    await Check.suite("StructureLinter: inline math") {
        let one = lint("\\begin{document}\nPrice is $5 and more text\nsecond line of the paragraph\n\nNew paragraph.\n\\end{document}\n")
        Check.equal(describe(one), ["warning@2:10+1"])
        Check.equal(one.first?.source, .structure)
        Check.equal(describe(lint("text $x + y\n")), ["warning@1:6+1"], "unclosed at end of a section file")
        Check.equal(describe(lint("a $x$ b $y\n\nc $z$\n")), ["warning@1:9+1"])
        Check.equal(lint("$x\ny$\n").count, 0, "math may span lines inside a paragraph")
        Check.equal(lint("$$ x\n\ny $$").count, 0, "display math is not checked")
        Check.equal(lint("\\(x\\)").count, 0)
        Check.equal(lint("\\$5 and \\$6").count, 0)
        Check.equal(describe(lint("a\r\n$x\r\n\r\nb")), ["warning@2:1+1"], "CRLF paragraph break")
        Check.equal(describe(lint("% $\n$x\n\n% c\n")), ["warning@2:1+1"], "$ inside a comment is ignored")
        Check.equal(lint("$x\n% comment\ny$\n").count, 0, "a comment-only line is not a paragraph break")
    }
}

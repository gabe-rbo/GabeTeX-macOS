import Foundation
import CheckKit
import TeXCore

@MainActor
func runScannerChecks() async {
    await Check.suite("Scanner: include kinds") {
        let text = """
        \\documentclass[a4paper]{article}
        \\usepackage{amsmath, tikz}
        \\usepackage[utf8]{inputenc}
        \\input{sections/intro}
        \\include{chapters/one}
        \\subfile{sub/a}
        \\import{dir/}{file}
        \\subimport{sub/}{part}
        \\bibliography{refs,more}
        \\addbibresource{refs.bib}
        \\includegraphics[width=3cm]{figs/plot}
        \\includepdf[pages=-]{doc.pdf}
        \\lstinputlisting[language=C]{code.c}
        \\inputminted{python}{script.py}
        \\input foo.tex
        % \\input{commented}
        \\verb|\\input{verb}| and \\url{http://x.org/\\input{no}}
        """
        let refs = LaTeXScanner.includes(in: text)
        let described = refs.map { "\($0.kind.rawValue)|\($0.argument)|\($0.directory ?? "-")|\($0.line)" }
        Check.equal(described, [
            "documentclass|article|-|1",
            "usepackage|amsmath|-|2",
            "usepackage|tikz|-|2",
            "usepackage|inputenc|-|3",
            "input|sections/intro|-|4",
            "include|chapters/one|-|5",
            "subfile|sub/a|-|6",
            "importFile|file|dir/|7",
            "subimport|part|sub/|8",
            "bibliography|refs|-|9",
            "bibliography|more|-|9",
            "addbibresource|refs.bib|-|10",
            "includegraphics|figs/plot|-|11",
            "includepdf|doc.pdf|-|12",
            "lstinputlisting|code.c|-|13",
            "inputminted|script.py|-|14",
            "input|foo.tex|-|15",
        ])
        // Every range points at its argument in the UTF-16 text.
        for ref in refs {
            Check.equal(substring(text, ref.range), ref.argument, "range of \(ref.kind) \(ref.argument)")
        }
    }

    await Check.suite("Scanner: arguments (lists, nesting, star, optional, spacing)") {
        let list = "\\usepackage{amsmath,amssymb , amsthm}"
        let refs = LaTeXScanner.includes(in: list)
        Check.equal(refs.map(\.argument), ["amsmath", "amssymb", "amsthm"])
        for ref in refs { Check.equal(substring(list, ref.range), ref.argument) }
        Check.equal(LaTeXScanner.includes(in: "\\usepackage{ a ,\n b }").map(\.argument), ["a", "b"])
        Check.equal(LaTeXScanner.includes(in: "\\bibliography{a,,b,}").map(\.argument), ["a", "b"], "empty items dropped")
        Check.equal(LaTeXScanner.includes(in: "\\includegraphics*[scale=.5]{a.png}").map(\.argument), ["a.png"], "star + optional")
        Check.equal(LaTeXScanner.includes(in: "\\includegraphics[width={0.5\\textwidth},angle=90]{b.png}").map(\.argument), ["b.png"],
                    "braces inside the optional argument")
        Check.equal(LaTeXScanner.includes(in: "\\input {spaced}").map(\.argument), ["spaced"], "space before brace")
        Check.equal(LaTeXScanner.includes(in: "\\input\n{nl}").map(\.argument), ["nl"], "newline before brace")
        Check.equal(LaTeXScanner.includes(in: "\\input{a%b\n}").map(\.argument), ["a"], "comment inside an argument is ignored")
        Check.equal(LaTeXScanner.includes(in: "\\input chapter.tex\n\\foo").map(\.argument), ["chapter.tex"], "\\input file form")
        let primitive = LaTeXScanner.includes(in: "x\n\\input chapter.tex\n")
        Check.equal(primitive.first.map { substring("x\n\\input chapter.tex\n", $0.range) }, "chapter.tex")
        Check.equal(LaTeXScanner.includes(in: "\\input{#1}").count, 0, "macro parameters are not files")
        Check.equal(LaTeXScanner.includes(in: "\\input{\\jobname.aux}").count, 0, "macros are not files")
        Check.equal(LaTeXScanner.includes(in: "\\\\input{x}").count, 0, "\\\\ is a line break, `input{x}` is plain text")
        Check.equal(LaTeXScanner.includes(in: "\\\\\\input{x}").map(\.argument), ["x"], "\\\\ followed by \\input")
        Check.equal(LaTeXScanner.includes(in: "\\%\\input{x}").map(\.argument), ["x"], "escaped percent is not a comment")
        Check.equal(LaTeXScanner.includes(in: "\\begin{verbatim}\n\\input{x}\n\\end{verbatim}\n\\input{y}").map(\.argument), ["y"], "verbatim ignored")
        Check.equal(LaTeXScanner.includes(in: "\\begin{lstlisting}[x]\n\\input{x}\n\\end{lstlisting}").count, 0)
        Check.equal(LaTeXScanner.includes(in: "\\iffalse\n\\input{x}\n\\fi\n\\input{y}").map(\.argument), ["y"], "\\iffalse block")
        Check.equal(LaTeXScanner.includes(in: "ação é \\input{ção}").map(\.argument), ["ção"])
        Check.equal(LaTeXScanner.includes(in: "😀\\input{x}").first?.range, NSRange(location: 9, length: 1), "UTF-16 offsets after an emoji")
        Check.equal(LaTeXScanner.includes(in: "a\r\nb\r\n\\input{x}").first?.line, 3, "CRLF line numbers")
        Check.equal(LaTeXScanner.includes(in: "a\rb\r\\input{x}").first?.line, 3, "CR line numbers")
        Check.equal(LaTeXScanner.includes(in: "\\input{a{b}c}").map(\.argument), ["a{b}c"], "nested braces")
        Check.equal(LaTeXScanner.includes(in: "\\input{unclosed").count, 0, "unterminated argument")
    }

    await Check.suite("Scanner: magic comments and root detection") {
        let text = """
        % !TEX root = ../main.tex
        % !TEX TS-program = xelatex
        % !TeX SPELLCHECK = pt_BR
        % !BIB program = biber
        \\section{x}
        """
        let m = LaTeXScanner.magicComments(in: text)
        Check.equal(m.root, "../main.tex")
        Check.equal(m.program, "xelatex")
        Check.equal(m.spellcheck, "pt_BR")
        Check.equal(m.bibProgram, "biber")
        Check.equal(LaTeXScanner.magicComments(in: "%!TEX program = lualatex\n").program, "lualatex")
        Check.equal(LaTeXScanner.magicComments(in: "% !TEX program = xelatex\n% !TEX program = lualatex").program, "xelatex", "first wins")
        Check.equal(LaTeXScanner.magicComments(in: "% !TEX bib = biber").bibProgram, "biber")
        Check.equal(LaTeXScanner.magicComments(in: "% !TEX encoding = UTF-8 Unicode\n% !TEX root = r.tex").root, "r.tex")
        Check.equal(LaTeXScanner.magicComments(in: "% !TeX ROOT = Upper.tex").root, "Upper.tex", "keys are case-insensitive")
        Check.equal(LaTeXScanner.magicComments(in: "% just text\n"), MagicComments())
        Check.equal(LaTeXScanner.magicComments(in: "x % !TEX root = a.tex"), MagicComments(), "must start the line")
        Check.equal(LaTeXScanner.magicComments(in: "% !TEX root =\n"), MagicComments(), "empty value ignored")
        let late = String(repeating: "\n", count: 25) + "% !TEX root = late.tex"
        Check.equal(LaTeXScanner.magicComments(in: late).root, nil, "only the first 20 lines are searched")
        let line20 = String(repeating: "\n", count: 19) + "% !TEX root = l20.tex"
        Check.equal(LaTeXScanner.magicComments(in: line20).root, "l20.tex", "line 20 is still inside")
        let busy = (1..<20).map { "line \($0)" }.joined(separator: "\n") + "\n% !TEX root = l20.tex\nmore\nlines\n"
        Check.equal(LaTeXScanner.magicComments(in: busy).root, "l20.tex", "value stops at the end of line 20")
        Check.equal(LaTeXScanner.magicComments(in: "% !TEX root = a b.tex\r\n% !TEX program = xelatex\r\n").root, "a b.tex", "CRLF and spaces")
        Check.equal(LaTeXScanner.magicComments(in: "% !TEX root = a b.tex\r\n% !TEX program = xelatex\r\n").program, "xelatex")

        Check.expect(LaTeXScanner.isRootDocument("\\documentclass{article}\n"))
        Check.expect(!LaTeXScanner.isRootDocument("% \\documentclass{article}\n"))
        Check.expect(!LaTeXScanner.isRootDocument("\\section{x}"))
        Check.expect(LaTeXScanner.isRootDocument("\\begin{document}\nx\\end{document}"))
        Check.expect(!LaTeXScanner.isRootDocument("\\begin{verbatim}\n\\documentclass{article}\n\\end{verbatim}"))
    }

    await Check.suite("Scanner: outline entries") {
        let url = fileURL("main.tex")
        let text = """
        \\part{Part One}
        \\chapter{Chapter}
        \\section{Intro \\label{sec:intro}}
        \\section*{Unnumbered}
        \\subsection[Short]{The {nested} long   title
          over two lines}
        % \\section{commented}
        \\subsubsection{Deep}
        \\paragraph{Para}
        \\subparagraph{Sub-para}
        \\section{ação — é}
        \\label{lab:top}
        \\section\\relax{Weird}
        """
        let entries = LaTeXScanner.outlineEntries(in: text, fileURL: url)
        let described = entries.map { "\($0.kind.rawValue)|\($0.title)|\($0.isStarred)|\($0.line)" }
        Check.equal(described, [
            "part|Part One|false|1",
            "chapter|Chapter|false|2",
            "section|Intro|false|3",
            "label|sec:intro|false|3",
            "section|Unnumbered|true|4",
            "subsection|The {nested} long title over two lines|false|5",
            "subsubsection|Deep|false|8",
            "paragraph|Para|false|9",
            "subparagraph|Sub-para|false|10",
            "section|ação — é|false|11",
            "label|lab:top|false|12",
        ])
        for entry in entries {
            Check.equal(entry.fileURL, url)
            Check.equal((text as NSString).substring(with: NSRange(location: entry.offset, length: 1)), "\\", "offset of \(entry.title) is the backslash")
        }
        let first = entries.first { $0.kind == .section && $0.title == "Intro" }
        Check.equal(first.map { LineIndex(text).line(ofOffset: $0.offset) }, 3)

        let beamer = """
        \\begin{frame}{First}
        x
        \\end{frame}
        \\begin{frame}[t]{Second}
        \\end{frame}
        \\begin{frame}
          \\frametitle{Third}
          \\label{fr:3}
        \\end{frame}
        \\begin{frame}<1->[fragile]{Fourth}
        \\end{frame}
        \\begin{frame}[plain]
        \\end{frame}
        \\frametitle{Loose}
        """
        let frames = LaTeXScanner.outlineEntries(in: beamer, fileURL: url).map { "\($0.kind.rawValue)|\($0.title)|\($0.line)" }
        Check.equal(frames, ["frame|First|1", "frame|Second|4", "frame|Third|6", "label|fr:3|8", "frame|Fourth|10", "frame|Loose|14"],
                    "untitled frames without \\frametitle are dropped")
    }

    await Check.suite("Scanner: labels and their context") {
        let url = fileURL("main.tex")
        let text = """
        \\section{Alpha}
        \\label{sec:a}
        \\begin{equation}\\label{eq:1} x \\end{equation}
        \\begin{theorem}\\label{thm:1} t \\end{theorem}
        \\begin{figure}\\begin{center}\\label{fig:1}\\end{center}\\end{figure}
        \\begin{align}
          a &= b \\label{eq:2} \\\\
          c &= d
        \\end{align}
        \\subsection{Beta}
        \\label{sub:b}
        \\begin{itemize}\\item\\label{it:1} x\\end{itemize}
        % \\label{commented}
        \\label{ação:1}
        """
        let labels = LaTeXScanner.labels(in: text, fileURL: url)
        Check.equal(labels.map { "\($0.key)|\($0.context ?? "nil")|\($0.line)" }, [
            "sec:a|Alpha|2",
            "eq:1|equation|3",
            "thm:1|theorem|4",
            "fig:1|figure|5",
            "eq:2|align|7",
            "sub:b|Beta|11",
            "it:1|itemize|12",
            "ação:1|Beta|14",
        ])
        Check.equal(LaTeXScanner.labels(in: "\\label{x}", fileURL: url).first?.context, nil, "no context outside headings and environments")
        Check.equal(LaTeXScanner.labels(in: "\\begin{document}\\label{x}\\end{document}", fileURL: url).first?.context, nil, "document is a layout wrapper")
        Check.equal(LaTeXScanner.labels(in: "\\label{a#1}\\label{\\foo}", fileURL: url).count, 0)
    }

    await Check.suite("Scanner: custom commands") {
        let text = """
        \\newcommand{\\foo}[2]{#1#2}
        \\newcommand\\bar{x}
        \\newcommand{\\opt}[2][d]{#1#2}
        \\renewcommand{\\ren}[1]{#1}
        \\providecommand*{\\prov}{}
        \\def\\baz#1#2{#1#2}
        \\DeclareMathOperator*{\\argmin}{arg\\,min}
        \\DeclareMathOperator{\\Hom}{Hom}
        \\NewDocumentCommand{\\xx}{m o m}{#1}
        \\NewDocumentCommand{\\yy}{O{x} m +m}{#1}
        \\DeclareDocumentCommand\\zz{ m }{#1}
        \\DeclarePairedDelimiter{\\abs}{\\lvert}{\\rvert}
        \\newcommand{\\foo}{dup}
        % \\newcommand{\\hidden}{x}
        \\newcommand{\\no@letters2}{x}
        \\begin{verbatim}
        \\newcommand{\\inverb}{x}
        \\end{verbatim}
        """
        let items = LaTeXScanner.customCommands(in: text)
        let described = items.map { "\($0.label)=\($0.insertText)" }
        Check.equal(described, [
            "\\foo=\\foo{${1:arg}}{${2:arg}}",
            "\\bar=\\bar",
            "\\opt=\\opt{${1:arg}}",
            "\\ren=\\ren{${1:arg}}",
            "\\prov=\\prov",
            "\\baz=\\baz{${1:arg}}{${2:arg}}",
            "\\argmin=\\argmin",
            "\\Hom=\\Hom",
            "\\xx=\\xx{${1:arg}}{${2:arg}}",
            "\\yy=\\yy{${1:arg}}{${2:arg}}",
            "\\zz=\\zz{${1:arg}}",
            "\\abs=\\abs{${1:arg}}",
        ], "deduplicated, in source order")
        Check.expect(items.allSatisfy { $0.kind == .command && $0.detail == "Defined in project" })
        for item in items {
            let snippet = Snippet(parsing: item.insertText)
            Check.expect(!snippet.text.contains("${"), "custom snippet \(item.insertText) parses")
        }
    }

    await Check.suite("Scanner: custom environments") {
        let text = """
        \\newenvironment{myenv}{a}{b}
        \\renewenvironment{renv}{a}{b}
        \\newtheorem{thm}{Theorem}[section]
        \\newtheorem*{rem}{Remark}
        \\declaretheorem[style=plain]{lemma}
        \\declaretheorem{prop, cor}
        \\NewDocumentEnvironment{docenv}{m}{a}{b}
        \\newtcolorbox{box}{colback=red}
        \\newtcbtheorem{ex}{Example}{}{ex}
        \\newtheorem{thm}{Duplicate}
        % \\newenvironment{hidden}{}{}
        \\newenvironment{\\bad}{}{}
        """
        Check.equal(LaTeXScanner.customEnvironments(in: text),
                    ["myenv", "renv", "thm", "rem", "lemma", "prop", "cor", "docenv", "box", "ex"])
    }
}

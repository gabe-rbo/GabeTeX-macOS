import Foundation
import CheckKit
import TeXCore

/// Median wall time in milliseconds of `body` over `runs` runs (after two warm-up runs).
private func medianMilliseconds(runs: Int = 9, _ body: () -> Void) -> Double {
    for _ in 0..<2 { body() }
    let clock = ContinuousClock()
    var times: [Double] = []
    for _ in 0..<runs {
        let start = clock.now
        body()
        let c = (clock.now - start).components
        times.append(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
    }
    times.sort()
    return times[times.count / 2]
}

private func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

@MainActor
func runPerformanceChecks() async {
    await Check.suite("Performance (informational timings; bounds are generous)") {
        #if DEBUG
        let scale = 40.0
        let configuration = "debug"
        #else
        let scale = 1.0
        let configuration = "release"
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
        \\begin{verbatim}
        \\foo { % $ unbalanced
        \\end{verbatim}
        \\input{sections/part}
        Plain prose without much markup, just words and more words to dilute the density of the commands in ação.

        """
        var doc = ""
        while (doc as NSString).length < 100_000 { doc += block }
        let ns = doc as NSString
        var report: [String] = []

        @MainActor func measure(_ name: String, limitMs: Double, _ body: () -> Void) {
            let ms = medianMilliseconds(body)
            report.append("\(name) \(fmt(ms)) ms")
            Check.expect(ms < limitMs * scale, "\(name): \(fmt(ms)) ms exceeds \(limitMs * scale) ms (\(configuration))")
        }

        let url = fileURL("main.tex")
        measure("tokenize", limitMs: 10) { _ = LaTeXTokenizer().tokenize(ns) }
        measure("outline", limitMs: 25) { _ = LaTeXScanner.outlineEntries(in: doc, fileURL: url) }
        measure("labels", limitMs: 25) { _ = LaTeXScanner.labels(in: doc, fileURL: url) }
        measure("includes", limitMs: 25) { _ = LaTeXScanner.includes(in: doc) }
        measure("customCommands", limitMs: 25) { _ = LaTeXScanner.customCommands(in: doc) }
        measure("structure lint", limitMs: 40) { _ = StructureLinter.diagnostics(in: doc, fileURL: url) }

        // Completion at the end of a 100 KB document (every keystroke pays for one masked copy + one walk).
        let withCommand = ns.appending("\\fr")
        let withCommandNS = withCommand as NSString
        measure("complete \\fr", limitMs: 25) {
            _ = CompletionEngine.complete(text: withCommandNS, cursor: withCommandNS.length, symbols: .empty)
        }
        let withRef = ns.appending("\\ref{eq")
        let withRefNS = withRef as NSString
        var symbols = ProjectSymbols.empty
        symbols.labels = (0..<2000).map { LabelDefinition(key: "eq:label\($0)", fileURL: url, line: $0 + 1, context: "equation") }
        measure("complete \\ref (2000 labels)", limitMs: 25) {
            _ = CompletionEngine.complete(text: withRefNS, cursor: withRefNS.length, symbols: symbols)
        }
        symbols.bibEntries = (0..<5000).map {
            BibEntry(key: "key\($0)", type: "article", title: "Title number \($0) about topology", author: "Author \($0)", year: "\(1900 + $0 % 120)",
                     fileURL: fileURL("refs.bib"), line: $0 + 1)
        }
        let withCite = ns.appending("\\cite{key12")
        let withCiteNS = withCite as NSString
        measure("complete \\cite (5000 entries)", limitMs: 40) {
            _ = CompletionEngine.complete(text: withCiteNS, cursor: withCiteNS.length, symbols: symbols)
        }

        // BibParser on ~1 MB.
        let bib = (0..<6000).map {
            "@article{key\($0),\n  author = {Author, Name and Other, Person},\n  title = {A {T}itle about topology number \($0)},\n  journal = {Journal},\n  year = {\(1900 + $0 % 120)},\n}\n"
        }.joined(separator: "\n")
        measure("bib parse (\(bib.utf16.count / 1024) KB)", limitMs: 80) { _ = BibParser.entries(in: bib, fileURL: fileURL("refs.bib")) }

        // ProjectIndex over 60 files of ~16 KB each.
        var files: [String: String] = [:]
        var main = "\\documentclass{article}\n\\begin{document}\n"
        for n in 0..<60 {
            main += "\\input{sections/s\(n)}\n"
            files["sections/s\(n).tex"] = String(repeating: block.replacingOccurrences(of: "sections/part", with: "sections/leaf"), count: 18)
        }
        files["sections/leaf.tex"] = "\\subsection{Leaf}\n"
        files["main.tex"] = main + "\\end{document}\n"
        measure("ProjectIndex.build (60 files)", limitMs: 200) {
            _ = ProjectIndex.build(rootFile: fileURL("main.tex"),
                                   read: { files[String($0.path.dropFirst("/proj/".count))] },
                                   fileExists: { files[String($0.path.dropFirst("/proj/".count))] != nil })
        }
        print("  TIMING \(configuration): " + report.joined(separator: "; "))
    }
}

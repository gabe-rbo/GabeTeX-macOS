import Foundation
import CheckKit
import TeXCore
@testable import TeXToolchain

/// TeXLogParser against real logs generated on the Mac by Tests/Fixtures/TeXToolchain/make-logs.sh.
@MainActor
func parserChecks() async {
    await Check.suite("LogParser: multi-file project (\\input, hyperref/tikz parentheses)") {
        let dir = Fixtures.project("multifile")
        let main = dir.appendingPathComponent("main.tex")
        let intro = dir.appendingPathComponent("sections/intro.tex")
        let theory = dir.appendingPathComponent("sections/theory.tex")
        let lemma = dir.appendingPathComponent("sections/sub/lemma.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("multifile.log"), mapPath: Fixtures.mapper(for: "multifile"))

        let undefined = expectDiagnostic(ds, message: "Undefined control sequence \\undefinedmacro", severity: .error,
                                         file: intro, line: 3, column: 19, length: 15)
        Check.expect(undefined?.detail?.contains("l.3 More text with an \\undefinedmacro") == true, "detail has the l.N context")
        expectDiagnostic(ds, message: "Environment lemma undefined.", severity: .error, file: lemma, line: 1, column: 1, length: 13)
        expectDiagnostic(ds, message: "\\begin{document} ended by \\end{lemma}.", severity: .error, file: lemma, line: 3, column: 1, length: 11)
        let missingDollar = ds.filter { $0.message == "Missing $ inserted." }
        Check.equal(missingDollar.map(\.line), [4, 5], "two Missing $ errors in theory.tex")
        Check.expect(missingDollar.allSatisfy { $0.fileURL == theory && $0.severity == .error }, "Missing $ in theory.tex")
        Check.equal(missingDollar.first?.column, 18, "\\alpha column")
        Check.equal(missingDollar.first?.length, 6, "\\alpha length")
        Check.equal(ds.filter { $0.severity == .error }.count, 5, "exactly five errors:\n      \(describe(ds))")

        expectDiagnostic(ds, message: "Unused global option(s): [nonexistentoption].", severity: .warning, file: main, line: nil)
        expectDiagnostic(ds, message: "Label `sec:space' multiply defined.", severity: .warning, file: main, line: nil)
        expectDiagnostic(ds, message: "hyperref: Token not allowed in a PDF string (Unicode): removing `math shift'.",
                         severity: .warning, file: main, line: 11)
        expectDiagnostic(ds, message: "Reference `sec:missing' on page 1 undefined.", severity: .warning, file: main, line: 12)
        expectDiagnostic(ds, message: "Citation `nokey' on page 1 undefined.", severity: .warning, file: main, line: 12)
        expectDiagnostic(ds, message: "Font shape `OT1/cmr/bx/sc' undefined using `OT1/cmr/bx/n' instead.",
                         severity: .warning, file: main, line: 13)
        expectDiagnostic(ds, message: "Some font shapes were not available, defaults substituted.", severity: .info, file: main, line: nil)
        expectDiagnostic(ds, message: "There were undefined references.", severity: .info, file: main, line: nil)
        expectDiagnostic(ds, message: "There were multiply-defined labels.", severity: .info, file: main, line: nil)
        Check.equal(ds.count, 14, "no unexpected diagnostics:\n      \(describe(ds))")
        // Sorted: errors first, then by path and line.
        Check.equal(ds.prefix(5).map { $0.fileURL?.lastPathComponent ?? "-" },
                    ["intro.tex", "lemma.tex", "lemma.tex", "theory.tex", "theory.tex"], "error order")
        Check.expect(ds.allSatisfy { $0.fileURL != nil }, "every diagnostic is attributed to a project file")
    }

    await Check.suite("LogParser: runaway argument / missing }") {
        let main = Fixtures.project("runaway").appendingPathComponent("main.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("runaway.log"), mapPath: Fixtures.mapper(for: "runaway"))
        let d = expectDiagnostic(ds, message: "File ended while scanning use of \\textbf .", severity: .error, file: main, line: nil)
        Check.expect(d?.detail?.contains("Runaway argument: {world \\par Next paragraph.") == true, "runaway text in detail: \(d?.detail ?? "nil")")
        Check.equal(ds.filter { $0.severity == .error }.count, 1, "Emergency stop / fatal error are dropped:\n      \(describe(ds))")
    }

    await Check.suite("LogParser: missing package") {
        let main = Fixtures.project("missingpkg").appendingPathComponent("main.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("missingpkg.log"), mapPath: Fixtures.mapper(for: "missingpkg"))
        expectDiagnostic(ds, message: "File `thispackagedoesnotexist.sty' not found.", severity: .error, file: main, line: nil,
                         missingFile: "thispackagedoesnotexist.sty")
        Check.equal(ds.filter { $0.severity == .error }.count, 1, describe(ds))
        let summary = TeXLogParser.parseLatexmkOutput(Fixtures.log("missingpkg.latexmk"))
        Check.equal(summary.missingFiles, ["thispackagedoesnotexist.sty"])
        Check.expect(summary.diagnostics.isEmpty, "no tool failure in missingpkg.latexmk")
    }

    await Check.suite("LogParser: missing graphics / \\input file") {
        let main = Fixtures.project("missinginput").appendingPathComponent("main.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("missinginput.log"), mapPath: Fixtures.mapper(for: "missinginput"))
        expectDiagnostic(ds, message: "File `figs/plot' not found.", severity: .error, file: main, line: 5,
                         column: 1, length: 27, missingFile: "figs/plot")
        expectDiagnostic(ds, message: "File `chapters/nothere.tex' not found.", severity: .error, file: main, line: nil,
                         missingFile: "chapters/nothere.tex")
        Check.equal(ds.filter { $0.severity == .error }.count, 2, describe(ds))
        Check.equal(TeXLogParser.parseLatexmkOutput(Fixtures.log("missinginput.latexmk")).missingFiles,
                    ["figs/plot", "chapters/nothere.tex"])
    }

    await Check.suite("LogParser: over/underfull boxes") {
        let main = Fixtures.project("badboxes").appendingPathComponent("main.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("badboxes.log"), mapPath: Fixtures.mapper(for: "badboxes"))
        expectDiagnostic(ds, message: "Underfull \\hbox (badness 10000) in paragraph at lines 6--8", severity: .badbox, file: main, line: 6)
        let narrow = expectDiagnostic(ds, message: "Overfull \\hbox (146.60309pt too wide) detected at line 9", severity: .badbox, file: main, line: 9)
        Check.equal(narrow?.detail, "\\OT1/cmr/m/n/10 This box is far too narrow for its contents")
        expectDiagnostic(ds, message: "Overfull \\vbox (109.99832pt too high) has occurred while \\output is active",
                         severity: .badbox, file: main, line: nil)
        expectDiagnostic(ds, message: "Overfull \\hbox (186.91743pt too wide) in paragraph at lines 13--16", severity: .badbox, file: main, line: 13)
        expectDiagnostic(ds, message: "Font shape `OT1/cmr/m/n' in size <5.5> not available size <5> substituted.",
                         severity: .warning, file: main, line: 17)
        expectDiagnostic(ds, message: "Size substitutions with differences up to 0.5pt have occurred.", severity: .info, file: main, line: nil)
        Check.equal(ds.count, 6, describe(ds))
    }

    await Check.suite("LogParser: non-ASCII file names and columns") {
        let chapter = Fixtures.project("unicode").appendingPathComponent("Seções/capítulo 1.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("unicode.log"), mapPath: Fixtures.mapper(for: "unicode"))
        expectDiagnostic(ds, message: "Undefined control sequence \\comandoinexistente", severity: .error, file: chapter, line: 2,
                         column: 33, length: 19)
        Check.equal(ds.count, 1, describe(ds))
    }

    await Check.suite("LogParser: XeLaTeX fontspec error + missing characters") {
        let main = Fixtures.project("xefont").appendingPathComponent("main.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("xefont.log"), mapPath: Fixtures.mapper(for: "xefont"))
        let font = expectDiagnostic(ds, message: "fontspec: The font \"NoSuchFontAnywhere\" cannot be found;", severity: .error,
                                    file: main, line: 5)
        Check.expect(font?.detail?.contains("this may be but usually is not a fontspec bug") == true, "long message continues in detail")
        Check.expect(ds.contains { $0.message.hasPrefix("Missing character(s) in font nullfont:") && $0.severity == .warning },
                     "missing characters are summarized:\n      \(describe(ds))")
    }

    await Check.suite("LogParser: BibTeX (.log + .blg)") {
        let dir = Fixtures.project("bibtex")
        let main = dir.appendingPathComponent("main.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("bibtex.log"), mapPath: Fixtures.mapper(for: "bibtex"))
        expectDiagnostic(ds, message: "Citation `nokey' on page 1 undefined.", severity: .warning, file: main, line: 3)
        expectDiagnostic(ds, message: "Reference `eq:nolabel' on page 1 undefined.", severity: .warning, file: main, line: 4)
        expectDiagnostic(ds, message: "There were undefined references.", severity: .info, file: main, line: nil)
        Check.equal(ds.count, 3, describe(ds))

        let blg = TeXLogParser.parseBibliographyLog(Fixtures.log("bibtex.blg"), source: .bibtex, mapPath: Fixtures.mapper(for: "bibtex"))
        let syntax = expectDiagnostic(blg, message: "I was expecting a `,' or a `}'", severity: .error,
                                      file: dir.appendingPathComponent("refs.bib"), line: 11, source: .bibtex)
        Check.expect(syntax?.detail?.contains("(Error may have been on previous line)") == true, "bibtex context in detail")
        expectDiagnostic(blg, message: "I didn't find a database entry for \"nokey\"", severity: .warning, file: nil, line: nil, source: .bibtex)
        Check.equal(blg.count, 2, describe(blg))
        Check.expect(TeXLogParser.parseLatexmkOutput(Fixtures.log("bibtex.latexmk")).diagnostics.isEmpty,
                     "“Bibtex errors: See file” is not a tool failure (the .blg has the details)")
    }

    await Check.suite("LogParser: biblatex/biber (.log, biber .blg format, broken biber in latexmk output)") {
        let dir = Fixtures.project("biber")
        let main = dir.appendingPathComponent("main.tex")
        let ds = TeXLogParser.parse(log: Fixtures.log("biber.log"), mapPath: Fixtures.mapper(for: "biber"))
        expectDiagnostic(ds, message: "Citation 'hatcher' on page 1 undefined.", severity: .warning, file: main, line: 5)
        expectDiagnostic(ds, message: "Empty bibliography.", severity: .warning, file: main, line: 6)
        expectDiagnostic(ds, message: "biblatex: Please (re)run Biber on the file: main and rerun LaTeX afterwards.",
                         severity: .info, file: main, line: nil)

        // biber's .blg format (biber cannot run on this Mac; see biber-format.blg's origin in the report).
        let blg = TeXLogParser.parseBibliographyLog(Fixtures.log("biber-format.blg"), source: .biber, mapPath: Fixtures.mapper(for: "biber"))
        let refs = dir.appendingPathComponent("refs.bib")
        expectDiagnostic(blg, message: "BibTeX subsystem: syntax error: found \"entry\", expected end of entry (\"}\" or \")\") (skipping to next \"@\")",
                         severity: .error, file: refs, line: 8, source: .biber)
        expectDiagnostic(blg, message: "Datamodel: book entry 'hatcher' (refs.bib): Invalid field 'publisher' for entrytype 'book'",
                         severity: .warning, file: refs, line: nil, source: .biber)
        expectDiagnostic(blg, message: "I didn't find a database entry for 'nokey' (section 0)", severity: .warning, file: nil, line: nil, source: .biber)

        let summary = TeXLogParser.parseLatexmkOutput(Fixtures.log("biber.latexmk"))
        let failure = summary.diagnostics.first
        Check.equal(summary.diagnostics.count, 1, "one biber failure")
        Check.equal(failure?.source, .biber)
        Check.equal(failure?.severity, .error)
        Check.equal(failure?.message, TeXLogParser.biberFailureMessage)
        Check.expect(failure?.detail?.contains("extracting arm64 binary with lipo failed") == true, "biber's own error in detail")
    }

    await Check.suite("LogParser: edge cases") {
        let project = URL(fileURLWithPath: "/p")
        let map: (String) -> URL? = { $0.hasPrefix("./") ? project.appendingPathComponent(String($0.dropFirst(2))) : nil }
        // Unbalanced parentheses inside error context must not corrupt the file stack.
        let log = """
        (./main.tex (./a.tex
        ./a.tex:2: Undefined control sequence.
        l.2 text ( \\foo
                         ) more
        )
        LaTeX Warning: Reference `x' on page 1 undefined on input line 7.

        )
        """
        let ds = TeXLogParser.parse(log: log, mapPath: map)
        expectDiagnostic(ds, message: "Undefined control sequence \\foo", severity: .error, file: project.appendingPathComponent("a.tex"), line: 2)
        expectDiagnostic(ds, message: "Reference `x' on page 1 undefined.", severity: .warning, file: project.appendingPathComponent("main.tex"), line: 7)
        // CRLF logs and \MessageBreak continuations.
        let crlf = "(./main.tex\r\nPackage foo Warning: first part\r\n(foo)                second part on input line 3.\r\n\r\n)\r\n"
        let w = TeXLogParser.parse(log: crlf, mapPath: map)
        expectDiagnostic(w, message: "foo: first part second part.", severity: .warning, file: project.appendingPathComponent("main.tex"), line: 3)
        // Duplicates collapse.
        let dup = TeXLogParser.normalized([Diagnostic(severity: .warning, source: .tex, message: "m", line: 1),
                                           Diagnostic(severity: .warning, source: .tex, message: "m", line: 1)])
        Check.equal(dup.count, 1)
    }

    await Check.suite("LogParser: performance (1 MB log < 200 ms)") {
        let base = Fixtures.log("multifile.log")
        var big = ""
        while big.utf8.count < 1_048_576 { big += base }
        let mapper = Fixtures.mapper(for: "multifile")
        _ = TeXLogParser.parse(log: base, mapPath: mapper)   // warm up
        var result: [Diagnostic] = []
        let seconds = measure { result = TeXLogParser.parse(log: big, mapPath: mapper) }
        print("    1 MB log (\(big.utf8.count) bytes) parsed in \(Int(seconds * 1000)) ms, \(result.count) diagnostics")
        // The budget is for a developer Mac; shared CI virtual machines are slower and noisier.
        let budget = ProcessInfo.processInfo.environment["CI"] == "true" ? 0.6 : 0.2
        Check.expect(seconds < budget, "parse took \(Int(seconds * 1000)) ms (budget \(Int(budget * 1000)) ms)")
        Check.equal(result.count, 14, "duplicates across repeated runs collapse")
    }
}

import Foundation
import PDFKit
import CheckKit
import TeXCore
@testable import TeXToolchain

/// End-to-end regression checks for the review of 2026-10-28, against the real TeX installation.
@MainActor
func regressionChecks(compiler: LaTeXCompiler) async {
    await Check.suite("LaTeXCompiler: overlay below a symlinked folder — real file untouched (#1)") {
        let base = Fixtures.scratch("symlinked-compile")
        let shared = base.appendingPathComponent("shared")
        let project = base.appendingPathComponent("proj")
        let main = project.appendingPathComponent("main.tex")
        Fixtures.write("\\documentclass{article}\n\\begin{document}\n\\input{chapters/one}\n\\end{document}\n", to: main)
        Fixtures.write("Saved text.\n\\typeout{GTX-REAL-ONE}\n", to: shared.appendingPathComponent("chapters/one.tex"))
        Fixtures.write("\\documentclass{article}\n\\begin{document}\n\\input{part}\n\\end{document}\n",
                       to: shared.appendingPathComponent("doc/main.tex"))
        Fixtures.write("Part on disk.\n\\typeout{GTX-REAL-PART}\n", to: shared.appendingPathComponent("doc/part.tex"))
        for (name, target) in [("chapters", "../shared/chapters"), ("linked", "../shared/doc")] {
            Check.expect((try? FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent(name).path,
                                                                     withDestinationPath: target)) != nil, "symlink \(name)")
        }
        _ = chmod(shared.appendingPathComponent("chapters/one.tex").path, 0o640)
        let before = fingerprint(shared)

        let one = project.appendingPathComponent("chapters/one.tex")
        let live = await compiler.compile(CompileRequest(
            projectDirectory: project, rootFile: main, engine: .pdflatex,
            overlays: [one: "Unsaved text.\n\\typeout{GTX-OVERLAY-ONE}\n\\oopsoverlay\n"], purpose: .live))
        Check.equal(live.status, .failed, "the overlay's deliberate error: \(describe(live.diagnostics))")
        Check.expect(live.log.contains("GTX-OVERLAY-ONE") && !live.log.contains("GTX-REAL-ONE"), "the compile used the overlay")
        expectDiagnostic(live.diagnostics, message: "Undefined control sequence \\oopsoverlay", severity: .error, file: one, line: 3)
        Check.equal(fingerprint(shared), before, "the real file is byte-identical (same inode, mode, mtime); nothing added next to it")

        // Root document inside a symlinked folder: compiled in the shadow, never inside the user's folder.
        let linkedMain = project.appendingPathComponent("linked/main.tex")
        let part = project.appendingPathComponent("linked/part.tex")
        let linked = await compiler.compile(CompileRequest(
            projectDirectory: project, rootFile: linkedMain, engine: .pdflatex,
            overlays: [part: "Part unsaved.\n\\typeout{GTX-OVERLAY-PART}\n"], purpose: .live))
        Check.equal(linked.status, .succeeded, "\(describe(linked.diagnostics)) \(linked.toolOutput.suffix(300))")
        Check.expect(linked.log.contains("GTX-OVERLAY-PART") && !linked.log.contains("GTX-REAL-PART"), "overlay used")
        Check.equal(fingerprint(shared), before, "no auxiliary or temporary file in the linked folder")

        let saved = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        Check.equal(saved.status, .succeeded, describe(saved.diagnostics))
        Check.expect(saved.log.contains("GTX-REAL-ONE"), "without overlay the real file is read through the link again")
        Check.equal(fingerprint(shared), before, "still untouched")

        // Diagnostics in a file below a (non-materialized) symlinked folder are reported, with the project path.
        Fixtures.write("Saved text.\n\\oopsondisk\n", to: shared.appendingPathComponent("chapters/one.tex"))
        let onDisk = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        expectDiagnostic(onDisk.diagnostics, message: "Undefined control sequence \\oopsondisk", severity: .error, file: one, line: 2)
    }

    await Check.suite("LaTeXCompiler: \\input{../macros} + \\bibliography{../refs} outside the project (#3)") {
        let base = Fixtures.scratch("ancestors")
        let papers = base.appendingPathComponent("papers")
        let project = papers.appendingPathComponent("paper1")
        let main = project.appendingPathComponent("main.tex")
        let macros = papers.appendingPathComponent("macros.tex")
        Fixtures.write("""
            \\documentclass{article}
            \\input{../macros}
            \\input{../../common/defs}
            \\begin{document}
            \\gtxmacro\\ \\gtxdefs\\ \\cite{knuth}.
            \\bibliographystyle{plain}
            \\bibliography{../refs}
            \\end{document}

            """, to: main)
        Fixtures.write("\\newcommand{\\gtxmacro}{GtxMacroText}\n\\typeout{GTX-MACROS-LOADED}\n\\undefinedinmacros\n", to: macros)
        Fixtures.write("\\newcommand{\\gtxdefs}{GtxDefsText}\n", to: base.appendingPathComponent("common/defs.tex"))
        Fixtures.write("@book{knuth, author = {Donald E. Knuth}, title = {The {\\TeX}book},\n  publisher = {Addison-Wesley}, year = {1984}}\n",
                       to: papers.appendingPathComponent("refs.bib"))

        let r = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        Check.equal(r.status, .failed, "the deliberate error in ../macros.tex: \(describe(r.diagnostics))")
        Check.expect(r.log.contains("GTX-MACROS-LOADED"), "../macros.tex was read")
        expectDiagnostic(r.diagnostics, message: "Undefined control sequence \\undefinedinmacros", severity: .error,
                         file: macros, line: 3)

        Fixtures.write("\\newcommand{\\gtxmacro}{GtxMacroText}\n\\typeout{GTX-MACROS-LOADED}\n", to: macros)
        let fixed = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .build))
        Check.equal(fixed.status, .succeeded, describe(fixed.diagnostics))
        Check.equal(fixed.diagnostics.filter { $0.severity >= .warning }.count, 0,
                    "citation resolved from ../refs.bib, no bibtex error: \(describe(fixed.diagnostics))")
        let text = fixed.pdfURL.flatMap { PDFDocument(url: $0)?.string } ?? ""
        Check.expect(text.contains("GtxMacroText") && text.contains("GtxDefsText") && text.contains("Knuth"),
                     "macros, ../../common/defs and the bibliography made it into the PDF: \(text.prefix(200))")
        Check.equal(Set((try? FileManager.default.contentsOfDirectory(atPath: papers.path)) ?? []),
                    ["macros.tex", "refs.bib", "paper1"], "nothing written next to the files outside the project")

        // Beyond the mirrored levels: a clear explanation instead of a bare "not found".
        let deep = base.appendingPathComponent("l1/l2/l3/proj")
        let deepMain = deep.appendingPathComponent("main.tex")
        Fixtures.write("Near text.\n\\typeout{GTX-NEAR}\n", to: base.appendingPathComponent("l1/near.tex"))
        Fixtures.write("Far text.\n", to: base.appendingPathComponent("far.tex"))
        Fixtures.write("\\documentclass{article}\n\\begin{document}\n\\input{../../../near}\n\\input{../../../../far}\n\\end{document}\n",
                       to: deepMain)
        let u = await compiler.compile(CompileRequest(projectDirectory: deep, rootFile: deepMain, engine: .pdflatex, purpose: .live))
        Check.equal(u.status, .failed)
        Check.expect(u.log.contains("GTX-NEAR"), "3 levels up is still reachable")
        let farPath = base.appendingPathComponent("far.tex").standardizedFileURL.path
        let explained = u.diagnostics.first { $0.source == .latexmk && $0.message.contains(farPath) }
        Check.expect(explained != nil, "unreachable ../ input explained: \(describe(u.diagnostics))")
        Check.equal(explained?.fileURL?.path, deepMain.path)
        Check.equal(explained?.line, 4)
    }

    await Check.suite("LaTeXCompiler: \\input{Chapters/Intro} for chapters/intro.tex maps to the on-disk spelling (#5)") {
        let project = Fixtures.scratch("case-insensitive")
        let main = project.appendingPathComponent("main.tex")
        let intro = project.appendingPathComponent("chapters/intro.tex")
        Fixtures.write("\\documentclass{article}\n\\begin{document}\n\\input{Chapters/Intro}\n\\end{document}\n", to: main)
        Fixtures.write("Intro text.\n\\oopscase\n", to: intro)
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("CHAPTERS/INTRO.TEX").path) else {
            print("    SKIP (the temporary folder is on a case-sensitive volume)")
            return
        }
        let r = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        Check.expect(r.log.contains("Chapters/Intro.tex"), "TeX opened the file with the other spelling")
        expectDiagnostic(r.diagnostics, message: "Undefined control sequence \\oopscase", severity: .error, file: intro, line: 2)
        let d = r.diagnostics.first { $0.message.contains("oopscase") }
        Check.equal(d?.fileURL?.path, intro.path, "byte-identical on-disk spelling (not Chapters/Intro.tex)")
    }

    await Check.suite("LaTeXCompiler: the project's .latexmkrc is honoured (#4)") {
        let project = Fixtures.scratch("latexmkrc")
        let main = project.appendingPathComponent("main.tex")
        let rc = project.appendingPathComponent(".latexmkrc")
        Fixtures.write("ensure_path('TEXINPUTS', './rcinputs//');\n", to: rc)
        Fixtures.write("\\ProvidesPackage{gtxrc}\n\\typeout{GTX-LATEXMKRC-OK}\n", to: project.appendingPathComponent("rcinputs/gtxrc.sty"))
        Fixtures.write("\\documentclass{article}\n\\usepackage{gtxrc}\n\\begin{document}\nRC.\n\\end{document}\n", to: main)
        let r = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        Check.equal(r.status, .succeeded, describe(r.diagnostics))
        Check.expect(r.log.contains("GTX-LATEXMKRC-OK"), "TEXINPUTS from .latexmkrc found rcinputs/gtxrc.sty")

        // Control: without the rc file the package cannot be found.
        try? FileManager.default.removeItem(at: rc)
        Fixtures.write("\\documentclass{article}\n\\usepackage{gtxrc}\n\\begin{document}\nRC again.\n\\end{document}\n", to: main)
        let without = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        Check.equal(without.status, .failed)
        Check.expect(without.diagnostics.contains { $0.missingFile == "gtxrc.sty" }, describe(without.diagnostics))
    }

    await Check.suite("LaTeXCompiler: Latin-1 overlay with inputenc{latin1} (#9)") {
        let project = Fixtures.scratch("latin1")
        let main = project.appendingPathComponent("main.tex")
        Fixtures.write("% saved\n", to: main)
        let source = "\\documentclass{article}\n\\usepackage[T1]{fontenc}\n\\usepackage[latin1]{inputenc}\n\\begin{document}\nação AÇÃO\n\\end{document}\n"
        var request = CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, overlays: [main: source], purpose: .live)
        request.overlayEncodings = [main: .isoLatin1]
        let r = await compiler.compile(request)
        Check.equal(r.status, .succeeded, describe(r.diagnostics))
        Check.expect(!r.diagnostics.contains { $0.message.contains("inputenc") || $0.message.contains("Keyboard character") },
                     "no inputenc errors: \(describe(r.diagnostics))")
        Check.equal(FileManager.default.contents(atPath: r.pathMapper.shadowURL(forProjectURL: main).path),
                    source.data(using: .isoLatin1), "the overlay was written in Latin-1")
        let text = r.pdfURL.flatMap { PDFDocument(url: $0)?.string } ?? ""
        Check.expect(text.contains("ação") && text.contains("AÇÃO"), "accents survive: \(text)")
        Check.equal(readText(main.path), "% saved\n", "project file untouched")

        // Control: the same text as UTF-8 bytes is rejected by inputenc{latin1} (Ç = C3 87, 0x87 is undefined).
        let utf8 = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex,
                                                         overlays: [main: source], purpose: .live))
        Check.expect(utf8.diagnostics.contains { $0.message.contains("inputenc") || $0.message.contains("Keyboard character") },
                     "UTF-8 bytes would have broken the compile: \(describe(utf8.diagnostics))")
    }

    await Check.suite("LaTeXCompiler.terminateAllRunningProcesses: a looping compile dies synchronously (#12)") {
        let project = Fixtures.scratch("quit-loop")
        let main = project.appendingPathComponent("main.tex")
        Fixtures.write("\\documentclass{article}\n\\begin{document}\n\\def\\loop{\\loop}\\loop\n\\end{document}\n", to: main)
        let id = ShadowWorkspace.identifier(for: project)
        let task = Task { await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live)) }
        var running: [Int32] = []
        for _ in 0..<80 {
            running = await pgrep("pdflatex.*\(id)")
            if !running.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Check.expect(!running.isEmpty, "pdflatex is looping")
        LaTeXCompiler.terminateAllRunningProcesses()
        Check.equal(await pgrep(id), [], "no latexmk/pdflatex of the project right after the call")
        let clock = ContinuousClock()
        let start = clock.now
        let result = await task.value
        Check.equal(result.status, .cancelled, "the interrupted compile reports cancellation")
        Check.expect(clock.now - start < .seconds(5), "and returns promptly")
        Fixtures.write("\\documentclass{article}\n\\begin{document}\nFine.\n\\end{document}\n", to: main)
        let next = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        Check.equal(next.status, .succeeded, "the compiler keeps working: \(describe(next.diagnostics))")
    }
}

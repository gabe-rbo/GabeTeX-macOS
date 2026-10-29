import Foundation
import CoreGraphics
import PDFKit
import Synchronization
import CheckKit
import TeXCore
@testable import TeXToolchain

/// End-to-end checks against the real TeX installation of this Mac.
@MainActor
func integrationChecks(online: Bool) async {
    var distribution: TeXDistribution?

    await Check.suite("Distribution detection (+ broken tools)") {
        distribution = await TeXDistributionLocator.locate()
        guard let dist = distribution else {
            Check.fail("no TeX distribution found")
            return
        }
        print("    \(dist.name) — \(dist.binDirectory.path) — root \(dist.texmfRoot?.path ?? "?") — writable \(dist.isUserWritable)")
        print("    version: \(dist.versionDescription ?? "?")")
        for (tool, problem) in dist.toolProblems { print("    problem: \(tool.rawValue): \(problem)") }
        Check.equal(dist.binDirectory.path, "/Library/TeX/texbin")
        Check.expect(dist.name.hasPrefix("MacTeX"), "MacTeX detected via /Library/TeX/texbin: \(dist.name)")
        Check.expect((dist.year ?? 0) >= 2024, "year parsed: \(String(describing: dist.year))")
        Check.equal(dist.texmfRoot?.path.hasPrefix("/usr/local/texlive/"), true)
        let tlpkg = (dist.texmfRoot?.path ?? "") + "/tlpkg"
        Check.equal(dist.isUserWritable, FileManager.default.isWritableFile(atPath: tlpkg))
        for tool in [TeXTool.pdflatex, .xelatex, .lualatex, .latexmk, .bibtex, .chktex, .synctex, .tlmgr, .kpsewhich] {
            Check.expect(dist.url(for: tool) != nil, "\(tool.rawValue) found")
        }
        Check.equal(dist.processEnvironment["max_print_line"], "10000")
        Check.expect(dist.processEnvironment["PATH"]?.hasPrefix("/Library/TeX/texbin:") == true)
        // biber on this Mac prints lipo's usage and fails: the health check must say so.
        if let biber = dist.url(for: .biber) {
            let direct = try? await ProcessRunner.run(biber, arguments: ["--version"], environment: dist.processEnvironment, timeout: .seconds(20))
            let works = direct?.succeeded == true && direct?.stdoutText.contains("biber version") == true
            Check.equal(dist.isWorking(.biber), works, "health check agrees with running biber --version")
            if !works {
                Check.expect(dist.toolProblems[.biber]?.contains("lipo") == true, "problem explains the lipo failure: \(dist.toolProblems[.biber] ?? "nil")")
            }
        }
        Check.equal(await TeXDistributionLocator.inspect(binDirectory: URL(fileURLWithPath: "/usr/bin")), nil, "/usr/bin is not a TeX installation")
        let all = await TeXDistributionLocator.candidates()
        Check.expect(all.first?.binDirectory.path == "/Library/TeX/texbin", "candidates best first: \(all.map(\.binDirectory.path))")
        Check.equal(Set(all.compactMap { $0.texmfRoot?.resolvingSymlinksInPath().path }).count, all.count, "one candidate per TEXMFROOT")
    }
    guard let dist = distribution else { return }
    let shadowRoot = Fixtures.scratch("shadow")
    let compiler = LaTeXCompiler(distribution: dist, shadowRoot: shadowRoot)

    await Check.suite("LaTeXCompiler: live overlay vs. disk, build → exported PDF") {
        let project = Fixtures.scratch("two-file")
        let main = project.appendingPathComponent("main.tex")
        let intro = project.appendingPathComponent("sections/intro.tex")
        Fixtures.write("\\documentclass{article}\n\\begin{document}\n\\input{sections/intro}\n\\typeout{GTX-MAIN-MARKER}\n\\end{document}\n", to: main)
        Fixtures.write("Introduction on disk.\n\\typeout{GTX-DISK-MARKER}\n", to: intro)

        let live = await compiler.compile(CompileRequest(
            projectDirectory: project, rootFile: main, engine: .pdflatex,
            overlays: [intro: "Introduction, unsaved.\n\\typeout{GTX-OVERLAY-MARKER}\n\\undefinedinoverlay\n"], purpose: .live))
        Check.equal(live.status, .failed, "undefined control sequence → failed. \(live.toolOutput.suffix(400))")
        Check.expect(live.log.contains("GTX-OVERLAY-MARKER") && !live.log.contains("GTX-DISK-MARKER"), "the live compile used the unsaved buffer")
        Check.expect(live.log.contains("GTX-MAIN-MARKER"), "main.tex compiled through its symlink")
        expectDiagnostic(live.diagnostics, message: "Undefined control sequence \\undefinedinoverlay", severity: .error,
                         file: intro, line: 3, column: 1, length: 19)
        Check.expect(live.pdfURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "PDF produced")
        Check.expect(live.pdfURL?.path.hasPrefix(shadowRoot.path) == true, "PDF lives in the shadow workspace")
        Check.equal(live.exportedPDFURL, nil, ".live never exports")
        Check.expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("main.pdf").path), "project untouched by .live")
        Check.equal(try? String(contentsOf: intro, encoding: .utf8), "Introduction on disk.\n\\typeout{GTX-DISK-MARKER}\n", "disk file unchanged")
        Check.equal(live.pathMapper, compiler.pathMapper(for: project))
        Check.expect(live.duration > 0)

        let build = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .build))
        Check.equal(build.status, .succeeded, describe(build.diagnostics))
        Check.expect(build.log.contains("GTX-DISK-MARKER") && !build.log.contains("GTX-OVERLAY-MARKER"), "without overlay the disk file is used again")
        Check.equal(build.exportedPDFURL?.path, project.appendingPathComponent("main.pdf").path)
        Check.expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("main.pdf").path), "PDF copied next to the root file")
        Check.expect(build.synctexURL != nil, "synctex produced")
        Check.equal(build.diagnostics.filter { $0.severity >= .warning }.count, 0, describe(build.diagnostics))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
        Check.equal(Set(leftovers), ["main.tex", "sections", "main.pdf"], "no auxiliary files in the project")
    }

    await Check.suite("LaTeXCompiler: root in a sub-directory, \\include of a sub-sub-directory") {
        let project = Fixtures.scratch("subdir")
        let main = project.appendingPathComponent("thesis/main.tex")
        let chapter = project.appendingPathComponent("thesis/chapters/one.tex")
        Fixtures.write("\\documentclass{report}\n\\begin{document}\n\\include{chapters/one}\n\\end{document}\n", to: main)
        Fixtures.write("\\chapter{One}\nText \\oops here.\n", to: chapter)
        let r = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .build))
        Check.equal(r.status, .failed, describe(r.diagnostics))
        expectDiagnostic(r.diagnostics, message: "Undefined control sequence \\oops", severity: .error, file: chapter, line: 2, column: 6, length: 5)
        Check.expect(!r.diagnostics.contains { $0.message.contains("chapters/one.aux") }, "\\include aux file could be written: \(describe(r.diagnostics))")
        Check.equal(r.exportedPDFURL?.path, project.appendingPathComponent("thesis/main.pdf").path, "exported next to the root file")
    }

    await Check.suite("LaTeXCompiler: cancellation kills latexmk + pdflatex; next compile waits and runs") {
        let project = Fixtures.scratch("loop")
        let main = project.appendingPathComponent("main.tex")
        Fixtures.write("\\documentclass{article}\n\\begin{document}\n\\def\\loop{\\loop}\\loop\n\\end{document}\n", to: main)
        let id = ShadowWorkspace.identifier(for: project)
        let first = Task { await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live)) }
        var running: [Int32] = []
        for _ in 0..<80 {
            running = await pgrep("pdflatex.*\(id)")
            if !running.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Check.expect(!running.isEmpty, "pdflatex is looping")
        // A second request queues behind the first one.
        Fixtures.write("\\documentclass{article}\n\\begin{document}\nFixed.\n\\end{document}\n", to: main)
        let second = Task { await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live)) }
        try? await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        first.cancel()
        let cancelled = await first.value
        Check.equal(cancelled.status, .cancelled)
        Check.expect(clock.now - start < .seconds(5), "cancel is prompt (\(clock.now - start))")
        let next = await second.value
        Check.equal(next.status, .succeeded, "queued compile ran after the cancelled one: \(describe(next.diagnostics))")
        try? await Task.sleep(for: .milliseconds(200))
        Check.equal(await pgrep(id), [], "no TeX process of this project remains")

        // Timeout: the endless loop is stopped and reported.
        Fixtures.write("\\documentclass{article}\n\\begin{document}\n\\def\\loop{\\loop}\\loop\n\\end{document}\n", to: main)
        let timed = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex,
                                                          purpose: .live, timeout: .seconds(3)))
        Check.equal(timed.status, .failed)
        Check.expect(timed.diagnostics.contains { $0.source == .latexmk && $0.message.contains("3 seconds") }, describe(timed.diagnostics))
        try? await Task.sleep(for: .milliseconds(200))
        Check.equal(await pgrep(id), [], "no TeX process after the timeout")
    }

    await Check.suite("LaTeXCompiler: broken biber → actionable error") {
        let project = Fixtures.scratch("biber")
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.copyItem(at: Fixtures.project("biber"), to: project)
        let main = project.appendingPathComponent("main.tex")
        for pass in 1...2 {
            let r = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
            if dist.isWorking(.biber) {
                Check.expect(!r.diagnostics.contains { $0.source == .biber && $0.message == TeXLogParser.biberFailureMessage },
                             "biber works here; no failure expected")
                continue
            }
            Check.equal(r.status, .failed, "pass \(pass)")
            let d = expectDiagnostic(r.diagnostics, message: TeXLogParser.biberFailureMessage, severity: .error, file: main, line: 2, source: .biber)
            Check.expect(d?.detail?.contains("lipo") == true, "detail explains why (pass \(pass)): \(d?.detail ?? "nil")")
            Check.equal(r.diagnostics.first?.source, .biber, "the biber error comes first (pass \(pass))")
            Check.expect(r.diagnostics.contains { $0.message == "Citation 'hatcher' on page 1 undefined." }, "cascading warnings are still listed")
        }
    }

    await Check.suite("LaTeXCompiler: BibTeX errors, missing package (line located, missingFiles)") {
        let bib = Fixtures.scratch("bibtex")
        try? FileManager.default.removeItem(at: bib)
        try? FileManager.default.copyItem(at: Fixtures.project("bibtex"), to: bib)
        let r = await compiler.compile(CompileRequest(projectDirectory: bib, rootFile: bib.appendingPathComponent("main.tex"), engine: .pdflatex, purpose: .live))
        Check.equal(r.status, .failed)
        expectDiagnostic(r.diagnostics, message: "I was expecting a `,' or a `}'", severity: .error,
                         file: bib.appendingPathComponent("refs.bib"), line: 11, source: .bibtex)
        expectDiagnostic(r.diagnostics, message: "Citation `nokey' on page 1 undefined.", severity: .warning,
                         file: bib.appendingPathComponent("main.tex"), line: 3)

        let pkg = Fixtures.scratch("missingpkg")
        try? FileManager.default.removeItem(at: pkg)
        try? FileManager.default.copyItem(at: Fixtures.project("missingpkg"), to: pkg)
        let m = await compiler.compile(CompileRequest(projectDirectory: pkg, rootFile: pkg.appendingPathComponent("main.tex"), engine: .pdflatex, purpose: .build))
        Check.equal(m.status, .failed)
        expectDiagnostic(m.diagnostics, message: "File `thispackagedoesnotexist.sty' not found.", severity: .error,
                         file: pkg.appendingPathComponent("main.tex"), line: 3, missingFile: "thispackagedoesnotexist.sty")
        Check.equal(m.missingFiles, ["thispackagedoesnotexist.sty"])
        Check.equal(m.exportedPDFURL, nil, "no pages of output → nothing exported")

        let missing = await compiler.compile(CompileRequest(projectDirectory: pkg, rootFile: pkg.appendingPathComponent("nope.tex"), engine: .pdflatex, purpose: .live))
        if case .toolError = missing.status {} else { Check.fail("missing root file → toolError, got \(missing.status)") }
        let outside = await compiler.compile(CompileRequest(projectDirectory: pkg, rootFile: URL(fileURLWithPath: "/tmp/x.tex"), engine: .pdflatex, purpose: .live))
        if case .toolError = outside.status {} else { Check.fail("root outside project → toolError") }
        var noLatexmk = dist
        noLatexmk.tools[.latexmk] = nil
        let broken = await LaTeXCompiler(distribution: noLatexmk, shadowRoot: shadowRoot)
            .compile(CompileRequest(projectDirectory: pkg, rootFile: pkg.appendingPathComponent("main.tex"), engine: .pdflatex, purpose: .live))
        if case .toolError(let message) = broken.status { Check.expect(message.contains("latexmk"), message) } else { Check.fail("no latexmk → toolError") }
    }

    await Check.suite("SyncTeX: forward/inverse round trip on a real PDF (+ PDFKit cross-check)") {
        let project = Fixtures.scratch("synctex")
        let main = project.appendingPathComponent("main.tex")
        let body = project.appendingPathComponent("sections/body.tex")
        Fixtures.write("\\documentclass{article}\n\\usepackage[a4paper,margin=2cm]{geometry}\n\\begin{document}\nFIRSTLINE alpha beta gamma.\n\n\\input{sections/body}\n\n\\end{document}\n", to: main)
        var lines: [String] = []
        for k in 1...80 { lines.append("Paragraph MARK\(k)X text text text.\n") }
        Fixtures.write(lines.joined(separator: "\n"), to: body)     // paragraph k is on line 2k-1
        let r = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        guard r.status == .succeeded, let pdf = r.pdfURL else {
            Check.fail("compile failed: \(r.status) \(describe(r.diagnostics))")
            return
        }
        let sync = SyncTeX(distribution: dist)
        let document = PDFDocument(url: pdf)
        var checked = 0
        for k in [1, 2, 10, 25, 60, 80] {
            let line = 2 * k - 1
            let boxes = await sync.forward(pdfURL: pdf, sourceFile: body, line: line, column: 1, mapper: r.pathMapper)
            guard let box = boxes.first else {
                Check.fail("forward search found nothing for line \(line)")
                continue
            }
            // Independent ground truth: where PDFKit finds "MARK<k>X" on the page.
            if let selection = document?.findString("MARK\(k)X", withOptions: []).first,
               let page = selection.pages.first, let index = document?.index(for: page) {
                let textBounds = selection.bounds(for: page)
                Check.equal(index + 1, box.page, "page of MARK\(k)X")
                Check.expect(box.rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: textBounds.midX, y: textBounds.midY)),
                             "forward box \(box.rect) contains the text MARK\(k)X at \(textBounds)")
            } else {
                Check.fail("PDFKit did not find MARK\(k)X")
            }
            let center = CGPoint(x: box.rect.minX + 30, y: box.rect.midY)
            let location = await sync.inverse(pdfURL: pdf, page: box.page, point: center, mapper: r.pathMapper)
            Check.equal(location?.fileURL.path, body.path, "inverse file for line \(line)")
            Check.equal(location?.line, line, "inverse(forward(line \(line)))")
            checked += 1
        }
        Check.equal(checked, 6)
        let pages = Set(await withTaskGroup(of: Int?.self) { group in
            for k in [1, 80] {
                group.addTask { await sync.forward(pdfURL: pdf, sourceFile: body, line: 2 * k - 1, column: 1, mapper: r.pathMapper).first?.page }
            }
            var result: [Int?] = []
            for await p in group { result.append(p) }
            return result
        }.compactMap { $0 })
        Check.equal(pages, [1, 2], "the document spans two pages and both are found")
        let first = await sync.forward(pdfURL: pdf, sourceFile: main, line: 4, column: 1, mapper: r.pathMapper)
        Check.equal(first.first?.page, 1)
        Check.equal(await sync.inverse(pdfURL: pdf, page: 99, point: .zero, mapper: r.pathMapper), nil, "page out of range")
        Check.equal(await sync.forward(pdfURL: pdf, sourceFile: project.appendingPathComponent("nothere.tex"), line: 1, column: 1, mapper: r.pathMapper), [])
    }

    await Check.suite("ChkTeX: live run") {
        let linter = ChkTeXLinter(distribution: dist)
        let file = URL(fileURLWithPath: "/tmp/sample.tex")
        let text = "Olá ação $x^10$ fim.\nSee section \\ref{a} and (0,1].\n``quoted\" text\n"
        let ds = await linter.lint(text: text, fileURL: file)
        let superscript = ds.first { $0.line == 1 }
        Check.equal(superscript?.column, 13, "UTF-16 column of 10 in x^10: \(describe(ds))")
        Check.equal(superscript?.length, 2)
        Check.expect(ds.contains { $0.line == 2 && $0.message.contains("Non-breaking space") }, describe(ds))
        Check.expect(!ds.contains { $0.detail?.hasSuffix(" 9") == true || $0.detail?.hasSuffix(" 10") == true }, "interval warnings suppressed")
        Check.expect(ds.allSatisfy { $0.source == .chktex && $0.fileURL == file })
    }

    await Check.suite("TeXPackageManager: kpsewhich and tlmgr search") {
        let manager = TeXPackageManager(distribution: dist)
        Check.expect(await manager.isInstalled(file: "amsmath.sty"))
        Check.expect(!(await manager.isInstalled(file: "thispackagedoesnotexist.sty")))
        guard online else {
            print("    SKIP tlmgr search (--offline)")
            return
        }
        do {
            let packages = try await manager.packages(providing: "tikz-cd.sty")
            Check.equal(packages.first, "tikz-cd", "\(packages)")
            let none = try await manager.packages(providing: "thispackagedoesnotexist-gabetex.sty")
            Check.equal(none, [])
        } catch {
            print("    SKIP tlmgr search (offline?): \(error.localizedDescription)")
        }
    }

    await Check.suite("DirectoryWatcher: FSEvents") {
        let dir = Fixtures.scratch("watch")
        let collected = Collected()
        let watcher = DirectoryWatcher(url: dir) { urls in collected.add(urls) }
        watcher.start()
        Check.expect(watcher.isRunning)
        try? await Task.sleep(for: .milliseconds(300))
        Fixtures.write("x", to: dir.appendingPathComponent("a.tex"))
        Fixtures.write("x", to: dir.appendingPathComponent(".hidden"))
        Fixtures.write("x", to: dir.appendingPathComponent(".git/HEAD"))
        Fixtures.write("x", to: dir.appendingPathComponent("sub/b.tex"))
        var names: Set<String> = []
        for _ in 0..<40 {
            names = Set(collected.urls.map(\.lastPathComponent))
            if names.contains("a.tex") && names.contains("b.tex") { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Check.expect(names.contains("a.tex") && names.contains("b.tex"), "changes delivered: \(names)")
        Check.expect(!names.contains(".hidden") && !names.contains("HEAD") && !names.contains(".git"), "hidden paths ignored: \(names)")
        Check.expect(collected.urls.allSatisfy { $0.path.hasPrefix(dir.path) }, "URLs use the watched spelling: \(collected.urls.map(\.path))")
        watcher.stop()
        Check.expect(!watcher.isRunning)
        try? await Task.sleep(for: .milliseconds(300))
        let count = collected.urls.count
        Fixtures.write("y", to: dir.appendingPathComponent("c.tex"))
        try? await Task.sleep(for: .milliseconds(600))
        Check.equal(collected.urls.count, count, "no events after stop()")
    }

    await regressionChecks(compiler: compiler)

    await compiler.clean(projectDirectory: Fixtures.scratch("two-file"))
    Check.expect(!FileManager.default.fileExists(atPath: compiler.shadowDirectory(for: Fixtures.scratch("two-file")).path), "clean removes the workspace")
}

/// Thread-safe accumulator for watcher callbacks.
final class Collected: Sendable {
    private let storage = Mutex<[URL]>([])
    func add(_ urls: [URL]) { storage.withLock { $0.append(contentsOf: urls) } }
    var urls: [URL] { storage.withLock { $0 } }
}

import Foundation
import CoreGraphics
import CheckKit
import TeXCore
@testable import TeXToolchain

/// Pure helpers: command builders and parsers (no TeX needed), plus the process runner and the shadow mirror.
@MainActor
func unitChecks() async {
    await Check.suite("ChkTeX: arguments and output parsing") {
        let args = ChkTeXLinter.arguments(suppressing: [2, 1])
        Check.equal(Array(args.prefix(5)), ["-q", "-I0", "-v0", "-f", "%l:%c:%d:%k:%n:%m\n"])
        Check.equal(Array(args.suffix(2)), ["-n1", "-n2"])
        // Real chktex 1.7 output for "Olá ação $x^10$ fim." — columns/lengths are bytes.
        let text = "Olá ação $x^10$ fim.\nSee section \\ref{a}\n"
        let out = "1:16:2:Warning:25:You might wish to put this between a pair of `{}'\n2:12:1:Warning:2:Non-breaking space (`~') should have been used.\n3:1:4:Error:9:`itemize' expected, found `enumerate'.\n"
        let file = URL(fileURLWithPath: "/p/a.tex")
        let ds = ChkTeXLinter.parse(output: out, text: text, fileURL: file, suppressed: [9])
        Check.equal(ds.count, 2)
        Check.equal(ds.first?.line, 1)
        Check.equal(ds.first?.column, 13, "byte column 16 → UTF-16 column 13 (á, ç, ã are 2 bytes)")
        Check.equal(ds.first?.length, 2)
        Check.equal(ds.first?.severity, .info, "chktex Warning → .info")
        Check.equal(ds.first?.source, .chktex)
        Check.equal(ds.last?.message, "Non-breaking space (`~') should have been used.")
        Check.equal(ds.last?.column, 12)
        let err = ChkTeXLinter.parse(output: "1:1:1:Error:99:Message with: colons\n", text: "x\n", fileURL: file)
        Check.equal(err.first?.severity, .warning, "chktex Error → .warning")
        Check.equal(err.first?.message, "Message with: colons")
        let smiley = ChkTeXLinter.utf16Span(byteColumn: 2, byteLength: 4, in: "a😀b")
        Check.expect(smiley.column == 2 && smiley.length == 2, "4-byte scalar = 2 UTF-16 units: \(smiley)")
        let emoji = ChkTeXLinter.utf16Span(byteColumn: 6, byteLength: 1, in: "a😀b")
        Check.equal(emoji.column, 4, "after a 4-byte emoji (2 UTF-16 units)")
        Check.expect(ChkTeXLinter.defaultSuppressions.contains(9) && !ChkTeXLinter.defaultSuppressions.contains(2), "curated defaults")
    }

    await Check.suite("TeXPackageManager: search parsing and ranking") {
        let real = Fixtures.text("tools/tlmgr-search-tikz-cd.txt")
        let parsed = TeXPackageManager.parseSearchOutput(real)
        Check.equal(parsed.map(\.package), ["tikz-cd"])
        Check.equal(parsed.first?.files, ["texmf-dist/tex/latex/tikz-cd/tikz-cd.sty"])
        Check.equal(TeXPackageManager.rank(parsed, for: "tikz-cd.sty"), ["tikz-cd"])
        let multi = """
        tlmgr: package repository https://mirror/tlnet (verified)
        bundle-x:
        \ttexmf-dist/tex/latex/bundle-x/foo.sty
        foo-extra:
        \ttexmf-dist/tex/latex/foo/foo.sty
        foo:
        \ttexmf-dist/tex/latex/foo/foo.sty
        \ttexmf-dist/doc/latex/foo/README
        decoy:
        \ttexmf-dist/tex/latex/decoy/foo.sty.bak
        """
        Check.equal(TeXPackageManager.rank(TeXPackageManager.parseSearchOutput(multi), for: "foo.sty"),
                    ["foo", "bundle-x", "foo-extra"], "stem match, then tlmgr order; non-exact file matches dropped")
        let byDirectory = "pgf-a:\n\ttexmf-dist/tex/latex/pgfplots/pgfplots.sty\npgfplots:\n\ttexmf-dist/tex/latex/pgfplots/pgfplots.sty\nzz:\n\ttexmf-dist/tex/latex/zz/pgfplots.sty\n"
        Check.equal(TeXPackageManager.rank(TeXPackageManager.parseSearchOutput(byDirectory), for: "pgfplots.sty").first, "pgfplots")
        Check.equal(TeXPackageManager.searchArguments(file: "tikz-cd.sty"), ["search", "--global", "--file", "/tikz-cd\\.sty"])
        Check.equal(TeXPackageManager.regexEscaped("c++(x).sty"), "c\\+\\+\\(x\\)\\.sty")
    }

    await Check.suite("TeXPackageManager: install command construction (sh + AppleScript escaping)") {
        let tlmgr = URL(fileURLWithPath: "/Library/TeX/texbin/tlmgr")
        let direct = TeXPackageManager.invocation(tlmgr: tlmgr, arguments: ["install", "tikz-cd"], userWritable: true, prompt: "p")
        Check.equal(direct.executable.path, "/Library/TeX/texbin/tlmgr")
        Check.equal(direct.arguments, ["install", "tikz-cd"])

        let admin = TeXPackageManager.invocation(tlmgr: URL(fileURLWithPath: "/opt/My \"TeX\"/bin/tlmgr"),
                                                 arguments: ["install", "it's"], userWritable: false,
                                                 prompt: "GabeTeX quer \"instalar\" pacotes")
        Check.equal(admin.executable.path, "/usr/bin/osascript")
        Check.equal(admin.arguments.count, 2)
        Check.equal(admin.arguments.first, "-e")
        let expected = #"do shell script "'/opt/My \"TeX\"/bin/tlmgr' 'install' 'it'\\''s'" with administrator privileges with prompt "GabeTeX quer \"instalar\" pacotes" without altering line endings"#
        Check.equal(admin.arguments.last, expected)
        Check.equal(TeXPackageManager.shellQuoted("a'b"), #"'a'\''b'"#)
        Check.equal(TeXPackageManager.appleScriptString(#"a\b"c"#), #""a\\b\"c""#)
        Check.expect(TeXPackageManager.isValidPackageName("tikz-cd") && TeXPackageManager.isValidPackageName("biber.universal-darwin"))
        Check.expect(!TeXPackageManager.isValidPackageName("x; rm -rf ~") && !TeXPackageManager.isValidPackageName("--all"))

        // The AppleScript actually compiles (osacompile only parses; nothing is executed).
        let scratch = Fixtures.scratch("osacompile")
        if let out = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osacompile"),
                                                  arguments: ["-o", scratch.appendingPathComponent("t.scpt").path, "-e", expected],
                                                  timeout: .seconds(20)) {
            Check.expect(out.succeeded, "osacompile accepts the generated script: \(out.combinedText)")
        }
    }

    await Check.suite("TeXPackageManager: error mapping") {
        Check.equal(TeXPackageManager.mapError(output: "0:47: execution error: User canceled. (-128)", exitCode: 1), .userCancelledAuthorization)
        Check.equal(TeXPackageManager.mapError(output: "tlmgr: Remote database (revision 7) seems to be older than local (revision 9 of x); please use a different mirror.\ntlmgr itself needs to be updated.\nPlease do this via either\n  tlmgr update --self", exitCode: 1), .tlmgrNeedsUpdate)
        if case .distributionFrozen(let m)? = TeXPackageManager.mapError(output: "tlmgr: Local TeX Live (2025) is older than remote repository (2026).\nCross release updates are only supported with\n  update-tlmgr-latest(.sh/.exe) --update", exitCode: 1) {
            Check.expect(m.contains("Local TeX Live (2025) is older than remote repository (2026)."), m)
        } else {
            Check.fail("frozen distribution not detected")
        }
        Check.equal(TeXPackageManager.mapError(output: "tlmgr install: package nosuchpkg not present in repository.", exitCode: 1),
                    .notFoundInRepository("nosuchpkg"))
        Check.equal(TeXPackageManager.mapError(output: "tlmgr: package repository x (verified)\n[1/1, ??:??/??:??] install: tikz-cd [5k]\nrunning mktexlsr ...\ndone", exitCode: 0), nil)
        if case .failed? = TeXPackageManager.mapError(output: "boom", exitCode: 2) {} else { Check.fail("generic failure") }
    }

    await Check.suite("SyncTeX: output parsing and coordinate conversion") {
        // Real `synctex view` output (pdfTeX, A4, 2 cm margins).
        let view = "This is SyncTeX command line utility, version 1.5\nSyncTeX result begin\nOutput:out/main.pdf\nPage:1\nx:125.878006\ny:66.655540\nh:56.692902\nv:68.592720\nW:481.889771\nH:8.855677\nbefore:\noffset:-1\nmiddle:\nafter:\nSyncTeX result end\n"
        let records = SyncTeX.parseViewOutput(view)
        Check.equal(records.count, 1)
        Check.equal(records.first, SyncTeX.ViewRecord(page: 1, h: 56.692902, v: 68.592720, width: 481.889771, height: 8.855677))
        let a4 = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
        if let r = records.first {
            let rect = SyncTeX.pageSpaceRect(r, mediaBox: a4)
            Check.expect(abs(rect.minY - (841.89 - 68.592720)) < 0.001 && abs(rect.maxY - (841.89 - 68.592720 + 8.855677)) < 0.001, "\(rect)")
            Check.expect(abs(rect.minX - 56.692902) < 0.001 && abs(rect.width - 481.889771) < 0.001)
        }
        let shifted = CGRect(x: 10, y: 20, width: 600, height: 800)
        let p = SyncTeX.synctexPoint(fromPageSpace: CGPoint(x: 110, y: 720), mediaBox: shifted)
        Check.expect(abs(p.x - 100) < 0.001 && abs(p.y - 100) < 0.001, "media box origin honoured: \(p)")
        let edit = "This is SyncTeX command line utility, version 1.5\nSyncTeX result begin\nOutput:/x/out/main.pdf\nInput:/x/src/./sections/body.tex\nLine:5\nColumn:-1\nOffset:0\nContext:\nSyncTeX result end\n"
        Check.equal(SyncTeX.parseEditOutput(edit), SyncTeX.EditRecord(input: "/x/src/./sections/body.tex", line: 5, column: nil))
        Check.equal(SyncTeX.parseEditOutput("SyncTeX result begin\nSyncTeX result end\n"), nil)
    }

    await Check.suite("latexmk: .fdb_latexmk rules, package files, argument list") {
        let fdb = "# Fdb version 4\n[\"biber /o/main\"] 1793221244.29773 \"/o/main.bcf\" \"/o/main.bbl\" \"/o/main\" 1793221248.66568 2\n  \"/o/main.bcf\" 1 2 3 \"pdflatex\"\n[\"pdflatex\"] 1793221247.92909 \"main.tex\" \"/o/main.pdf\" \"main\" 1793221248.66597 0\n"
        Check.equal(LaTeXCompiler.bibliographyRules(inFdb: fdb), [LaTeXCompiler.BibliographyRule(tool: .biber, base: "/o/main", lastExitCode: 2)])
        Check.expect(LaTeXCompiler.isPackageFile("tikz-cd.sty") && LaTeXCompiler.isPackageFile("ecrm1000.tfm"))
        Check.expect(!LaTeXCompiler.isPackageFile("figs/plot") && !LaTeXCompiler.isPackageFile("chapters/nothere.tex") && !LaTeXCompiler.isPackageFile("nothere.tex"))
        let args = LaTeXCompiler.latexmkArguments(engine: .xelatex, outputDirectory: URL(fileURLWithPath: "/s/out/thesis"),
                                                  shellEscape: true, extra: ["-silent"], rootFileName: "main file.tex")
        Check.equal(args, ["-xelatex", "-interaction=nonstopmode", "-file-line-error", "-synctex=1", "-f",
                           "-e", "$bibtex_fudge = 0;", "-outdir=/s/out/thesis", "-shell-escape", "-silent", "main file.tex"])
        Check.equal(LaTeXCompiler.biblatexLine(in: "\\documentclass{article}\n% \\usepackage{biblatex}\n\\usepackage[backend=biber]{biblatex}\n"), 3)
        Check.equal(LaTeXCompiler.missingFileLine(in: "\\documentclass{article}\n\\usepackage{amsmath}\n\\usepackage{thispackagedoesnotexist}\n", name: "thispackagedoesnotexist.sty"), 3)
        Check.equal(LaTeXCompiler.missingFileLine(in: "a\n\\input{chapters/nothere}\n", name: "chapters/nothere.tex"), 2)
        Check.equal(LaTeXCompiler.missingFileLine(in: "\\usepackage{amsmath}\n", name: "amsmath-other.sty"), nil)
    }

    await Check.suite("ShadowPathMapper") {
        let mapper = ShadowPathMapper(projectDirectory: URL(fileURLWithPath: "/Users/g/Proj"),
                                      shadowDirectory: URL(fileURLWithPath: "/Users/g/Library/Caches/S/abc/src"))
        Check.equal(mapper.projectURL(forShadowPath: "/Users/g/Library/Caches/S/abc/src/./sections/a.tex")?.path, "/Users/g/Proj/sections/a.tex")
        Check.equal(mapper.projectURL(forShadowPath: "./main.tex")?.path, "/Users/g/Proj/main.tex")
        Check.equal(mapper.projectURL(forShadowPath: "/usr/local/texlive/2026/texmf-dist/tex/latex/base/article.cls"), nil)
        Check.equal(mapper.shadowURL(forProjectURL: URL(fileURLWithPath: "/Users/g/Proj/sections/a.tex")).path,
                    "/Users/g/Library/Caches/S/abc/src/sections/a.tex")
        Check.equal(mapper.ancestorDirectory, nil, "the two-argument initializer has no ancestor layer")
        Check.equal(ShadowPathMapper.lexicallyStandardized("/a/./b/../c//d/"), "/a/c/d")
        Check.equal(ShadowPathMapper.lexicallyStandardized("/../x"), "/x")
        let layered = ShadowPathMapper(projectDirectory: URL(fileURLWithPath: "/Users/g/Math/papers/p1"),
                                       shadowDirectory: URL(fileURLWithPath: "/C/abc/tree/Math/papers/p1"),
                                       ancestorDirectory: URL(fileURLWithPath: "/Users/g"),
                                       ancestorShadowDirectory: URL(fileURLWithPath: "/C/abc/tree"))
        Check.equal(layered.projectURL(forShadowPath: "/C/abc/tree/Math/papers/p1/./a.tex")?.path, "/Users/g/Math/papers/p1/a.tex")
        Check.equal(layered.projectURL(forShadowPath: "/C/abc/tree/Math/papers/p1/../macros.tex")?.path, "/Users/g/Math/papers/macros.tex")
        Check.equal(layered.projectURL(forShadowPath: "/private/C/abc/tree/shared/refs.bib")?.path, "/Users/g/shared/refs.bib")
        Check.equal(layered.projectURL(forShadowPath: "/C/abc/out/main.aux"), nil)
        Check.equal(layered.shadowURL(forProjectURL: URL(fileURLWithPath: "/Users/g/Math/macros.tex")).path, "/C/abc/tree/Math/macros.tex")
        Check.equal(layered.shadowURL(forProjectURL: URL(fileURLWithPath: "/Users/g/Math/papers/p1/a.tex")).path, "/C/abc/tree/Math/papers/p1/a.tex")
        Check.equal(layered.shadowURL(forProjectURL: URL(fileURLWithPath: "/etc/hosts")).path, "/etc/hosts")
        let top = ShadowWorkspace.layout(forProjectPath: "/Users/g/Math/papers/p1")
        Check.expect(top.ancestor == "/Users/g" && top.components == ["Math", "papers", "p1"], "layout 3 levels up: \(top)")
        let shallow = ShadowWorkspace.layout(forProjectPath: "/Proj")
        Check.expect(shallow.ancestor == "/" && shallow.components == ["Proj"], "layout stops at /: \(shallow)")
        Check.equal(ShadowWorkspace.identifier(for: URL(fileURLWithPath: "/Users/g/Proj")).count, 16)
        Check.equal(ShadowWorkspace.identifier(for: URL(fileURLWithPath: "/Users/g/Proj")),
                    ShadowWorkspace.identifier(for: URL(fileURLWithPath: "/Users/g/Proj/")), "stable per project path")
    }

    await Check.suite("ShadowWorkspace: symlink mirror, overlays, stale entries") {
        let base = Fixtures.scratch("mirror")
        let project = base.appendingPathComponent("Projeto Ação", isDirectory: true)
        Fixtures.write("main\n", to: project.appendingPathComponent("main.tex"))
        Fixtures.write("intro\n", to: project.appendingPathComponent("sections/intro.tex"))
        Fixtures.write("secret\n", to: project.appendingPathComponent(".git/config"))
        Fixtures.write("x\n", to: project.appendingPathComponent("sections/.svn/entries"))
        Fixtures.write("hidden\n", to: project.appendingPathComponent(".hidden.tex"))
        Fixtures.write("$pdf_mode = 1;\n", to: project.appendingPathComponent(".latexmkrc"))
        Fixtures.write("finder\n", to: project.appendingPathComponent(".DS_Store"))
        Fixtures.write("swap\n", to: project.appendingPathComponent(".main.tex.swp"))
        Fixtures.write("backup\n", to: project.appendingPathComponent("main.tex~"))
        let ws = ShadowWorkspace(projectDirectory: project, root: base.appendingPathComponent("shadow"))
        let src = ws.sourceDirectory.path
        do {
            let snap = try ws.refresh(overlays: [project.appendingPathComponent("sections/intro.tex"): "UNSAVED\n"])
            Check.equal(ShadowWorkspace.readLink(src + "/main.tex"), project.path + "/main.tex", "symlink to the original")
            Check.equal(ShadowWorkspace.readLink(src + "/sections/intro.tex"), nil, "overlay is a real file")
            Check.equal(try? String(contentsOfFile: src + "/sections/intro.tex", encoding: .utf8), "UNSAVED\n")
            Check.equal(try? String(contentsOfFile: project.path + "/sections/intro.tex", encoding: .utf8), "intro\n", "project file untouched")
            for skipped in [".git", "sections/.svn", ".DS_Store", ".main.tex.swp", "main.tex~"] {
                Check.expect(!FileManager.default.fileExists(atPath: src + "/" + skipped) && ShadowWorkspace.readLink(src + "/" + skipped) == nil,
                             "\(skipped) is not mirrored")
            }
            Check.equal(ShadowWorkspace.readLink(src + "/.latexmkrc"), project.path + "/.latexmkrc", ".latexmkrc is mirrored (#4)")
            Check.equal(ShadowWorkspace.readLink(src + "/.hidden.tex"), project.path + "/.hidden.tex", "other hidden files are mirrored")
            Check.expect(FileManager.default.fileExists(atPath: ws.outputDirectory.path + "/sections"), "out/ mirrors directories")
            Check.equal(Set(snap.projectFiles.keys), ["main.tex", "sections/intro.tex", ".hidden.tex", ".latexmkrc"])

            // Overlay dropped → symlink again; file deleted in project → removed from mirror; stale hidden
            // entries (e.g. a temporary file of an interrupted write) are removed too.
            try? FileManager.default.removeItem(at: project.appendingPathComponent("main.tex"))
            try? FileManager.default.removeItem(at: project.appendingPathComponent(".hidden.tex"))
            Fixtures.write("new\n", to: project.appendingPathComponent("new.tex"))
            Fixtures.write("stale\n", to: URL(fileURLWithPath: src + "/.stale-hidden"))
            Fixtures.write("stale\n", to: URL(fileURLWithPath: src + "/sections/.intro.tex.gabetex-1234abcd.tmp"))
            _ = try ws.refresh(overlays: [:])
            Check.equal(ShadowWorkspace.readLink(src + "/sections/intro.tex"), project.path + "/sections/intro.tex")
            Check.expect(!FileManager.default.fileExists(atPath: src + "/main.tex") && ShadowWorkspace.readLink(src + "/main.tex") == nil, "stale entry removed")
            Check.equal(ShadowWorkspace.readLink(src + "/.hidden.tex"), nil, "stale hidden link removed")
            Check.expect(!FileManager.default.fileExists(atPath: src + "/.stale-hidden")
                         && !FileManager.default.fileExists(atPath: src + "/sections/.intro.tex.gabetex-1234abcd.tmp"), "stale hidden files removed")
            Check.equal(ShadowWorkspace.readLink(src + "/new.tex"), project.path + "/new.tex")
            // Overlay for a file that does not exist on disk yet (new unsaved file in a new folder).
            _ = try ws.refresh(overlays: [project.appendingPathComponent("drafts/x.tex"): "draft"])
            Check.equal(try? String(contentsOfFile: src + "/drafts/x.tex", encoding: .utf8), "draft")
        } catch {
            Check.fail("refresh threw \(error)")
        }
    }

    await Check.suite("ProcessRunner: stdin, large output, exit codes, timeout") {
        let sh = URL(fileURLWithPath: "/bin/sh")
        do {
            let cat = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), stdin: Data("héllo\n".utf8))
            Check.equal(cat.stdoutText, "héllo\n")
            // 4 MB on stdout and stderr at once: no pipe deadlock.
            let big = try await ProcessRunner.run(sh, arguments: ["-c", "head -c 4000000 /dev/zero; head -c 3000000 /dev/zero >&2; exit 3"],
                                                  timeout: .seconds(30))
            Check.equal(big.stdout.count, 4_000_000)
            Check.equal(big.stderr.count, 3_000_000)
            Check.equal(big.exitCode, 3)
            let env = try await ProcessRunner.run(sh, arguments: ["-c", "printf %s \"$GTX_X\"; pwd"], environment: ["GTX_X": "1", "PATH": "/bin:/usr/bin"],
                                                  currentDirectory: URL(fileURLWithPath: "/usr"))
            Check.equal(env.stdoutText, "1/usr\n")
            let clock = ContinuousClock()
            let start = clock.now
            let slow = try await ProcessRunner.run(sh, arguments: ["-c", "sleep 30"], timeout: .milliseconds(300))
            Check.expect(slow.timedOut && !slow.succeeded, "timed out")
            Check.expect(clock.now - start < .seconds(5), "timeout is prompt")
        } catch {
            Check.fail("runner threw \(error)")
        }
        do throws(ProcessRunnerError) {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"))
            Check.fail("spawning a missing tool must throw")
        } catch {
            Check.expect(error.localizedMessage.contains("/nonexistent/tool"), error.localizedMessage)
        }
    }

    await Check.suite("ProcessRunner: cancellation kills the whole process tree") {
        let marker = "gabetex-tree-\(UInt32.random(in: 0...UInt32.max))"
        // A parent shell with two looping sub-shells (like latexmk → pdflatex). The marker is the shell's
        // $0, which the forked sub-shells inherit, so `pgrep -f` sees all three. (macOS' sleep rejects
        // extra operands, so the marker cannot be passed to sleep itself.)
        let loop = "(while :; do sleep 1; done)"
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                        arguments: ["-c", "\(loop) & \(loop) & wait", marker])
        }
        var running: [Int32] = []
        for _ in 0..<50 {
            running = await pgrep(marker)
            if running.count >= 3 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Check.expect(running.count >= 3, "shell and both sub-shells started (\(running.count))")
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let output = try? await task.value
        Check.expect(output?.cancelled == true, "cancelled flag set")
        Check.expect(clock.now - start < .seconds(5), "cancellation is prompt")
        try? await Task.sleep(for: .milliseconds(200))
        Check.equal(await pgrep(marker), [], "no orphaned grandchildren")
    }

    await Check.suite("AsyncLock: FIFO, cancellation while waiting") {
        let lock = AsyncLock()
        Check.expect(await lock.acquire())
        let waiter = Task { await lock.acquire() }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        Check.equal(await waiter.value, false, "a cancelled waiter gives up")
        let second = Task { () -> Bool in
            let ok = await lock.acquire()
            if ok { lock.release() }
            return ok
        }
        try? await Task.sleep(for: .milliseconds(50))
        lock.release()
        Check.equal(await second.value, true, "next waiter gets the lock")
        Check.expect(await lock.acquire(), "lock is free again")
        lock.release()
    }
}

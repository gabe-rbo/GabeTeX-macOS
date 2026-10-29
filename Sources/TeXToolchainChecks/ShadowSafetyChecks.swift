import Foundation
import CheckKit
import TeXCore
@testable import TeXToolchain

/// Regression checks (review 2026-10-28) that need no TeX run: symlinked folders are never written
/// through (#1), the ancestor layer (#3), overlay encodings (#9) and `terminateAll` (#12).
@MainActor
func shadowSafetyChecks() async {
    await Check.suite("ShadowWorkspace: overlays below a symlinked folder never reach the real files (#1a)") {
        let base = Fixtures.scratch("symlink-unit")
        let shared = base.appendingPathComponent("shared/chapters")
        let project = base.appendingPathComponent("proj")
        Fixtures.write("REAL ONE\n", to: shared.appendingPathComponent("one.tex"))
        Fixtures.write("REAL TWO\n", to: shared.appendingPathComponent("sub/two.tex"))
        Fixtures.write("main\n", to: project.appendingPathComponent("main.tex"))
        Check.expect((try? FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("chapters").path,
                                                                 withDestinationPath: "../shared/chapters")) != nil, "symlink created")
        _ = chmod(shared.appendingPathComponent("one.tex").path, 0o640)
        let before = fingerprint(base.appendingPathComponent("shared"))
        let ws = ShadowWorkspace(projectDirectory: project, root: base.appendingPathComponent("shadow"))
        let src = ws.sourceDirectory.path
        do {
            let snap = try ws.refresh(overlays: [
                project.appendingPathComponent("chapters/one.tex"): "OVERLAY ONE\n",
                project.appendingPathComponent("chapters/sub/two.tex"): "OVERLAY TWO\n",
                project.appendingPathComponent("chapters/new/three.tex"): "NEW\n",
            ])
            Check.equal(ShadowWorkspace.readLink(src + "/chapters"), nil, "the linked folder is materialized as a real directory")
            Check.equal(ShadowWorkspace.readLink(src + "/chapters/sub"), nil, "… recursively along the overlay's path")
            Check.equal(readText(src + "/chapters/one.tex"), "OVERLAY ONE\n")
            Check.equal(ShadowWorkspace.readLink(src + "/chapters/one.tex"), nil, "the overlay is a real file in the shadow")
            Check.equal(readText(src + "/chapters/sub/two.tex"), "OVERLAY TWO\n")
            Check.equal(readText(src + "/chapters/new/three.tex"), "NEW\n")
            Check.expect(snap.projectFiles["chapters/one.tex"] != nil && snap.projectFiles["chapters/sub/two.tex"] != nil,
                         "files of materialized folders are project files: \(snap.projectFiles.keys.sorted())")
            Check.equal(fingerprint(base.appendingPathComponent("shared")), before,
                        "real files byte-identical (same inode, mode, mtime) and no stray files next to them")

            // Overlays gone → the folder is a single symlink again; nothing was ever written into shared/.
            _ = try ws.refresh(overlays: [:])
            Check.equal(ShadowWorkspace.readLink(src + "/chapters"), project.path + "/chapters", "back to one symlink")
            Check.equal(fingerprint(base.appendingPathComponent("shared")), before, "still untouched")

            // The root document below a symlinked folder: its directory is materialized too (pinned).
            let pinned = try ws.refresh(overlays: [:], pinned: [project.appendingPathComponent("chapters/sub/two.tex")])
            Check.equal(ShadowWorkspace.readLink(src + "/chapters/sub"), nil, "cwd of a pinned root is a real shadow folder")
            Check.expect(pinned.projectFiles["chapters/sub/two.tex"] != nil, "pinned root is a known project file")
        } catch {
            Check.fail("refresh threw \(error)")
        }
    }

    await Check.suite("ShadowWorkspace.writeAtomically: hard guard against escaping the mirror (#1b)") {
        let base = Fixtures.scratch("guard-unit")
        let src = base.appendingPathComponent("src").path
        let outside = base.appendingPathComponent("outside").path
        try? FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        _ = symlink(outside, src + "/escape")
        for (path, label) in [(src + "/escape/x.tex", "through a symlinked folder"),
                              (src + "/../outside/y.tex", "with ../"),
                              (src + "/escape/deeper/z.tex", "below a missing folder behind a link")] {
            do throws(ShadowWorkspace.Failure) {
                try ShadowWorkspace.writeAtomically(Data("x".utf8), to: path, within: src)
                Check.fail("writeAtomically must refuse a path \(label)")
            } catch {
                Check.expect(error.message.contains("refusing") || error.message.contains("cannot resolve"),
                             "refused \(label): \(error.message)")
            }
        }
        Check.equal((try? FileManager.default.contentsOfDirectory(atPath: outside)) ?? ["?"], [], "nothing created outside")
        do throws(ShadowWorkspace.Failure) {
            try ShadowWorkspace.writeAtomically(Data("ok".utf8), to: src + "/ok.tex", within: src)
            // Replaces a symlink instead of following it.
            _ = symlink(outside + "/target.tex", src + "/link.tex")
            try ShadowWorkspace.writeAtomically(Data("over".utf8), to: src + "/link.tex", within: src)
        } catch {
            Check.fail("a write inside the mirror must succeed: \(error.message)")
        }
        Check.equal(readText(src + "/ok.tex"), "ok")
        Check.equal(ShadowWorkspace.readLink(src + "/link.tex"), nil, "the symlink itself was replaced")
        Check.expect(!FileManager.default.fileExists(atPath: outside + "/target.tex"), "its target was not created")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: src)) ?? []).filter { $0.hasSuffix(".tmp") }
        Check.equal(leftovers, [], "no temporary files left behind")
    }

    await Check.suite("ShadowWorkspace: ancestor layer mirrors the folders above the project (#3)") {
        let base = Fixtures.scratch("ancestor-unit")
        let project = base.appendingPathComponent("papers/paper1")
        Fixtures.write("main\n", to: project.appendingPathComponent("main.tex"))
        Fixtures.write("macros\n", to: base.appendingPathComponent("papers/macros.tex"))
        Fixtures.write("defs\n", to: base.appendingPathComponent("common/defs.tex"))
        Fixtures.write("x\n", to: base.appendingPathComponent("papers/.git/HEAD"))
        let ws = ShadowWorkspace(projectDirectory: project, root: base.appendingPathComponent("shadow"))
        Check.equal(ws.layout.components.count, ShadowWorkspace.ancestorLevels)
        Check.equal(ws.layout.components.last, "paper1")
        do {
            _ = try ws.refresh(overlays: [:])
        } catch {
            Check.fail("refresh threw \(error)")
        }
        let src = ws.sourceDirectory
        let parent = src.deletingLastPathComponent().path            // mirror of base/papers
        let grandparent = src.deletingLastPathComponent().deletingLastPathComponent().path   // mirror of base
        Check.equal(ShadowWorkspace.readLink(parent + "/macros.tex"), base.path + "/papers/macros.tex", "sibling file linked")
        Check.equal(ShadowWorkspace.readLink(grandparent + "/common"), base.path + "/common", "sibling folder linked (2 levels up)")
        Check.equal(ShadowWorkspace.readLink(grandparent + "/papers"), nil, "folders on the way down are real")
        Check.expect(!FileManager.default.fileExists(atPath: parent + "/.git"), "VCS folders are not mirrored in the ancestor layer")
        Check.equal(readText(src.path + "/../../common/defs.tex"), "defs\n", "../../common/defs.tex resolves in the shadow")

        let mapper = ws.pathMapper
        Check.equal(mapper.projectURL(forShadowPath: src.path + "/../macros.tex")?.path, base.path + "/papers/macros.tex",
                    "ancestor-layer path maps back to the real file")
        Check.equal(mapper.projectURL(forShadowPath: src.path + "/./main.tex")?.path, project.path + "/main.tex")
        Check.equal(mapper.shadowURL(forProjectURL: base.appendingPathComponent("common/defs.tex")).standardizedFileURL.path,
                    URL(fileURLWithPath: grandparent + "/common/defs.tex").standardizedFileURL.path)
        Check.equal(mapper.projectURL(forShadowPath: ws.outputDirectory.path + "/main.aux"), nil, "out/ is not mapped")
        Check.equal(LaTeXCompiler.projectFile(forLogPath: "../macros.tex", cwd: src.path, mapper: mapper,
                                              projectDirectory: project, projectFiles: [:])?.path,
                    base.path + "/papers/macros.tex", "log paths with ../ map to the real file")
        Check.equal(LaTeXCompiler.projectFile(forLogPath: "../nothere.tex", cwd: src.path, mapper: mapper,
                                              projectDirectory: project, projectFiles: [:]), nil)
    }

    await Check.suite("LaTeXCompiler.projectFile: case-insensitive fallback to the on-disk spelling (#5)") {
        let project = URL(fileURLWithPath: "/nonexistent-gtx/p")
        let mapper = ShadowPathMapper(projectDirectory: project, shadowDirectory: URL(fileURLWithPath: "/nonexistent-gtx/s/tree/p"))
        let cwd = "/nonexistent-gtx/s/tree/p"
        let files: [String: URL] = [
            "chapters/intro.tex": URL(fileURLWithPath: "/nonexistent-gtx/p/chapters/intro.tex"),
            "Seções/capítulo.tex": URL(fileURLWithPath: "/nonexistent-gtx/p/Seções/capítulo.tex"),
            "a.tex": URL(fileURLWithPath: "/nonexistent-gtx/p/a.tex"),
            "A.tex": URL(fileURLWithPath: "/nonexistent-gtx/p/A.tex"),
        ]
        func map(_ raw: String, folded: Bool = false) -> String? {
            LaTeXCompiler.projectFile(forLogPath: raw, cwd: cwd, mapper: mapper, projectDirectory: project, projectFiles: files,
                                      foldedProjectFiles: folded ? LaTeXCompiler.foldedIndex(files) : nil)?.path
        }
        Check.equal(map("./chapters/intro.tex"), "/nonexistent-gtx/p/chapters/intro.tex", "exact")
        Check.equal(map("./Chapters/Intro.tex"), "/nonexistent-gtx/p/chapters/intro.tex", "\\input{Chapters/Intro} → on-disk spelling")
        Check.equal(map("CHAPTERS/INTRO.TEX", folded: true), "/nonexistent-gtx/p/chapters/intro.tex", "with a precomputed index")
        let nfd = "./SEÇÕES/CAPÍTULO.tex".decomposedStringWithCanonicalMapping
        Check.equal(map(nfd), "/nonexistent-gtx/p/Seções/capítulo.tex", "case + Unicode normalization")
        Check.equal(map("./A.tex"), "/nonexistent-gtx/p/A.tex", "the exact spelling wins")
        Check.equal(map("./a.TEX"), nil, "ambiguous case-insensitive matches are not guessed")
        Check.equal(map("./other.tex"), nil)
    }

    await Check.suite("ShadowWorkspace: overlays are written in their encoding (#9)") {
        let base = Fixtures.scratch("encoding-unit")
        let project = base.appendingPathComponent("proj")
        let latin = project.appendingPathComponent("latin.tex")
        let euro = project.appendingPathComponent("euro.tex")
        let plain = project.appendingPathComponent("plain.tex")
        Fixtures.write("x", to: latin)
        let ws = ShadowWorkspace(projectDirectory: project, root: base.appendingPathComponent("shadow"))
        do {
            _ = try ws.refresh(overlays: [latin: "ação AÇÃO\n", euro: "5 €\n", plain: "ação\n"],
                               encodings: [latin: .isoLatin1, URL(fileURLWithPath: euro.path + "/../euro.tex"): .isoLatin1])
        } catch {
            Check.fail("refresh threw \(error)")
        }
        let src = ws.sourceDirectory.path
        Check.equal(FileManager.default.contents(atPath: src + "/latin.tex"), "ação AÇÃO\n".data(using: .isoLatin1), "Latin-1 bytes")
        Check.equal(FileManager.default.contents(atPath: src + "/euro.tex"), Data("5 €\n".utf8), "€ is not Latin-1 → UTF-8 fallback")
        Check.equal(FileManager.default.contents(atPath: src + "/plain.tex"), Data("ação\n".utf8), "no encoding → UTF-8")
        Check.equal(readText(latin.path), "x", "project file untouched")
    }

    await Check.suite("ProcessRunner.terminateAll: synchronous SIGKILL of every live group (#12)") {
        let marker = "gabetex-kill-\(UInt32.random(in: 0...UInt32.max))"
        let spared = "gabetex-spared-\(UInt32.random(in: 0...UInt32.max))"
        let loop = "(while :; do sleep 1; done)"
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "\(loop) & \(loop) & wait", marker])
        }
        let keep = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "\(loop) & wait", spared],
                                        killOnTerminateAll: false)
        }
        var running: [Int32] = []
        for _ in 0..<50 {
            running = await pgrep(marker)
            let sparedRunning = await pgrep(spared)
            if running.count >= 3 && !sparedRunning.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Check.expect(running.count >= 3, "shell and both sub-shells started (\(running.count))")
        let killed = ProcessRunner.terminateAll()
        Check.expect(killed >= 1, "at least one group killed (\(killed))")
        Check.equal(await pgrep(marker), [], "nothing of the group survives, right after the call")
        Check.expect(!(await pgrep(spared)).isEmpty, "processes registered with killOnTerminateAll: false are spared")
        let clock = ContinuousClock()
        let start = clock.now
        let output = try? await task.value
        Check.expect(output?.cancelled == true, "the waiting task reports cancellation")
        Check.expect(clock.now - start < .seconds(5), "the waiting task returns promptly")
        keep.cancel()
        _ = try? await keep.value
        try? await Task.sleep(for: .milliseconds(200))
        Check.equal(await pgrep(spared), [], "normal cancellation still works")
        Check.equal(ProcessGroupRegistry.registeredGroups, [], "registry empty once everything exited")
        // Ordinary runs still work afterwards and unregister themselves.
        let echo = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["ok"])
        Check.equal(echo?.stdoutText, "ok\n")
        Check.equal(echo?.cancelled, false)
        Check.equal(ProcessGroupRegistry.registeredGroups, [])
    }
}

/// Contents of a text file (nil if missing).
func readText(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
}

/// One line per entry below `directory` (not following symlinks): path, type, inode, mode, mtime and the
/// contents of regular files — equal fingerprints mean nothing was modified, replaced or added.
func fingerprint(_ directory: URL) -> [String] {
    var lines: [String] = []
    ShadowWorkspace.walk(directory: directory.path, relative: "", skipping: { _ in false }) { rel, type in
        let path = directory.path + "/" + rel
        var info = stat()
        _ = lstat(path, &info)
        let data = type == .regular ? (FileManager.default.contents(atPath: path) ?? Data()) : Data()
        lines.append("\(rel)|\(type)|\(info.st_ino)|\(String(info.st_mode, radix: 8))|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(data.base64EncodedString())")
        return true
    }
    return lines
}

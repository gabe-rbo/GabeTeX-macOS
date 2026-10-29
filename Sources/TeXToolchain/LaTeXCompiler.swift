import Foundation
import Darwin
import TeXCore

/// Runs latexmk in a shadow workspace (ARCHITECTURE.md §Shadow workspace). One instance per project.
///
/// - `compile` mirrors the project — and the folders up to `ShadowWorkspace.ancestorLevels` above it, so
///   `../` inputs work — into `<shadow>/tree` (symlinks + the request's unsaved overlays, written in their
///   `overlayEncodings`), runs `latexmk` with cwd = the root file's shadow directory and `-outdir` = the
///   matching directory of `<shadow>/out`, then parses the TeX log, the bibliography log and latexmk's output.
/// - Nothing is ever written into the user's files (only `.build` copies the PDF next to the root file).
/// - Only one compile runs per project at a time (also across `LaTeXCompiler` instances): a new request
///   waits until the previous run — typically just cancelled — has exited.
/// - Cancelling the calling task terminates the whole TeX process tree promptly and returns `.cancelled`.
public actor LaTeXCompiler {
    public let distribution: TeXDistribution
    /// Folder that holds one shadow workspace per project.
    public nonisolated let shadowRoot: URL

    /// `~/Library/Caches/io.github.gabe-rbo.GabeTeX/Shadow`.
    public static var defaultShadowRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("io.github.gabe-rbo.GabeTeX", isDirectory: true)
            .appendingPathComponent("Shadow", isDirectory: true)
    }

    public init(distribution: TeXDistribution) {
        self.init(distribution: distribution, shadowRoot: nil)
    }

    /// - Parameter shadowRoot: where shadow workspaces live (default `defaultShadowRoot`).
    public init(distribution: TeXDistribution, shadowRoot: URL?) {
        self.distribution = distribution
        self.shadowRoot = (shadowRoot ?? Self.defaultShadowRoot).standardizedFileURL
    }

    /// Synchronously kills (SIGKILL) every TeX process group started by this module that is still
    /// running (latexmk with its pdflatex/bibtex children, chktex, synctex, kpsewhich …; never a tlmgr
    /// install). Call from `applicationWillTerminate` — Task cancellation is asynchronous and would race
    /// with process exit, leaving e.g. a looping pdflatex at 100 % CPU after the app quits. Lock-free and
    /// non-blocking; compiles that were running return `.cancelled`.
    public nonisolated static func terminateAllRunningProcesses() {
        ProcessRunner.terminateAll()
    }

    /// The shadow workspace of a project (stable per project path): contains `tree/` (the mirror) and `out/`.
    public nonisolated func shadowDirectory(for projectDirectory: URL) -> URL {
        shadowRoot.appendingPathComponent(ShadowWorkspace.identifier(for: projectDirectory), isDirectory: true)
    }

    /// The mapper between project paths and the shadow mirror — the same value every
    /// `CompileResult.pathMapper` of this project carries.
    public nonisolated func pathMapper(for projectDirectory: URL) -> ShadowPathMapper {
        ShadowWorkspace(projectDirectory: projectDirectory, root: shadowDirectory(for: projectDirectory)).pathMapper
    }

    /// Removes the shadow workspace (mirror and auxiliary files) of a project. Waits for a running compile.
    public func clean(projectDirectory: URL) async {
        let workspace = ShadowWorkspace(projectDirectory: projectDirectory.standardizedFileURL,
                                        root: shadowDirectory(for: projectDirectory))
        let lock = WorkspaceLocks.lock(for: workspace.root.path)
        guard await lock.acquire() else { return }
        defer { lock.release() }
        workspace.remove()
    }

    // MARK: Compile

    public func compile(_ request: CompileRequest) async -> CompileResult {
        let clock = ContinuousClock()
        let started = clock.now
        let projectDirectory = request.projectDirectory.standardizedFileURL
        let workspace = ShadowWorkspace(projectDirectory: projectDirectory, root: shadowDirectory(for: projectDirectory))
        let mapper = workspace.pathMapper
        func elapsed() -> TimeInterval {
            let c = (clock.now - started).components
            return Double(c.seconds) + Double(c.attoseconds) / 1e18
        }
        func early(_ status: CompileStatus, toolOutput: String = "") -> CompileResult {
            CompileResult(status: status, toolOutput: toolOutput, duration: elapsed(), pathMapper: mapper)
        }

        let lock = WorkspaceLocks.lock(for: workspace.root.path)
        guard await lock.acquire() else { return early(.cancelled) }
        defer { lock.release() }
        if Task.isCancelled { return early(.cancelled) }

        guard let latexmk = distribution.url(for: .latexmk) else {
            return early(.toolError(String(localized: "latexmk was not found in \(distribution.name).")))
        }
        let rootPath = request.rootFile.standardizedFileURL.path
        guard rootPath.hasPrefix(projectDirectory.path + "/") else {
            return early(.toolError(String(localized: "The root document is not inside the project folder.")))
        }
        let rootRelative = String(rootPath.dropFirst(projectDirectory.path.count + 1))
        let rootRelativeDirectory = (rootRelative as NSString).deletingLastPathComponent
        let rootName = (rootRelative as NSString).lastPathComponent
        let jobname = (rootName as NSString).deletingPathExtension

        let snapshot: ShadowWorkspace.Snapshot
        do {
            snapshot = try workspace.refresh(overlays: request.overlays, encodings: request.overlayEncodings,
                                             pinned: [request.rootFile])
        } catch {
            return early(.toolError(error.message))
        }
        guard snapshot.projectFiles[rootRelative.precomposedStringWithCanonicalMapping] != nil else {
            return early(.toolError(String(localized: "The root document \(rootName) does not exist.")))
        }
        if Task.isCancelled { return early(.cancelled) }

        let cwd = rootRelativeDirectory.isEmpty ? workspace.sourceDirectory
            : workspace.sourceDirectory.appendingPathComponent(rootRelativeDirectory, isDirectory: true)
        // TeX may write next to its input (minted, \write18 …): never run it inside the user's folders.
        let realTree = ShadowWorkspace.realPath(workspace.treeDirectory.path) ?? workspace.treeDirectory.path
        guard let realCwd = ShadowWorkspace.realPath(cwd.path), realCwd.hasPrefix(realTree + "/") || realCwd == realTree else {
            return early(.toolError(String(localized: "Could not prepare the build folder for \(rootName).")))
        }
        let outDirectory = rootRelativeDirectory.isEmpty ? workspace.outputDirectory
            : workspace.outputDirectory.appendingPathComponent(rootRelativeDirectory, isDirectory: true)
        let arguments = Self.latexmkArguments(engine: request.engine, outputDirectory: outDirectory,
                                              shellEscape: request.shellEscape, extra: request.extraArguments,
                                              rootFileName: rootName)
        let timeout = request.timeout ?? (request.purpose == .live ? .seconds(300) : .seconds(1800))
        var environment = distribution.processEnvironment
        // bibtex runs from the compile folder (see latexmkArguments) and writes .bbl/.blg to the absolute
        // out/ path; older bibtex versions only allow that below TEXMFOUTPUT (openout_any = p).
        environment["TEXMFOUTPUT"] = workspace.outputDirectory.path

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(latexmk, arguments: arguments,
                                                 environment: environment,
                                                 currentDirectory: cwd, timeout: timeout)
        } catch {
            return early(.toolError(error.localizedMessage))
        }
        let toolOutput = output.combinedText
        if output.cancelled || Task.isCancelled { return early(.cancelled, toolOutput: toolOutput) }

        let logPath = outDirectory.appendingPathComponent(jobname + ".log").path
        guard let logData = FileManager.default.contents(atPath: logPath) else {
            let reason = Self.lastLines(of: toolOutput, count: 12)
            return early(.toolError(reason.isEmpty
                ? String(localized: "latexmk did not run TeX (exit status \(output.exitCode ?? -1)).")
                : String(localized: "latexmk did not run TeX: \(reason)")), toolOutput: toolOutput)
        }
        let log = String(decoding: logData, as: UTF8.self)

        // Diagnostics ------------------------------------------------------------------------------
        let projectRootURL = projectDirectory
        let projectFiles = snapshot.projectFiles
        let foldedProjectFiles = Self.foldedIndex(projectFiles)
        let cwdPath = cwd.path
        let mapLogPath: (String) -> URL? = { raw in
            Self.projectFile(forLogPath: raw, cwd: cwdPath, mapper: mapper, projectDirectory: projectRootURL,
                             projectFiles: projectFiles, foldedProjectFiles: foldedProjectFiles)
        }
        let rootURL = projectFiles[rootRelative.precomposedStringWithCanonicalMapping] ?? request.rootFile.standardizedFileURL
        var diagnostics = TeXLogParser.parse(log: log, mapPath: mapLogPath)

        let summary = TeXLogParser.parseLatexmkOutput(toolOutput)
        let fdb = (try? String(contentsOfFile: outDirectory.appendingPathComponent(jobname + ".fdb_latexmk").path, encoding: .utf8))
            .map { Self.bibliographyRules(inFdb: $0) } ?? []
        let rootText = request.overlays[request.rootFile.standardizedFileURL]
            ?? request.overlays.first(where: { $0.key.standardizedFileURL.path == rootPath })?.value
            ?? Self.readText(atPath: rootPath)
        diagnostics += bibliographyDiagnostics(rules: fdb, summary: summary, outDirectory: outDirectory, jobname: jobname,
                                               rootURL: rootURL, rootText: rootText, mapPath: mapLogPath,
                                               projectFiles: projectFiles)
        diagnostics += summary.diagnostics.filter { $0.source != .biber && $0.source != .bibtex }

        // "! LaTeX Error: File `x.sty' not found." has no l.N context: point at the line that requests it.
        diagnostics = diagnostics.map { d in
            guard d.line == nil, let name = d.missingFile, let url = d.fileURL else { return d }
            let text = request.overlays.first(where: { $0.key.standardizedFileURL.path == url.path })?.value
                ?? Self.readText(atPath: url.path)
            guard let text, let line = Self.missingFileLine(in: text, name: name) else { return d }
            var located = d
            located.line = line
            return located
        }
        let realRootDirectory = rootRelativeDirectory.isEmpty ? projectDirectory
            : projectDirectory.appendingPathComponent(rootRelativeDirectory, isDirectory: true)
        diagnostics += Self.unreachableInputDiagnostics(for: diagnostics, rootDirectory: realRootDirectory, rootURL: rootURL)

        if output.timedOut {
            let seconds = timeout.components.seconds
            diagnostics.append(Diagnostic(severity: .error, source: .latexmk,
                                          message: String(localized: "Compilation was stopped after \(seconds) seconds. The document may contain an endless loop."),
                                          fileURL: rootURL))
        }
        if !diagnostics.contains(where: { $0.severity == .error }), let code = output.exitCode, code != 0 {
            diagnostics.append(Diagnostic(severity: .error, source: .latexmk,
                                          message: String(localized: "latexmk reported a problem (exit status \(code))."),
                                          detail: Self.lastLines(of: toolOutput, count: 15), fileURL: rootURL))
        }
        diagnostics = TeXLogParser.normalized(diagnostics)
        let status: CompileStatus = diagnostics.contains(where: { $0.severity == .error }) ? .failed : .succeeded

        // Outputs ----------------------------------------------------------------------------------
        let pdfURL = Self.pdfLocation(toolOutput: toolOutput, defaultURL: outDirectory.appendingPathComponent(jobname + ".pdf"))
        let synctex = outDirectory.appendingPathComponent(jobname + ".synctex.gz")
        let synctexURL = FileManager.default.fileExists(atPath: synctex.path) ? synctex : nil
        var exported: URL?
        if request.purpose == .build, let pdfURL, !log.contains("\nNo pages of output.") {
            let destinationDirectory = rootRelativeDirectory.isEmpty ? projectDirectory
                : projectDirectory.appendingPathComponent(rootRelativeDirectory, isDirectory: true)
            let destination = destinationDirectory.appendingPathComponent(jobname + ".pdf")
            do {
                try Self.copyAtomically(from: pdfURL, to: destination)
                exported = destination
            } catch {
                diagnostics.append(Diagnostic(severity: .warning, source: .latexmk,
                                              message: String(localized: "Could not copy the PDF to \(destination.path): \(error.localizedDescription)")))
            }
        }

        var missing: [String] = []
        for name in diagnostics.compactMap(\.missingFile) + summary.missingFiles
        where Self.isPackageFile(name) && !missing.contains(name) {
            missing.append(name)
        }

        return CompileResult(status: status, pdfURL: pdfURL, exportedPDFURL: exported, synctexURL: synctexURL,
                             diagnostics: diagnostics, log: log, toolOutput: toolOutput, duration: elapsed(),
                             missingFiles: missing, pathMapper: mapper)
    }

    // MARK: Bibliography

    /// A `["bibtex <base>"]` / `["biber <base>"]` rule of latexmk's `.fdb_latexmk` and its last exit status.
    struct BibliographyRule: Sendable, Equatable {
        var tool: DiagnosticSource   // .bibtex or .biber
        var base: String             // absolute path without extension
        var lastExitCode: Int?
    }

    static func bibliographyRules(inFdb text: String) -> [BibliographyRule] {
        var rules: [BibliographyRule] = []
        for line in text.split(separator: "\n") where line.hasPrefix("[\"bibtex ") || line.hasPrefix("[\"biber ") {
            guard let close = line.range(of: "\"]") else { continue }
            let name = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]
            guard let space = name.firstIndex(of: " ") else { continue }
            let tool: DiagnosticSource = name[..<space] == "biber" ? .biber : .bibtex
            let base = String(name[name.index(after: space)...])
            let lastToken = line.split(separator: " ").last.map(String.init)
            rules.append(BibliographyRule(tool: tool, base: base, lastExitCode: lastToken.flatMap { Int($0) }))
        }
        return rules
    }

    private func bibliographyDiagnostics(rules: [BibliographyRule], summary: LatexmkOutputSummary, outDirectory: URL,
                                         jobname: String, rootURL: URL, rootText: String?,
                                         mapPath: @escaping (String) -> URL?, projectFiles: [String: URL]) -> [Diagnostic] {
        var result: [Diagnostic] = []
        let mapBib: (String) -> URL? = { name in
            if let url = mapPath(name) { return url }
            // bibtex/biber find databases through BIBINPUTS too: fall back to a unique file-name match.
            let file = (name as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
            let matches = projectFiles.filter { ($0.key as NSString).lastPathComponent == file }
            return matches.count == 1 ? matches.first?.value : nil
        }
        var failedTools = Set(summary.diagnostics.filter { $0.severity == .error && ($0.source == .biber || $0.source == .bibtex) }.map(\.source))
        var parsedTools = Set<DiagnosticSource>()
        for rule in rules {
            let blg = rule.base + ".blg"
            if let data = FileManager.default.contents(atPath: blg) {
                let text = String(decoding: data, as: UTF8.self)
                result += TeXLogParser.parseBibliographyLog(text, source: rule.tool, mapPath: mapBib)
                parsedTools.insert(rule.tool)
            } else if let code = rule.lastExitCode, code != 0 {
                // The tool ran (in this or an earlier run) and could not even write its log; latexmk does not
                // retry it until its inputs change, so this keeps the explanation visible on later compiles.
                failedTools.insert(rule.tool)
            }
        }
        failedTools.subtract(parsedTools)
        let biblatexLine = rootText.flatMap(Self.biblatexLine(in:))
        for tool in failedTools.sorted(by: { $0.rawValue < $1.rawValue }) {
            let fromSummary = summary.diagnostics.first { $0.source == tool && $0.severity == .error }
            var detail: [String] = []
            if tool == .biber, let problem = distribution.toolProblems[.biber] { detail.append(problem) }
            if let d = fromSummary?.detail, !d.isEmpty { detail.append(d) }
            let message = tool == .biber ? TeXLogParser.biberFailureMessage
                : (fromSummary?.message ?? String(localized: "BibTeX failed to run; the bibliography was not generated."))
            result.append(Diagnostic(severity: .error, source: tool, message: message,
                                     detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
                                     fileURL: rootURL, line: biblatexLine))
        }
        return result
    }

    /// 1-based line of `\usepackage[…]{biblatex}` (or the first `\addbibresource`/`\bibliography`).
    static func biblatexLine(in text: String) -> Int? {
        var fallback: Int?
        var lineNumber = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            let code = line.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if code.contains("\\usepackage") && code.contains("biblatex") { return lineNumber }
            if fallback == nil && (code.contains("\\addbibresource") || code.contains("\\bibliography{")) { fallback = lineNumber }
        }
        return fallback
    }

    /// 1-based line whose (uncommented) code names `name` — or `name` without a .sty/.cls/.tex extension —
    /// as an item of a `{…}` argument, e.g. `\usepackage{a,name}` or `\input{chapters/name}`.
    static func missingFileLine(in text: String, name: String) -> Int? {
        var candidates: Set<String> = [name]
        let ext = (name as NSString).pathExtension.lowercased()
        if ["sty", "cls", "tex"].contains(ext) { candidates.insert((name as NSString).deletingPathExtension) }
        var lineNumber = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            let code = uncommented(line)
            var index = code.startIndex
            while let open = code[index...].firstIndex(of: "{") {
                guard let close = code[open...].firstIndex(of: "}") else { break }
                let items = code[code.index(after: open)..<close].split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if items.contains(where: { candidates.contains($0) }) { return lineNumber }
                index = code.index(after: close)
            }
        }
        return nil
    }

    /// The part of a source line before its first unescaped `%`.
    static func uncommented(_ line: Substring) -> Substring {
        var escaped = false
        for i in line.indices {
            let c = line[i]
            if c == "%" && !escaped { return line[..<i] }
            escaped = c == "\\" ? !escaped : false
        }
        return line
    }

    // MARK: Helpers

    /// `-e '$bibtex_fudge = 0'`: latexmk's default runs bibtex *inside* the out directory, where
    /// `\bibliography{../refs}` can never be found (kpathsea resolves `../` names against the cwd only).
    /// Without the fudge bibtex runs from the compile folder like TeX itself; it writes to out/ (see TEXMFOUTPUT).
    static func latexmkArguments(engine: TeXEngine, outputDirectory: URL, shellEscape: Bool, extra: [String],
                                 rootFileName: String) -> [String] {
        var arguments = [engine.latexmkFlag, "-interaction=nonstopmode", "-file-line-error", "-synctex=1", "-f",
                         "-e", "$bibtex_fudge = 0;", "-outdir=\(outputDirectory.path)"]
        if shellEscape { arguments.append("-shell-escape") }
        arguments += extra
        arguments.append(rootFileName)
        return arguments
    }

    /// Maps a path from the TeX log (relative to the compile cwd, or absolute) to the project file with
    /// its on-disk spelling — or to the real file outside the project for inputs reached with `../`.
    /// nil for TeX Live files, files in out/ and anything that does not exist.
    ///
    /// On a case-insensitive volume TeX opens `\input{Chapters/Intro}` as `Chapters/Intro.tex` although the
    /// file is `chapters/intro.tex`: when the exact spelling is unknown the lookup falls back to a
    /// case-insensitive match (`foldedProjectFiles`, see `foldedIndex`; computed here when nil), so the
    /// diagnostic carries the on-disk spelling and attaches to the right buffer.
    static func projectFile(forLogPath raw: String, cwd: String, mapper: ShadowPathMapper, projectDirectory: URL,
                            projectFiles: [String: URL], foldedProjectFiles: [String: URL]? = nil) -> URL? {
        var path = raw
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
        if !path.hasPrefix("/") { path = cwd + "/" + path }
        guard let url = mapper.projectURL(forShadowPath: path) else { return nil }
        let projectPath = projectDirectory.path
        let full = url.path
        if full.hasPrefix(projectPath + "/") {
            let relative = String(full.dropFirst(projectPath.count + 1)).precomposedStringWithCanonicalMapping
            if let known = projectFiles[relative] { return known }
            let folded = foldedKey(relative)
            if let match = (foldedProjectFiles ?? foldedIndex(projectFiles))[folded] { return match }
            // Below a symlinked project folder (mirrored as a single link, so not listed).
            return isExistingFile(full) ? SyncTeX.canonicalSpelling(of: url, within: projectDirectory) : nil
        }
        // Outside the project: the ancestor layer (`\input{../macros}`).
        guard isExistingFile(full) else { return nil }
        return mapper.ancestorDirectory.map { SyncTeX.canonicalSpelling(of: url, within: $0) } ?? url
    }

    /// NFC + case-folded form of a path, for case-insensitive comparisons.
    static func foldedKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// `projectFiles` keyed by `foldedKey`. Spellings that collide (only possible on a case-sensitive
    /// volume, where the exact lookup succeeds anyway) are left out.
    static func foldedIndex(_ projectFiles: [String: URL]) -> [String: URL] {
        var index: [String: URL] = [:]
        var ambiguous: Set<String> = []
        for (key, url) in projectFiles {
            let folded = foldedKey(key)
            if index.updateValue(url, forKey: folded) != nil { ambiguous.insert(folded) }
        }
        for folded in ambiguous { index[folded] = nil }
        return index
    }

    static func isExistingFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// File contents as text: UTF-8, else ISO Latin-1 (legacy `inputenc{latin1}` documents).
    static func readText(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Explains inputs like `\input{../../../../x}` that TeX could not find although they exist relative to
    /// the real root folder: they are beyond the folders mirrored by the shadow workspace.
    static func unreachableInputDiagnostics(for diagnostics: [Diagnostic], rootDirectory: URL, rootURL: URL) -> [Diagnostic] {
        var result: [Diagnostic] = []
        var seen: Set<String> = []
        for d in diagnostics {
            guard let name = d.missingFile, name.hasPrefix("../") || name.contains("/../") else { continue }
            let base = URL(fileURLWithPath: ShadowPathMapper.lexicallyStandardized(rootDirectory.path + "/" + name))
            var candidates = [base]
            if base.pathExtension.isEmpty {
                candidates += ["tex", "bib", "pdf", "png", "jpg", "eps"].map { base.appendingPathExtension($0) }
            }
            guard let found = candidates.first(where: { isExistingFile($0.path) }), seen.insert(found.path).inserted else { continue }
            let levels = ShadowWorkspace.ancestorLevels
            result.append(Diagnostic(
                severity: .error, source: .latexmk,
                message: String(localized: "\(found.path) exists, but the background compiler cannot reach it: it only mirrors the project folder and the \(levels) folders above it. Open a folder that contains this file as the project."),
                fileURL: d.fileURL ?? rootURL, line: d.line))
        }
        return result
    }

    /// The PDF latexmk reports ("Log file says output to '…pdf'"), else `defaultURL`; nil if it does not exist.
    static func pdfLocation(toolOutput: String, defaultURL: URL) -> URL? {
        let marker = "Latexmk: Log file says output to '"
        if let r = toolOutput.range(of: marker, options: .backwards) {
            let rest = toolOutput[r.upperBound...]
            if let end = rest.firstIndex(of: "'") {
                let path = String(rest[..<end])
                if path.hasSuffix(".pdf"), FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path).standardizedFileURL
                }
            }
        }
        return FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : nil
    }

    /// Names a TeX Live package can provide (for the installer): no directory part and a package-ish extension.
    static func isPackageFile(_ name: String) -> Bool {
        guard !name.contains("/") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["sty", "cls", "def", "cfg", "clo", "fd", "ldf", "bst", "bbx", "cbx", "lbx", "dbx", "tfm", "otf",
                "ttf", "pfb", "map", "enc", "lua"].contains(ext) && name.count > ext.count + 1
    }

    static func lastLines(of text: String, count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.allSatisfy { $0 == " " || $0 == "-" } }
            .suffix(count).joined(separator: "\n")
    }

    /// Copies to a temporary file in the destination directory, then renames it over the destination.
    static func copyAtomically(from source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).gabetex-\(UUID().uuidString.prefix(8))")
        try FileManager.default.copyItem(at: source, to: temporary)
        if rename(temporary.path, destination.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
}

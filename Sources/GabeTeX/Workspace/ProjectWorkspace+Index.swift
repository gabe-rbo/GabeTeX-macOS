import SwiftUI
import TeXCore
import TeXToolchain
import EditorKit

// MARK: - Edits, project index, linting and merged diagnostics

extension ProjectWorkspace {
    static let lintableExtensions: Set<String> = ["tex", "ltx", "sty", "cls"]

    /// Called by the editor after every edit of `buffer` (after `noteEdit()`).
    func bufferDidChange(_ buffer: SourceBuffer) {
        updateWindowEdited()
        scheduleStructureLint(for: buffer)
        scheduleChkTeX(for: buffer)
        scheduleIndexRefresh()
        scheduleLiveCompile()
    }

    /// The engine used for compiling: `% !TEX program` > project setting > default.
    var effectiveEngine: TeXEngine {
        if let magic = index?.magicComments.program, let engine = TeXEngine(magicProgram: magic) { return engine }
        return engineOverride ?? settings.defaultEngine
    }

    // MARK: Index

    func scheduleIndexRefresh() {
        debounce("index", after: .milliseconds(300)) { [weak self] in await self?.refreshIndex() }
    }

    /// Rebuilds the project index and root choice off the main actor from a snapshot.
    func refreshIndex() async {
        var overlays: [URL: String] = [:]
        for (url, buffer) in buffers where buffer.isDirty { overlays[url] = buffer.text }
        let input = IndexBuilder.Input(
            folder: folderURL,
            overrideRoot: mainFileOverride,
            currentFile: currentFile,
            stickyRoot: mainFile,
            files: allFiles,
            overlays: overlays,
            rootStatus: rootStatus
        )
        let output = await Task.detached(priority: .utility) { IndexBuilder.compute(input) }.value
        if Task.isCancelled { return }

        rootStatus = output.rootStatus
        if output.rootCandidates != rootCandidates { rootCandidates = output.rootCandidates }
        let previousRoot = mainFile
        if output.root != mainFile { mainFile = output.root }
        if output.index != index {
            index = output.index
            let newSymbols = output.index?.symbols(projectFiles: output.projectFiles) ?? .empty
            if newSymbols != symbols { symbols = newSymbols }
        }
        if let previousRoot, let newRoot = output.root, previousRoot != newRoot {
            scheduleLiveCompile()
        }
    }

    // MARK: Structure lint (instant, in-process)

    func scheduleStructureLint(for buffer: SourceBuffer, immediately: Bool = false) {
        let url = buffer.url
        guard Self.lintableExtensions.contains(url.pathExtension.lowercased()) else {
            if structureDiagnostics[url] != nil {
                structureDiagnostics[url] = nil
                rebuildDiagnostics()
            }
            return
        }
        debounce("structure:\(url.path)", after: immediately ? .milliseconds(0) : .milliseconds(300)) { [weak self] in
            guard let self, let buffer = self.buffers[url] else { return }
            let text = buffer.text
            let version = buffer.changeCount
            let found = await Task.detached(priority: .userInitiated) {
                StructureLinter.diagnostics(in: text, fileURL: url)
            }.value
            guard self.buffers[url] === buffer, buffer.changeCount == version else { return }
            let previous = self.structureDiagnostics[url] ?? []
            if !Self.sameDiagnostics(found, previous) {
                self.structureDiagnostics[url] = Self.reusingIDs(found, from: previous)
                self.rebuildDiagnostics()
            }
        }
    }

    // MARK: chktex (current file, debounced)

    func scheduleChkTeX(for buffer: SourceBuffer) {
        let url = buffer.url
        guard settings.chktexEnabled, Self.lintableExtensions.contains(url.pathExtension.lowercased()) else { return }
        debounce("chktex:\(url.path)", after: .milliseconds(1500)) { [weak self] in
            guard let self, self.settings.chktexEnabled, self.currentFile == url,
                  let buffer = self.buffers[url] else { return }
            await self.toolchain.ensureLocated()
            guard let distribution = self.toolchain.distribution, distribution.url(for: .chktex) != nil else { return }
            let text = buffer.text
            let version = buffer.changeCount
            let found = await ChkTeXLinter(distribution: distribution).lint(text: text, fileURL: url)
            guard self.buffers[url] === buffer, buffer.changeCount == version, self.settings.chktexEnabled else { return }
            let previous = self.chktexDiagnostics[url] ?? []
            if !Self.sameDiagnostics(found, previous) {
                self.chktexDiagnostics[url] = Self.reusingIDs(found, from: previous)
                self.rebuildDiagnostics()
            }
        }
    }

    /// Settings changed: clear or refresh chktex results.
    func applyChkTeXSetting() {
        if settings.chktexEnabled {
            if let buffer = currentBuffer { scheduleChkTeX(for: buffer) }
        } else if !chktexDiagnostics.isEmpty {
            chktexDiagnostics = [:]
            rebuildDiagnostics()
        }
    }

    // MARK: Merged diagnostics

    /// Diagnostics = compile ∪ chktex ∪ structure lint, errors first, then by file and line.
    func rebuildDiagnostics() {
        var all = compileDiagnostics
        for list in chktexDiagnostics.values { all.append(contentsOf: list) }
        for list in structureDiagnostics.values { all.append(contentsOf: list) }
        all.sort { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            let pathA = a.fileURL?.path ?? ""
            let pathB = b.fileURL?.path ?? ""
            if pathA != pathB { return pathA.localizedStandardCompare(pathB) == .orderedAscending }
            return (a.line ?? 0) < (b.line ?? 0)
        }
        guard !Self.sameDiagnostics(all, diagnostics) else { return }
        diagnostics = all

        var grouped: [URL: [Diagnostic]] = [:]
        var errors = 0, warnings = 0, others = 0
        for diagnostic in all {
            if let url = diagnostic.fileURL { grouped[url, default: []].append(diagnostic) }
            switch diagnostic.severity {
            case .error: errors += 1
            case .warning: warnings += 1
            case .badbox, .info: others += 1
            }
        }
        diagnosticsByFile = grouped
        errorCount = errors
        warningCount = warnings
        otherIssueCount = others
        if let selected = selectedIssueID, !all.contains(where: { $0.id == selected }) { selectedIssueID = nil }
    }

    func diagnostics(for url: URL?) -> [Diagnostic] {
        guard let url else { return [] }
        return diagnosticsByFile[url] ?? []
    }

    /// Gives every diagnostic in `new` the id of an identical one in `old` (same severity, source, message,
    /// place and detail), so a new compile or lint result that repeats a known problem keeps its identity:
    /// the editor keeps the underline anchored where edits have moved it, and the Issues selection survives.
    nonisolated static func reusingIDs(_ new: [Diagnostic], from old: [Diagnostic]) -> [Diagnostic] {
        guard !old.isEmpty, !new.isEmpty else { return new }
        struct Key: Hashable {
            var severity: DiagnosticSeverity
            var source: DiagnosticSource
            var message: String
            var detail: String?
            var fileURL: URL?
            var line: Int?
            var column: Int?
            var length: Int?
            init(_ d: Diagnostic) {
                severity = d.severity; source = d.source; message = d.message; detail = d.detail
                fileURL = d.fileURL; line = d.line; column = d.column; length = d.length
            }
        }
        var pool: [Key: [UUID]] = [:]
        for diagnostic in old { pool[Key(diagnostic), default: []].append(diagnostic.id) }
        return new.map { diagnostic in
            var result = diagnostic
            let key = Key(diagnostic)
            if var ids = pool[key], !ids.isEmpty {
                result.id = ids.removeFirst()
                pool[key] = ids
            }
            return result
        }
    }

    /// Gives each diagnostic the exact URL its file has in this workspace (an open buffer or a project
    /// file), repairing a different letter case or link spelling coming back from the compiler.
    func projectSpelling(of diagnostics: [Diagnostic]) -> [Diagnostic] {
        let files = Set(allFiles)
        var lowercased: [String: URL] = [:]
        var cache: [URL: URL] = [:]
        return diagnostics.map { diagnostic in
            guard let url = diagnostic.fileURL else { return diagnostic }
            let target: URL
            if let cached = cache[url] {
                target = cached
            } else if buffers[url] != nil || files.contains(url) {
                target = url
            } else {
                let canonical = canonicalURL(url)
                if buffers[canonical] != nil || files.contains(canonical) {
                    target = canonical
                } else {
                    if lowercased.isEmpty { for file in allFiles { lowercased[file.path.lowercased()] = file } }
                    target = lowercased[url.path.lowercased()] ?? url
                }
                cache[url] = target
            }
            guard target != url else { return diagnostic }
            var fixed = diagnostic
            fixed.fileURL = target
            return fixed
        }
    }

    /// Equality ignoring the random `id`, so unchanged results do not re-render the editor.
    nonisolated static func sameDiagnostics(_ a: [Diagnostic], _ b: [Diagnostic]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.severity != y.severity || x.source != y.source || x.message != y.message || x.fileURL != y.fileURL
                || x.line != y.line || x.column != y.column || x.length != y.length || x.detail != y.detail {
                return false
            }
        }
        return true
    }
}

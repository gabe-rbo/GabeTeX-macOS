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
        // Edit counters at snapshot time: the reference warnings below are only applied to text that has not
        // changed since (the index reads the unsaved text of dirty buffers, so it is live while typing).
        let versions = buffers.mapValues { $0.changeCount }
        let input = IndexBuilder.Input(
            folder: folderURL,
            overrideRoot: mainFileOverride,
            currentFile: currentFile,
            stickyRoot: mainFile,
            files: allFiles,
            overlays: overlays,
            rootStatus: rootStatus
        )
        // The reference / citation lint is pure and takes a few milliseconds: it runs right behind the index,
        // still off the main actor.
        let (output, findings) = await Task.detached(priority: .utility) { () -> (IndexBuilder.Output, [ReferenceFinding]) in
            let output = IndexBuilder.compute(input)
            return (output, output.index.map { ReferenceLinter.findings(index: $0) } ?? [])
        }.value
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
        applyReferenceFindings(findings, overlays: Set(overlays.keys), versions: versions)
        if let previousRoot, let newRoot = output.root, previousRoot != newRoot {
            scheduleLiveCompile()
        }
    }

    // MARK: Reference & citation warnings

    /// Stores the live reference / citation warnings computed from the index that was built for the snapshot
    /// (`overlays` = the files whose unsaved text it read, `versions` = every open buffer's edit counter), and
    /// refreshes the merged diagnostics. No root document (or no index) clears them. A result for text that has
    /// changed since is dropped — the edit already scheduled a newer rebuild — so underlines never land on
    /// stale positions.
    func applyReferenceFindings(_ findings: [ReferenceFinding], overlays: Set<URL>, versions: [URL: Int]) {
        for (url, buffer) in buffers where buffer.changeCount != (versions[url] ?? 0) { return }
        referenceOverlayFiles = overlays
        let diagnostics = projectSpelling(of: findings.map(\.diagnostic))
        var shadows = Set<String>()
        for (finding, diagnostic) in zip(findings, diagnostics) {
            shadows.insert(Self.shadowKey(finding.kind, path: diagnostic.fileURL?.path, key: finding.key))
        }
        // Same place, same message → same id, so the editor keeps the underline and the Issues selection survives.
        let previous = referenceDiagnostics
        let updated = Self.reusingIDs(diagnostics, from: previous)
        var changed = false
        if !Self.sameDiagnostics(updated, previous) {
            referenceDiagnostics = updated
            changed = true
        }
        if shadows != referenceShadows {
            referenceShadows = shadows
            changed = true
        }
        if changed { rebuildDiagnostics() }
    }

    /// Identity of a problem the live warnings report: a duplicate label is global, a reference or citation
    /// belongs to the file it is used in.
    nonisolated static func shadowKey(_ kind: ReferenceFinding.Kind, path: String?, key: String) -> String {
        switch kind {
        case .duplicateLabel: "label\u{1F}\(key)"
        case .undefinedReference: "ref\u{1F}\(path ?? "")\u{1F}\(key)"
        case .missingCitation: "cite\u{1F}\(path ?? "")\u{1F}\(key)"
        }
    }

    /// LaTeX's own “Reference `k' … undefined”, “Citation `k' … undefined” and “Label `k' multiply defined”
    /// warning for a key the live warnings already report: showing both would list every problem twice.
    private func isShadowedByReferenceWarning(_ diagnostic: Diagnostic) -> Bool {
        guard diagnostic.source == .tex, diagnostic.severity == .warning,
              let warning = ReferenceLinter.texWarning(diagnostic.message) else { return false }
        return referenceShadows.contains(Self.shadowKey(warning.kind, path: diagnostic.fileURL?.path, key: warning.key))
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

    /// Diagnostics = compile ∪ chktex ∪ structure lint ∪ reference & citation warnings, errors first, then by
    /// file and line.
    func rebuildDiagnostics() {
        // A buffer whose unsaved text the index was built from was closed without saving (a save schedules its
        // own rebuild): the index no longer matches the files, so rebuild it.
        if referenceOverlayFiles.contains(where: { buffers[$0] == nil }) {
            referenceOverlayFiles = []
            scheduleIndexRefresh()
        }
        var all = referenceShadows.isEmpty ? compileDiagnostics : compileDiagnostics.filter { !isShadowedByReferenceWarning($0) }
        for list in chktexDiagnostics.values { all.append(contentsOf: list) }
        for list in structureDiagnostics.values { all.append(contentsOf: list) }
        all.append(contentsOf: referenceDiagnostics)
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

import SwiftUI
import AppKit
import TeXCore
import TeXToolchain
import PreviewKit

// MARK: - Compilation (live + explicit builds)

extension ProjectWorkspace {
    var isCompiling: Bool {
        if case .compiling = compileState { return true }
        return false
    }

    /// ⌘B / toolbar: save everything, then build (the PDF is also copied next to the root file).
    func compile() { startCompile(.build, explicit: true) }

    /// Debounced background compile while typing (no-op when live compile is off).
    func scheduleLiveCompile() {
        guard settings.liveCompile else { return }
        debounce("live", after: .seconds(settings.liveDelay)) { [weak self] in
            self?.startCompile(.live)
        }
    }

    /// Starts a compile.
    ///
    /// - A live compile never interrupts a running compile of the same root and engine: the running one
    ///   finishes (so slow documents still produce a PDF while you type) and exactly one more live compile
    ///   follows if edits asked for it. Changing the root or the engine, `force`, an explicit build and
    ///   Stop cancel the running compile instead.
    /// - `explicit` is true for ⌘B and the toolbar: only then is “Nothing to compile” shown.
    /// - `saveFirst` (default: builds save all files) is false for compile-on-save, which has just saved
    ///   the current file and passes the other unsaved buffers to the compiler as overlays.
    func startCompile(_ purpose: CompilePurpose, force: Bool = false, explicit: Bool = false, saveFirst: Bool? = nil) {
        guard !stopped else { return }
        debounceTasks["live"]?.cancel()
        if purpose == .live, !force, !settings.liveCompile { return }
        guard let root = mainFile else {
            if explicit, purpose == .build {
                present(
                    title: String(localized: "Nothing to compile"),
                    message: String(localized: "Open a .tex file that contains \\documentclass, or choose one with Set as Main Document.")
                )
            }
            return
        }
        if purpose == .live, case .compiling(.build) = compileState {
            rerunLiveAfterBuild = true
            return
        }
        let signature = CompileSignature(root: root, engine: effectiveEngine)
        if purpose == .live, !force, isCompiling, inflightSignature == signature {
            rerunLiveAfterBuild = true
            return
        }
        // Files outside the watched folder send no events: look at them now, before saving or reading buffers.
        checkUnwatchedBuffers()
        if purpose == .build, saveFirst ?? true, !saveAll() { return }

        var overlays: [URL: String] = [:]
        var encodings: [URL: String.Encoding] = [:]
        for (url, buffer) in buffers where buffer.isDirty {
            overlays[url] = buffer.text
            if let format = formats[url] { encodings[url] = format.encoding }
        }
        var request = CompileRequest(
            projectDirectory: folderURL,
            rootFile: root,
            engine: signature.engine,
            overlays: overlays,
            purpose: purpose
        )
        request.overlayEncodings = encodings

        compileTask?.cancel()
        compileGeneration += 1
        let generation = compileGeneration
        inflightSignature = signature
        rerunLiveAfterBuild = false
        compileState = .compiling(purpose)
        compileTask = Task { [weak self] in
            guard let self else { return }
            guard let compiler = await self.currentCompiler() else {
                self.finishWithoutTeX(generation: generation)
                return
            }
            if Task.isCancelled { return }
            let result = await compiler.compile(request)
            self.finishCompile(result, purpose: purpose, generation: generation)
        }
    }

    /// Cancels the running compile (toolbar Stop, ⌘.).
    func stopCompile() {
        guard isCompiling else { return }
        compileTask?.cancel()
        compileTask = nil
        compileGeneration += 1
        compileState = .idle
        inflightSignature = nil
        rerunLiveAfterBuild = false
    }

    func currentCompiler() async -> LaTeXCompiler? {
        await toolchain.compiler()
    }

    private func finishWithoutTeX(generation: Int) {
        guard generation == compileGeneration else { return }
        compileTask = nil
        inflightSignature = nil
        rerunLiveAfterBuild = false
        compileState = .toolError(String(localized: "No TeX distribution was found."))
    }

    private func finishCompile(_ result: CompileResult, purpose: CompilePurpose, generation: Int) {
        guard generation == compileGeneration else { return }
        compileTask = nil
        inflightSignature = nil
        hasCompiled = true
        lastCompileDuration = result.duration
        pathMapper = result.pathMapper
        log = result.log
        toolOutput = result.toolOutput

        switch result.status {
        case .cancelled:
            compileState = .idle
            if rerunLiveAfterBuild {
                rerunLiveAfterBuild = false
                startCompile(.live)
            }
            return
        case .toolError(let message):
            compileState = .toolError(message)
            let reason = Diagnostic(severity: .error, source: .latexmk, message: message, detail: result.toolOutput.isEmpty ? nil : result.toolOutput)
            compileDiagnostics = Self.reusingIDs(projectSpelling(of: [reason] + result.diagnostics), from: compileDiagnostics)
        case .succeeded:
            compileState = .succeeded
            compileDiagnostics = Self.reusingIDs(projectSpelling(of: result.diagnostics), from: compileDiagnostics)
        case .failed:
            compileState = .failed
            compileDiagnostics = Self.reusingIDs(projectSpelling(of: result.diagnostics), from: compileDiagnostics)
        }
        rebuildDiagnostics()

        if let pdf = result.pdfURL { updatePreview(pdf) }
        if let exported = result.exportedPDFURL { exportedPDFURL = exported }

        Task { [self] in await packages.noteMissing(result.missingFiles) }

        if purpose == .build, settings.syncAfterBuild, pdfURL != nil { forwardSearch(silent: true) }
        if rerunLiveAfterBuild {
            // Edits arrived while this compile ran: one more run with the current text, right away.
            rerunLiveAfterBuild = false
            startCompile(.live)
        }
    }

    /// Shows the newest PDF (also when the compile failed but still produced one).
    private func updatePreview(_ pdf: URL) {
        let stamp = TextFileIO.modificationDate(of: pdf)
        guard pdf != pdfURL || stamp != pdfStamp else { return }
        pdfURL = pdf
        pdfStamp = stamp
        preview.load(pdf)
    }

    // MARK: Settings reactions

    func liveCompileSettingChanged() {
        if settings.liveCompile { startCompile(.live) } else { debounceTasks["live"]?.cancel() }
    }

    func toolchainDidChange() {
        if mainFile != nil { startCompile(.live, force: true) }
        if let buffer = currentBuffer { scheduleChkTeX(for: buffer) }
    }

    func setEngineOverride(_ engine: TeXEngine?) {
        engineOverride = engine
        scheduleLiveCompile()
    }

    // MARK: Maintenance

    /// Removes the shadow workspace (auxiliary files) and rebuilds from scratch.
    func cleanAuxiliaryFiles() {
        stopCompile()
        Task { [self] in
            guard let compiler = await currentCompiler() else { return }
            await compiler.clean(projectDirectory: folderURL)
            compileDiagnostics = []
            rebuildDiagnostics()
            log = ""
            toolOutput = ""
            pdfStamp = nil
            flash(String(localized: "Auxiliary files removed"))
            startCompile(.live, force: true)
        }
    }

    func revealPDF() {
        if let exportedPDFURL, FileManager.default.fileExists(atPath: exportedPDFURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([exportedPDFURL])
        } else if let pdfURL {
            NSWorkspace.shared.activateFileViewerSelecting([pdfURL])
        }
    }
}

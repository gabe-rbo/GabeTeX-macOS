import SwiftUI
import Observation
import Synchronization
import TeXCore
import TeXToolchain
import EditorKit
import PreviewKit

// MARK: - Word and page counts (owner: stats agent — see claude/SPEC-1.0.md §2)
//
// What is counted, and how, is `DocumentStatistics` (TeXCore, pure). This file decides *when*:
// - the whole project is counted ~0.7 s after the last change to a buffer, the root, the include structure or
//   the open tabs, off the main actor, newest request wins;
// - the selection is counted ~0.15 s after it last changed (text only: cheap, no includes);
// - after each successful compile, ~0.9 s later, SyncTeX is asked for the page of every section heading
//   (a few `synctex view` processes at a time, in the background; a newer compile cancels the lookup).
// Nothing here is awaited by typing, saving or compiling. The loops are driven by `withObservationTracking`
// on the state they depend on, so no other file needs to call into this one.
extension ProjectWorkspace {
    /// Only these files are LaTeX text whose selection can be counted.
    static let statisticsFileExtensions: Set<String> = ["tex", "ltx"]

    /// Opens the Document Statistics popover (anchored to the status bar capsule).
    func showDocumentStatistics() {
        guard mainFile != nil else {
            flash(String(localized: "Open a LaTeX document to see its statistics."))
            return
        }
        statistics.isPopoverPresented = true
        scheduleStatisticsRefresh(immediately: true)
    }

    // MARK: Driving loop

    /// Keeps `statistics` current for as long as the calling task lives. The status bar starts it from a
    /// `.task`, so it ends with the window.
    func runStatisticsUpdates() async {
        scheduleStatisticsRefresh(immediately: true)
        refreshSelectionStatistics()
        scheduleSectionPages()
        async let documents: Void = followDocumentChanges()
        async let selections: Void = followSelectionChanges()
        async let compiles: Void = followCompiles()
        _ = await (documents, selections, compiles)
    }

    /// Anything that can change the words of the project: the root, the include structure, the open tabs and the
    /// edit counter of every open buffer.
    private func followDocumentChanges() async {
        while !Task.isCancelled {
            await waitForChange { [self] in
                _ = mainFile
                _ = index
                _ = tabs
                for buffer in buffers.values { _ = buffer.changeCount }
            }
            if Task.isCancelled { return }
            scheduleStatisticsRefresh()
        }
    }

    private func followSelectionChanges() async {
        while !Task.isCancelled {
            await waitForChange { [self] in
                _ = editor.selectionLength
                _ = editor.cursor
                if let file = currentFile {
                    _ = file
                    _ = buffers[file]?.changeCount
                }
            }
            if Task.isCancelled { return }
            refreshSelectionStatistics()
        }
    }

    private func followCompiles() async {
        while !Task.isCancelled {
            await waitForChange { [self] in
                _ = compileState
                _ = lastCompileDuration
                _ = pdfURL
            }
            if Task.isCancelled { return }
            scheduleSectionPages()
        }
    }

    /// Returns after the first change to anything `read` looked at, or when the calling task is cancelled.
    private func waitForChange(_ read: @escaping () -> Void) async {
        let gate = ChangeGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.install(continuation)
                withObservationTracking {
                    read()
                } onChange: {
                    gate.fire()
                }
            }
        } onCancel: {
            gate.fire()
        }
    }

    // MARK: Words of the project

    func scheduleStatisticsRefresh(immediately: Bool = false) {
        debounce("statistics", after: immediately ? .zero : .milliseconds(700)) { [weak self] in
            await self?.refreshStatistics()
        }
    }

    /// Counts the project off the main actor from a snapshot of the unsaved buffers.
    func refreshStatistics() async {
        guard !stopped else { return }
        guard let root = mainFile else {
            statistics.reset()
            return
        }
        var overlays: [URL: String] = [:]
        for (url, buffer) in buffers where buffer.isDirty { overlays[url] = buffer.text }
        statistics.documentGeneration &+= 1
        let generation = statistics.documentGeneration
        let counted = await Task.detached(priority: .utility) {
            StatisticsBuilder.compute(root: root, overlays: overlays)
        }.value
        guard generation == statistics.documentGeneration, !stopped else { return }
        statistics.apply(counted)
        // A compile that finished before the first count could not look the headings up.
        if statistics.pageStamp == nil { scheduleSectionPages() }
    }

    // MARK: Words of the selection

    /// Counts the selected text (nothing for other files than LaTeX sources). A selection is read and counted
    /// only once it has rested for a moment, so dragging out a selection stays smooth.
    func refreshSelectionStatistics() {
        guard editor.selectionLength > 0, let file = currentFile,
              Self.statisticsFileExtensions.contains(file.pathExtension.lowercased()) else {
            debounceTasks["statistics.selection"]?.cancel()
            statistics.selectionGeneration &+= 1
            statistics.apply(selection: nil)
            return
        }
        debounce("statistics.selection", after: .milliseconds(150)) { [weak self] in
            guard let self, !self.stopped else { return }
            guard let text = self.editor.selectedText else {
                self.statistics.selectionGeneration &+= 1
                self.statistics.apply(selection: nil)
                return
            }
            self.statistics.selectionGeneration &+= 1
            let generation = self.statistics.selectionGeneration
            let counted = await Task.detached(priority: .userInitiated) {
                DocumentStatistics.counts(in: text)
            }.value
            guard generation == self.statistics.selectionGeneration, !self.stopped else { return }
            self.statistics.apply(selection: counted)
        }
    }

    // MARK: Pages of the sections

    /// Looks the sections up in the PDF after a successful compile. A compile that is running cancels the
    /// lookup in flight: the PDF it reads is about to be replaced.
    func scheduleSectionPages() {
        guard compileState == .succeeded else {
            if isCompiling {
                debounceTasks["statistics.pages"]?.cancel()
                statistics.pageGeneration &+= 1
            }
            return
        }
        debounce("statistics.pages", after: .milliseconds(900)) { [weak self] in
            await self?.refreshSectionPages()
        }
    }

    private func refreshSectionPages() async {
        let model = statistics
        guard !stopped, compileState == .succeeded, let pdf = pdfURL, let mapper = pathMapper, let distribution,
              let document = model.document else { return }
        guard SectionPageLocator.hasSyncTeXData(for: pdf) else {
            model.forgetPages()
            return
        }
        let stamp = StatisticsModel.PageStamp(pdf: pdf, compile: lastCompileDuration, headings: document.sections.count)
        if model.pageStamp == stamp { return }
        let headings = document.sections.map {
            SectionPageLocator.Heading(key: $0.stableKey, fileURL: $0.fileURL, line: $0.line, endLine: $0.headingEndLine)
        }
        model.pageGeneration &+= 1
        let generation = model.pageGeneration
        let found = await SectionPageLocator.locate(headings, pdfURL: pdf, distribution: distribution, mapper: mapper)
        guard !Task.isCancelled, generation == model.pageGeneration, !stopped else { return }
        guard let found else {
            model.forgetPages()
            return
        }
        model.apply(placements: found.placements, totalPages: found.totalPages)
        model.pageStamp = stamp
    }
}

/// Wakes one waiting task exactly once: when the observed state changes or the waiting task is cancelled,
/// whichever comes first (and also if either happens before the task has started waiting).
nonisolated final class ChangeGate: Sendable {
    private enum State {
        case waiting
        case installed(CheckedContinuation<Void, Never>)
        case fired
    }

    private let state = Mutex<State>(.waiting)

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { current -> Bool in
            if case .fired = current { return true }
            current = .installed(continuation)
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func fire() {
        let continuation = state.withLock { current -> CheckedContinuation<Void, Never>? in
            let previous = current
            current = .fired
            if case .installed(let waiting) = previous { return waiting }
            return nil
        }
        continuation?.resume()
    }
}

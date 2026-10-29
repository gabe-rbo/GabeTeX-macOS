import AppKit
import Observation
import PreviewKit

// Presentation mode (owner: present agent — see claude/SPEC-1.0.md §3).
//
// The presentation itself (windows, presenter view, keyboard, displays, reloads) lives in PreviewKit
// (`PresentationController`); the workspace starts it from the compiled PDF, keeps it following the preview's
// reloads, and knows from the root's preamble whether the document is a Beamer talk (toolbar button) and where its
// notes are.

/// Bookkeeping of the presentation feature (stored in the workspace's `[present]` block).
struct PresentationTracking {
    /// The root document is being watched for its class and notes option.
    var isObservingSource = false
    var scanTask: Task<Void, Never>?
    /// Ends the presentation when the project window closes.
    var windowCloseObserver: NSObjectProtocol?
}

extension ProjectWorkspace {
    /// Whether a presentation can start: a compiled PDF is on hand.
    var canPresent: Bool { preview.hasDocument && preview.pdfURL != nil }

    /// Whether a presentation is running (or starting).
    var isPresenting: Bool { presentation != nil }

    /// The root document uses a slide class (`\documentclass{beamer}`): the toolbar shows "Present".
    var isPresentationDocument: Bool { presentationSource.isPresentation }

    /// Starts presenting the compiled PDF from the first slide (audience + presenter windows). While a presentation
    /// runs, brings it to the front instead.
    func startPresentation() {
        startPresentation(fromPage: 0)
    }

    /// Starts presenting from the page the preview shows.
    func startPresentationFromCurrentPage() {
        startPresentation(fromPage: preview.currentPageIndex)
    }

    /// Starts a presentation, or ends the running one (the toolbar button while presenting).
    func togglePresentation() {
        if isPresenting { stopPresentation() } else { startPresentation() }
    }

    /// Ends the presentation (its windows close and the project window comes back).
    func stopPresentation() {
        presentation?.end()
    }

    private func startPresentation(fromPage page: Int) {
        if let presentation {
            presentation.bringToFront()
            return
        }
        guard canPresent, let url = preview.pdfURL else {
            flash(String(localized: "Compile the document to present it"))
            return
        }
        trackPresentationSource()
        let controller = PresentationController(title: displayName, notesHint: presentationSource.notesSide)
        controller.onEnd = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.presentationDidEnd(controller)
        }
        presentation = controller
        observeProjectWindowCloseForPresentation()
        let screen = window?.screen
        Task { [weak self] in
            let started = await controller.start(url: url, at: page, following: self?.preview, presenterScreen: screen)
            guard let self, self.presentation === controller, !started else { return }
            // Ended while loading, or the PDF could not be read.
            self.presentation = nil
            if !controller.hasEnded {
                self.present(title: String(localized: "The presentation could not start"),
                             message: controller.loadFailure?.message ?? String(localized: "The PDF file could not be read."))
            }
        }
    }

    private func presentationDidEnd(_ controller: PresentationController) {
        guard presentation === controller else { return }
        presentation = nil
        if let observer = presentationTracking.windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            presentationTracking.windowCloseObserver = nil
        }
        guard !stopped, !isClosingProject else { return }
        bringWindowToFront()
    }

    /// Closing the project window (or quitting) ends its presentation.
    private func observeProjectWindowCloseForPresentation() {
        guard presentationTracking.windowCloseObserver == nil, let window else { return }
        presentationTracking.windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentation?.end() }
        }
    }

    // MARK: Root document class and notes

    /// Watches the root document (main file and index rebuilds) for its class and Beamer notes option. Idempotent;
    /// started by the toolbar and by `startPresentation`.
    func trackPresentationSource() {
        guard !presentationTracking.isObservingSource, !stopped else { return }
        presentationTracking.isObservingSource = true
        observePresentationSource()
        refreshPresentationSource()
    }

    private func observePresentationSource() {
        withObservationTracking {
            _ = index
            _ = mainFile
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observePresentationSource()
                self.refreshPresentationSource()
            }
        }
    }

    /// Scans the root's preamble (the open buffer if there is one, else the file, read off the main thread).
    private func refreshPresentationSource() {
        presentationTracking.scanTask?.cancel()
        guard let root = mainFile else {
            if presentationSource != PresentationSourceInfo() { presentationSource = PresentationSourceInfo() }
            return
        }
        let openText = buffers[root]?.text
        presentationTracking.scanTask = Task { [weak self] in
            let info: PresentationSourceInfo
            if let openText {
                info = PresentationSourceInfo.scan(openText)
            } else {
                info = await Self.scanPresentationSource(at: root)
            }
            guard let self, !Task.isCancelled, !self.stopped else { return }
            if self.presentationSource != info { self.presentationSource = info }
            if let presentation = self.presentation, presentation.notesHint != info.notesSide {
                presentation.notesHint = info.notesSide
            }
        }
    }

    @concurrent
    private nonisolated static func scanPresentationSource(at url: URL) async -> PresentationSourceInfo {
        guard let data = try? Data(contentsOf: url) else { return PresentationSourceInfo() }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return PresentationSourceInfo.scan(text)
    }
}

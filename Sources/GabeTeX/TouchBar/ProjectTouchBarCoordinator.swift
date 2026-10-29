import AppKit
import EditorKit
import Observation
import PDFKit
import PreviewKit
import TeXToolchain

/// Connects one project to the Touch Bars of its editor and of its PDF preview (docked in the project window
/// or in the separate PDF window): publishes the compile state, the issue counts and the preview state, and
/// routes the bars' app-level commands (Compile/Stop, Next Issue, PDF preview, separate PDF window) to the
/// workspace.
///
/// Installed once per workspace (`install(on:)`, from `wireCallbacks()`). It is kept alive by the command
/// handlers it sets on the workspace's `EditorController` and `PDFPreviewController` (so it lives as long as
/// they do) and holds the workspace weakly. On Macs without a Touch Bar it only keeps two small values up to
/// date (AppKit never asks for a bar there).
final class ProjectTouchBarCoordinator {
    /// A live compile that is still running after this long shows Stop (quick background compiles while
    /// typing would otherwise make the button flicker between Compile and Stop).
    static let liveCompileStopDelay: Duration = .milliseconds(1500)

    /// What the bars show, read from the workspace under observation.
    private struct Snapshot: Equatable {
        enum Compile: Equatable { case idle, build, live }
        var compile: Compile
        var hasMainFile: Bool
        var errorCount: Int
        var warningCount: Int
        var showPreview: Bool
        var isPreviewDetached: Bool
    }

    private weak var workspace: ProjectWorkspace?
    private var observationGeneration = 0
    private var snapshot: Snapshot?
    private var liveCompileTimer: Task<Void, Never>?
    private var longLiveCompile = false
    private var keyWindowObserver: NSObjectProtocol?

    private init(workspace: ProjectWorkspace) {
        self.workspace = workspace
    }

    isolated deinit {
        liveCompileTimer?.cancel()
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    }

    /// Starts publishing the workspace state to its Touch Bars and handling their commands.
    @discardableResult
    static func install(on workspace: ProjectWorkspace) -> ProjectTouchBarCoordinator {
        let coordinator = ProjectTouchBarCoordinator(workspace: workspace)
        workspace.editor.onTouchBarCommand = { command in coordinator.perform(command) }
        workspace.preview.onTouchBarCommand = { command in coordinator.perform(command) }
        coordinator.keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                coordinator?.focusPDFViewIfPDFWindowIsKey()
                // A window that has just opened gets its content (and `workspace.pdfWindow`) a moment later.
                Task { [weak coordinator] in
                    try? await Task.sleep(for: .milliseconds(300))
                    coordinator?.focusPDFViewIfPDFWindowIsKey()
                }
            }
        }
        coordinator.observe()
        return coordinator
    }

    // MARK: Commands

    func perform(_ command: EditorTouchBarCommand) {
        guard let workspace else { return }
        switch command {
        case .compile: workspace.compile()
        case .stopCompile: workspace.stopCompile()
        case .nextIssue: workspace.goToNextIssue(forward: true)
        case .togglePreview: workspace.togglePreviewVisibility()
        case .togglePreviewWindow: workspace.togglePreviewDetached()
        }
    }

    func perform(_ command: PDFTouchBarCommand) {
        guard let workspace else { return }
        switch command {
        case .compile: workspace.compile()
        case .stopCompile: workspace.stopCompile()
        case .togglePreviewWindow: workspace.togglePreviewDetached()
        }
    }

    // MARK: Separate PDF window

    /// The Touch Bar follows the key window's first responder. The separate PDF window contains nothing but the
    /// PDF, yet right after it opens (or is brought forward by ⌥⌘P) no view in it is first responder, so its bar
    /// would be empty: hand the focus to the PDF view, as a click would.
    private func focusPDFViewIfPDFWindowIsKey() {
        guard let window = workspace?.pdfWindow, window.isKeyWindow, let content = window.contentView,
              let pdfView = Self.pdfView(in: content) else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: pdfView) { return }
        window.makeFirstResponder(pdfView)
    }

    private static func pdfView(in view: NSView) -> GabePDFView? {
        if let pdf = view as? GabePDFView { return pdf }
        for subview in view.subviews {
            if let found = pdfView(in: subview) { return found }
        }
        return nil
    }

    // MARK: State

    /// Reads the workspace under observation (re-registering after every change) and publishes outside of
    /// the tracking closure, so nothing the bars read (e.g. the PDF page) is tracked here.
    private func observe() {
        observationGeneration &+= 1
        let generation = observationGeneration
        let current = withObservationTracking {
            readSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observe()
            }
        }
        snapshot = current
        publish()
    }

    private func readSnapshot() -> Snapshot? {
        guard let workspace else { return nil }
        let compile: Snapshot.Compile = switch workspace.compileState {
        case .compiling(.build): .build
        case .compiling(.live): .live
        default: .idle
        }
        return Snapshot(
            compile: compile,
            hasMainFile: workspace.mainFile != nil,
            errorCount: workspace.errorCount,
            warningCount: workspace.warningCount,
            showPreview: workspace.showPreview,
            isPreviewDetached: workspace.isPreviewDetached
        )
    }

    private func publish() {
        guard let workspace, let snapshot else { return }
        // Explicit builds show Stop at once; live compiles only once they take longer than the delay.
        if snapshot.compile == .live { startLiveCompileTimer() } else { stopLiveCompileTimer() }
        let running = snapshot.compile == .build || (snapshot.compile == .live && longLiveCompile)
        let editorCompile: EditorTouchBarStatus.CompileState = running ? .running : (snapshot.hasMainFile ? .ready : .unavailable)
        let pdfCompile: PDFTouchBarStatus.CompileState = running ? .running : (snapshot.hasMainFile ? .ready : .unavailable)
        workspace.editor.touchBarStatus = EditorTouchBarStatus(
            compile: editorCompile,
            errorCount: snapshot.errorCount,
            warningCount: snapshot.warningCount,
            // Detached, the preview toggle brings the PDF window forward (⌥⌘P): the preview counts as shown.
            isPreviewVisible: snapshot.isPreviewDetached || snapshot.showPreview,
            isPreviewDetached: snapshot.isPreviewDetached
        )
        workspace.preview.touchBarStatus = PDFTouchBarStatus(compile: pdfCompile,
                                                             isPreviewDetached: snapshot.isPreviewDetached)
    }

    private func startLiveCompileTimer() {
        guard liveCompileTimer == nil else { return }
        liveCompileTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.liveCompileStopDelay)
            guard let self, !Task.isCancelled else { return }
            self.longLiveCompile = true
            self.publish()
        }
    }

    private func stopLiveCompileTimer() {
        liveCompileTimer?.cancel()
        liveCompileTimer = nil
        longLiveCompile = false
    }
}

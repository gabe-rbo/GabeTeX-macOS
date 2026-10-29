import SwiftUI
import AppKit
import Observation
import TeXCore
import TeXToolchain
import EditorKit
import PreviewKit
import VimKit

/// A user-facing alert raised by the workspace (shown by the project window).
struct WorkspaceAlert: Identifiable {
    /// One extra button next to the dismiss button.
    struct Action {
        var title: String
        var isDestructive = false
        var handler: () -> Void
    }

    let id = UUID()
    var title: String
    var message: String
    /// Extra buttons, in display order (before the dismiss button).
    var actions: [Action] = []
    /// The dismiss button reads “Cancel” instead of “OK” (used when the extra buttons are choices).
    var offersCancel = false
}

/// “Move to Trash” with unsaved changes in the affected files: waiting for the user’s decision.
struct PendingTrash: Identifiable {
    let id = UUID()
    var url: URL
    var dirty: [URL]
}

/// “Close Other Tabs” with unsaved changes in some of them: waiting for the user’s decision.
struct PendingBulkClose: Identifiable {
    let id = UUID()
    var closing: [URL]
    var dirty: [URL]
}

/// What a compile was started for; a running live compile is only restarted when this changes.
struct CompileSignature: Equatable {
    var root: URL
    var engine: TeXEngine
}

/// Everything about one open project: files, buffers and tabs, the project index, compilation,
/// diagnostics and SyncTeX. One instance per project window.
///
/// Observation is deliberately granular: keystrokes only touch the (per-buffer) `SourceBuffer`
/// state; everything else changes in debounced steps.
@Observable
final class ProjectWorkspace {
    enum SidebarMode: String, CaseIterable, Identifiable {
        case files, outline
        var id: String { rawValue }
    }

    enum CompileState: Equatable {
        case idle
        case compiling(CompilePurpose)
        case succeeded
        case failed
        case toolError(String)
    }

    enum ExternalChange: Equatable {
        case modified
        case deleted
    }

    // MARK: Identity & services

    let folderURL: URL
    /// The project folder’s physical path (links resolved, on-disk case): the reference for file identity.
    let folderPhysical: String
    let initialFile: URL?
    var displayName: String { folderURL.lastPathComponent }

    @ObservationIgnored let settings = AppSettings.shared
    @ObservationIgnored let toolchain = ToolchainModel.shared
    @ObservationIgnored let editor = EditorController()
    @ObservationIgnored let preview = PDFPreviewController()
    @ObservationIgnored let packages = PackageInstallCoordinator()

    // MARK: File tree

    var fileTree: [FileNode] = []
    var allFiles: [URL] = []
    var treeTruncated = false
    /// File or folder selected in the sidebar.
    var sidebarSelection: URL?
    var sidebarMode: SidebarMode = .files

    // MARK: Buffers & tabs

    @ObservationIgnored var buffers: [URL: SourceBuffer] = [:]
    /// On-disk encoding per buffer (observed: the status bar shows it).
    var formats: [URL: TextFileFormat] = [:]
    /// What each buffer last read from / wrote to disk, to detect changes made by other programs.
    @ObservationIgnored var diskStates: [URL: TextFileIO.DiskState] = [:]
    /// Buffers whose file was not valid UTF-8 (and was repaired in memory); the value is the count of bad bytes.
    var encodingProblems: [URL: Int] = [:]
    /// Physical path → buffer key, so two spellings of one file never become two buffers.
    @ObservationIgnored var physicalKeys: [String: URL] = [:]
    var tabs: [URL] = []
    var currentFile: URL?
    var externalChanges: [URL: ExternalChange] = [:]
    /// Tab waiting for a “save changes?” answer.
    var pendingClose: URL?
    var pendingTrash: PendingTrash?
    var pendingBulkClose: PendingBulkClose?

    // MARK: Root document & index

    var mainFile: URL?
    var mainFileOverride: URL?
    var index: ProjectIndex?
    var symbols: ProjectSymbols = .empty
    var rootCandidates: [URL] = []
    var engineOverride: TeXEngine? {
        didSet { UserDefaults.standard.set(engineOverride?.rawValue, forKey: sessionKey("engine")) }
    }
    @ObservationIgnored var rootStatus: [URL: Bool] = [:]

    // MARK: Diagnostics

    var diagnostics: [Diagnostic] = []
    var diagnosticsByFile: [URL: [Diagnostic]] = [:]
    var errorCount = 0
    var warningCount = 0
    var otherIssueCount = 0
    var selectedIssueID: UUID?
    @ObservationIgnored var compileDiagnostics: [Diagnostic] = []
    @ObservationIgnored var chktexDiagnostics: [URL: [Diagnostic]] = [:]
    @ObservationIgnored var structureDiagnostics: [URL: [Diagnostic]] = [:]

    // MARK: Compilation

    var compileState: CompileState = .idle
    var lastCompileDuration: TimeInterval?
    var log = ""
    var toolOutput = ""
    var pdfURL: URL?
    var exportedPDFURL: URL?
    @ObservationIgnored var pathMapper: ShadowPathMapper?
    @ObservationIgnored var compileTask: Task<Void, Never>?
    @ObservationIgnored var compileGeneration = 0
    /// A live compile was requested while another compile was running: run exactly one more afterwards.
    @ObservationIgnored var rerunLiveAfterBuild = false
    /// Root and engine of the compile in flight.
    @ObservationIgnored var inflightSignature: CompileSignature?
    @ObservationIgnored var pdfStamp: Date?
    /// True once a compile has produced a result in this session.
    var hasCompiled = false

    // MARK: UI state

    var showPreview: Bool { didSet { settings.showPreview = showPreview } }
    var showIssues: Bool { didSet { settings.showIssues = showIssues } }
    var isQuickOpenPresented = false
    /// The PDF preview lives in its own window instead of beside the editor.
    var isPreviewDetached = false
    /// The share of the work area the editor takes beside the PDF (the divider position), remembered per
    /// project and kept while the PDF is detached or hidden. See `EditorPreviewSplit`.
    var editorShare = EditorPreviewSplit.standardShare
    /// Pending “New Label…” / “Rename…” dialog (File ▸ Project Labels).
    var labelEditor: LabelEditorRequest?
    /// Pending “name this file / folder” dialog (New File, New Folder, Rename).
    var namePrompt: NamePrompt?
    var alert: WorkspaceAlert?
    var statusMessage: String?

    @ObservationIgnored weak var window: NSWindow?
    /// The detached PDF window, while it is open.
    @ObservationIgnored weak var pdfWindow: NSWindow?
    /// The project window is going away: closing its PDF window must not re-dock the preview (the detached
    /// state is remembered for the next time the project opens).
    @ObservationIgnored var isClosingProject = false
    /// The PDF window was reopened by `start()`; the project window keeps the focus.
    @ObservationIgnored var keepsFocusWhenPDFWindowOpens = false
    /// Newest forward-sync request; older answers are dropped.
    @ObservationIgnored var syncGeneration = 0
    @ObservationIgnored var watcher: DirectoryWatcher?
    @ObservationIgnored var debounceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var jumpTask: Task<Void, Never>?
    @ObservationIgnored var statusTask: Task<Void, Never>?
    @ObservationIgnored var started = false
    /// Set by `stop()`; `start()` checks it after every await so a window closed meanwhile stays quiet.
    @ObservationIgnored var stopped = false
    @ObservationIgnored var activationObserver: NSObjectProtocol?

    // MARK: Init

    init(reference: ProjectReference) {
        let folder = reference.folderURL.standardizedFileURL
        self.folderURL = folder
        self.folderPhysical = FileIdentity.physicalPath(folder.path) ?? folder.path
        self.initialFile = reference.initialFile
        self.showPreview = AppSettings.shared.showPreview
        self.showIssues = AppSettings.shared.showIssues
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "project.\(folderURL.path).engine") {
            engineOverride = TeXEngine(rawValue: raw)
        }
        if let path = defaults.string(forKey: "project.\(folderURL.path).mainFile") {
            mainFileOverride = URL(fileURLWithPath: path).standardizedFileURL
        }
        editorShare = EditorPreviewSplit.storedShare(forProject: folder.path, defaults: defaults)
    }

    func sessionKey(_ name: String) -> String { "project.\(folderURL.path).\(name)" }

    // MARK: Lifecycle

    /// Starts scanning, watching and compiling. Idempotent; called by the window's `.task`.
    func start() async {
        guard !started, !stopped else { return }
        started = true
        WorkspaceRegistry.shared.register(self)
        RecentProjects.shared.add(folderURL)
        wireCallbacks()
        observeActivation()

        await scanTree()
        guard !stopped else { return }
        restoreSession()
        if let initialFile { open(initialFile, focusEditor: true) }
        if UserDefaults.standard.bool(forKey: sessionKey("pdfDetached")) { detachPreview(restoring: true) }
        startWatcher()

        await toolchain.ensureLocated()
        guard !stopped else { return }
        await refreshIndex()
        guard !stopped else { return }
        if tabs.isEmpty, let first = mainFile ?? allFiles.first(where: { $0.pathExtension == "tex" }) {
            open(first, focusEditor: true)
        }
        if let current = currentBuffer { scheduleStructureLint(for: current, immediately: true) }
        if settings.liveCompile { startCompile(.live) }
    }

    func stop() {
        stopped = true
        projectWindowWillClose()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        watcher?.stop()
        watcher = nil
        compileTask?.cancel()
        compileTask = nil
        jumpTask?.cancel()
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        WorkspaceRegistry.shared.unregister(self)
    }

    /// Files outside the watched folder (and files behind symbolic links) get no file-system events:
    /// look at every open file whenever the app comes back to the front.
    private func observeActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkAllBuffersForExternalChanges() }
        }
    }

    private func wireCallbacks() {
        editor.onVimExCommand = { [weak self] command in self?.handleVimCommand(command) }
        editor.onOpenReference = { [weak self] reference in self?.openReference(reference) }
        editor.onOpenLabel = { [weak self] key in self?.openLabel(key) }
        // PDF → source: the PDF reports the clicked word (double-click or ⌘-click, see Settings), the app finds it.
        preview.syncTrigger = settings.pdfSyncTrigger
        preview.onSyncClick = { [weak self] click in self?.syncFromPDF(click) }
        // Source → PDF: ⌘-click on text and the editor's “Show in PDF” context-menu item.
        editor.onShowInPDF = { [weak self] position, word in self?.showInPDF(position: position, editorWord: word) }

        packages.managerProvider = { [weak self] in await self?.packageManager() }
        packages.onInstalled = { [weak self] in self?.startCompile(.live, force: true) }
        packages.onFailure = { [weak self] title, message in self?.present(title: title, message: message) }
        // Touch Bar (editor + PDF): project state and app-level commands. Nothing visible without a Touch Bar.
        ProjectTouchBarCoordinator.install(on: self)
    }

    // MARK: Helpers shared by the extensions

    var distribution: TeXDistribution? { toolchain.distribution }

    func packageManager() async -> TeXPackageManager? {
        await toolchain.ensureLocated()
        guard let distribution = toolchain.distribution else { return nil }
        return TeXPackageManager(distribution: distribution)
    }

    /// Schedules `work` after `delay`, replacing any pending work with the same key.
    func debounce(_ key: String, after delay: Duration, _ work: @escaping @MainActor () async -> Void) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    func present(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        var actions: [WorkspaceAlert.Action] = []
        if let actionTitle, let action { actions.append(WorkspaceAlert.Action(title: actionTitle, handler: action)) }
        alert = WorkspaceAlert(title: title, message: message, actions: actions)
    }

    /// An alert that asks the user to choose between `actions` (the dismiss button reads “Cancel”).
    func presentChoice(title: String, message: String, actions: [WorkspaceAlert.Action]) {
        alert = WorkspaceAlert(title: title, message: message, actions: actions, offersCancel: true)
    }

    /// Shows a short message in the status bar.
    func flash(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    func bringWindowToFront() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    var hasUnsavedChanges: Bool { buffers.values.contains { $0.isDirty } }

    var dirtyURLs: [URL] { tabs.filter { buffers[$0]?.isDirty == true } }

    func updateWindowEdited() {
        let dirty = hasUnsavedChanges
        if window?.isDocumentEdited != dirty { window?.isDocumentEdited = dirty }
    }

    // MARK: Vim

    private func handleVimCommand(_ command: VimExCommand) {
        switch command {
        case .write: saveCurrent()
        case .quit: if let current = currentFile { closeTab(current) }
        case .writeQuit:
            if let current = currentFile { save(current) { [weak self] in self?.closeTab(current, force: true) } }
        case .writeAll: saveAll()
        case .compile: compile()
        case .goToLine: break   // the Vim engine already moved the cursor
        case .unknown(let text): flash(String(localized: "Not an editor command: \(text)"))
        }
    }
}

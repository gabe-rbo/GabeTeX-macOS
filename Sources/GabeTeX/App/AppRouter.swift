import SwiftUI
import AppKit
import TeXCore

/// Opens project windows from anywhere (menus, Welcome, Finder/Dock). SwiftUI's `openWindow` is only
/// available inside views, so a long-lived view hands its actions to the router.
@Observable
final class AppRouter {
    static let shared = AppRouter()

    @ObservationIgnored var openWindow: OpenWindowAction? { didSet { drainPending() } }
    @ObservationIgnored var dismissWindow: DismissWindowAction?
    @ObservationIgnored private var pending: [ProjectReference] = []
    @ObservationIgnored private var pendingPDFWindows: [PDFWindowReference] = []
    /// True once the app has agreed to quit: windows closing from then on must not change saved window state.
    @ObservationIgnored var isTerminating = false
    /// Number of project windows currently on screen (kept by `ProjectWindow`).
    @ObservationIgnored var projectWindowCount = 0

    /// True when Finder, the Dock or `open -a` asked the app to open something (used by Welcome at launch).
    @ObservationIgnored private(set) var launchOpenReceived = false

    /// True when a project window is open or about to open (used by Welcome at launch).
    var hasProjectWindows: Bool { projectWindowCount > 0 || !pending.isEmpty }

    // MARK: Opening

    /// Opens (or focuses) the window of a folder; when `file` is given it is opened in that window.
    func open(folder: URL, file: URL? = nil) {
        let folder = folder.standardizedFileURL
        RecentProjects.shared.add(folder)
        if let existing = WorkspaceRegistry.shared.workspace(for: folder) {
            if let file { existing.open(file) }
            existing.bringWindowToFront()
            return
        }
        let reference = ProjectReference(folderURL: folder, initialFile: file)
        if let openWindow {
            openWindow(id: "project", value: reference)
            dismissWindow?(id: "welcome")
        } else {
            pending.append(reference)
        }
    }

    /// Opens a single file: its folder becomes the project (or the folder of the root it points to).
    func open(file: URL) {
        let file = file.standardizedFileURL
        let reference = Self.reference(forFile: file)
        open(folder: reference.folderURL, file: reference.initialFile)
    }

    /// Routes URLs delivered by Finder/Dock.
    func handleOpen(urls: [URL]) {
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            launchOpenReceived = true
            if isDirectory.boolValue { open(folder: url) } else { open(file: url) }
        }
    }

    /// Opens (or brings forward) the detached PDF window of a project.
    func openPDFWindow(for folder: URL) {
        let reference = PDFWindowReference(folderURL: folder)
        if let openWindow {
            openWindow(id: "pdf", value: reference)
        } else {
            pendingPDFWindows.append(reference)
        }
    }

    private func drainPending() {
        guard let openWindow else { return }
        let pdfWindows = pendingPDFWindows
        pendingPDFWindows = []
        for reference in pdfWindows { openWindow(id: "pdf", value: reference) }
        guard !pending.isEmpty else { return }
        let references = pending
        pending = []
        for reference in references {
            openWindow(id: "project", value: reference)
        }
        dismissWindow?(id: "welcome")
    }

    func showWelcome() {
        openWindow?(id: "welcome")
    }

    // MARK: Panels

    func chooseFolderAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a folder that contains your LaTeX project.")
        if panel.runModal() == .OK, let url = panel.url { open(folder: url) }
    }

    func chooseFileAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a LaTeX file. Its folder opens as a project.")
        if panel.runModal() == .OK, let url = panel.url { open(file: url) }
    }

    // MARK: Helpers

    /// For a file with `% !TEX root = ../main.tex` the project is the root's folder.
    static func reference(forFile file: URL) -> ProjectReference {
        let folder = file.deletingLastPathComponent()
        if let data = TextFileIO.readHead(file, maxBytes: 4096),
           let loaded = TextFileIO.decode(data),
           let root = LaTeXScanner.magicComments(in: loaded.text).root {
            let rootURL = URL(fileURLWithPath: root, relativeTo: folder).standardizedFileURL
            let rootFolder = rootURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: rootURL.path), rootFolder != folder.standardizedFileURL,
               file.standardizedFileURL.relativePath(from: rootFolder) != nil {
                return ProjectReference(folderURL: rootFolder, initialFile: file)
            }
        }
        return ProjectReference(folderURL: folder, initialFile: file)
    }
}

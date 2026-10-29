import SwiftUI
import AppKit
import TeXCore
import TeXToolchain

// MARK: - File tree, watching and file operations

extension ProjectWorkspace {
    // MARK: Scanning & watching

    /// Rescans the folder off the main actor and publishes the result if it changed.
    func scanTree() async {
        let root = folderURL
        let result = await Task.detached(priority: .utility) { FileTreeScanner.scan(root: root) }.value
        if result.nodes != fileTree { fileTree = result.nodes }
        if result.files != allFiles { allFiles = result.files }
        if result.truncated != treeTruncated { treeTruncated = result.truncated }
    }

    func startWatcher() {
        let watcher = DirectoryWatcher(url: folderURL) { [weak self] urls in
            Task { @MainActor in self?.handleFileSystemChanges(urls) }
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: Creating

    /// Folder used as the target of “New File” / “New Folder”: the selected folder, the folder of the
    /// selected file, or the project root.
    var newItemDirectory: URL {
        guard let selection = sidebarSelection else { return folderURL }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: selection.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? selection : selection.deletingLastPathComponent()
        }
        return folderURL
    }

    private func validatedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.contains("/") || name == "." || name == ".." {
            present(title: String(localized: "Invalid name"), message: String(localized: "Names cannot be empty or contain “/”."))
            return nil
        }
        return name
    }

    func createFile(named rawName: String, in directory: URL) {
        guard var name = validatedName(rawName) else { return }
        if (name as NSString).pathExtension.isEmpty { name += ".tex" }
        let url = directory.appendingPathComponent(name).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            present(title: String(localized: "“\(name)” already exists"), message: String(localized: "Choose a different name."))
            return
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            present(title: String(localized: "Could not create “\(name)”"), message: String(localized: "Check that you have permission to write in this folder."))
            return
        }
        Task { [self] in
            await scanTree()
            open(url, focusEditor: true)
        }
    }

    func createFolder(named rawName: String, in directory: URL) {
        guard let name = validatedName(rawName) else { return }
        let url = directory.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            present(title: String(localized: "“\(name)” already exists"), message: String(localized: "Choose a different name."))
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            Task { [self] in
                await scanTree()
                sidebarSelection = url
            }
        } catch {
            present(title: String(localized: "Could not create “\(name)”"), message: error.localizedDescription)
        }
    }

    // MARK: Renaming, duplicating, trashing

    func rename(_ url: URL, to rawName: String) {
        guard let name = validatedName(rawName), name != url.lastPathComponent else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            present(title: String(localized: "“\(name)” already exists"), message: String(localized: "Choose a different name."))
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            present(title: String(localized: "Could not rename “\(url.lastPathComponent)”"), message: error.localizedDescription)
            return
        }
        remapURLs(from: url, to: destination)
        Task { [self] in await scanTree() }
    }

    func duplicate(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var attempt = 1
        var destination: URL
        repeat {
            let suffix = attempt == 1 ? String(localized: "copy") : String(localized: "copy \(attempt)")
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            destination = directory.appendingPathComponent(name).standardizedFileURL
            attempt += 1
        } while FileManager.default.fileExists(atPath: destination.path)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            present(title: String(localized: "Could not duplicate “\(url.lastPathComponent)”"), message: error.localizedDescription)
            return
        }
        let copied = destination
        Task { [self] in
            await scanTree()
            sidebarSelection = copied
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: copied.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                open(copied)
            }
        }
    }

    /// Asks first when a file (or a file in the folder) has unsaved edits; otherwise trashes right away.
    func moveToTrash(_ url: URL) {
        let prefix = url.path + "/"
        let dirty = tabs.filter { ($0 == url || $0.path.hasPrefix(prefix)) && buffers[$0]?.isDirty == true }
        guard dirty.isEmpty else {
            pendingTrash = PendingTrash(url: url, dirty: dirty)
            return
        }
        performTrash(url)
    }

    /// Answer to the “unsaved changes” dialog of Move to Trash. Saving first means the Trash holds the
    /// latest version; a file that cannot be saved cancels the whole operation.
    func resolveTrash(_ request: PendingTrash, save: Bool) {
        pendingTrash = nil
        if save, !saveBatch(request.dirty).isEmpty { return }
        performTrash(request.url)
    }

    /// Trashes first and closes the tabs only when that worked, so a failure loses nothing.
    private func performTrash(_ url: URL) {
        let prefix = url.path + "/"
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            present(title: String(localized: "Could not move “\(url.lastPathComponent)” to the Trash"), message: error.localizedDescription)
            return
        }
        for tab in tabs where tab == url || tab.path.hasPrefix(prefix) { closeTab(tab, force: true) }
        if let override = mainFileOverride, override == url || override.path.hasPrefix(prefix) { setMainFile(nil) }
        if sidebarSelection == url { sidebarSelection = nil }
        Task { [self] in await scanTree() }
        scheduleIndexRefresh()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Main document

    func setMainFile(_ url: URL?) {
        mainFileOverride = url?.standardizedFileURL
        UserDefaults.standard.set(mainFileOverride?.path, forKey: sessionKey("mainFile"))
        // Going back to “automatic” must not keep the old explicit choice as the sticky root.
        if url == nil { mainFile = nil }
        scheduleIndexRefresh()
        scheduleLiveCompile()
    }

    func isMainFile(_ url: URL) -> Bool { mainFile == url }

    // MARK: Remapping after a rename

    /// Updates every structure that refers to `old` (or files below it) after a move on disk.
    func remapURLs(from old: URL, to new: URL) {
        let oldPrefix = old.path + "/"
        func mapped(_ u: URL) -> URL? {
            if u == old { return new }
            if u.path.hasPrefix(oldPrefix) {
                return URL(fileURLWithPath: new.path + "/" + u.path.dropFirst(oldPrefix.count)).standardizedFileURL
            }
            return nil
        }
        for (url, buffer) in buffers {
            guard let target = mapped(url) else { continue }
            buffers[url] = nil
            buffers[target] = buffer
            buffer.didMove(to: target)
            if let format = formats.removeValue(forKey: url) { formats[target] = format }
            if let state = diskStates.removeValue(forKey: url) { diskStates[target] = state }
            if let problem = encodingProblems.removeValue(forKey: url) { encodingProblems[target] = problem }
            if let change = externalChanges.removeValue(forKey: url) { externalChanges[target] = change }
            structureDiagnostics[url] = nil
            chktexDiagnostics[url] = nil
        }
        tabs = tabs.map { mapped($0) ?? $0 }
        if let current = currentFile, let target = mapped(current) { currentFile = target }
        if let selection = sidebarSelection, let target = mapped(selection) { sidebarSelection = target }
        if let main = mainFile, let target = mapped(main) { mainFile = target }
        if let override = mainFileOverride, let target = mapped(override) {
            mainFileOverride = target
            UserDefaults.standard.set(target.path, forKey: sessionKey("mainFile"))
        }
        rebuildIdentityIndex()
        rootStatus = [:]
        rebuildDiagnostics()
        persistSession()
        scheduleIndexRefresh()
        if let current = currentBuffer { scheduleStructureLint(for: current, immediately: true) }
    }
}

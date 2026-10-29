import SwiftUI
import AppKit
import TeXCore
import EditorKit

// MARK: - Opening, tabs, saving, external changes

/// Why a save did not happen.
enum SaveFailure {
    /// The file on disk changed since the buffer last loaded or wrote it.
    case conflict
    case readOnly
    case notRepresentable(String)
    case other(String)
}

extension ProjectWorkspace {
    /// Extensions that open in their default app instead of the editor.
    static let externalExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "eps", "svg", "ps", "ai", "psd", "webp", "ico", "icns",
        "zip", "gz", "tar", "7z", "rar", "dmg", "key", "pages", "numbers", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "odt", "mov", "mp4", "mp3", "wav", "dvi", "xdv"
    ]

    var currentBuffer: SourceBuffer? { currentFile.flatMap { buffers[$0] } }

    func buffer(for url: URL) -> SourceBuffer? { buffers[url] }

    func isDirty(_ url: URL) -> Bool { tabs.contains(url) && buffers[url]?.isDirty == true }

    // MARK: File identity

    /// The key under which the buffer of `url` lives. Two spellings of one file — another letter case, a
    /// link into the project folder, `/var` vs `/private/var` — resolve to the same key:
    /// - a file that already has a buffer keeps that buffer’s key;
    /// - a file inside the project folder is spelled with the folder’s own spelling plus its true on-disk
    ///   path below it;
    /// - a link inside the project that leads outside keeps its project-space spelling (what the compiler
    ///   and its diagnostics use);
    /// - anything else is spelled by its physical path.
    func canonicalURL(_ url: URL) -> URL {
        let standard = url.standardizedFileURL
        guard let physical = FileIdentity.physicalPath(standard.path) else { return standard }
        if let existing = physicalKeys[physical] { return existing }
        if FileIdentity.isInside(physical, base: folderPhysical) {
            return URL(fileURLWithPath: folderURL.path + String(physical.dropFirst(folderPhysical.count))).standardizedFileURL
        }
        if standard.path.hasPrefix(folderURL.path + "/") { return standard }
        return URL(fileURLWithPath: physical).standardizedFileURL
    }

    func registerIdentity(of url: URL) {
        if let physical = FileIdentity.physicalPath(url.path) { physicalKeys[physical] = url }
    }

    func forgetIdentity(of url: URL) {
        physicalKeys = physicalKeys.filter { $0.value != url }
    }

    /// Recomputes `physicalKeys` from the open buffers (after a rename or re-keying).
    func rebuildIdentityIndex() {
        var index: [String: URL] = [:]
        for url in buffers.keys {
            if let physical = FileIdentity.physicalPath(url.path) { index[physical] = url }
        }
        physicalKeys = index
    }

    /// True when the file lives outside the watched project folder (also behind a link): no file-system
    /// events arrive for it.
    private func isUnwatched(_ physical: String) -> Bool {
        !FileIdentity.isInside(physical, base: folderPhysical)
    }

    // MARK: Open

    /// Opens `url` in a tab and makes it current. With `line`, jumps there once the editor shows it.
    @discardableResult
    func open(_ requested: URL, line: Int? = nil, column: Int? = nil, focusEditor: Bool = false) -> Bool {
        var url = canonicalURL(requested)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            present(title: String(localized: "File not found"), message: String(localized: "“\(url.lastPathComponent)” does not exist."))
            return false
        }
        if isDirectory.boolValue {
            sidebarSelection = requested.standardizedFileURL
            return false
        }
        // The file is already open under its physical (outside-the-project) spelling, but the request names
        // it through the project: switch the buffer to the project-space spelling the compiler knows.
        let lexical = requested.standardizedFileURL
        if url != lexical, lexical.path.hasPrefix(folderURL.path + "/"), !url.path.hasPrefix(folderURL.path + "/"),
           buffers[url] != nil, buffers[lexical] == nil {
            remapURLs(from: url, to: lexical)
            url = lexical
        }
        if buffers[url] == nil {
            if Self.externalExtensions.contains(url.pathExtension.lowercased()) {
                NSWorkspace.shared.open(url)
                return false
            }
            do {
                try loadBuffer(url)
            } catch TextFileError.notText {
                NSWorkspace.shared.open(url)
                return false
            } catch {
                present(title: String(localized: "Could not open “\(url.lastPathComponent)”"), message: error.localizedDescription)
                return false
            }
        }
        if !tabs.contains(url) {
            if let current = currentFile, let position = tabs.firstIndex(of: current) {
                tabs.insert(url, at: position + 1)
            } else {
                tabs.append(url)
            }
        }
        selectFile(url)
        if let line {
            jump(to: url, line: line, column: column)
        } else if focusEditor {
            jumpTask?.cancel()
            jumpTask = Task { [weak self] in
                guard let self, await self.waitForEditor(showing: url), !Task.isCancelled else { return }
                self.editor.focus()
            }
        }
        return true
    }

    /// Reads `url` (already a canonical key) into a new buffer.
    func loadBuffer(_ url: URL) throws {
        let loaded = try TextFileIO.read(url)
        buffers[url] = SourceBuffer(url: url, text: loaded.text)
        formats[url] = loaded.format
        diskStates[url] = loaded.diskState
        encodingProblems[url] = loaded.invalidByteCount > 0 ? loaded.invalidByteCount : nil
        registerIdentity(of: url)
    }

    func selectFile(_ url: URL) {
        guard currentFile != url else {
            sidebarSelection = url
            return
        }
        currentFile = url
        sidebarSelection = url
        persistSession()
        scheduleIndexRefresh()
        if let buffer = buffers[url] {
            scheduleStructureLint(for: buffer, immediately: true)
            scheduleChkTeX(for: buffer)
        }
    }

    /// True when the editor view displays `url`’s buffer right now.
    private func isEditorShowing(_ url: URL) -> Bool {
        guard currentFile == url, let textView = editor.textView else { return false }
        return textView.textStorage === buffers[url]?.textStorage
    }

    /// Waits (briefly) until the editor view displays `url`’s buffer. False when it never did.
    @discardableResult
    func waitForEditor(showing url: URL) async -> Bool {
        for _ in 0..<40 {
            if isEditorShowing(url) { return true }
            try? await Task.sleep(for: .milliseconds(25))
            if Task.isCancelled { return false }
        }
        return isEditorShowing(url)
    }

    func jump(to url: URL, line: Int, column: Int?) {
        jumpTask?.cancel()
        jumpTask = Task { [weak self] in
            guard let self else { return }
            let shown = await self.waitForEditor(showing: url)
            // Never move the caret of whatever file happens to be showing.
            guard shown, !Task.isCancelled, self.isEditorShowing(url) else { return }
            self.editor.goTo(line: line, column: column, highlight: true)
            self.editor.focus()
        }
    }

    // MARK: Tabs

    func selectTab(at position: Int) {
        guard tabs.indices.contains(position) else { return }
        selectFile(tabs[position])
    }

    func selectNextTab() { cycleTab(by: 1) }
    func selectPreviousTab() { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        guard tabs.count > 1, let current = currentFile, let position = tabs.firstIndex(of: current) else { return }
        selectFile(tabs[(position + delta + tabs.count) % tabs.count])
    }

    func moveTab(_ url: URL, before target: URL) {
        guard url != target, let from = tabs.firstIndex(of: url), tabs.contains(target) else { return }
        tabs.remove(at: from)
        if let to = tabs.firstIndex(of: target) { tabs.insert(url, at: to) }
        persistSession()
    }

    /// Closes a tab; a dirty buffer first asks what to do (`pendingClose`).
    func closeTab(_ url: URL, force: Bool = false) {
        guard let position = tabs.firstIndex(of: url) else { return }
        if !force, buffers[url]?.isDirty == true {
            pendingClose = url
            return
        }
        tabs.remove(at: position)
        if let closing = buffers[url] { (editor.textView as? LaTeXTextView)?.forget(closing) }
        buffers[url] = nil
        formats[url] = nil
        diskStates[url] = nil
        encodingProblems[url] = nil
        externalChanges[url] = nil
        structureDiagnostics[url] = nil
        chktexDiagnostics[url] = nil
        forgetIdentity(of: url)
        rebuildDiagnostics()
        if currentFile == url {
            if tabs.isEmpty {
                currentFile = nil
                persistSession()
            } else {
                selectFile(tabs[min(position, tabs.count - 1)])
            }
        } else {
            persistSession()
        }
        updateWindowEdited()
    }

    func closeCurrentTab() {
        if let currentFile { closeTab(currentFile) }
    }

    /// Answer to the “save changes?” dialog for `url`.
    func resolvePendingClose(_ url: URL, save: Bool) {
        pendingClose = nil
        if save {
            // A conflict or an error keeps the tab open; "Overwrite" in the conflict alert closes it afterwards.
            self.save(url) { [weak self] in self?.closeTab(url, force: true) }
        } else {
            closeTab(url, force: true)
        }
    }

    /// “Close Other Tabs”: closes the clean ones right away and asks once about all the dirty ones.
    func closeOtherTabs(keeping keep: URL) {
        let others = tabs.filter { $0 != keep }
        let dirty = others.filter { buffers[$0]?.isDirty == true }
        if dirty.isEmpty {
            for url in others { closeTab(url, force: true) }
        } else {
            pendingBulkClose = PendingBulkClose(closing: others, dirty: dirty)
        }
    }

    /// Answer to the “N files have unsaved changes” dialog.
    func resolveBulkClose(_ request: PendingBulkClose, save: Bool) {
        pendingBulkClose = nil
        var keepOpen = Set<URL>()
        if save { keepOpen = Set(saveBatch(request.dirty)) }
        for url in request.closing where !keepOpen.contains(url) { closeTab(url, force: true) }
    }

    // MARK: Save

    /// Saves one file. Returns true when it was written right away; when the file changed on disk the user
    /// is asked (Overwrite / Reload / Cancel) and `completion` runs after a successful overwrite.
    @discardableResult
    func save(_ url: URL, then completion: (() -> Void)? = nil) -> Bool {
        guard let buffer = buffers[url] else { return false }
        if let failure = attemptWrite(buffer, force: false) {
            presentSaveFailure(failure, for: url, then: completion)
            return false
        }
        completion?()
        return true
    }

    /// Writes the buffer. nil = saved. `force` skips the “changed on disk” check (the user chose Overwrite).
    private func attemptWrite(_ buffer: SourceBuffer, force: Bool) -> SaveFailure? {
        let url = buffer.url
        if !force, hasDiskConflict(url) { return .conflict }
        let state: TextFileIO.DiskState
        do {
            state = try TextFileIO.write(buffer.text, to: url, format: formats[url] ?? .utf8)
        } catch TextFileError.notRepresentable(let name) {
            return .notRepresentable(name)
        } catch TextFileError.readOnly {
            return .readOnly
        } catch {
            return .other(error.localizedDescription)
        }
        buffer.markSaved()
        diskStates[url] = state
        externalChanges[url] = nil
        encodingProblems[url] = nil
        rootStatus[url] = nil
        updateWindowEdited()
        scheduleIndexRefresh()
        return nil
    }

    /// True when the file on disk is not what this buffer last loaded or wrote (somebody else changed it).
    /// A deleted file is not a conflict: saving simply creates it again. A changed timestamp with identical
    /// bytes (a `touch`) is not a conflict either.
    private func hasDiskConflict(_ url: URL) -> Bool {
        if externalChanges[url] == .modified { return true }
        guard let known = diskStates[url], let stamp = TextFileIO.stamp(of: url) else { return false }
        if stamp == known.stamp { return false }
        guard let now = TextFileIO.currentState(of: url) else { return false }
        if now.digest == known.digest {
            diskStates[url] = now
            return false
        }
        return true
    }

    private func forceSave(_ url: URL, then completion: (() -> Void)?) {
        guard let buffer = buffers[url] else { return }
        if let failure = attemptWrite(buffer, force: true) {
            presentSaveFailure(failure, for: url, then: completion)
        } else {
            completion?()
        }
    }

    private func presentSaveFailure(_ failure: SaveFailure, for url: URL, then completion: (() -> Void)?) {
        let name = url.lastPathComponent
        switch failure {
        case .conflict:
            // The banner stays visible whatever the user answers here.
            if externalChanges[url] == nil { externalChanges[url] = .modified }
            presentChoice(
                title: String(localized: "“\(name)” changed on disk"),
                message: String(localized: "Another program modified this file after you opened it. Overwrite replaces the version on disk with yours; Reload discards your changes and loads the version on disk."),
                actions: [
                    WorkspaceAlert.Action(title: String(localized: "Overwrite"), isDestructive: true) { [weak self] in
                        self?.forceSave(url, then: completion)
                    },
                    WorkspaceAlert.Action(title: String(localized: "Reload")) { [weak self] in
                        self?.reloadFromDisk(url)
                    }
                ]
            )
        case .readOnly:
            present(title: String(localized: "Could not save “\(name)”"), message: TextFileError.readOnly.localizedDescription)
        case .notRepresentable(let encoding):
            present(
                title: String(localized: "Could not save “\(name)”"),
                message: String(localized: "The text contains characters that cannot be stored in the file’s \(encoding) encoding. You can save it as UTF-8 instead."),
                actionTitle: String(localized: "Save as UTF-8")
            ) { [weak self] in
                self?.formats[url] = .utf8
                self?.save(url, then: completion)
            }
        case .other(let message):
            present(title: String(localized: "Could not save “\(name)”"), message: message)
        }
    }

    /// Saves every file in `urls` that has unsaved changes. Files that cannot be saved — changed on disk,
    /// read-only, unencodable — are skipped and reported together in one alert; nothing is overwritten.
    /// Returns the URLs that were not saved.
    @discardableResult
    func saveBatch(_ urls: [URL]) -> [URL] {
        var failures: [(url: URL, failure: SaveFailure)] = []
        for url in urls {
            guard let buffer = buffers[url], buffer.isDirty else { continue }
            if let failure = attemptWrite(buffer, force: false) { failures.append((url, failure)) }
        }
        guard !failures.isEmpty else { return [] }
        var lines: [String] = []
        var hasConflict = false
        for (url, failure) in failures {
            let name = url.lastPathComponent
            let reason: String
            switch failure {
            case .conflict:
                hasConflict = true
                if externalChanges[url] == nil { externalChanges[url] = .modified }
                reason = String(localized: "changed on disk")
            case .readOnly:
                reason = String(localized: "read-only")
            case .notRepresentable(let encoding):
                reason = String(localized: "has characters that \(encoding) cannot store")
            case .other(let message):
                reason = message
            }
            lines.append(String(localized: "“\(name)”: \(reason)"))
        }
        var message = lines.joined(separator: "\n")
        if hasConflict {
            message += "\n\n" + String(localized: "Use Keep Mine or Reload in the banner above each file, then save again.")
        }
        present(title: String(localized: "Some files were not saved"), message: message)
        return failures.map(\.url)
    }

    /// ⌘S: saves the current file (and builds when “compile on save” is on — without saving other files).
    func saveCurrent() {
        guard let currentFile else { return }
        if settings.compileOnSave {
            save(currentFile) { [weak self] in self?.startCompile(.build, saveFirst: false) }
        } else {
            save(currentFile)
        }
    }

    /// Saves everything that can be saved; false when something was skipped (already reported to the user).
    @discardableResult
    func saveAll() -> Bool {
        saveBatch(dirtyURLs).isEmpty
    }

    // MARK: Encoding

    /// Banner action: keep the repaired UTF-8 text (the bad bytes stay U+FFFD and the file is written as UTF-8).
    func keepUTF8(_ url: URL) {
        encodingProblems[url] = nil
    }

    /// Banner action: read the file again as ISO Latin-1 (asks first when there are unsaved edits).
    func reopenAsLatin1(_ url: URL) {
        guard let buffer = buffers[url] else { return }
        guard buffer.isDirty else {
            performReopenAsLatin1(url)
            return
        }
        presentChoice(
            title: String(localized: "Discard your changes?"),
            message: String(localized: "Reopening “\(url.lastPathComponent)” as Latin-1 loads it from disk again and discards the unsaved changes in the editor."),
            actions: [
                WorkspaceAlert.Action(title: String(localized: "Reopen as Latin-1"), isDestructive: true) { [weak self] in
                    self?.performReopenAsLatin1(url)
                }
            ]
        )
    }

    private func performReopenAsLatin1(_ url: URL) {
        guard let buffer = buffers[url] else { return }
        do {
            let loaded = try TextFileIO.read(url, asLatin1: true)
            applyDiskContent(loaded, to: buffer)
        } catch {
            present(title: String(localized: "Could not reload “\(url.lastPathComponent)”"), message: error.localizedDescription)
        }
        updateWindowEdited()
    }

    // MARK: External changes

    func handleFileSystemChanges(_ urls: [URL]) {
        var touchesTree = false
        var touchesIndex = false
        for raw in urls {
            // FSEvents reports real paths (and the on-disk letter case): map them to the buffer’s spelling.
            let url = canonicalURL(raw)
            if buffers[url] != nil { checkExternalChange(url) }
            touchesTree = true
            if ["tex", "ltx", "bib", "sty", "cls"].contains(url.pathExtension.lowercased()) {
                rootStatus[url] = nil
                touchesIndex = true
            }
        }
        if touchesTree {
            debounce("tree", after: .milliseconds(200)) { [weak self] in await self?.scanTree() }
        }
        if touchesIndex { scheduleIndexRefresh() }
    }

    /// Looks at the disk state of every open file (on app activation).
    func checkAllBuffersForExternalChanges() {
        guard !stopped else { return }
        for url in Array(buffers.keys) { checkExternalChange(url) }
    }

    /// Looks at the open files that live outside the watched folder (or behind a link): no events arrive for them.
    func checkUnwatchedBuffers() {
        for (physical, url) in physicalKeys where isUnwatched(physical) { checkExternalChange(url) }
    }

    func checkExternalChange(_ url: URL) {
        guard let buffer = buffers[url] else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if buffer.isDirty { externalChanges[url] = .deleted } else { closeTab(url, force: true) }
            return
        }
        let stamp = TextFileIO.stamp(of: url)
        let known = diskStates[url]
        if stamp != nil, stamp == known?.stamp, externalChanges[url] != .deleted { return }
        guard let loaded = try? TextFileIO.read(url) else { return }
        if loaded.digest == known?.digest {
            // Touched, or changed and changed back: the bytes are what the buffer last saw.
            diskStates[url] = loaded.diskState
            externalChanges[url] = nil
            return
        }
        if loaded.text == buffer.text {
            diskStates[url] = loaded.diskState
            formats[url] = loaded.format
            externalChanges[url] = nil
            return
        }
        if buffer.isDirty {
            externalChanges[url] = .modified
        } else {
            applyDiskContent(loaded, to: buffer)
        }
    }

    private func applyDiskContent(_ loaded: TextFileIO.Loaded, to buffer: SourceBuffer) {
        let url = buffer.url
        buffer.reload(text: loaded.text)
        formats[url] = loaded.format
        diskStates[url] = loaded.diskState
        encodingProblems[url] = loaded.invalidByteCount > 0 ? loaded.invalidByteCount : nil
        externalChanges[url] = nil
        afterTextReplaced(buffer)
    }

    /// Banner action: discard local edits and take the file from disk.
    func reloadFromDisk(_ url: URL) {
        guard let buffer = buffers[url] else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            closeTab(url, force: true)
            return
        }
        do {
            let loaded = try TextFileIO.read(url)
            applyDiskContent(loaded, to: buffer)
        } catch {
            present(title: String(localized: "Could not reload “\(url.lastPathComponent)”"), message: error.localizedDescription)
        }
        updateWindowEdited()
    }

    /// Banner action: keep the editor’s version (it overwrites the disk version on the next save).
    func keepMine(_ url: URL) {
        externalChanges[url] = nil
        if let state = TextFileIO.currentState(of: url) { diskStates[url] = state }
    }

    private func afterTextReplaced(_ buffer: SourceBuffer) {
        scheduleStructureLint(for: buffer, immediately: true)
        scheduleChkTeX(for: buffer)
        scheduleIndexRefresh()
        scheduleLiveCompile()
        updateWindowEdited()
    }

    // MARK: Session

    func persistSession() {
        let defaults = UserDefaults.standard
        defaults.set(tabs.compactMap { $0.relativePath(from: folderURL) }, forKey: sessionKey("tabs"))
        defaults.set(currentFile?.relativePath(from: folderURL), forKey: sessionKey("current"))
    }

    func restoreSession() {
        let defaults = UserDefaults.standard
        for relative in defaults.stringArray(forKey: sessionKey("tabs")) ?? [] {
            let url = canonicalURL(folderURL.appendingPathComponent(relative))
            guard FileManager.default.fileExists(atPath: url.path), !tabs.contains(url) else { continue }
            if buffers[url] == nil, (try? loadBuffer(url)) == nil { continue }
            tabs.append(url)
        }
        if let relative = defaults.string(forKey: sessionKey("current")) {
            let url = canonicalURL(folderURL.appendingPathComponent(relative))
            if tabs.contains(url) { selectFile(url); return }
        }
        if let first = tabs.first { selectFile(first) }
    }
}

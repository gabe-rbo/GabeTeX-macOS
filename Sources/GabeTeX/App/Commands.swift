import SwiftUI
import TeXToolchain

/// The menu bar. Actions go to the key project window’s workspace (`@FocusedValue`); titles, enabled
/// states and checkmarks come from its `CommandState` snapshot, which is also a focused value.
struct AppCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.commandState) private var focusedState
    @Environment(\.openWindow) private var openWindow
    private let router = AppRouter.shared

    private var state: CommandState { focusedState ?? .none }

    /// ⌘W closes the current tab, but only in a project window that has one (never in the PDF window).
    private var closesTab: Bool { state.hasCurrentFile && !state.isPDFWindowKey }

    /// Runs `action` on the key window’s workspace. Anything that shows the editor or a dialog lives in the
    /// project window, so when the detached PDF window is key that window comes forward first.
    private func inProject(_ action: (ProjectWorkspace) -> Void) {
        guard let workspace else { return }
        if state.isPDFWindowKey { workspace.bringWindowToFront() }
        action(workspace)
    }

    var body: some Commands {
        SidebarCommands()

        // File. One group, in the placement that is known to render in this WindowGroup app (`.newItem`):
        // `.saveItem` shows nothing on macOS 27, and its Close / Save items never appeared.
        CommandGroup(replacing: .newItem) {
            Group {
                Button("New Project…") { openWindow(id: "new-project") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New File…") { inProject { $0.promptNewFile() } }
                    .keyboardShortcut("n")
                    .disabled(workspace == nil)
                Divider()
                Button("Open Folder…") { router.chooseFolderAndOpen() }
                    .keyboardShortcut("o")
                Button("Open File…") { router.chooseFileAndOpen() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                OpenRecentMenu()
            }
            Divider()
            // The one and only ⌘W: the current tab while there is one, else the window. In the PDF window it
            // closes that window (and so docks the preview again). The system's own Close is removed (see
            // `SystemCloseItemRemover`).
            Group {
                Button {
                    if let workspace, closesTab {
                        workspace.closeCurrentTab()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                } label: {
                    if closesTab { Text("Close Tab") } else { Text("Close Window") }
                }
                .keyboardShortcut("w")
                if closesTab {
                    Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                }
            }
            Divider()
            Group {
                Button("Save") { workspace?.saveCurrent() }
                    .keyboardShortcut("s")
                    .disabled(!state.hasCurrentFile)
                Button("Save All") { workspace?.saveAll() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(workspace == nil)
            }
            Divider()
            Group {
                Button("Reveal in Finder") {
                    if let url = workspace?.currentFile { workspace?.revealInFinder(url) }
                }
                .disabled(!state.hasCurrentFile)
                ProjectLabelsMenu(workspace: workspace, bringsProjectForward: state.isPDFWindowKey)
            }
        }

        // Edit
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { inProject { $0.editor.showFind() } }
                .keyboardShortcut("f")
                .disabled(!state.hasCurrentFile)
            Button("Find and Replace…") { inProject { $0.editor.showFind(replace: true) } }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!state.hasCurrentFile)
            Button("Go to Line…") { inProject { $0.promptGoToLine() } }
                .keyboardShortcut("l")
                .disabled(!state.hasCurrentFile)
            Divider()
            Button("Toggle Comment") { inProject { $0.editor.toggleComment() } }
                .keyboardShortcut("/")
                .disabled(!state.hasCurrentFile)
            Button("Indent") { inProject { $0.editor.indentSelection() } }
                .keyboardShortcut("]")
                .disabled(!state.hasCurrentFile)
            Button("Outdent") { inProject { $0.editor.outdentSelection() } }
                .keyboardShortcut("[")
                .disabled(!state.hasCurrentFile)
            Button("Complete") { inProject { $0.editor.triggerCompletion() } }
                .keyboardShortcut(.space, modifiers: .control)
                .disabled(!state.hasCurrentFile)
        }

        // View
        CommandGroup(after: .toolbar) {
            Divider()
            Button {
                workspace?.togglePreviewVisibility()
            } label: {
                if state.isPreviewDetached {
                    Text("Show PDF Window")
                } else if state.showPreview {
                    Text("Hide PDF Preview")
                } else {
                    Text("Show PDF Preview")
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(workspace == nil)
            Button {
                workspace?.togglePreviewDetached()
            } label: {
                if state.isPreviewDetached {
                    Text("Attach PDF to Project Window")
                } else {
                    Text("Open PDF in Separate Window")
                }
            }
            .disabled(workspace == nil)
            Button {
                withAnimation(.smooth) { workspace?.showIssues.toggle() }
            } label: {
                if state.showIssues { Text("Hide Issues") } else { Text("Show Issues") }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(workspace == nil)
            Button("Quick Open…") { inProject { $0.isQuickOpenPresented = true } }
                .keyboardShortcut("p")
                .disabled(workspace == nil)
            Divider()
            Button("Show Files") { inProject { $0.sidebarMode = .files } }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Button("Show Outline") { inProject { $0.sidebarMode = .outline } }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Divider()
            Button("Show Next Tab") { workspace?.selectNextTab() }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(state.tabCount < 2)
            Button("Show Previous Tab") { workspace?.selectPreviousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(state.tabCount < 2)
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button("Tab \(number)") { workspace?.selectTab(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                        .disabled(state.tabCount < number)
                }
            }
            .disabled(workspace == nil)
        }

        // Window
        CommandGroup(before: .windowList) {
            Button("Welcome to GabeTeX") { openWindow(id: "welcome") }
            Divider()
        }

        // Build
        CommandMenu("Build") {
            Button("Compile") { workspace?.compile() }
                .keyboardShortcut("b")
                .disabled(!state.canCompile)
            Button("Stop") { workspace?.stopCompile() }
                .keyboardShortcut(".")
                .disabled(!state.isCompiling)
            Divider()
            Toggle("Live Compile", isOn: Binding(
                get: { state.liveCompile },
                set: { AppSettings.shared.liveCompile = $0 }
            ))
            Menu("Engine") {
                Picker("Engine", selection: Binding<TeXEngine?>(
                    get: { state.engineOverride },
                    set: { workspace?.setEngineOverride($0) }
                )) {
                    Text("Automatic (\(state.defaultEngine.displayName))").tag(TeXEngine?.none)
                    ForEach(TeXEngine.allCases) { engine in
                        Text(engine.displayName).tag(TeXEngine?.some(engine))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(workspace == nil)
            Divider()
            Button("Set as Main Document") {
                if let workspace, let url = workspace.currentFile { workspace.setMainFile(url) }
            }
            .disabled(!state.hasCurrentFile)
            Button("Use Automatic Main Document") { workspace?.setMainFile(nil) }
                .disabled(!state.hasMainOverride)
            Button("Clean Auxiliary Files") { workspace?.cleanAuxiliaryFiles() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Divider()
            Button("Show in PDF") { workspace?.forwardSearch() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!state.hasCurrentFile)
            Button("Show PDF in Finder") { workspace?.revealPDF() }
                .disabled(!state.hasPDF)
            Divider()
            Button("Next Issue") { inProject { $0.goToNextIssue(forward: true) } }
                .keyboardShortcut("'")
                .disabled(workspace == nil)
            Button("Previous Issue") { inProject { $0.goToNextIssue(forward: false) } }
                .keyboardShortcut("'", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }
    }
}

/// File ▸ Open Recent. A view of its own, so the list follows `RecentProjects` through ordinary view
/// observation.
private struct OpenRecentMenu: View {
    private let recents = RecentProjects.shared

    var body: some View {
        let items = recents.existing
        Menu("Open Recent") {
            ForEach(items, id: \.self) { url in
                Button(url.lastPathComponent) { AppRouter.shared.open(folder: url) }
            }
            if !items.isEmpty { Divider() }
            Button("Clear Menu") { recents.clear() }
                .disabled(items.isEmpty)
        }
    }
}

/// File ▸ Project Labels: toggles the labels of the key window’s project; “New Label…” creates one and gives it
/// to the project. A view of its own, so the list follows `ProjectLabelStore` through ordinary observation.
private struct ProjectLabelsMenu: View {
    let workspace: ProjectWorkspace?
    let bringsProjectForward: Bool

    var body: some View {
        Menu("Project Labels") {
            if let workspace {
                LabelsMenuContent(project: workspace.folderURL) {
                    if bringsProjectForward { workspace.bringWindowToFront() }
                    workspace.labelEditor = LabelEditorRequest(mode: .create(assignTo: workspace.folderURL))
                }
            }
        }
        .disabled(workspace == nil)
    }
}

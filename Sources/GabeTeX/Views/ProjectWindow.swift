import SwiftUI
import AppKit
import TeXCore

/// The root of one project window: owns the workspace and presents window-level dialogs.
struct ProjectWindow: View {
    @LocalState private var workspace: ProjectWorkspace
    private let settings = AppSettings.shared
    private let toolchain = ToolchainModel.shared

    init(reference: ProjectReference) {
        _workspace = LocalState(wrappedValue: ProjectWorkspace(reference: reference))
    }

    var body: some View {
        ProjectContent()
            .publishesMenuState()           // before `.environment`, which it reads
            .environment(workspace)
            .environment(settings)
            .environment(toolchain)
            .background(WindowAccessor(workspace: workspace))
            .capturesWindowActions()
            .task { await workspace.start() }
            .onAppear { AppRouter.shared.projectWindowCount += 1 }
            .onDisappear { AppRouter.shared.projectWindowCount = max(0, AppRouter.shared.projectWindowCount - 1) }
            .onChange(of: toolchain.generation) { _, _ in workspace.toolchainDidChange() }
            .onChange(of: settings.liveCompile) { _, _ in workspace.liveCompileSettingChanged() }
            .onChange(of: settings.chktexEnabled) { _, _ in workspace.applyChkTeXSetting() }
            .onChange(of: settings.pdfSyncTrigger) { _, trigger in workspace.preview.syncTrigger = trigger }
    }
}

/// Split view + dialogs. Separate from `ProjectWindow` so the workspace is available from the environment.
struct ProjectContent: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @LocalState private var columnVisibility = NavigationSplitViewVisibility.all
    @LocalState private var promptText = ""

    var body: some View {
        layout
        .alert(
            workspace.alert?.title ?? "",
            isPresented: alertBinding,
            presenting: workspace.alert
        ) { alert in
            ForEach(alert.actions.indices, id: \.self) { index in
                let action = alert.actions[index]
                Button(action.title, role: action.isDestructive ? .destructive : nil) { action.handler() }
            }
            if alert.offersCancel {
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
        .alert(
            workspace.namePrompt?.title ?? "",
            isPresented: Binding(get: { workspace.namePrompt != nil }, set: { if !$0 { workspace.namePrompt = nil } }),
            presenting: workspace.namePrompt
        ) { prompt in
            TextField(prompt.fieldLabel, text: $promptText)
            Button(prompt.confirmTitle) { workspace.commit(prompt, text: promptText) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .onChange(of: workspace.namePrompt?.id) { _, _ in
            promptText = workspace.namePrompt?.initialText ?? ""
        }
        .confirmationDialog(
            pendingCloseTitle,
            isPresented: Binding(get: { workspace.pendingClose != nil }, set: { if !$0 { workspace.pendingClose = nil } }),
            titleVisibility: .visible,
            presenting: workspace.pendingClose
        ) { url in
            Button("Save") { workspace.resolvePendingClose(url, save: true) }
            Button("Don’t Save", role: .destructive) { workspace.resolvePendingClose(url, save: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your changes will be lost if you don’t save them.")
        }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(get: { workspace.pendingTrash != nil }, set: { if !$0 { workspace.pendingTrash = nil } }),
            titleVisibility: .visible,
            presenting: workspace.pendingTrash
        ) { request in
            Button("Save and Move to Trash") { workspace.resolveTrash(request, save: true) }
            Button("Discard Changes and Move to Trash", role: .destructive) { workspace.resolveTrash(request, save: false) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(String(localized: "Unsaved changes in \(Self.names(request.dirty)) will be lost if you don’t save them."))
        }
        .confirmationDialog(
            bulkCloseTitle,
            isPresented: Binding(get: { workspace.pendingBulkClose != nil }, set: { if !$0 { workspace.pendingBulkClose = nil } }),
            titleVisibility: .visible,
            presenting: workspace.pendingBulkClose
        ) { request in
            Button("Save All") { workspace.resolveBulkClose(request, save: true) }
            Button("Don’t Save", role: .destructive) { workspace.resolveBulkClose(request, save: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your changes will be lost if you don’t save them.")
        }
    }

    /// The split view with its title, toolbar, quick-open overlay and label sheet (kept apart from the dialogs
    /// below so the compiler can type-check each chain).
    private var layout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 440)
        } detail: {
            DetailView()
        }
        .navigationTitle(workspace.displayName)
        .navigationSubtitle(subtitle)
        .toolbar { ProjectToolbar() }
        .overlay { QuickOpenOverlay() }
        .sheet(item: labelEditorBinding) { request in
            LabelEditorSheet(request: request)
        }
    }

    private var labelEditorBinding: Binding<LabelEditorRequest?> {
        Binding(get: { workspace.labelEditor }, set: { workspace.labelEditor = $0 })
    }

    /// Dismissing clears the alert only if it is still the one that was on screen: a button may have
    /// replaced it with a follow-up alert.
    private var alertBinding: Binding<Bool> {
        let presented = workspace.alert?.id
        return Binding(
            get: { workspace.alert != nil },
            set: { if !$0, workspace.alert?.id == presented { workspace.alert = nil } }
        )
    }

    private static func names(_ urls: [URL]) -> String {
        ListFormatter.localizedString(byJoining: urls.map { "“\($0.lastPathComponent)”" })
    }

    private var trashTitle: String {
        guard let request = workspace.pendingTrash else { return "" }
        return String(localized: "Move “\(request.url.lastPathComponent)” to the Trash?")
    }

    private var bulkCloseTitle: String {
        guard let request = workspace.pendingBulkClose else { return "" }
        return String(localized: "Do you want to save the changes you made to \(Self.names(request.dirty))?")
    }

    private var subtitle: String {
        guard let file = workspace.currentFile else { return "" }
        return file.relativePath(from: workspace.folderURL) ?? file.lastPathComponent
    }

    private var pendingCloseTitle: String {
        guard let url = workspace.pendingClose else { return "" }
        return String(localized: "Do you want to save the changes you made to “\(url.lastPathComponent)”?")
    }
}

/// Tab strip, banners, editor | PDF, issues and status bar.
struct DetailView: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty {
                TabStrip()
            }
            BannerStack()
            WorkArea()
            StatusBar()
        }
        .animation(.smooth(duration: 0.2), value: workspace.tabs.isEmpty)
        .background {
            // Only while the setting is on, so caret moves do not re-render anything otherwise.
            if settings.followCursorInPDF { CursorFollower() }
        }
    }
}

/// Reports the caret to the workspace for “Follow cursor in PDF”. An invisible view of its own, so only this
/// tiny body is re-evaluated when the caret moves.
private struct CursorFollower: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        let cursor = workspace.editor.cursor
        let selection = workspace.editor.selectionLength
        return Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: cursor) { _, _ in workspace.cursorDidMove() }
            .onChange(of: selection) { _, _ in workspace.cursorDidMove() }
    }
}

/// Editor | PDF preview on top, Issues panel below.
struct WorkArea: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        VSplitView {
            EditorPreviewSplit()
                .frame(minHeight: 180)
            if workspace.showIssues {
                IssuesPanel()
                    .frame(minHeight: 110, idealHeight: 230)
            }
        }
    }
}

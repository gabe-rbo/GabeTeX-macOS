import SwiftUI
import TeXToolchain

/// Keys for the focused values (written by hand because `@Entry` is a macro that needs the full Xcode
/// toolchain).
private struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = ProjectWorkspace
}

private struct CommandStateFocusKey: FocusedValueKey {
    typealias Value = CommandState
}

extension FocusedValues {
    /// The workspace of the key project window (the target of menu actions).
    var workspace: ProjectWorkspace? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }

    /// What the key window’s state means for the menus (titles, enabled/disabled, checkmarks).
    var commandState: CommandState? {
        get { self[CommandStateFocusKey.self] }
        set { self[CommandStateFocusKey.self] = newValue }
    }
}

/// A value-type snapshot of everything the menu bar needs to know about the key project window.
///
/// Menus are rebuilt when a focused value changes, which is the one update path that is certain to work;
/// reading `@Observable` properties directly inside `Commands` is not relied upon.
struct CommandState: Equatable {
    var hasCurrentFile = false
    var canCompile = false
    var isCompiling = false
    var showPreview = true
    var showIssues = false
    var tabCount = 0
    var hasMainOverride = false
    var hasPDF = false
    var engineOverride: TeXEngine?
    var liveCompile = true
    var defaultEngine: TeXEngine = .pdflatex
    var isPreviewDetached = false
    /// The key window is the detached PDF window (menus that need the editor bring the project window forward).
    var isPDFWindowKey = false

    static let none = CommandState()
}

extension ProjectWorkspace {
    /// The current menu-relevant state (read inside a view body so the menus follow every change).
    func commandState(settings: AppSettings, inPDFWindow: Bool = false) -> CommandState {
        CommandState(
            hasCurrentFile: currentFile != nil,
            canCompile: mainFile != nil,
            isCompiling: isCompiling,
            showPreview: showPreview,
            showIssues: showIssues,
            tabCount: tabs.count,
            hasMainOverride: mainFileOverride != nil,
            hasPDF: pdfURL != nil,
            engineOverride: engineOverride,
            liveCompile: settings.liveCompile,
            defaultEngine: settings.defaultEngine,
            isPreviewDetached: isPreviewDetached,
            isPDFWindowKey: inPDFWindow
        )
    }
}

/// Publishes the workspace and its `CommandState` for the menu bar from inside a project window — and from the
/// detached PDF window, so the menus work while either is key.
struct MenuStatePublisher: ViewModifier {
    var inPDFWindow = false
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.workspace, workspace)
            .focusedSceneValue(\.commandState, workspace.commandState(settings: settings, inPDFWindow: inPDFWindow))
    }
}

extension View {
    func publishesMenuState(inPDFWindow: Bool = false) -> some View {
        modifier(MenuStatePublisher(inPDFWindow: inPDFWindow))
    }
}

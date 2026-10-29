import SwiftUI
import EditorKit
import TeXToolchain

/// The menu bar, bound to the command registry: every item's title, enabled state, checkmark, action and
/// keyboard shortcut come from `CommandRegistry` and `ShortcutStore`, so shortcuts changed in Settings ›
/// Shortcuts show and work here at once.
///
/// Actions go to the key project window’s workspace (`@FocusedValue`); titles, enabled states and checkmarks come
/// from its `CommandState` snapshot, which is also a focused value. This struct only decides the menu layout.
struct AppCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.commandState) private var focusedState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// The stored shortcuts: changing one rewrites this key, which rebuilds the menus.
    @AppStorage(ShortcutStore.defaultsKey) private var storedShortcuts = ""
    private let registry = CommandRegistry.shared
    private let shortcuts = ShortcutStore.shared

    private var state: CommandState { focusedState ?? .none }

    /// The context every item acts in. Also hands SwiftUI's window actions to the command palette.
    private var context: CommandContext {
        CommandEnvironment.openWindow = openWindow
        CommandEnvironment.openSettings = openSettings
        return CommandContext(workspace: workspace, state: state, openWindow: openWindow, openSettings: openSettings)
    }

    // MARK: Items

    /// A menu item for a registry command. `title` overrides the command's title (submenus show short ones);
    /// `shortcutOf` borrows another command's shortcut (⌘W closes the window when there is no tab).
    @ViewBuilder
    private func item(_ id: CommandID, title: String? = nil, shortcutOf shortcutID: CommandID? = nil) -> some View {
        if let command = registry[id] {
            let context = self.context
            Button(title ?? command.title(in: context)) { command.perform(context) }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: shortcutID ?? id))
                .disabled(!command.isEnabled(context))
        }
    }

    /// A menu item with a checkmark (`AppCommand.isOn`).
    @ViewBuilder
    private func toggle(_ id: CommandID, title: String? = nil) -> some View {
        if let command = registry[id] {
            let context = self.context
            Toggle(title ?? command.title(in: context), isOn: Binding(
                get: { command.isOn?(context) ?? false },
                set: { _ in command.perform(context) }
            ))
            .keyboardShortcut(shortcuts.keyboardShortcut(for: id))
            .disabled(!command.isEnabled(context))
        }
    }

    // MARK: Menus

    var body: some Commands {
        SidebarCommands()

        // GabeTeX ▸ Keyboard Shortcuts… (right after Settings…)
        CommandGroup(after: .appSettings) {
            item(.keyboardShortcuts)
        }

        // File. One group, in the placement that is known to render in this WindowGroup app (`.newItem`):
        // `.saveItem` shows nothing on macOS 27, and its Close / Save items never appeared.
        CommandGroup(replacing: .newItem) {
            Group {
                item(.newProject)
                item(.newFile)
                Divider()
                item(.openFolder)
                item(.openFile)
                OpenRecentMenu()
            }
            Divider()
            // The one and only ⌘W: the current tab while there is one, else the window. In the PDF window it
            // closes that window (and so docks the preview again). The system's own Close is removed (see
            // `SystemCloseItemRemover`, which recognises these two items by title). Both shortcuts are fixed.
            Group {
                if context.closesTab {
                    item(.closeTab)
                    item(.closeWindow)
                } else {
                    item(.closeWindow, shortcutOf: .closeTab)
                }
            }
            Divider()
            Group {
                item(.save)
                item(.saveAll)
            }
            Divider()
            Group {
                item(.revealInFinder)
                ProjectLabelsMenu(workspace: workspace, newLabel: registry[.newProjectLabel], context: context,
                                  shortcut: shortcuts.keyboardShortcut(for: .newProjectLabel))
            }
        }

        // Edit
        CommandGroup(after: .pasteboard) {
            Divider()
            Group {
                item(.find)
                item(.findAndReplace)
                item(.goToLine)
            }
            Divider()
            Group {
                item(.toggleComment)
                item(.indent)
                item(.outdent)
                item(.complete)
            }
            Divider()
            insertMenu
        }

        // View
        CommandGroup(after: .toolbar) {
            Divider()
            Group {
                item(.togglePreview)
                item(.togglePDFWindow)
                item(.toggleIssues)
                item(.quickOpen)
                item(.commandPalette)
            }
            Divider()
            Group {
                item(.showFiles)
                item(.showOutline)
            }
            Divider()
            Group {
                item(.documentStatistics)
                item(.presentation)
            }
            Divider()
            Group {
                item(.nextTab)
                item(.previousTab)
                Menu("Go to Tab") {
                    ForEach(1...9, id: \.self) { number in
                        item(.tab(number), title: String(localized: "Tab \(number)"))
                    }
                }
                .disabled(workspace == nil)
            }
        }

        // Window
        CommandGroup(before: .windowList) {
            item(.welcome)
            Divider()
        }

        // Build
        CommandMenu("Build") {
            Group {
                item(.compile)
                item(.stop)
            }
            Divider()
            Group {
                toggle(.liveCompile)
                Menu("Engine") {
                    toggle(.automaticEngine)
                    Divider()
                    ForEach(TeXEngine.allCases) { engine in
                        toggle(.engine(engine), title: engine.displayName)
                    }
                }
                .disabled(workspace == nil)
            }
            Divider()
            Group {
                item(.setMainDocument)
                item(.automaticMainDocument)
                item(.cleanAuxiliaryFiles)
            }
            Divider()
            Group {
                item(.showInPDF)
                item(.revealPDF)
            }
            Divider()
            Group {
                item(.nextIssue)
                item(.previousIssue)
            }
        }
    }

    /// Edit ▸ Insert: the LaTeX markup actions of the Touch Bar (no default shortcuts; assign them in Settings).
    private var insertMenu: some View {
        Menu(String(localized: "Insert")) {
            Group {
                item(.inlineMath)
                Menu(String(localized: "Display Math")) {
                    ForEach(LaTeXMarkupAction.DisplayMath.allCases, id: \.self) { kind in
                        item(.displayMath(kind), title: kind.label)
                    }
                }
                item(.fraction)
                item(.superscript)
                item(.subscript)
            }
            Divider()
            ForEach(LaTeXMarkupAction.TextStyle.allCases, id: \.self) { style in
                item(.textStyle(style))
            }
            Divider()
            Menu(String(localized: "Environments")) {
                ForEach(EditorTouchBar.environments, id: \.self) { name in
                    item(.environment(name), title: name)
                }
            }
            Menu(String(localized: "Sections")) {
                ForEach(EditorTouchBar.sections, id: \.self) { name in
                    item(.section(name), title: "\\" + name)
                }
            }
        }
        .disabled(!state.hasCurrentFile)
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

/// File ▸ Project Labels: toggles the labels of the key window’s project; “New Label…” (the registry's
/// `newProjectLabel` command, with its shortcut) creates one and gives it to the project. A view of its own, so
/// the list follows `ProjectLabelStore` through ordinary observation.
private struct ProjectLabelsMenu: View {
    let workspace: ProjectWorkspace?
    let newLabel: AppCommand?
    let context: CommandContext
    let shortcut: KeyboardShortcut?
    private let store = ProjectLabelStore.shared

    var body: some View {
        Menu("Project Labels") {
            if let workspace {
                ForEach(store.labels) { label in
                    LabelToggle(label: label, project: workspace.folderURL)
                }
                if !store.labels.isEmpty { Divider() }
                if let newLabel {
                    Button(String(localized: "New Label…")) { newLabel.perform(context) }
                        .keyboardShortcut(shortcut)
                }
            }
        }
        .disabled(workspace == nil)
    }
}

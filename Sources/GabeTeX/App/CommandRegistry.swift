import SwiftUI
import AppKit
import EditorKit

/// A stable command identifier (`"build.compile"`). Stored in the user's shortcut preferences and the command
/// palette's recents, so existing ids must never change.
struct CommandID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
    var description: String { rawValue }
}

/// Where a command is listed (Settings › Shortcuts sections, the palette's category column).
enum CommandCategory: String, CaseIterable, Identifiable {
    case file, edit, insert, view, build, window, app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: String(localized: "File")
        case .edit: String(localized: "Edit")
        case .insert: String(localized: "Insert")
        case .view: String(localized: "View")
        case .build: String(localized: "Build")
        case .window: String(localized: "Window")
        case .app: String(localized: "GabeTeX")
        }
    }
}

/// What a command acts on: the key window's workspace and its menu-state snapshot.
///
/// Menus build it from the focused scene values; the command palette builds it from the workspace it was opened
/// for (`live(workspace:inPDFWindow:)`).
struct CommandContext {
    var workspace: ProjectWorkspace?
    var state: CommandState
    var openWindow: OpenWindowAction?
    var openSettings: OpenSettingsAction?

    /// A context for `workspace` read right now (the palette; not a stale menu snapshot).
    static func live(workspace: ProjectWorkspace?, inPDFWindow: Bool) -> CommandContext {
        CommandContext(
            workspace: workspace,
            state: workspace?.commandState(settings: AppSettings.shared, inPDFWindow: inPDFWindow) ?? .none,
            openWindow: CommandEnvironment.openWindow ?? AppRouter.shared.openWindow,
            openSettings: CommandEnvironment.openSettings
        )
    }

    /// ⌘W closes the current tab, but only in a project window that has one (never in the PDF window).
    var closesTab: Bool { state.hasCurrentFile && !state.isPDFWindowKey }

    /// Runs `action` on the key window's workspace. Anything that shows the editor or a dialog lives in the
    /// project window, so when the detached PDF window is key that window comes forward first.
    func inProject(_ action: (ProjectWorkspace) -> Void) {
        guard let workspace else { return }
        if state.isPDFWindowKey { workspace.bringWindowToFront() }
        action(workspace)
    }

    /// The workspace that is presenting: the key one, or — while the presentation windows have the focus and
    /// no project window publishes its state — any presenting workspace.
    var presentingWorkspace: ProjectWorkspace? {
        if let workspace, workspace.isPresenting { return workspace }
        return WorkspaceRegistry.shared.all.first { $0.isPresenting }
    }

    func open(windowID: String) {
        if let openWindow { openWindow(id: windowID) } else { AppRouter.shared.openWindow?(id: windowID) }
    }

    func showSettings() {
        if let openSettings {
            openSettings()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.activate()
    }
}

/// SwiftUI actions that only exist inside views and `Commands`; `AppCommands` hands them over so the command
/// palette (an AppKit panel) can use them too.
enum CommandEnvironment {
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?
}

/// One command of the app: menus, the command palette and Settings › Shortcuts are all built from these.
struct AppCommand: Identifiable {
    let id: CommandID
    /// The stable, localized name (Settings › Shortcuts, palette search).
    let title: String
    let category: CommandCategory
    /// SF Symbol shown in the palette and in Settings.
    let symbol: String
    /// The shortcut a fresh installation has (identical to the menus before shortcuts became editable).
    var defaultShortcut: KeyCombo?
    /// False for shortcuts that belong to the system's conventions (⌘W, ⌘,): shown, never editable.
    var isCustomizable = true
    var showsInPalette = true
    /// False for commands that are not in GabeTeX's own menus (a shortcut could not work for them).
    var showsInSettings = true
    /// Extra words the palette matches (not shown).
    var keywords: [String] = []
    /// The title as the menu shows it right now ("Show Issues" / "Hide Issues"); nil = `title`.
    var dynamicTitle: ((CommandContext) -> String)?
    var isEnabled: (CommandContext) -> Bool = { _ in true }
    /// For toggles: whether the menu shows a checkmark.
    var isOn: ((CommandContext) -> Bool)?
    let perform: (CommandContext) -> Void

    func title(in context: CommandContext) -> String {
        dynamicTitle?(context) ?? title
    }
}

/// All commands, in menu order. Built once (titles are localized at launch).
final class CommandRegistry {
    static let shared = CommandRegistry()

    let commands: [AppCommand]
    private let index: [CommandID: Int]

    init(commands: [AppCommand] = CommandRegistry.makeCommands()) {
        var unique: [AppCommand] = []
        var index: [CommandID: Int] = [:]
        for command in commands where index[command.id] == nil {
            index[command.id] = unique.count
            unique.append(command)
        }
        self.commands = unique
        self.index = index
    }

    subscript(id: CommandID) -> AppCommand? {
        index[id].map { commands[$0] }
    }

    /// The definitions `ShortcutMap` works with.
    var shortcutDefinitions: [ShortcutMap.Definition] {
        commands.map {
            ShortcutMap.Definition(id: $0.id.rawValue, defaultCombo: $0.defaultShortcut, isCustomizable: $0.isCustomizable)
        }
    }

    /// Commands of a category, in menu order.
    func commands(in category: CommandCategory) -> [AppCommand] {
        commands.filter { $0.category == category }
    }
}

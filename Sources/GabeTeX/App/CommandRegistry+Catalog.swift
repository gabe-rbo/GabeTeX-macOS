import SwiftUI
import AppKit
import EditorKit
import TeXToolchain

// The command catalog: every menu command plus the editor and markup actions. Default shortcuts are the ones the
// menus had before shortcuts became editable (plus ⇧⌘P for the palette and ⌥⌘↩ for presentations).

extension CommandID {
    // File
    static let newProject: CommandID = "file.newProject"
    static let newFile: CommandID = "file.newFile"
    static let openFolder: CommandID = "file.openFolder"
    static let openFile: CommandID = "file.openFile"
    static let closeTab: CommandID = "file.closeTab"
    static let closeWindow: CommandID = "file.closeWindow"
    static let save: CommandID = "file.save"
    static let saveAll: CommandID = "file.saveAll"
    static let revealInFinder: CommandID = "file.revealInFinder"
    static let newProjectLabel: CommandID = "file.newProjectLabel"
    // Edit
    static let find: CommandID = "edit.find"
    static let findAndReplace: CommandID = "edit.findAndReplace"
    static let goToLine: CommandID = "edit.goToLine"
    static let toggleComment: CommandID = "edit.toggleComment"
    static let indent: CommandID = "edit.indent"
    static let outdent: CommandID = "edit.outdent"
    static let complete: CommandID = "edit.complete"
    // Insert (LaTeX markup, as on the Touch Bar)
    static let inlineMath: CommandID = "insert.inlineMath"
    static let fraction: CommandID = "insert.fraction"
    static let superscript: CommandID = "insert.superscript"
    static let `subscript`: CommandID = "insert.subscript"
    static func displayMath(_ kind: LaTeXMarkupAction.DisplayMath) -> CommandID {
        CommandID(rawValue: "insert.displayMath.\(String(describing: kind))")
    }
    static func textStyle(_ style: LaTeXMarkupAction.TextStyle) -> CommandID {
        CommandID(rawValue: "insert.\(style.rawValue)")
    }
    static func environment(_ name: String) -> CommandID { CommandID(rawValue: "insert.environment.\(name)") }
    static func section(_ name: String) -> CommandID { CommandID(rawValue: "insert.section.\(name)") }
    // View
    static let togglePreview: CommandID = "view.togglePreview"
    static let togglePDFWindow: CommandID = "view.togglePDFWindow"
    static let toggleIssues: CommandID = "view.toggleIssues"
    static let quickOpen: CommandID = "view.quickOpen"
    static let commandPalette: CommandID = "view.commandPalette"
    static let showFiles: CommandID = "view.showFiles"
    static let showOutline: CommandID = "view.showOutline"
    static let documentStatistics: CommandID = "view.documentStatistics"
    static let presentation: CommandID = "view.presentation"
    static let nextTab: CommandID = "view.nextTab"
    static let previousTab: CommandID = "view.previousTab"
    static func tab(_ number: Int) -> CommandID { CommandID(rawValue: "view.tab.\(number)") }
    // Build
    static let compile: CommandID = "build.compile"
    static let stop: CommandID = "build.stop"
    static let liveCompile: CommandID = "build.liveCompile"
    static let automaticEngine: CommandID = "build.engine.automatic"
    static func engine(_ engine: TeXEngine) -> CommandID { CommandID(rawValue: "build.engine.\(engine.rawValue)") }
    static let setMainDocument: CommandID = "build.setMainDocument"
    static let automaticMainDocument: CommandID = "build.automaticMainDocument"
    static let cleanAuxiliaryFiles: CommandID = "build.cleanAuxiliaryFiles"
    static let showInPDF: CommandID = "build.showInPDF"
    static let revealPDF: CommandID = "build.revealPDF"
    static let nextIssue: CommandID = "build.nextIssue"
    static let previousIssue: CommandID = "build.previousIssue"
    // Window and app
    static let welcome: CommandID = "window.welcome"
    static let settings: CommandID = "app.settings"
    static let keyboardShortcuts: CommandID = "app.keyboardShortcuts"
}

extension CommandRegistry {
    /// The catalog, in menu order.
    static func makeCommands() -> [AppCommand] {
        fileCommands() + editCommands() + insertCommands() + viewCommands() + buildCommands() + otherCommands()
    }

    private static func combo(_ character: Character, _ modifiers: KeyCombo.Modifiers) -> KeyCombo {
        KeyCombo(character, modifiers)
    }

    private static let hasWorkspace: (CommandContext) -> Bool = { $0.workspace != nil }
    private static let hasFile: (CommandContext) -> Bool = { $0.state.hasCurrentFile }

    // MARK: File

    private static func fileCommands() -> [AppCommand] {
        [
            AppCommand(id: .newProject, title: String(localized: "New Project…"), category: .file,
                       symbol: "plus.rectangle.on.folder", defaultShortcut: combo("n", [.command, .shift]),
                       perform: { $0.open(windowID: "new-project") }),
            AppCommand(id: .newFile, title: String(localized: "New File…"), category: .file, symbol: "doc.badge.plus",
                       defaultShortcut: combo("n", .command), isEnabled: hasWorkspace,
                       perform: { $0.inProject { $0.promptNewFile() } }),
            AppCommand(id: .openFolder, title: String(localized: "Open Folder…"), category: .file, symbol: "folder",
                       defaultShortcut: combo("o", .command),
                       perform: { _ in AppRouter.shared.chooseFolderAndOpen() }),
            AppCommand(id: .openFile, title: String(localized: "Open File…"), category: .file, symbol: "doc",
                       defaultShortcut: combo("o", [.command, .option]),
                       perform: { _ in AppRouter.shared.chooseFileAndOpen() }),
            AppCommand(id: .closeTab, title: String(localized: "Close Tab"), category: .file, symbol: "xmark",
                       defaultShortcut: combo("w", .command), isCustomizable: false,
                       isEnabled: { $0.closesTab },
                       perform: { context in
                           if let workspace = context.workspace, context.closesTab { workspace.closeCurrentTab() }
                       }),
            AppCommand(id: .closeWindow, title: String(localized: "Close Window"), category: .file,
                       symbol: "xmark.rectangle", defaultShortcut: combo("w", [.command, .shift]),
                       isCustomizable: false, perform: { _ in NSApp.keyWindow?.performClose(nil) }),
            AppCommand(id: .save, title: String(localized: "Save"), category: .file, symbol: "square.and.arrow.down",
                       defaultShortcut: combo("s", .command), isEnabled: hasFile,
                       perform: { $0.workspace?.saveCurrent() }),
            AppCommand(id: .saveAll, title: String(localized: "Save All"), category: .file,
                       symbol: "square.and.arrow.down.on.square", defaultShortcut: combo("s", [.command, .option]),
                       isEnabled: hasWorkspace, perform: { $0.workspace?.saveAll() }),
            AppCommand(id: .revealInFinder, title: String(localized: "Reveal in Finder"), category: .file,
                       symbol: "folder.badge.questionmark", isEnabled: hasFile,
                       perform: { context in
                           if let workspace = context.workspace, let url = workspace.currentFile {
                               workspace.revealInFinder(url)
                           }
                       }),
            AppCommand(id: .newProjectLabel, title: String(localized: "New Project Label…"), category: .file,
                       symbol: "tag", keywords: [String(localized: "Project Labels")], isEnabled: hasWorkspace,
                       perform: { context in
                           context.inProject { workspace in
                               workspace.labelEditor = LabelEditorRequest(mode: .create(assignTo: workspace.folderURL))
                           }
                       }),
        ]
    }

    // MARK: Edit

    private static func editCommands() -> [AppCommand] {
        [
            AppCommand(id: .find, title: String(localized: "Find…"), category: .edit, symbol: "magnifyingglass",
                       defaultShortcut: combo("f", .command), isEnabled: hasFile,
                       perform: { $0.inProject { $0.editor.showFind() } }),
            AppCommand(id: .findAndReplace, title: String(localized: "Find and Replace…"), category: .edit,
                       symbol: "text.magnifyingglass", defaultShortcut: combo("f", [.command, .option]),
                       isEnabled: hasFile, perform: { $0.inProject { $0.editor.showFind(replace: true) } }),
            AppCommand(id: .goToLine, title: String(localized: "Go to Line…"), category: .edit,
                       symbol: "arrow.right.to.line", defaultShortcut: combo("l", .command), isEnabled: hasFile,
                       perform: { $0.inProject { $0.promptGoToLine() } }),
            AppCommand(id: .toggleComment, title: String(localized: "Toggle Comment"), category: .edit,
                       symbol: "percent", defaultShortcut: combo("/", .command), isEnabled: hasFile,
                       perform: { $0.inProject { $0.editor.toggleComment() } }),
            AppCommand(id: .indent, title: String(localized: "Indent"), category: .edit, symbol: "increase.indent",
                       defaultShortcut: combo("]", .command), isEnabled: hasFile,
                       perform: { $0.inProject { $0.editor.indentSelection() } }),
            AppCommand(id: .outdent, title: String(localized: "Outdent"), category: .edit, symbol: "decrease.indent",
                       defaultShortcut: combo("[", .command), isEnabled: hasFile,
                       perform: { $0.inProject { $0.editor.outdentSelection() } }),
            AppCommand(id: .complete, title: String(localized: "Complete"), category: .edit, symbol: "text.badge.plus",
                       defaultShortcut: EditorConfiguration.defaultCompletionTrigger,
                       keywords: [String(localized: "Autocomplete")], isEnabled: hasFile,
                       perform: { context in
                           context.inProject { workspace in
                               workspace.editor.focus()
                               workspace.editor.triggerCompletion()
                           }
                       }),
        ]
    }

    // MARK: Insert

    private static func markup(_ id: CommandID, _ title: String, _ symbol: String, _ action: LaTeXMarkupAction,
                               keywords: [String] = []) -> AppCommand {
        AppCommand(id: id, title: title, category: .insert, symbol: symbol, keywords: keywords, isEnabled: hasFile,
                   perform: { context in
                       context.inProject { workspace in
                           workspace.editor.focus()
                           workspace.editor.performMarkup(action)
                       }
                   })
    }

    private static func insertCommands() -> [AppCommand] {
        var commands = [markup(.inlineMath, LaTeXMarkupAction.inlineMath.localizedName, "dollarsign", .inlineMath)]
        let displayMath = String(localized: "Display Math")
        for kind in LaTeXMarkupAction.DisplayMath.allCases {
            commands.append(markup(.displayMath(kind), String(localized: "Display Math (\(kind.label))"), "function",
                                   .displayMath(kind), keywords: [displayMath]))
        }
        commands += [
            markup(.fraction, LaTeXMarkupAction.fraction.localizedName, "divide", .fraction, keywords: ["\\frac"]),
            markup(.superscript, LaTeXMarkupAction.superscript.localizedName, "textformat.superscript", .superscript),
            markup(.subscript, LaTeXMarkupAction.subscript.localizedName, "textformat.subscript", .subscript),
        ]
        let styleSymbols: [LaTeXMarkupAction.TextStyle: String] = [.bold: "bold", .italic: "italic", .emphasis: "textformat"]
        for style in LaTeXMarkupAction.TextStyle.allCases {
            commands.append(markup(.textStyle(style), style.localizedName, styleSymbols[style] ?? "textformat",
                                   .textStyle(style), keywords: ["\\" + style.textCommand]))
        }
        let environment = String(localized: "Environment")
        for name in EditorTouchBar.environments {
            commands.append(markup(.environment(name), String(localized: "Environment (\(name))"), "curlybraces",
                                   .environment(name), keywords: [environment, "\\begin"]))
        }
        let section = String(localized: "Section")
        for name in EditorTouchBar.sections {
            commands.append(markup(.section(name), "\\\(name){…}", "number", .section(name), keywords: [section]))
        }
        return commands
    }

    // MARK: View

    private static func viewCommands() -> [AppCommand] {
        var commands: [AppCommand] = [
            AppCommand(id: .togglePreview, title: String(localized: "Show or Hide PDF Preview"), category: .view,
                       symbol: "doc.richtext", defaultShortcut: combo("p", [.command, .option]),
                       dynamicTitle: { context in
                           if context.state.isPreviewDetached { return String(localized: "Show PDF Window") }
                           return context.state.showPreview ? String(localized: "Hide PDF Preview")
                               : String(localized: "Show PDF Preview")
                       },
                       isEnabled: hasWorkspace, perform: { $0.workspace?.togglePreviewVisibility() }),
            AppCommand(id: .togglePDFWindow, title: String(localized: "Open or Attach PDF Window"), category: .view,
                       symbol: "arrow.up.forward.app",
                       dynamicTitle: { context in
                           context.state.isPreviewDetached ? String(localized: "Attach PDF to Project Window")
                               : String(localized: "Open PDF in Separate Window")
                       },
                       isEnabled: hasWorkspace, perform: { $0.workspace?.togglePreviewDetached() }),
            AppCommand(id: .toggleIssues, title: String(localized: "Show or Hide Issues"), category: .view,
                       symbol: "exclamationmark.triangle", defaultShortcut: combo("m", [.command, .shift]),
                       dynamicTitle: { context in
                           context.state.showIssues ? String(localized: "Hide Issues") : String(localized: "Show Issues")
                       },
                       isEnabled: hasWorkspace,
                       perform: { context in withAnimation(.smooth) { context.workspace?.showIssues.toggle() } }),
            AppCommand(id: .quickOpen, title: String(localized: "Quick Open…"), category: .view,
                       symbol: "doc.text.magnifyingglass", defaultShortcut: combo("p", .command), isEnabled: hasWorkspace,
                       perform: { $0.inProject { $0.isQuickOpenPresented = true } }),
            AppCommand(id: .commandPalette, title: String(localized: "Command Palette…"), category: .view,
                       symbol: "command", defaultShortcut: combo("p", [.command, .shift]), showsInPalette: false,
                       isEnabled: hasWorkspace,
                       perform: { context in
                           guard let workspace = context.workspace else { return }
                           CommandPaletteController.shared.toggle(for: workspace, inPDFWindow: context.state.isPDFWindowKey)
                       }),
            AppCommand(id: .showFiles, title: String(localized: "Show Files"), category: .view, symbol: "folder",
                       defaultShortcut: combo("1", [.command, .option]), isEnabled: hasWorkspace,
                       perform: { $0.inProject { $0.sidebarMode = .files } }),
            AppCommand(id: .showOutline, title: String(localized: "Show Outline"), category: .view,
                       symbol: "list.bullet.indent", defaultShortcut: combo("2", [.command, .option]),
                       isEnabled: hasWorkspace, perform: { $0.inProject { $0.sidebarMode = .outline } }),
            AppCommand(id: .documentStatistics, title: String(localized: "Document Statistics…"), category: .view,
                       symbol: "chart.bar.doc.horizontal",
                       keywords: [String(localized: "Word Count"), String(localized: "Pages")],
                       isEnabled: hasWorkspace, perform: { $0.inProject { $0.showDocumentStatistics() } }),
            AppCommand(id: .presentation, title: String(localized: "Start Presentation"), category: .view,
                       symbol: "play.rectangle", defaultShortcut: KeyCombo(.return, [.command, .option]),
                       keywords: ["Beamer", String(localized: "Slides")],
                       dynamicTitle: { context in
                           context.presentingWorkspace != nil ? String(localized: "End Presentation")
                               : String(localized: "Start Presentation")
                       },
                       isEnabled: { context in
                           context.presentingWorkspace != nil || (context.workspace?.canPresent ?? false)
                       },
                       perform: { context in
                           if let presenting = context.presentingWorkspace {
                               presenting.stopPresentation()
                           } else if let workspace = context.workspace, workspace.canPresent {
                               workspace.startPresentation()
                           }
                       }),
            AppCommand(id: .nextTab, title: String(localized: "Show Next Tab"), category: .view,
                       symbol: "arrow.right.square", defaultShortcut: KeyCombo(.tab, .control),
                       isEnabled: { $0.state.tabCount >= 2 }, perform: { $0.workspace?.selectNextTab() }),
            AppCommand(id: .previousTab, title: String(localized: "Show Previous Tab"), category: .view,
                       symbol: "arrow.left.square", defaultShortcut: KeyCombo(.tab, [.control, .shift]),
                       isEnabled: { $0.state.tabCount >= 2 }, perform: { $0.workspace?.selectPreviousTab() }),
        ]
        for number in 1...9 {
            commands.append(AppCommand(
                id: .tab(number), title: String(localized: "Go to Tab \(number)"), category: .view,
                symbol: "\(number).square", defaultShortcut: combo(Character("\(number)"), .command),
                isEnabled: { $0.state.tabCount >= number },
                perform: { $0.workspace?.selectTab(at: number - 1) }))
        }
        return commands
    }

    // MARK: Build

    private static func buildCommands() -> [AppCommand] {
        var commands: [AppCommand] = [
            AppCommand(id: .compile, title: String(localized: "Compile"), category: .build, symbol: "play.fill",
                       defaultShortcut: combo("b", .command), isEnabled: { $0.state.canCompile },
                       perform: { $0.workspace?.compile() }),
            AppCommand(id: .stop, title: String(localized: "Stop"), category: .build, symbol: "stop.fill",
                       defaultShortcut: combo(".", .command), isEnabled: { $0.state.isCompiling },
                       perform: { $0.workspace?.stopCompile() }),
            AppCommand(id: .liveCompile, title: String(localized: "Live Compile"), category: .build, symbol: "bolt",
                       isOn: { $0.state.liveCompile }, perform: { _ in AppSettings.shared.liveCompile.toggle() }),
            AppCommand(id: .automaticEngine, title: String(localized: "Engine: Automatic"), category: .build,
                       symbol: "gearshape.2",
                       dynamicTitle: { context in
                           String(localized: "Automatic (\(context.state.defaultEngine.displayName))")
                       },
                       isEnabled: hasWorkspace, isOn: { $0.state.engineOverride == nil },
                       perform: { $0.workspace?.setEngineOverride(nil) }),
        ]
        for engine in TeXEngine.allCases {
            commands.append(AppCommand(
                id: .engine(engine), title: String(localized: "Engine: \(engine.displayName)"), category: .build,
                symbol: "gearshape.2", isEnabled: hasWorkspace, isOn: { $0.state.engineOverride == engine },
                perform: { $0.workspace?.setEngineOverride(engine) }))
        }
        commands += [
            AppCommand(id: .setMainDocument, title: String(localized: "Set as Main Document"), category: .build,
                       symbol: "star", isEnabled: hasFile,
                       perform: { context in
                           if let workspace = context.workspace, let url = workspace.currentFile { workspace.setMainFile(url) }
                       }),
            AppCommand(id: .automaticMainDocument, title: String(localized: "Use Automatic Main Document"),
                       category: .build, symbol: "star.slash", isEnabled: { $0.state.hasMainOverride },
                       perform: { $0.workspace?.setMainFile(nil) }),
            AppCommand(id: .cleanAuxiliaryFiles, title: String(localized: "Clean Auxiliary Files"), category: .build,
                       symbol: "trash", defaultShortcut: combo("k", [.command, .shift]), isEnabled: hasWorkspace,
                       perform: { $0.workspace?.cleanAuxiliaryFiles() }),
            AppCommand(id: .showInPDF, title: String(localized: "Show in PDF"), category: .build,
                       symbol: "text.viewfinder", defaultShortcut: combo("j", [.command, .shift]),
                       keywords: ["SyncTeX"], isEnabled: hasFile, perform: { $0.workspace?.forwardSearch() }),
            AppCommand(id: .revealPDF, title: String(localized: "Show PDF in Finder"), category: .build,
                       symbol: "doc.viewfinder", isEnabled: { $0.state.hasPDF }, perform: { $0.workspace?.revealPDF() }),
            AppCommand(id: .nextIssue, title: String(localized: "Next Issue"), category: .build,
                       symbol: "chevron.down.circle", defaultShortcut: combo("'", .command), isEnabled: hasWorkspace,
                       perform: { $0.inProject { $0.goToNextIssue(forward: true) } }),
            AppCommand(id: .previousIssue, title: String(localized: "Previous Issue"), category: .build,
                       symbol: "chevron.up.circle", defaultShortcut: combo("'", [.command, .shift]),
                       isEnabled: hasWorkspace, perform: { $0.inProject { $0.goToNextIssue(forward: false) } }),
        ]
        return commands
    }

    // MARK: Window and app

    private static func otherCommands() -> [AppCommand] {
        [
            AppCommand(id: .welcome, title: String(localized: "Welcome to GabeTeX"), category: .window,
                       symbol: "house", perform: { $0.open(windowID: "welcome") }),
            AppCommand(id: .keyboardShortcuts, title: String(localized: "Keyboard Shortcuts…"), category: .app,
                       symbol: "keyboard", keywords: [String(localized: "Settings")],
                       perform: { context in
                           UserDefaults.standard.set(SettingsView.Pane.shortcuts.rawValue, forKey: SettingsView.paneKey)
                           context.showSettings()
                       }),
            // Shown in the palette only: the system's own Settings… item carries ⌘,.
            AppCommand(id: .settings, title: String(localized: "Settings…"), category: .app, symbol: "gearshape",
                       defaultShortcut: combo(",", .command), isCustomizable: false, showsInSettings: false,
                       perform: { $0.showSettings() }),
        ]
    }
}

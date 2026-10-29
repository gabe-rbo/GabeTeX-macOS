import SwiftUI
import Observation
import EditorKit
import PreviewKit
import TeXToolchain

/// App-wide preferences, persisted in `UserDefaults`. Views read only the properties they need, so
/// changing one setting re-renders only the views that depend on it.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let defaultEngine = "settings.defaultEngine"
        static let liveCompile = "settings.liveCompile"
        static let liveDelay = "settings.liveDelay"
        static let compileOnSave = "settings.compileOnSave"
        static let chktexEnabled = "settings.chktexEnabled"
        static let syncAfterBuild = "settings.syncAfterBuild"
        static let pdfSyncTrigger = "settings.pdfSyncTrigger"
        static let followCursorInPDF = "settings.followCursorInPDF"
        static let customBinDirectory = "settings.customBinDirectory"
        static let fontName = "settings.editor.fontName"
        static let fontSize = "settings.editor.fontSize"
        static let lineHeight = "settings.editor.lineHeight"
        static let showLineNumbers = "settings.editor.showLineNumbers"
        static let wrapLines = "settings.editor.wrapLines"
        static let highlightCurrentLine = "settings.editor.highlightCurrentLine"
        static let vimMode = "settings.editor.vimMode"
        static let autoPair = "settings.editor.autoPair"
        static let autoCloseEnvironments = "settings.editor.autoCloseEnvironments"
        static let autoCompletion = "settings.editor.autoCompletion"
        static let indentWidth = "settings.editor.indentWidth"
        static let insertSpaces = "settings.editor.insertSpaces"
        static let spellChecking = "settings.editor.spellChecking"
        static let tabCompletes = "settings.editor.tabCompletes"
        static let completionAcceptKeys = "settings.editor.completionAcceptKeys"
        static let showPreview = "ui.showPreview"
        static let showIssues = "ui.showIssues"
    }

    // MARK: General

    var defaultEngine: TeXEngine { didSet { defaults.set(defaultEngine.rawValue, forKey: Key.defaultEngine) } }
    var liveCompile: Bool { didSet { defaults.set(liveCompile, forKey: Key.liveCompile) } }
    /// Seconds of inactivity before a live compile starts (0.5 … 5).
    var liveDelay: Double { didSet { defaults.set(liveDelay, forKey: Key.liveDelay) } }
    var compileOnSave: Bool { didSet { defaults.set(compileOnSave, forKey: Key.compileOnSave) } }
    var chktexEnabled: Bool { didSet { defaults.set(chktexEnabled, forKey: Key.chktexEnabled) } }
    var syncAfterBuild: Bool { didSet { defaults.set(syncAfterBuild, forKey: Key.syncAfterBuild) } }
    /// The gesture in the PDF that jumps to the source: double-click (default) or ⌘-click.
    var pdfSyncTrigger: PDFSyncTrigger { didSet { defaults.set(pdfSyncTrigger.rawValue, forKey: Key.pdfSyncTrigger) } }
    /// Scroll the PDF to the caret’s position when the caret rests (off by default).
    var followCursorInPDF: Bool { didSet { defaults.set(followCursorInPDF, forKey: Key.followCursorInPDF) } }
    /// Custom TeX `bin` directory ("" = detect automatically).
    var customBinDirectory: String { didSet { defaults.set(customBinDirectory, forKey: Key.customBinDirectory) } }

    // MARK: Editor

    /// PostScript name of the editor font; "" = system monospaced (SF Mono).
    var fontName: String { didSet { defaults.set(fontName, forKey: Key.fontName) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    var lineHeight: Double { didSet { defaults.set(lineHeight, forKey: Key.lineHeight) } }
    var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: Key.showLineNumbers) } }
    var wrapLines: Bool { didSet { defaults.set(wrapLines, forKey: Key.wrapLines) } }
    var highlightCurrentLine: Bool { didSet { defaults.set(highlightCurrentLine, forKey: Key.highlightCurrentLine) } }
    var vimMode: Bool { didSet { defaults.set(vimMode, forKey: Key.vimMode) } }
    var autoPairBrackets: Bool { didSet { defaults.set(autoPairBrackets, forKey: Key.autoPair) } }
    var autoCloseEnvironments: Bool { didSet { defaults.set(autoCloseEnvironments, forKey: Key.autoCloseEnvironments) } }
    var autoCompletion: Bool { didSet { defaults.set(autoCompletion, forKey: Key.autoCompletion) } }
    var indentWidth: Int { didSet { defaults.set(indentWidth, forKey: Key.indentWidth) } }
    var insertSpaces: Bool { didSet { defaults.set(insertSpaces, forKey: Key.insertSpaces) } }
    var spellChecking: Bool { didSet { defaults.set(spellChecking, forKey: Key.spellChecking) } }
    /// Tab right after a completable prefix completes (on by default; Gabe's choice).
    var tabCompletes: Bool { didSet { defaults.set(tabCompletes, forKey: Key.tabCompletes) } }
    /// Which keys accept a suggestion of the completion popup.
    var completionAcceptKeys: CompletionAcceptKeys {
        didSet { defaults.set(completionAcceptKeys.rawValue, forKey: Key.completionAcceptKeys) }
    }

    // MARK: Window layout (shared by all project windows)

    var showPreview: Bool { didSet { defaults.set(showPreview, forKey: Key.showPreview) } }
    var showIssues: Bool { didSet { defaults.set(showIssues, forKey: Key.showIssues) } }

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }

        defaultEngine = TeXEngine(rawValue: d.string(forKey: Key.defaultEngine) ?? "") ?? .pdflatex
        liveCompile = bool(Key.liveCompile, true)
        liveDelay = min(5, max(0.5, double(Key.liveDelay, 1.0)))
        compileOnSave = bool(Key.compileOnSave, true)
        chktexEnabled = bool(Key.chktexEnabled, true)
        syncAfterBuild = bool(Key.syncAfterBuild, false)
        pdfSyncTrigger = PDFSyncTrigger(rawValue: d.string(forKey: Key.pdfSyncTrigger) ?? "") ?? .doubleClick
        followCursorInPDF = bool(Key.followCursorInPDF, false)
        customBinDirectory = d.string(forKey: Key.customBinDirectory) ?? ""

        fontName = d.string(forKey: Key.fontName) ?? ""
        fontSize = min(40, max(8, double(Key.fontSize, 13)))
        lineHeight = min(2.2, max(1.0, double(Key.lineHeight, 1.25)))
        showLineNumbers = bool(Key.showLineNumbers, true)
        wrapLines = bool(Key.wrapLines, true)
        highlightCurrentLine = bool(Key.highlightCurrentLine, true)
        vimMode = bool(Key.vimMode, false)
        autoPairBrackets = bool(Key.autoPair, true)
        autoCloseEnvironments = bool(Key.autoCloseEnvironments, true)
        autoCompletion = bool(Key.autoCompletion, true)
        indentWidth = min(8, max(1, int(Key.indentWidth, 2)))
        insertSpaces = bool(Key.insertSpaces, true)
        spellChecking = bool(Key.spellChecking, false)
        tabCompletes = bool(Key.tabCompletes, true)
        completionAcceptKeys = CompletionAcceptKeys(rawValue: d.string(forKey: Key.completionAcceptKeys) ?? "") ?? .tabAndReturn

        showPreview = bool(Key.showPreview, true)
        showIssues = bool(Key.showIssues, false)
    }

    /// The configuration handed to `LaTeXEditorView`. The completion trigger is the shortcut of Edit ▸ Complete
    /// (Settings › Shortcuts), so the menu and the editor always agree.
    var editorConfiguration: EditorConfiguration {
        EditorConfiguration(
            fontName: fontName.isEmpty ? nil : fontName,
            fontSize: CGFloat(fontSize),
            lineHeightMultiple: CGFloat(lineHeight),
            showLineNumbers: showLineNumbers,
            wrapLines: wrapLines,
            highlightCurrentLine: highlightCurrentLine,
            vimMode: vimMode,
            autoPairBrackets: autoPairBrackets,
            autoCloseEnvironments: autoCloseEnvironments,
            autoCompletion: autoCompletion,
            indentWidth: indentWidth,
            insertSpaces: insertSpaces,
            spellChecking: spellChecking,
            tabCompletes: tabCompletes,
            completionAcceptKeys: completionAcceptKeys,
            completionTrigger: ShortcutStore.shared.combo(for: .complete)
        )
    }

    /// The custom bin directory as a URL, or nil when detection is automatic.
    var customBinURL: URL? {
        let trimmed = customBinDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }
}

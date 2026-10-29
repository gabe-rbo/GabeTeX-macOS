import AppKit

/// Which keys accept the selected suggestion of the completion popup.
public nonisolated enum CompletionAcceptKeys: String, CaseIterable, Hashable, Sendable, Codable {
    /// Tab and Return both accept (the default).
    case tabAndReturn
    /// Only Tab accepts; Return closes the popup and starts a new line.
    case tabOnly
    /// Only Return accepts; Tab closes the popup and does its usual job (indent, next snippet field).
    case returnOnly

    public var acceptsTab: Bool { self != .returnOnly }
    public var acceptsReturn: Bool { self != .tabOnly }
}

/// User-configurable editor settings (persisted by the app).
public struct EditorConfiguration: Equatable, Sendable {
    /// nil → `NSFont.monospacedSystemFont` (SF Mono).
    public var fontName: String?
    public var fontSize: CGFloat
    /// Line height multiple.
    public var lineHeightMultiple: CGFloat
    public var showLineNumbers: Bool
    public var wrapLines: Bool
    public var highlightCurrentLine: Bool
    public var vimMode: Bool
    public var autoPairBrackets: Bool
    /// Typing Enter after `\begin{env}` inserts `\end{env}`.
    public var autoCloseEnvironments: Bool
    /// Show the completion popup automatically while typing (otherwise only with ⌃Space / ⌥⎋).
    public var autoCompletion: Bool
    public var indentWidth: Int
    public var insertSpaces: Bool
    public var spellChecking: Bool
    /// "Tab completes": Tab right after a completable prefix (`\com…`, inside `\ref{…}`, `\cite{…}`,
    /// `\begin{…}`, file and package arguments) opens the completion popup, or inserts the only candidate
    /// directly; anywhere else Tab keeps its usual behaviour (indent, next snippet field). Vim: insert mode only.
    public var tabCompletes: Bool
    /// Which keys accept the popup's selected suggestion.
    public var completionAcceptKeys: CompletionAcceptKeys
    /// The shortcut that always opens completion at the caret (⌃Space by default; nil = none). The app keeps it
    /// equal to the shortcut of its Edit ▸ Complete command.
    public var completionTrigger: KeyCombo?

    /// The default completion trigger: ⌃Space.
    public static let defaultCompletionTrigger = KeyCombo(.space, [.control])

    public init(
        fontName: String? = nil,
        fontSize: CGFloat = 13,
        lineHeightMultiple: CGFloat = 1.25,
        showLineNumbers: Bool = true,
        wrapLines: Bool = true,
        highlightCurrentLine: Bool = true,
        vimMode: Bool = false,
        autoPairBrackets: Bool = true,
        autoCloseEnvironments: Bool = true,
        autoCompletion: Bool = true,
        indentWidth: Int = 2,
        insertSpaces: Bool = true,
        spellChecking: Bool = false,
        tabCompletes: Bool = true,
        completionAcceptKeys: CompletionAcceptKeys = .tabAndReturn,
        completionTrigger: KeyCombo? = EditorConfiguration.defaultCompletionTrigger
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineHeightMultiple = lineHeightMultiple
        self.showLineNumbers = showLineNumbers
        self.wrapLines = wrapLines
        self.highlightCurrentLine = highlightCurrentLine
        self.vimMode = vimMode
        self.autoPairBrackets = autoPairBrackets
        self.autoCloseEnvironments = autoCloseEnvironments
        self.autoCompletion = autoCompletion
        self.indentWidth = indentWidth
        self.insertSpaces = insertSpaces
        self.spellChecking = spellChecking
        self.tabCompletes = tabCompletes
        self.completionAcceptKeys = completionAcceptKeys
        self.completionTrigger = completionTrigger
    }
}

extension EditorConfiguration {
    /// One indentation level: `indentWidth` spaces, or a tab when `insertSpaces` is false.
    public var indentUnit: String {
        insertSpaces ? String(repeating: " ", count: max(1, indentWidth)) : "\t"
    }

    /// The editor font: the configured family if it exists, otherwise SF Mono.
    public var resolvedFont: NSFont {
        let size = max(6, min(fontSize, 96))
        if let name = fontName, !name.isEmpty, let font = NSFont(name: name, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// True when a change between `self` and `other` requires re-typesetting the text
    /// (font, metrics, tab width or wrapping).
    func affectsLayout(comparedTo other: EditorConfiguration) -> Bool {
        fontName != other.fontName || fontSize != other.fontSize
            || lineHeightMultiple != other.lineHeightMultiple || wrapLines != other.wrapLines
            || indentWidth != other.indentWidth || insertSpaces != other.insertSpaces
    }
}

/// Font-derived metrics shared by the text view, the layout manager and the gutter, so that line
/// heights and baselines are identical everywhere (crisp, uniform lines regardless of fallback fonts).
struct EditorMetrics: Equatable {
    var font: NSFont
    /// Height of every line fragment (points, integral).
    var lineHeight: CGFloat
    /// Distance from the top of a line fragment to the baseline (points, integral): text is centered.
    var baselineOffset: CGFloat
    /// Advance of a space in the editor font.
    var spaceWidth: CGFloat
    var tabInterval: CGFloat

    init(configuration: EditorConfiguration) {
        let font = configuration.resolvedFont
        self.font = font
        let natural = ceil(font.ascender - font.descender + font.leading)
        let multiple = max(0.8, min(configuration.lineHeightMultiple, 3))
        let height = max(natural, (natural * multiple).rounded())
        self.lineHeight = height
        // Center the ascender…descender box in the line: baseline = (L + ascender + descender) / 2.
        self.baselineOffset = ((height + font.ascender + font.descender) / 2).rounded()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        self.spaceWidth = space > 0 ? space : font.pointSize * 0.6
        let columns = configuration.insertSpaces ? max(1, configuration.indentWidth) : max(1, configuration.indentWidth)
        self.tabInterval = self.spaceWidth * CGFloat(columns)
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.tabStops = []
        style.defaultTabInterval = tabInterval
        style.lineBreakMode = .byWordWrapping
        return style
    }
}

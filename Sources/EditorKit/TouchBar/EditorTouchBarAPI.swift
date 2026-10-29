import AppKit

// MARK: - Markup actions

/// A LaTeX markup insertion, performed on the editor's selection as **one** undoable edit
/// (`LaTeXTextView.performMarkup(_:)`). Used by the Touch Bar; menus may use it too.
///
/// Every action looks at the context of the selection:
/// - math-only constructs (`\alpha`, `\frac`, `\mathbb{R}`) are wrapped in `$…$` outside math, and merged
///   into an inline formula that ends right before the caret (`$x$|` + α → `$x\alpha$`);
/// - with a selection, wrapping actions wrap it (and keep the wrapped text selected), environments and
///   display math wrap whole lines;
/// - without a selection, insertions with something to fill in use the snippet engine (tab stops).
public nonisolated enum LaTeXMarkupAction: Hashable, Sendable {
    /// Display-math constructs offered by the Touch Bar.
    public nonisolated enum DisplayMath: String, CaseIterable, Hashable, Sendable {
        /// `\[ … \]`
        case brackets = "\\[ \\]"
        case equation
        case equationStar = "equation*"
        case align
        case alignStar = "align*"

        /// What the Touch Bar shows (LaTeX, not localized).
        public var label: String { rawValue }
    }

    /// Text styles. In math, bold/italic/emphasis become `\mathbf` / `\mathit` / `\mathit`.
    public nonisolated enum TextStyle: String, CaseIterable, Hashable, Sendable {
        case bold, italic, emphasis

        /// The command used outside math.
        public var textCommand: String {
            switch self {
            case .bold: "textbf"
            case .italic: "textit"
            case .emphasis: "emph"
            }
        }

        /// The command used inside math (`\emph` is not allowed in math mode).
        public var mathCommand: String {
            switch self {
            case .bold: "mathbf"
            case .italic, .emphasis: "mathit"
            }
        }

        /// Localized name ("Bold", "Italic", "Emphasis").
        public var localizedName: String {
            switch self {
            case .bold: String(localized: "Bold")
            case .italic: String(localized: "Italic")
            case .emphasis: String(localized: "Emphasis")
            }
        }
    }

    /// `$…$` around the selection, or `$|$`. Refused inside math.
    case inlineMath
    /// A display-math block around the selected lines, or an empty block. Refused inside math.
    case displayMath(DisplayMath)
    /// `\frac{|}{}`; with a selection `\frac{selection}{|}`.
    case fraction
    /// `^{|}` in math (`\textsuperscript{|}` in text); with a selection `^{selection}`.
    case superscript
    /// `_{|}` in math (`\textsubscript{|}` in text); with a selection `_{selection}`.
    case `subscript`
    /// A math command such as `\alpha` or `\mathbb{R}`; replaces the selection.
    case mathCommand(String)
    /// `\begin{name} … \end{name}` (snippet from the completion catalog) around the selected lines.
    case environment(String)
    /// `\section{|}` etc. (`name` without backslash); with a selection `\section{selection}`.
    case section(String)
    /// `\textbf{…}` / `\textit{…}` / `\emph{…}` (math variants in math).
    case textStyle(TextStyle)
    /// Toggles `% ` comments on the selected lines (same as ⌘/).
    case toggleComment

    /// A short, localized name (used as the undo action name).
    public var localizedName: String {
        switch self {
        case .inlineMath: String(localized: "Inline Math")
        case .displayMath: String(localized: "Display Math")
        case .fraction: String(localized: "Fraction")
        case .superscript: String(localized: "Superscript")
        case .subscript: String(localized: "Subscript")
        case .mathCommand: String(localized: "Math Symbol")
        case .environment: String(localized: "Environment")
        case .section: String(localized: "Section")
        case .textStyle(let style): style.localizedName
        case .toggleComment: String(localized: "Toggle Comment")
        }
    }
}

// MARK: - App-level state and commands

/// What the editor's Touch Bar shows about the project (set by the host app, see
/// `EditorController.touchBarStatus`).
public nonisolated struct EditorTouchBarStatus: Equatable, Sendable {
    /// The Compile item: `.running` turns it into Stop.
    public nonisolated enum CompileState: Equatable, Sendable {
        /// Nothing can be compiled (no main document): the item is disabled.
        case unavailable
        case ready
        case running
    }

    public var compile: CompileState
    public var errorCount: Int
    public var warningCount: Int
    /// Whether the PDF preview is shown; nil when the host has no preview toggle (item disabled).
    public var isPreviewVisible: Bool?
    /// Whether the PDF preview is in its own window; nil when the host cannot detach it (item disabled).
    public var isPreviewDetached: Bool?

    public init(compile: CompileState = .unavailable, errorCount: Int = 0, warningCount: Int = 0,
                isPreviewVisible: Bool? = nil, isPreviewDetached: Bool? = nil) {
        self.compile = compile
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.isPreviewVisible = isPreviewVisible
        self.isPreviewDetached = isPreviewDetached
    }

    /// Errors + warnings (what the Issues item counts).
    public var issueCount: Int { max(0, errorCount) + max(0, warningCount) }
}

/// App-level commands sent by the editor's Touch Bar (see `EditorController.onTouchBarCommand`).
public nonisolated enum EditorTouchBarCommand: Hashable, Sendable {
    case compile
    case stopCompile
    case nextIssue
    case togglePreview
    case togglePreviewWindow
}

extension EditorController {
    /// Project state shown by the editor's Touch Bar (compile/stop, issue count, preview state). Setting it
    /// updates a live Touch Bar immediately; it does nothing visible on Macs without a Touch Bar.
    public var touchBarStatus: EditorTouchBarStatus {
        get { EditorTouchBarSlot.existing(for: self)?.status ?? EditorTouchBarStatus() }
        set {
            let slot = EditorTouchBarSlot.slot(for: self)
            guard slot.status != newValue else { return }
            slot.status = newValue
            EditorTouchBarProvider.hostStateDidChange(for: self)
        }
    }

    /// Receives the Touch Bar's app-level commands (Compile, Stop, Next Issue, PDF preview). While nil, those
    /// items are disabled.
    public var onTouchBarCommand: ((EditorTouchBarCommand) -> Void)? {
        get { EditorTouchBarSlot.existing(for: self)?.onCommand }
        set {
            EditorTouchBarSlot.slot(for: self).onCommand = newValue
            EditorTouchBarProvider.hostStateDidChange(for: self)
        }
    }

    /// Performs a LaTeX markup action on the current selection as one undoable edit (see
    /// `LaTeXTextView.performMarkup(_:)`). Returns false when nothing was changed.
    @discardableResult
    public func performMarkup(_ action: LaTeXMarkupAction) -> Bool {
        editor?.performMarkup(action) ?? false
    }
}

/// Touch Bar state kept beside an `EditorController` (its stored properties are declared in EditorAPI.swift;
/// this side table keeps the Touch Bar self-contained). Entries die with their controller.
final class EditorTouchBarSlot {
    weak var owner: EditorController?
    var status = EditorTouchBarStatus()
    var onCommand: ((EditorTouchBarCommand) -> Void)?

    private static var slots: [ObjectIdentifier: EditorTouchBarSlot] = [:]

    private init(owner: EditorController) {
        self.owner = owner
    }

    static func existing(for controller: EditorController) -> EditorTouchBarSlot? {
        guard let slot = slots[ObjectIdentifier(controller)] else { return nil }
        // An identifier can be reused by a new object once the old one is gone.
        return slot.owner === controller ? slot : nil
    }

    static func slot(for controller: EditorController) -> EditorTouchBarSlot {
        if let slot = existing(for: controller) { return slot }
        slots = slots.filter { $0.value.owner != nil }
        let slot = EditorTouchBarSlot(owner: controller)
        slots[ObjectIdentifier(controller)] = slot
        return slot
    }
}

// MARK: - Identifiers and catalog

/// The editor's Touch Bar: identifiers, default layout and the symbol tables.
///
/// `LaTeXTextView.makeTouchBar()` builds it while the editor is first responder (AppKit asks lazily, and
/// only on Macs with a Touch Bar). It is customizable through View ▸ Customize Touch Bar…
public enum EditorTouchBar {
    /// Identifies the bar for customization (the user's arrangement is saved under it).
    public static let customizationIdentifier = NSTouchBar.CustomizationIdentifier("io.github.gabe-rbo.GabeTeX.editor")

    /// Item identifiers of the editor's bar.
    public enum Item {
        public static let compile = make("compile")
        public static let showInPDF = make("showInPDF")
        public static let issues = make("issues")
        public static let togglePreview = make("togglePreview")
        public static let previewWindow = make("previewWindow")
        public static let inlineMath = make("inlineMath")
        public static let displayMath = make("displayMath")
        public static let fraction = make("fraction")
        public static let superscript = make("superscript")
        public static let `subscript` = make("subscript")
        public static let greekLetters = make("greekLetters")
        public static let mathSymbols = make("mathSymbols")
        public static let environments = make("environments")
        public static let sections = make("sections")
        public static let textStyle = make("textStyle")
        public static let comment = make("comment")

        // Items inside popovers (not customizable).
        static let greekScrubber = make("greekLetters.scrubber")
        static let symbolScrubber = make("mathSymbols.scrubber")
        static let environmentScrubber = make("environments.scrubber")
        static func displayMathOption(_ kind: LaTeXMarkupAction.DisplayMath) -> NSTouchBarItem.Identifier {
            make("displayMath.\(String(describing: kind))")
        }
        static func sectionOption(_ name: String) -> NSTouchBarItem.Identifier {
            make("sections.\(name)")
        }

        private static func make(_ name: String) -> NSTouchBarItem.Identifier {
            NSTouchBarItem.Identifier("io.github.gabe-rbo.GabeTeX.editor.\(name)")
        }
    }

    /// The default arrangement (fits the 13" Touch Bar next to a collapsed Control Strip). The Issues item is
    /// appended (at the right end, so nothing else moves) while there are errors or warnings.
    public static let defaultItemIdentifiers: [NSTouchBarItem.Identifier] = [
        Item.compile, Item.showInPDF,
        Item.inlineMath, Item.displayMath, Item.fraction, Item.greekLetters, Item.mathSymbols,
        Item.environments, Item.sections, Item.textStyle,
    ]

    /// The default arrangement for a status (adds Issues when there are errors or warnings).
    public static func defaultItemIdentifiers(for status: EditorTouchBarStatus) -> [NSTouchBarItem.Identifier] {
        status.issueCount > 0 ? defaultItemIdentifiers + [Item.issues] : defaultItemIdentifiers
    }

    /// The editor's own items (everything the delegate creates).
    public static let editorItemIdentifiers: [NSTouchBarItem.Identifier] = [
        Item.compile, Item.showInPDF, Item.issues, Item.togglePreview, Item.previewWindow,
        Item.inlineMath, Item.displayMath, Item.fraction, Item.superscript, Item.subscript,
        Item.greekLetters, Item.mathSymbols, Item.environments, Item.sections, Item.textStyle, Item.comment,
    ]

    /// What View ▸ Customize Touch Bar… offers.
    public static let customizationAllowedItemIdentifiers: [NSTouchBarItem.Identifier] =
        editorItemIdentifiers + [.candidateList, .characterPicker, .flexibleSpace, .fixedSpaceSmall, .fixedSpaceLarge]

    /// A Touch Bar entry: what the key shows and the math command it inserts.
    public nonisolated struct Symbol: Hashable, Sendable {
        public var glyph: String
        public var command: String

        public init(_ glyph: String, _ command: String) {
            self.glyph = glyph
            self.command = command
        }
    }

    /// Greek letters with their own LaTeX command (lowercase including the `var` forms, then uppercase).
    public static let greekLetters: [Symbol] = [
        Symbol("α", "\\alpha"), Symbol("β", "\\beta"), Symbol("γ", "\\gamma"), Symbol("δ", "\\delta"),
        Symbol("ϵ", "\\epsilon"), Symbol("ε", "\\varepsilon"), Symbol("ζ", "\\zeta"), Symbol("η", "\\eta"),
        Symbol("θ", "\\theta"), Symbol("ϑ", "\\vartheta"), Symbol("ι", "\\iota"), Symbol("κ", "\\kappa"),
        Symbol("λ", "\\lambda"), Symbol("μ", "\\mu"), Symbol("ν", "\\nu"), Symbol("ξ", "\\xi"),
        Symbol("π", "\\pi"), Symbol("ρ", "\\rho"), Symbol("σ", "\\sigma"), Symbol("τ", "\\tau"),
        Symbol("υ", "\\upsilon"), Symbol("ϕ", "\\phi"), Symbol("φ", "\\varphi"), Symbol("χ", "\\chi"),
        Symbol("ψ", "\\psi"), Symbol("ω", "\\omega"),
        Symbol("Γ", "\\Gamma"), Symbol("Δ", "\\Delta"), Symbol("Θ", "\\Theta"), Symbol("Λ", "\\Lambda"),
        Symbol("Ξ", "\\Xi"), Symbol("Π", "\\Pi"), Symbol("Σ", "\\Sigma"), Symbol("Υ", "\\Upsilon"),
        Symbol("Φ", "\\Phi"), Symbol("Ψ", "\\Psi"), Symbol("Ω", "\\Omega"),
    ]

    /// Frequent math symbols, grouped: operators, arrows, relations, sets, operations, logic, number sets.
    /// Number sets use `\mathbb` (amssymb/amsfonts).
    public static let mathSymbols: [Symbol] = [
        Symbol("∑", "\\sum"), Symbol("∏", "\\prod"), Symbol("∫", "\\int"), Symbol("∂", "\\partial"),
        Symbol("∇", "\\nabla"), Symbol("∞", "\\infty"),
        Symbol("→", "\\to"), Symbol("↦", "\\mapsto"), Symbol("↪", "\\hookrightarrow"),
        Symbol("⇒", "\\Rightarrow"), Symbol("⇔", "\\Leftrightarrow"),
        Symbol("≤", "\\leq"), Symbol("≥", "\\geq"), Symbol("≠", "\\neq"), Symbol("≈", "\\approx"),
        Symbol("≅", "\\cong"), Symbol("≃", "\\simeq"), Symbol("≡", "\\equiv"),
        Symbol("∈", "\\in"), Symbol("∉", "\\notin"), Symbol("⊂", "\\subset"), Symbol("⊆", "\\subseteq"),
        Symbol("∪", "\\cup"), Symbol("∩", "\\cap"), Symbol("∅", "\\emptyset"),
        Symbol("×", "\\times"), Symbol("⊗", "\\otimes"), Symbol("⊕", "\\oplus"), Symbol("∘", "\\circ"),
        Symbol("∧", "\\wedge"), Symbol("∨", "\\vee"),
        Symbol("∀", "\\forall"), Symbol("∃", "\\exists"), Symbol("¬", "\\neg"),
        Symbol("ℕ", "\\mathbb{N}"), Symbol("ℤ", "\\mathbb{Z}"), Symbol("ℚ", "\\mathbb{Q}"),
        Symbol("ℝ", "\\mathbb{R}"), Symbol("ℂ", "\\mathbb{C}"),
    ]

    /// Environments offered by the Environments popover (theorem-like first).
    public static let environments: [String] = [
        "theorem", "lemma", "proposition", "corollary", "definition", "remark", "example", "proof",
        "itemize", "enumerate", "figure", "table",
    ]

    /// Sectioning commands offered by the Sections popover.
    public static let sections: [String] = ["section", "subsection", "subsubsection", "paragraph"]

    /// SF Symbols used by the editor's bar (each has a text fallback if the system lacks it).
    public static let symbolNames: [String] = [
        "play.fill", "stop.fill", "doc.text.magnifyingglass", "xmark.octagon.fill",
        "exclamationmark.triangle.fill", "checkmark.circle", "doc.richtext", "arrow.up.forward.app",
        "arrow.down.right.and.arrow.up.left", "textformat.superscript", "textformat.subscript", "bold",
        "italic", "percent",
    ]
}

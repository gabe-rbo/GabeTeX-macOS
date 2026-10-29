import AppKit
import Observation
import TeXCore
import VimKit

/// Imperative bridge between the app and the editor view, plus observable editor state for the status bar.
@Observable
public final class EditorController {
    /// Cursor position in the current buffer (1-based).
    public internal(set) var cursor = SourcePosition(line: 1, column: 1)
    public internal(set) var selectionLength = 0
    /// Current Vim mode, nil when Vim emulation is off.
    public internal(set) var vimMode: VimMode?
    /// Incomplete Vim command keys, e.g. "2d".
    public internal(set) var vimPendingKeys = ""
    /// Vim ":" / "/" command line text while typing it.
    public internal(set) var vimCommandLine: String?
    /// The last Vim message ("E486: Pattern not found: x", "3 substitutions on 2 lines"), if any.
    public internal(set) var vimMessage: String?

    /// Vim ex commands the app handles (:w, :q, :make …).
    @ObservationIgnored public var onVimExCommand: ((VimExCommand) -> Void)?
    /// ⌘-click on the argument of \input/\include/\subfile/\includegraphics… → the raw argument and kind.
    @ObservationIgnored public var onOpenReference: ((IncludeReference) -> Void)?
    /// ⌘-click on a \ref/\eqref/\cref key → label key (app jumps to the definition).
    @ObservationIgnored public var onOpenLabel: ((String) -> Void)?
    /// "Show in PDF": ⌘-click on ordinary text (not an include argument, a `\ref`-family key or a `\cite`
    /// key — those keep their own behaviour) and the "Show in PDF" item of the editor's context menu.
    /// Gives the position (1-based line, UTF-16 column) and the word there: for ⌘-click the caret has just
    /// been moved to that position; the menu item reports the clicked position without moving the caret
    /// itself (AppKit's right-click may select the word under the pointer, as in any text view). The word is `word(at:)` of that position — the word containing it or ending right at it,
    /// nil when there is none. The context-menu item only exists while this handler is set.
    @ObservationIgnored public var onShowInPDF: ((SourcePosition, String?) -> Void)?

    /// The live text view (set by the editor implementation).
    @ObservationIgnored public internal(set) weak var textView: NSTextView?
    @ObservationIgnored weak var editor: LaTeXTextView?

    public init() {}

    /// Connects the controller to an editor (done by `LaTeXEditorView`; call it yourself when using
    /// `LaTeXTextView` directly).
    public func bind(to editor: LaTeXTextView) {
        if self.editor !== editor {
            self.editor = editor
            textView = editor
        }
        if editor.controller !== self {
            editor.controller = self
            editor.vim?.publishState()
            if editor.vim == nil, vimMode != nil { vimMode = nil }
        }
    }

    /// Moves the caret to a 1-based line/column, scrolls it into view (centered) and, if requested,
    /// briefly flashes the line's content with the same soft accent highlight as `reveal(_:flash:)`.
    public func goTo(line: Int, column: Int? = nil, highlight: Bool = true) {
        guard let tv = editor, let storage = tv.textStorage else { return }
        let lines = tv.lineTable
        let index = max(0, min(line - 1, lines.lineCount - 1))
        let content = lines.contentsRange(ofLine: index, in: storage.mutableString)
        var offset = content.location + max(0, (column ?? 1) - 1)
        offset = min(offset, content.end)
        if offset < storage.length, offset > content.location {
            offset = storage.mutableString.rangeOfComposedCharacterSequence(at: offset).location
        }
        tv.reveal(caret: offset, flashRange: highlight ? tv.flashRange(trimming: content) : nil)
    }

    /// Places the caret at the start of `range`, centers it vertically (the horizontal scroll offset —
    /// negative under the floating ruler on macOS 26 — is kept) and, if `flash`, shows a soft
    /// accent-colored rounded highlight behind `range` (Light/Dark aware, following the glyph rects
    /// including wrapped lines) that fades out in ~1.2 s; with Reduce Motion it stays ~0.8 s and is then
    /// removed without animation. Used for SyncTeX jumps and navigation.
    ///
    /// Nothing is written to the text, the undo manager or the dirty state. The highlight survives
    /// scrolling and re-layout, and is cancelled by another `reveal`/`goTo`, a buffer swap, a text edit
    /// or the view leaving its window. The range is clamped to the text; an empty range highlights the
    /// content of its line (a range starting past the end only moves the caret). Does nothing while no
    /// buffer is shown.
    public func reveal(_ range: NSRange, flash: Bool = true) {
        editor?.reveal(range, flash: flash)
    }

    /// The word at or right before a UTF-16 offset of the current buffer, with its range (nil when none).
    ///
    /// A word is a run of letters, digits and combining marks (decomposed accents and emoji are safe in
    /// UTF-16; an emoji itself is not a word character). A LaTeX control word counts as a word **without**
    /// its backslash: `\section` → `section` (range excludes the backslash), and it ends at its last
    /// letter (`\alpha1` → `alpha`, `1`). Position rule: the word starting at or containing the character
    /// right after the offset wins (for `\command` that includes the backslash); otherwise the word that
    /// ends exactly at the offset; otherwise nil (between separators, in whitespace after punctuation…).
    /// The offset is clamped to the text.
    public func word(at offset: Int) -> (word: String, range: NSRange)? {
        editor?.word(at: offset)
    }

    /// Selects a range and scrolls it into view.
    public func select(_ range: NSRange) {
        guard let tv = editor, let storage = tv.textStorage else { return }
        let r = range.clamped(to: storage.length)
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
    }

    /// Makes the editor first responder.
    public func focus() {
        guard let tv = editor else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Inserts text at the selection as an undoable user edit (no auto-pairing).
    public func insertText(_ text: String) {
        guard let tv = editor, tv.buffer != nil else { return }
        let selection = tv.selectedRange()
        tv.performEdit([TextEdit(range: selection, text: text)],
                       selection: NSRange(location: selection.location + text.utf16.count, length: 0))
    }

    /// Toggles `% ` comments on the selected lines (⌘/).
    public func toggleComment() {
        editor?.toggleComment()
    }

    /// Indents the selected lines by one level.
    public func indentSelection() {
        editor?.shiftSelectedLines(outdent: false)
    }

    /// Outdents the selected lines by one level.
    public func outdentSelection() {
        editor?.shiftSelectedLines(outdent: true)
    }

    /// Shows the find bar (⌘F) / find-and-replace (⌥⌘F).
    public func showFind(replace: Bool = false) {
        guard let tv = editor else { return }
        focus()
        tv.showFindBar(replace: replace)
    }

    /// Opens the completion popup at the caret (⌃Space).
    public func triggerCompletion() {
        editor?.completion.trigger(manual: true)
    }

    /// The selected text, if any.
    public var selectedText: String? {
        guard let tv = editor, let storage = tv.textStorage else { return nil }
        let r = tv.selectedRange().clamped(to: storage.length)
        return r.length > 0 ? storage.mutableString.substring(with: r) : nil
    }
}

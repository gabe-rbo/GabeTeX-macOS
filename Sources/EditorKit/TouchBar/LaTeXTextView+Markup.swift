import AppKit
import TeXCore
import VimKit

extension LaTeXTextView {
    /// Whether a caret at `offset` (UTF-16) is in math mode (`$…$`, `\[…\]`, `equation`, `align` …),
    /// computed from the current text (not from possibly stale highlighting).
    public func isMathMode(at offset: Int) -> Bool {
        guard let storage = textStorage else { return false }
        if offset > MathModeProbe.prefixLimit {
            return MathModeProbe.isMath(at: offset, tokens: syntaxTokens)   // very large document: highlighter tokens
        }
        return MathModeProbe.isMath(at: offset, in: storage.mutableString)
    }

    /// Performs a LaTeX markup action on the selection as **one** undoable edit (see `LaTeXMarkupAction`).
    /// Returns false when nothing changed (no buffer, not editable, refused in this context — which beeps).
    ///
    /// Vim: works in every mode except while typing a `:`/`/` command line (beeps). In normal/visual mode an
    /// insertion that leaves something to fill in (`\frac{|}{}`, `\section{|}`, an empty environment)
    /// switches to insert mode, like a snippet; anything else stays in (or returns to) normal mode with the
    /// cursor on the inserted or wrapped text. The engine's pending keys are discarded.
    @discardableResult
    public func performMarkup(_ action: LaTeXMarkupAction) -> Bool {
        guard let storage = textStorage, let buffer, isEditable else { return false }
        let vimMode = vim?.engine.mode
        if vimMode == .commandLine {
            NSSound.beep()
            return false
        }
        if hasMarkedText() { unmarkText() }
        completion.dismiss()
        let commandMode = vimMode == .normal || vimMode == .visual || vimMode == .visualLine
        let text = storage.mutableString
        let selection = selectedRange().clamped(to: storage.length)
        let caret = selection.location
        let afterDollar = selection.length == 0 && caret > 0 && text.character(at: caret - 1) == 36
        let planner = MarkupPlanner(text: text, selection: selection, indentUnit: configuration.indentUnit,
                                    lineEnding: lineEnding, mathAtLocation: isMathMode(at: caret),
                                    mathBeforeLocation: afterDollar && isMathMode(at: caret - 1))
        let plan = planner.plan(action)
        let name = action.localizedName
        let changeCount = buffer.changeCount

        switch plan {
        case .refuse:
            NSSound.beep()
            return false

        case .toggleComment:
            toggleComment()
            if commandMode { vim?.setMode(.normal) }

        case .snippet(let range, let snippet):
            // Insert mode first: switching modes afterwards would collapse the selected placeholder.
            if commandMode { vim?.setMode(.insert) }
            insertCompletion(CompletionItem(kind: .snippet, label: name, insertText: snippet), replacing: range)
            if buffer.changeCount != changeCount { undoManager?.setActionName(name) }

        case .replace(let range, let newText, let newSelection, let normalCaret, let expectsTyping):
            if commandMode, expectsTyping { vim?.setMode(.insert) }
            guard performEdit([TextEdit(range: range, text: newText)], selection: newSelection, actionName: name) else {
                return false
            }
            if commandMode, !expectsTyping {
                let length = textStorage?.length ?? 0
                setSelectedRange(NSRange(location: max(0, min(normalCaret, length)), length: 0))
                vim?.setMode(.normal)
            }
            if case .inlineMath = action, selection.length == 0 {
                // Like a typed `$`: typing `$` again steps over the closer, Backspace removes the empty pair.
                autoClosers.append(newSelection.location)
            }
        }
        scrollRangeToVisible(selectedRange())
        return buffer.changeCount != changeCount
    }
}

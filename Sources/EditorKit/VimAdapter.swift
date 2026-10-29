import AppKit
import TeXCore
import VimKit

/// Connects a `VimEngine` to the text view: `VimTextBuffer` conformance (undoable edits, undo groups,
/// selection, visible lines), key routing, block caret state, controller state and clipboard registers.
final class VimAdapter: VimTextBuffer {
    unowned let textView: LaTeXTextView
    let engine = VimEngine()
    /// Undo groups opened by the engine and still open.
    private var openGroups = 0

    init(textView: LaTeXTextView) {
        self.textView = textView
        engine.readClipboard = { [weak textView] in
            (textView?.vimPasteboard ?? .general).string(forType: .string)
        }
        engine.writeClipboard = { [weak textView] text in
            let pasteboard = textView?.vimPasteboard ?? .general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        engine.onModeChange = { [weak self] mode in
            self?.modeDidChange(mode)
        }
        engine.onExCommand = { [weak self] command in
            self?.textView.controller?.onVimExCommand?(command)
        }
        engine.onMessage = { [weak self] message in
            self?.textView.controller?.vimMessage = message
        }
        engine.onViewport = { [weak self] command in
            self?.scrollCursor(command)
        }
        engine.indentUnit = textView.configuration.indentUnit
    }

    /// Normal-mode-like states draw a block caret.
    var wantsBlockCaret: Bool {
        switch engine.mode {
        case .normal, .visual, .visualLine, .commandLine: true
        case .insert, .replace: false
        }
    }

    /// Insert/replace mode: typing goes to the text view (completion and auto-pairing allowed).
    var isInsertLike: Bool { engine.mode == .insert || engine.mode == .replace }

    // MARK: - Keys

    /// Routes a key to the engine. Returns true when the key was consumed (the text view must not
    /// handle it). In normal/visual mode every non-⌘ key is consumed, even unknown ones.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        // Outside insert/replace mode dead keys (`^` `~` `` ` `` `´` on ABNT2 / US-International) are Vim
        // commands: resolve them through the layout. Insert mode keeps the native dead-key composition.
        guard let key = Self.key(for: event, resolvingDeadKeys: !isInsertLike) else {
            return !isInsertLike
        }
        var consumed = false
        textView.batchEdits {
            consumed = engine.handle(key, in: self)
        }
        publishState()
        if !consumed, !isInsertLike {
            return true   // never let normal-mode keys type text
        }
        return consumed
    }

    /// Converts a key event to a `VimKey` (nil for keys Vim does not know).
    ///
    /// A dead key arrives with empty `event.characters`. With `resolvingDeadKeys` (normal, visual and
    /// command-line modes) it is translated through the current keyboard layout to the character it
    /// types on its own (`~`, `^`, `` ` ``, `´`), and the event is not fed to the text input system, so
    /// no dead-key state is left to combine with the next keystroke.
    static func key(for event: NSEvent, resolvingDeadKeys: Bool = false) -> VimKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        switch event.keyCode {
        case 53: return VimKey(special: .escape)
        case 36, 76: return VimKey(special: .enter, control: control)
        case 51: return VimKey(special: .backspace, control: control)
        case 48: return flags.contains(.shift) ? nil : VimKey(special: .tab, control: control)
        case 117: return VimKey(special: .delete, control: control)
        case 123: return VimKey(special: .left, control: control)
        case 124: return VimKey(special: .right, control: control)
        case 125: return VimKey(special: .down, control: control)
        case 126: return VimKey(special: .up, control: control)
        case 115: return VimKey(special: .home, control: control)
        case 119: return VimKey(special: .end, control: control)
        case 116: return VimKey(special: .pageUp, control: control)
        case 121: return VimKey(special: .pageDown, control: control)
        default: break
        }
        if control {
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else { return nil }
            if characters == "[" { return VimKey(special: .escape) }
            return VimKey(characters, control: true)
        }
        var characters = event.characters ?? ""
        if characters.isEmpty, resolvingDeadKeys, let resolved = KeyboardLayoutTranslator.deadKeyCharacters(for: event) {
            characters = resolved
        }
        guard !characters.isEmpty else { return nil }
        for scalar in characters.unicodeScalars {
            if scalar.value < 32 || scalar.value == 127 || (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return VimKey(characters)
    }

    /// Force a mode (e.g. normal when enabling Vim).
    func setMode(_ mode: VimMode) {
        textView.batchEdits {
            engine.setMode(mode, in: self)
        }
        publishState()
    }

    /// The user changed the selection with the mouse: keep the engine's visual state consistent.
    func mouseSelectionDidChange() {
        publishState()
    }

    private func modeDidChange(_ mode: VimMode) {
        if !isInsertLike {
            textView.completion.dismiss()
            textView.endSnippetSession()
            textView.autoClosers = []
        }
        textView.updateInsertionPointStateAndRestartTimer(true)
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
        publishState()
    }

    /// Mirrors the engine state into the controller (status bar).
    func publishState() {
        guard let controller = textView.controller else { return }
        if controller.vimMode != engine.mode { controller.vimMode = engine.mode }
        if controller.vimPendingKeys != engine.pendingKeys { controller.vimPendingKeys = engine.pendingKeys }
        if controller.vimCommandLine != engine.commandLine { controller.vimCommandLine = engine.commandLine }
    }

    private func scrollCursor(_ command: VimViewportCommand) {
        guard let scroll = textView.enclosingScrollView, let lm = textView.layoutManager,
              let storage = textView.textStorage else { return }
        let caret = min(textView.selectedRange().location, max(0, storage.length - 1))
        guard storage.length > 0 else { return }
        let glyph = lm.glyphIndexForCharacter(at: caret)
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
        let visibleHeight = scroll.contentView.bounds.height
        let y: CGFloat = switch command {
        case .cursorToTop: rect.minY
        case .cursorToCenter: rect.midY - visibleHeight / 2
        case .cursorToBottom: rect.maxY - visibleHeight
        }
        let maxY = max(0, textView.frame.height - visibleHeight)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: max(0, min(y, maxY))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - VimTextBuffer

    var vimText: NSString {
        textView.textStorage?.mutableString ?? ""
    }

    var vimSelection: NSRange {
        get { textView.selectedRange() }
        set {
            let old = textView.selectedRange()
            let length = textView.textStorage?.length ?? 0
            let range = newValue.clamped(to: length)
            textView.setSelectedRange(range)
            // Scroll to the end that moved (the Vim cursor).
            let focus = range.location != old.location || range.length == 0
                ? NSRange(location: range.location, length: 0)
                : NSRange(location: range.end, length: 0)
            textView.scrollRangeToVisible(focus)
        }
    }

    func vimReplace(_ range: NSRange, with string: String) {
        textView.performEdit([TextEdit(range: range, text: string)])
    }

    func vimBeginUndoGroup() {
        guard let undo = textView.undoManager else { return }
        textView.breakUndoCoalescing()
        undo.beginUndoGrouping()
        openGroups += 1
    }

    func vimEndUndoGroup() {
        guard openGroups > 0 else { return }
        openGroups -= 1
        textView.breakUndoCoalescing()
        // The run loop may already have closed the outer automatic group; never end more groups than are open.
        if let undo = textView.undoManager, undo.groupingLevel > 0 {
            undo.endUndoGrouping()
        }
    }

    func vimUndo() {
        guard let undo = textView.undoManager else { return }
        textView.breakUndoCoalescing()
        while undo.groupingLevel > 1 { undo.endUndoGrouping() }
        if undo.canUndo { undo.undo() } else { NSSound.beep() }
    }

    func vimRedo() {
        guard let undo = textView.undoManager else { return }
        textView.breakUndoCoalescing()
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        if undo.canRedo { undo.redo() } else { NSSound.beep() }
    }

    var vimVisibleLines: ClosedRange<Int>? {
        guard textView.enclosingScrollView != nil, let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return nil }
        var rect = textView.visibleRect
        rect.origin.y -= textView.textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let lines = textView.lineTable
        var first = lines.lineIndex(containing: chars.location)
        var last = lines.lineIndex(containing: max(chars.location, chars.end - 1))
        // Only fully visible lines.
        let firstRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: lines.startOfLine(first)), effectiveRange: nil)
        if firstRect.minY < rect.minY - 0.5, first < last { first += 1 }
        let lastRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: lines.startOfLine(last)), effectiveRange: nil)
        if lastRect.maxY > rect.maxY + 0.5, last > first { last -= 1 }
        return (first + 1)...(last + 1)
    }
}

extension LaTeXTextView {
    /// Turns Vim emulation on/off (block caret, controller state).
    func setVimEnabled(_ enabled: Bool) {
        if enabled {
            if vim == nil {
                let adapter = VimAdapter(textView: self)
                vim = adapter
                adapter.setMode(.normal)
            }
        } else if vim != nil {
            vim = nil
            if let controller {
                controller.vimMode = nil
                controller.vimPendingKeys = ""
                controller.vimCommandLine = nil
                controller.vimMessage = nil
            }
        }
        updateInsertionPointStateAndRestartTimer(true)
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
    }

    /// The Vim engine, when Vim emulation is on (for tests and advanced hosts).
    public var vimEngine: VimEngine? { vim?.engine }
}

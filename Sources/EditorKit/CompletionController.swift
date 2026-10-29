import AppKit
import SwiftUI
import TeXCore

/// Observable state of the completion popup (read by the SwiftUI list).
@Observable
final class CompletionModel {
    var items: [CompletionItem] = []
    var selectedIndex = 0
    var prefix = ""
    /// Bumped to request scrolling the selection into view.
    var scrollRequest = 0
}

/// Drives the completion popup of a `LaTeXTextView`: triggering (auto, debounced, and manual),
/// live re-filtering while typing, keyboard navigation and acceptance.
final class CompletionController {
    unowned let textView: LaTeXTextView
    let model = CompletionModel()
    /// The current result (nil when inactive). Active even without a window (headless use).
    private(set) var result: CompletionResult?
    private var panel: CompletionPanel?
    private var hostingView: NSHostingView<CompletionListView>?
    private var pendingTrigger: Task<Void, Never>?
    private var refreshScheduled = false
    private var resignObserver: NSObjectProtocol?
    /// The user picked the selected row (arrow keys); otherwise it is the default one (see `acceptWithTab`).
    private var selectionChosen = false
    /// Auto-trigger delay after typing.
    var debounce: Duration = .milliseconds(80)

    static let rowHeight: CGFloat = 24
    static let maxVisibleRows = 9
    static let verticalPadding: CGFloat = 6

    init(textView: LaTeXTextView) {
        self.textView = textView
    }

    var isVisible: Bool { result != nil }

    // MARK: - Triggering

    /// Computes completions at the caret and shows them. `manual` (⌃Space / ⌥⎋) also works after a
    /// bare `\` and beeps when nothing is available.
    func trigger(manual: Bool) {
        pendingTrigger?.cancel()
        pendingTrigger = nil
        guard textView.buffer != nil, textView.vim?.isInsertLike ?? true else { return }
        guard let fresh = compute() else {
            dismiss()
            if manual { NSSound.beep() }
            return
        }
        present(fresh, resetSelection: true)
    }

    /// True while an automatic popup is scheduled: the user has just typed a completable prefix and the popup
    /// is about to open (`debounce`).
    var isTriggerPending: Bool { pendingTrigger != nil }

    func cancelPendingTrigger() {
        pendingTrigger?.cancel()
        pendingTrigger = nil
    }

    /// Called after every edit. While visible, re-filters; otherwise may schedule an auto-trigger.
    func textDidChange(byTyping: Bool) {
        if isVisible {
            scheduleRefresh()
            return
        }
        guard byTyping, textView.configuration.autoCompletion, textView.vim?.isInsertLike ?? true,
              let storage = textView.textStorage else {
            cancelPendingTrigger()
            return
        }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { cancelPendingTrigger(); return }
        let text = storage.mutableString
        let caret = selection.location
        let lineStart = textView.lineTable.startOfLine(textView.lineTable.lineIndex(containing: caret))
        let wantsTrigger = TextScan.commandPrefixStart(before: caret, in: text) != nil
            || TextScan.isInCommandArgument(caret: caret, in: text, lineStart: lineStart)
        guard wantsTrigger else { cancelPendingTrigger(); return }
        pendingTrigger?.cancel()
        let delay = debounce
        pendingTrigger = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingTrigger = nil
            self.trigger(manual: false)
        }
    }

    func selectionDidChange() {
        guard let result else { return }
        let selection = textView.selectedRange()
        let anchor = result.replacementRange.location
        let line = textView.lineTable.lineIndex(containing: selection.location)
        if selection.length > 0 || selection.location < anchor
            || line != textView.lineTable.lineIndex(containing: anchor) {
            dismiss()
        } else {
            scheduleRefresh()
        }
    }

    private func compute() -> CompletionResult? {
        guard let storage = textView.textStorage else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        guard let fresh = textView.completionProvider(storage.mutableString, selection.location, textView.symbols),
              !fresh.items.isEmpty else { return nil }
        let range = fresh.replacementRange
        guard range.location != NSNotFound, range.end <= storage.length, range.location <= selection.location else { return nil }
        return fresh
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshNow()
        }
    }

    /// Re-computes synchronously (before accepting, so the replacement range is current).
    func refreshNow() {
        guard isVisible else { return }
        guard let fresh = compute() else {
            dismiss()
            return
        }
        present(fresh, resetSelection: false)
    }

    // MARK: - Presentation

    private func present(_ fresh: CompletionResult, resetSelection: Bool, selecting preferred: Int = 0) {
        let previousID = result.flatMap { r in model.items.indices.contains(model.selectedIndex) ? r.items[model.selectedIndex].id : nil }
        result = fresh
        model.prefix = fresh.prefix
        model.items = fresh.items
        if !resetSelection, let previousID, let index = fresh.items.firstIndex(where: { $0.id == previousID }) {
            model.selectedIndex = index
        } else {
            model.selectedIndex = fresh.items.indices.contains(preferred) ? preferred : 0
            selectionChosen = false
        }
        model.scrollRequest += 1
        showPanel()
    }

    private func showPanel() {
        guard let window = textView.window, let result else { return }
        let panel = self.panel ?? makePanel()
        let size = panelSize(for: result.items)
        guard let frame = panelFrame(size: size, anchor: result.replacementRange.location) else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame, display: false)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    /// Keeps the popup attached to the text while scrolling (hides it when the anchor scrolls away).
    func reposition() {
        guard isVisible, let panel, panel.isVisible, let result else { return }
        guard let frame = panelFrame(size: panel.frame.size, anchor: result.replacementRange.location) else {
            dismiss()
            return
        }
        panel.setFrameOrigin(frame.origin)
    }

    func dismiss() {
        cancelPendingTrigger()
        guard result != nil || panel?.isVisible == true else { return }
        result = nil
        model.items = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private func makePanel() -> CompletionPanel {
        let panel = CompletionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.isMovable = false
        let list = CompletionListView(model: model, rowHeight: Self.rowHeight, verticalPadding: Self.verticalPadding) { [weak self] index in
            self?.accept(index: index)
        }
        let hosting = NSHostingView(rootView: list)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    private func panelSize(for items: [CompletionItem]) -> NSSize {
        let labelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let detailFont = NSFont.systemFont(ofSize: 11)
        var labelWidth: CGFloat = 0
        var detailWidth: CGFloat = 0
        var hasPackage = false
        for item in items.prefix(60) {
            labelWidth = max(labelWidth, (item.label as NSString).size(withAttributes: [.font: labelFont]).width)
            if let detail = item.detail {
                detailWidth = max(detailWidth, (detail as NSString).size(withAttributes: [.font: detailFont]).width)
            }
            if item.package != nil { hasPackage = true }
        }
        let width = 12 + 18 + 8 + min(labelWidth, 300) + 16 + min(detailWidth, 220) + (hasPackage ? 80 : 0) + 12
        let rows = CGFloat(min(items.count, Self.maxVisibleRows))
        return NSSize(width: max(240, min(ceil(width), 620)), height: rows * Self.rowHeight + Self.verticalPadding * 2)
    }

    /// Screen frame below the anchor character (above it when there is no room below).
    private func panelFrame(size: NSSize, anchor: Int) -> NSRect? {
        guard let window = textView.window else { return nil }
        var actual = NSRange(location: NSNotFound, length: 0)
        let caretRect = textView.firstRect(forCharacterRange: NSRange(location: anchor, length: 0), actualRange: &actual)
        guard caretRect != .zero else { return nil }
        // Hide when the anchor is scrolled out of the editor.
        let inWindow = window.convertFromScreen(caretRect)
        let inView = textView.convert(inWindow, from: nil)
        if !textView.visibleRect.insetBy(dx: -2, dy: -2).intersects(inView) { return nil }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let textInset: CGFloat = 12 + 18 + 8 + 6 // padding + badge + spacing: aligns the label with the typed text
        var x = caretRect.minX - textInset
        var y = caretRect.minY - size.height - 3
        if y < screen.minY { y = caretRect.maxY + 3 }
        x = max(screen.minX + 4, min(x, screen.maxX - size.width - 4))
        y = max(screen.minY, min(y, screen.maxY - size.height))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Keyboard

    /// Handles navigation keys while visible. Returns true when the key was consumed.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else {
            if event.keyCode == 49, flags == .control { return false } // ⌃Space: re-trigger
            return false
        }
        let keys = textView.configuration.completionAcceptKeys
        switch event.keyCode {
        case 125: move(by: 1); return true                         // ↓
        case 126: move(by: -1); return true                        // ↑
        case 121: move(by: Self.maxVisibleRows - 1); return true    // PgDn
        case 116: move(by: -(Self.maxVisibleRows - 1)); return true // PgUp
        case 36, 76:                                                // Return, Enter
            if keys.acceptsReturn { acceptSelected(); return true }
            dismiss()
            return false                                            // a new line, as usual
        case 48:                                                    // Tab
            if keys.acceptsTab, !event.modifierFlags.contains(.shift) { acceptWithTab(); return true }
            if keys.acceptsTab { acceptSelected(); return true }
            dismiss()
            if event.modifierFlags.contains(.shift) { return false } // ⇧Tab: outdent / previous field
            textView.insertPlainTab()                               // indent / next snippet field
            return true
        case 53: dismiss(); return true                             // Esc
        default: return false
        }
    }

    /// Same for action selectors (key bindings).
    func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(by: Self.maxVisibleRows - 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(by: -(Self.maxVisibleRows - 1))
        case #selector(NSResponder.insertNewline(_:)):
            guard textView.configuration.completionAcceptKeys.acceptsReturn else {
                dismiss()
                return false                                        // the text view inserts the new line
            }
            acceptSelected()
        case #selector(NSResponder.insertTab(_:)):
            if textView.configuration.completionAcceptKeys.acceptsTab {
                acceptWithTab()
            } else {
                dismiss()
                textView.insertPlainTab()
            }
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    // MARK: - Tab completion

    /// What Tab inserts from a result when the user has not picked a row.
    private enum TabChoice: Equatable {
        case accept(Int)
        /// Nothing to complete: Tab does its usual job (indent, next snippet field).
        case plainTab
    }

    /// Whether accepting `item` would only re-type the text it replaces (`\sec` → `\sec`).
    private func isNoOp(_ item: CompletionItem, in result: CompletionResult, text: NSString) -> Bool {
        let range = result.replacementRange
        let current = range.end <= text.length ? text.substring(with: range) : ""
        let snippet = Snippet(parsing: item.insertText)
        return snippet.text == current && snippet.tabStops.isEmpty
    }

    /// Tab never just re-types what is there. The first suggestion is taken unless it equals the typed text
    /// (`\sec` is a command, the secant): then Tab extends to the first suggestion that starts with it
    /// (`\section`), or — when there is none (`\alpha`), or inside a snippet field, where Tab means "next
    /// field" — does its usual job.
    private func tabChoice(for result: CompletionResult) -> TabChoice {
        guard let storage = textView.textStorage, let first = result.items.first else { return .plainTab }
        let text = storage.mutableString
        if !isNoOp(first, in: result, text: text) { return .accept(0) }
        if textView.snippetSession != nil { return .plainTab }
        let typed = result.prefix.lowercased()
        let extended = result.items.firstIndex { item in
            item.label.lowercased().hasPrefix(typed) && !isNoOp(item, in: result, text: text)
        }
        return extended.map { .accept($0) } ?? .plainTab
    }

    /// Tab with the popup open (Tab is an accept key): accepts the row the user picked; otherwise what
    /// `tabChoice` says — exactly what Tab does before the popup has appeared (`tabComplete`).
    func acceptWithTab() {
        if selectionChosen {
            acceptSelected()
            return
        }
        refreshNow()
        guard let result else {
            textView.insertPlainTab()
            return
        }
        switch tabChoice(for: result) {
        case .accept(let index):
            accept(index: index)
        case .plainTab:
            dismiss()
            textView.insertPlainTab()
        }
    }

    /// "Tab completes" (`EditorConfiguration.tabCompletes`) with the popup closed. Returns false — Tab then does
    /// its usual job — when there is no completable prefix right before the caret or nothing to add:
    /// - a command needs at least one letter after the backslash (`\s|`, not a bare `\|`) and must end at the
    ///   caret (not `\sec|tion`); argument contexts (`\ref{|`, `\cite{a,|`, `\begin{fig|`, files, packages)
    ///   may be empty;
    /// - suggestions that only re-type the text don't count (see `tabChoice`).
    ///
    /// Otherwise: exactly one suggestion adds something → it is inserted. Several → if the user has just typed
    /// (`triggerPending`: the automatic popup was about to open) and Tab accepts, Tab does what it would do with
    /// that popup open — insert the suggestion — so the result never depends on typing speed; else the popup
    /// opens with that suggestion selected.
    func tabComplete(triggerPending: Bool = false) -> Bool {
        cancelPendingTrigger()
        guard textView.buffer != nil, textView.vim?.isInsertLike ?? true, let storage = textView.textStorage,
              let fresh = compute() else { return false }
        let text = storage.mutableString
        let caret = textView.selectedRange().location
        if fresh.prefix.hasPrefix("\\") {
            guard fresh.prefix.utf16.count >= 2 else { return false }
            if caret < text.length, TextScan.isCommandLetter(text.character(at: caret)) { return false }
        }
        guard case .accept(let index) = tabChoice(for: fresh) else { return false }
        let additions = fresh.items.filter { !isNoOp($0, in: fresh, text: text) }.count
        if additions == 1 || (triggerPending && textView.configuration.completionAcceptKeys.acceptsTab) {
            dismiss()
            textView.insertCompletion(fresh.items[index], replacing: fresh.replacementRange)
        } else {
            present(fresh, resetSelection: true, selecting: index)
        }
        return true
    }

    private func move(by delta: Int) {
        let count = model.items.count
        guard count > 0 else { return }
        var index = model.selectedIndex + delta
        if abs(delta) == 1 {
            index = (index + count) % count // wrap around with the arrows
        } else {
            index = max(0, min(index, count - 1))
        }
        model.selectedIndex = index
        model.scrollRequest += 1
        selectionChosen = true
    }

    func acceptSelected() {
        accept(index: model.selectedIndex)
    }

    func accept(index: Int) {
        let chosenID = model.items.indices.contains(index) ? model.items[index].id : nil
        refreshNow()
        // refreshNow may have re-filtered the list; keep the user's choice by identity when possible.
        guard let result, let item = chosenID.flatMap({ id in result.items.first { $0.id == id } })
                ?? (result.items.indices.contains(index) ? result.items[index] : nil) else {
            dismiss()
            return
        }
        let range = result.replacementRange
        dismiss()
        textView.insertCompletion(item, replacing: range)
    }

    /// The items currently offered (headless inspection).
    var items: [CompletionItem] { result?.items ?? [] }
}

/// Borderless, non-activating panel: never becomes key, so the text view keeps typing focus.
final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

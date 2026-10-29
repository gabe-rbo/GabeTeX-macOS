import SwiftUI
import AppKit
import TeXCore
import TeXToolchain
import EditorKit
import PreviewKit

// MARK: - Two-way SyncTeX with word-level precision

/// SyncTeX knows lines, not words. In both directions the app refines the answer to the exact word:
/// - PDF → source: the PDF reports the clicked word and its surroundings; `SourceWordLocator` finds that word
///   in the source around SyncTeX's line (see its documentation for the matching rules).
/// - Source → PDF: the app hands PreviewKit the word at the caret and its surroundings, so the PDF highlights
///   that word instead of the whole box SyncTeX returned.
extension ProjectWorkspace {
    // MARK: Source → PDF

    /// ⇧⌘J (Build ▸ Show in PDF): shows the PDF position of the word at the caret.
    func forwardSearch(silent: Bool = false) {
        showInPDF(position: nil, editorWord: nil, silent: silent)
    }

    /// Source → PDF for `position` (the caret when nil): ⇧⌘J, ⌘-click on text and “Show in PDF”.
    /// - Parameters:
    ///   - editorWord: the word the editor found at `position`, if it did.
    ///   - silent: no messages, and a hidden preview stays hidden.
    ///   - onlyIfOffscreen: “Follow cursor”: the PDF scrolls only when the target is not already visible.
    func showInPDF(position: SourcePosition?, editorWord: String?, silent: Bool = false, onlyIfOffscreen: Bool = false) {
        guard let distribution, let pdfURL, let mapper = pathMapper, let file = currentFile else {
            if !silent { flash(String(localized: "Compile the document first to show a position in the PDF.")) }
            return
        }
        if silent, !isPreviewOnScreen { return }       // nothing to show it on
        let position = position ?? editor.cursor
        let target = syncTarget(in: file, at: position, editorWord: editorWord)
        if !silent { revealPreviewForSync() }
        syncGeneration &+= 1
        let generation = syncGeneration
        Task { [self] in
            let boxes = await SyncTeX(distribution: distribution).forward(
                pdfURL: pdfURL, sourceFile: file, line: position.line, column: position.column, mapper: mapper
            )
            guard generation == syncGeneration else { return }       // a newer request supersedes this one
            if boxes.isEmpty {
                if !silent { flash(String(localized: "No matching position was found in the PDF.")) }
                return
            }
            let highlights = boxes.map { PDFHighlight(pageIndex: max(0, $0.page - 1), rect: $0.rect) }
            preview.showHighlights(
                highlights,
                matching: target?.display,
                contextBefore: target?.contextBefore ?? "",
                contextAfter: target?.contextAfter ?? "",
                scroll: onlyIfOffscreen ? .ifNeeded : .center
            )
        }
    }

    /// The typeset word at `position` with its surroundings: decoded from the source (so `Poincar{\'e}` is
    /// “Poincaré”, comments and command names are not words), else the editor's own word.
    private func syncTarget(in file: URL, at position: SourcePosition, editorWord: String?) -> SourceWordTarget? {
        guard let buffer = buffers[file] else { return nil }
        let text = buffer.text as NSString
        let index = LineIndex(text)
        let offset = index.offset(of: position)
        if let target = SourceWordLocator.target(at: offset, in: text, lineIndex: index) { return target }
        guard let found = editor.word(at: offset),
              SourceWordLocator.isPlainText(found.range, in: text, lineIndex: index) else { return nil }
        return SourceWordTarget(display: editorWord ?? found.word, range: found.range, contextBefore: "", contextAfter: "")
    }

    // MARK: Follow cursor

    /// “Follow cursor in PDF”: once the caret has rested for ~0.6 s without a selection, shows its place in the
    /// PDF — silently: it scrolls only when the target is off screen and never takes the focus.
    func cursorDidMove() {
        guard settings.followCursorInPDF else { return }
        debounce("followCursor", after: .milliseconds(600)) { [weak self] in
            guard let self, self.settings.followCursorInPDF, self.editor.selectionLength == 0,
                  self.pdfURL != nil, self.isPreviewOnScreen else { return }
            self.showInPDF(position: nil, editorWord: nil, silent: true, onlyIfOffscreen: true)
        }
    }

    // MARK: PDF → source

    /// A double-click or ⌘-click in the PDF (see Settings ▸ General): finds the clicked word in the source,
    /// selects it with a brief highlight and focuses the editor.
    func syncFromPDF(_ click: PDFSyncClick) {
        guard let distribution, let pdfURL, let mapper = pathMapper else { return }
        Task { [self] in
            let location = await SyncTeX(distribution: distribution).inverse(
                pdfURL: pdfURL, page: click.pageIndex + 1, point: click.point, mapper: mapper
            )
            guard let location else {
                flash(String(localized: "No source position was found for this spot."))
                return
            }
            reveal(location, for: click)
        }
    }

    /// Opens the file of `location` and puts the caret on the clicked word: first on SyncTeX's line, then
    /// around it; when the word cannot be found the whole line is highlighted instead.
    private func reveal(_ location: SourceLocation, for click: PDFSyncClick) {
        guard open(location.fileURL), let file = currentFile else { return }
        jumpTask?.cancel()
        jumpTask = Task { [weak self] in
            guard let self, await self.waitForEditor(showing: file), !Task.isCancelled,
                  let buffer = self.buffers[file] else { return }
            let text = buffer.text as NSString
            let index = LineIndex(text)
            var range: NSRange?
            if let word = click.word, !word.isEmpty {
                let query = SourceWordQuery(word: word, contextBefore: click.contextBefore, contextAfter: click.contextAfter)
                range = SourceWordLocator.locate(query, in: text, lineIndex: index, line: location.line, column: location.column)?.range
            }
            let target = range ?? SourceWordLocator.lineRange(location.line, in: text, lineIndex: index)
            self.editor.reveal(target, flash: true)
            // The click happened in the PDF — maybe in the detached window: the editor must be where the user lands.
            self.bringWindowToFront()
            self.editor.focus()
        }
    }
}

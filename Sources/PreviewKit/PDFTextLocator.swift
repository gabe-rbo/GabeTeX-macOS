import AppKit
import PDFKit

/// PDFKit side of the precise sync: turns a word from the source into the rectangles of its occurrence on the
/// page (forward search) and a click on the page into a word with context (inverse search). The matching rules
/// themselves live in the pure `PDFTextFolding` / `PDFTextIndex`.
enum PDFTextLocator {
    // MARK: Forward: source word -> rectangles

    /// The rectangles to highlight for a forward search.
    ///
    /// When `text` is non-nil and occurs on a page of `boxes` inside, or within about a line of, one of the SyncTeX
    /// boxes, the result is the tight bounds of that single occurrence (one rectangle per line it covers). Among
    /// several occurrences whole words win, then the one whose surroundings best agree with the source context,
    /// then the one closest to a box. Without a usable occurrence the boxes themselves are returned.
    static func resolve(_ boxes: [PDFHighlight], matching text: String?, contextBefore: String, contextAfter: String,
                        in document: PDFDocument) -> [PDFHighlight] {
        guard let text, !boxes.isEmpty, let needle = PDFTextNeedle(text) else { return boxes }
        let source = PDFSourceContext(contextBefore: contextBefore, contextAfter: contextAfter)

        struct PageWork {
            var index: Int
            var page: PDFPage
            var text: PDFTextIndex
            var boxes: [CGRect]
        }
        var pages: [PageWork] = []
        for pageIndex in Set(boxes.map(\.pageIndex)).sorted() where pageIndex >= 0 && pageIndex < document.pageCount {
            guard let page = document.page(at: pageIndex), let string = page.string, !string.isEmpty else { continue }
            let rects = boxes.filter { $0.pageIndex == pageIndex }.map { $0.rect.standardized }.filter(isUsable)
            guard !rects.isEmpty else { continue }
            pages.append(PageWork(index: pageIndex, page: page, text: PDFTextIndex(pageText: string), boxes: rects))
        }

        func candidates(_ occurrences: (PDFTextIndex) -> [PDFTextOccurrence]) -> [PDFMatchCandidate] {
            var result: [PDFMatchCandidate] = []
            for work in pages {
                for occurrence in occurrences(work.text) {
                    let rects = lineRects(of: occurrence.range, on: work.page)
                    guard !rects.isEmpty else { continue }
                    result.append(PDFMatchCandidate(
                        pageIndex: work.index, occurrence: occurrence, rects: rects,
                        contextScore: work.text.contextScore(for: occurrence, source: source),
                        gap: PDFMatchRanking.gap(of: rects, to: work.boxes)))
                }
            }
            return result
        }

        var best = PDFMatchRanking.best(of: candidates { $0.occurrences(of: needle) })
        if best == nil {
            best = PDFMatchRanking.best(of: candidates { $0.prefixOccurrences(of: needle) })
        }
        guard let best else { return boxes }
        return best.rects.map { PDFHighlight(pageIndex: best.pageIndex, rect: $0) }
    }

    /// Bounds of the text in `range`, one rectangle per line.
    static func lineRects(of range: NSRange, on page: PDFPage) -> [CGRect] {
        guard range.length > 0, let selection = page.selection(for: range) else { return [] }
        let lines = selection.selectionsByLine()
        let parts = lines.isEmpty ? [selection] : lines
        return parts.map { $0.bounds(for: page) }.filter { rect in
            isUsable(rect) && rect.width > 0.5 && rect.height > 0.5
        }
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }

    // MARK: Inverse: click -> word with context

    /// Describes what is under `point` (PDF page space) on `page`: the word (`nil` when the point is not on text) and
    /// about 40 characters of page text on each side of it.
    static func syncClick(on page: PDFPage, pageIndex: Int, at point: CGPoint) -> PDFSyncClick {
        var click = PDFSyncClick(pageIndex: pageIndex, point: point)
        guard let text = page.string, !text.isEmpty else { return click }
        let ns = text as NSString

        var word: NSRange?
        var anchor: NSRange?
        if let selection = page.selectionForWord(at: point), isOnText(selection, page: page, point: point),
           let raw = characterRange(of: selection, on: page, limit: ns.length) {
            anchor = raw
            if let trimmed = PDFTextFolding.trimmedWordRange(in: ns, range: raw) {
                if !ns.substring(with: trimmed).contains(where: \.isWhitespace) {
                    word = trimmed
                } else if let index = characterIndex(containing: point, in: raw, on: page) {
                    // PDFKit selected several words (it does for some lines): take the one under the pointer.
                    if let found = PDFTextFolding.wordRange(in: ns, at: index) {
                        word = found
                        anchor = found
                    } else {
                        anchor = NSRange(location: index, length: 1)
                    }
                }
            }
        }
        if anchor == nil {
            let index = page.characterIndex(at: point)
            if index >= 0, index < ns.length,
               let selection = page.selection(for: NSRange(location: index, length: 1)),
               isOnText(selection, page: page, point: point) {
                word = PDFTextFolding.wordRange(in: ns, at: index)
                anchor = word ?? NSRange(location: index, length: 1)
            }
        }
        guard let around = word ?? anchor else { return click }
        if let word {
            let cleaned = PDFTextFolding.cleaned(ns.substring(with: word))
            click.word = cleaned.isEmpty ? nil : cleaned
        }
        let context = PDFTextFolding.context(in: text, around: around)
        click.contextBefore = context.before
        click.contextAfter = context.after
        return click
    }

    /// `true` when `point` lies on (or within a few points of) one of the text lines of `selection`.
    private static func isOnText(_ selection: PDFSelection, page: PDFPage, point: CGPoint) -> Bool {
        let lines = selection.selectionsByLine()
        let parts = lines.isEmpty ? [selection] : lines
        return parts.contains { part in
            let bounds = part.bounds(for: page)
            return isUsable(bounds) && bounds.insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    /// The character inside `range` whose box contains `point` (the nearest one when boxes touch).
    private static func characterIndex(containing point: CGPoint, in range: NSRange, on page: PDFPage) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in range.location..<min(range.location + range.length, range.location + 600) {
            guard let rect = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page), isUsable(rect),
                  rect.insetBy(dx: -0.5, dy: -3).contains(point) else { continue }
            let distance = abs(rect.midX - point.x)
            if let current = best, current.distance <= distance { continue }
            best = (index, distance)
        }
        return best?.index
    }

    /// The UTF-16 range of the page string covered by `selection` (all its pieces on `page`).
    private static func characterRange(of selection: PDFSelection, on page: PDFPage, limit: Int) -> NSRange? {
        let count = selection.numberOfTextRanges(on: page)
        guard count > 0 else { return nil }
        var low = Int.max
        var high = 0
        for index in 0..<count {
            let range = selection.range(at: index, on: page)
            guard range.location != NSNotFound else { continue }
            low = min(low, range.location)
            high = max(high, range.location + range.length)
        }
        guard low != Int.max else { return nil }
        let start = min(low, limit)
        let end = min(high, limit)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}

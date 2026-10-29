import Foundation
import CoreGraphics
import TeXCore

/// Finds the PDF page of every section heading with SyncTeX (forward search), for the page column of Document
/// Statistics. Pure of UI; each lookup is one `synctex view` process, a few at a time, cancellable.
///
/// What SyncTeX answers for a heading's line (checked on real `article`, `report`, `book` and `memoir` output):
/// - the boxes of the heading itself, on the page where it starts;
/// - and, when the heading made TeX ship pages out (a `\chapter` after `\clearpage` / `\cleardoublepage`), the
///   running header and footer of those earlier pages too, because the output routine ran while TeX was reading
///   that line.
/// The heading is on the **last** of the answered pages, and its boxes there are the ones in that page's list.
public enum SectionPageLocator {
    /// One heading to look up.
    public struct Heading: Sendable, Hashable {
        /// Echoed in `Output.placements`.
        public var key: String
        public var fileURL: URL
        /// 1-based line the heading command starts on.
        public var line: Int
        /// 1-based line its title ends on (SyncTeX records the line a command finished on); equals `line` for
        /// one-line headings.
        public var endLine: Int

        public init(key: String, fileURL: URL, line: Int, endLine: Int) {
            self.key = key
            self.fileURL = fileURL
            self.line = line
            self.endLine = max(endLine, line)
        }
    }

    public struct Output: Sendable, Hashable {
        /// Pages of the PDF the headings were looked up in.
        public var totalPages: Int
        /// Placement by `Heading.key`; headings SyncTeX knows nothing about are missing. The front matter
        /// (`SectionStatistics.frontMatterID`) is always there, on page 1.
        public var placements: [String: HeadingPlacement]
    }

    /// SyncTeX answers one question per process: at most this many run at once.
    private static let concurrency = 4
    /// More headings than this and the lookup is skipped (a thesis has a few hundred).
    public static let headingLimit = 1500

    /// Whether the compile left SyncTeX data next to the PDF.
    public static func hasSyncTeXData(for pdf: URL) -> Bool {
        let stem = pdf.deletingPathExtension()
        let manager = FileManager.default
        return manager.fileExists(atPath: stem.appendingPathExtension("synctex.gz").path)
            || manager.fileExists(atPath: stem.appendingPathExtension("synctex").path)
    }

    /// Looks every heading up; nil when the PDF cannot be read, has no SyncTeX data, there are too many
    /// headings, or the calling task was cancelled.
    public static func locate(
        _ headings: [Heading], pdfURL: URL, distribution: TeXDistribution, mapper: ShadowPathMapper
    ) async -> Output? {
        guard headings.count <= headingLimit, hasSyncTeXData(for: pdfURL),
              let document = CGPDFDocument(pdfURL as CFURL), document.numberOfPages > 0 else { return nil }
        let totalPages = document.numberOfPages
        let synctex = SyncTeX(distribution: distribution)

        var placements: [String: HeadingPlacement] = [:]
        // The front matter starts the document.
        placements[SectionStatistics.frontMatterID] = HeadingPlacement(page: 1, isAtPageTop: true)

        var cancelled = false
        await withTaskGroup(of: (Int, [SyncTeXBox]).self) { group in
            var next = 0
            while next < min(concurrency, headings.count) {
                let index = next
                let heading = headings[index]
                group.addTask { (index, await boxes(for: heading, pdfURL: pdfURL, synctex: synctex, mapper: mapper)) }
                next += 1
            }
            while let (index, found) = await group.next() {
                if Task.isCancelled {
                    cancelled = true
                    group.cancelAll()
                    continue
                }
                if let placement = placement(of: found, in: document) {
                    placements[headings[index].key] = placement
                }
                if next < headings.count {
                    let following = next
                    let heading = headings[following]
                    group.addTask { (following, await boxes(for: heading, pdfURL: pdfURL, synctex: synctex, mapper: mapper)) }
                    next += 1
                }
            }
        }
        if cancelled || Task.isCancelled { return nil }
        return Output(totalPages: totalPages, placements: placements)
    }

    /// The boxes SyncTeX has for a heading: its last line first, then the line it started on.
    private static func boxes(for heading: Heading, pdfURL: URL, synctex: SyncTeX, mapper: ShadowPathMapper) async -> [SyncTeXBox] {
        var lines = [heading.endLine]
        if heading.line != heading.endLine { lines.append(heading.line) }
        for line in lines {
            if Task.isCancelled { return [] }
            let found = await synctex.forward(pdfURL: pdfURL, sourceFile: heading.fileURL, line: line, column: 0, mapper: mapper)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// The page the heading is on (the last page SyncTeX answered, see the type's documentation) and whether
    /// its boxes there start in the top part of the page.
    static func placement(of boxes: [SyncTeXBox], in document: CGPDFDocument) -> HeadingPlacement? {
        guard let page = boxes.map(\.page).max(), page >= 1, page <= document.numberOfPages else { return nil }
        var top = -Double.infinity
        for box in boxes where box.page == page { top = max(top, Double(box.rect.maxY)) }
        var atTop = false
        if let pdfPage = document.page(at: page) {
            let media = pdfPage.getBoxRect(.mediaBox)
            atTop = PageAttribution.isAtPageTop(maxY: top, mediaMinY: Double(media.minY), mediaHeight: Double(media.height))
        }
        return HeadingPlacement(page: page, isAtPageTop: atTop)
    }
}

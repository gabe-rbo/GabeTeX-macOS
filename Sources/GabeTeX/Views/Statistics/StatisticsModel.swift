import SwiftUI
import Observation
import TeXCore

/// The numbers the status bar capsule, the Document Statistics popover and the outline sidebar show.
///
/// Plain observable state: `ProjectWorkspace+Statistics.swift` decides when to count (off the main actor)
/// and hands the results to the `apply…` methods, so views only ever read finished values.
@Observable
final class StatisticsModel {
    /// Counts of the whole project at the last refresh; nil without a root document and before the first count.
    private(set) var document: DocumentStatistics?
    /// Words of each outline node's whole subtree (its own text plus its sub-sections), by `OutlineNode.id`:
    /// the small numbers in the outline sidebar.
    private(set) var wordsByID: [String: Int] = [:]
    /// Counts of the selected text; nil while nothing is selected.
    private(set) var selection: StatisticsCounts?
    /// Pages each section spans (its sub-sections included), by `SectionStatistics.stableKey`. Empty until a
    /// successful compile with SyncTeX data has been looked at.
    private(set) var pageSpans: [String: PageSpan] = [:]
    /// The Document Statistics popover is showing (anchored to the status bar capsule).
    var isPopoverPresented = false

    /// Where each heading landed in the PDF at the last page lookup, by `stableKey` (and the front matter).
    @ObservationIgnored private var placements: [String: HeadingPlacement] = [:]
    /// Pages of the PDF those placements were found in.
    @ObservationIgnored private var placedPages = 0

    /// Newest-wins counters: an answer that comes back after a newer request started is dropped.
    @ObservationIgnored var documentGeneration = 0
    @ObservationIgnored var selectionGeneration = 0
    @ObservationIgnored var pageGeneration = 0
    /// What the page lookup last ran for, so a compile that changed nothing is not looked at twice.
    @ObservationIgnored var pageStamp: PageStamp?

    /// Identity of one page lookup: the compile it followed and the headings it asked about.
    struct PageStamp: Equatable {
        var pdf: URL
        var compile: TimeInterval?
        var headings: Int
    }

    // MARK: Applying results

    /// A fresh count of the project (nil: there is no root document).
    func apply(_ counted: DocumentStatistics?) {
        if counted != document { document = counted }
        var words: [String: Int] = [:]
        if let counted {
            words.reserveCapacity(counted.sections.count)
            for section in counted.sections { words[section.id] = section.subtree.words }
        }
        if words != wordsByID { wordsByID = words }
        rebuildPageSpans()
    }

    func apply(selection counts: StatisticsCounts?) {
        if counts != selection { selection = counts }
    }

    /// Where the headings landed in a PDF of `totalPages` pages.
    func apply(placements found: [String: HeadingPlacement], totalPages: Int) {
        placements = found
        placedPages = totalPages
        rebuildPageSpans()
    }

    /// Forgets the project (no root document any more).
    func reset() {
        documentGeneration &+= 1
        selectionGeneration &+= 1
        pageGeneration &+= 1
        pageStamp = nil
        placements = [:]
        placedPages = 0
        if document != nil { document = nil }
        if !wordsByID.isEmpty { wordsByID = [:] }
        if selection != nil { selection = nil }
        if !pageSpans.isEmpty { pageSpans = [:] }
    }

    /// The PDF the pages were looked up in is gone or cannot be trusted any more.
    func forgetPages() {
        pageGeneration &+= 1
        pageStamp = nil
        placements = [:]
        placedPages = 0
        if !pageSpans.isEmpty { pageSpans = [:] }
    }

    // MARK: Pages per section

    private func rebuildPageSpans() {
        // Without a single heading found in the PDF the front matter alone would claim every page.
        guard let document, placedPages > 0,
              document.sections.isEmpty || document.sections.contains(where: { placements[$0.stableKey] != nil }) else {
            if !pageSpans.isEmpty { pageSpans = [:] }
            return
        }
        let sections = document.allSections
        let marks: [HeadingPlacement?] = sections.map { placements[$0.stableKey] }
        let own = PageAttribution.spans(placements: marks, totalPages: placedPages)
        let spans = PageAttribution.subtreeSpans(levels: sections.map(\.level), spans: own)
        var result: [String: PageSpan] = [:]
        for (section, span) in zip(sections, spans) {
            if let span, result[section.stableKey] == nil { result[section.stableKey] = span }
        }
        if result != pageSpans { pageSpans = result }
    }
}

/// Number and page formatting shared by the capsule, the popover and the outline (pt-BR strings).
enum StatisticsText {
    static func number(_ value: Int) -> String { value.formatted() }

    static func words(_ count: Int) -> String {
        let shown = number(count)
        return count == 1 ? String(localized: "\(shown) word") : String(localized: "\(shown) words")
    }

    static func pages(_ count: Int) -> String {
        let shown = number(count)
        return count == 1 ? String(localized: "\(shown) page") : String(localized: "\(shown) pages")
    }

    /// “12 of 1,234 words”.
    static func wordsOfTotal(_ part: Int, _ total: Int) -> String {
        let shownPart = number(part)
        let shownTotal = number(total)
        return total == 1 ? String(localized: "\(shownPart) of \(shownTotal) word")
                          : String(localized: "\(shownPart) of \(shownTotal) words")
    }

    /// “7”, “3–5”, “≈ 1”.
    static func pageRange(_ span: PageSpan) -> String {
        let text = span.first == span.last ? "\(span.first)" : "\(span.first)–\(span.last)"
        return span.isApproximate ? "≈ \(text)" : text
    }
}

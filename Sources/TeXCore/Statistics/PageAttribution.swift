import Foundation

/// Where a section heading landed in the PDF (from a SyncTeX forward search of its line).
public struct HeadingPlacement: Hashable, Sendable {
    /// 1-based PDF page.
    public var page: Int
    /// The heading sits at the top of its page, so the previous section ends on the page before.
    public var isAtPageTop: Bool

    public init(page: Int, isAtPageTop: Bool = false) {
        self.page = page
        self.isAtPageTop = isAtPageTop
    }
}

/// The pages a section occupies.
public struct PageSpan: Hashable, Sendable {
    public var first: Int
    public var last: Int
    /// The section starts on a page it shares with the next section (so "its" pages are only approximate).
    public var isApproximate: Bool

    public init(first: Int, last: Int, isApproximate: Bool = false) {
        self.first = first
        self.last = last
        self.isApproximate = isApproximate
    }

    public var pageCount: Int { last - first + 1 }
}

/// Turns the pages found by SyncTeX for each heading into per-section page spans. Pure.
public enum PageAttribution {
    /// A heading whose top edge is in the upper part of the page counts as "at the top": the text block starts
    /// there, perhaps lowered by a chapter's opening space (`book`, `report` and `memoir` chapters begin about
    /// 24 % down the page, `article` sections about 16 %). A heading further down has text above it. Errs on the
    /// side of `true`, which only ends the previous section's range one page early when a few lines of it
    /// share the page with the heading.
    public static let topFraction = 0.72

    /// Whether a box whose top edge is at `maxY` (PDF page space, origin bottom-left) in a media box that
    /// spans `mediaMinY ..< mediaMinY + mediaHeight` lies in the top part of its page.
    public static func isAtPageTop(maxY: Double, mediaMinY: Double, mediaHeight: Double) -> Bool {
        guard mediaHeight > 0 else { return false }
        return (maxY - mediaMinY) / mediaHeight >= topFraction
    }

    /// Page spans for sections in reading order.
    ///
    /// A section spans from the page of its heading to the page of the next heading: that page is shared when
    /// the next heading lies below the top of the page, so the range ends on it; when the next heading is at
    /// the top of its page, the section ends on the page before. A section that starts on the very page its
    /// successor starts on is marked approximate. The last section runs to the last page.
    ///
    /// - Parameters:
    ///   - placements: one entry per section in reading order (include the front matter first, normally
    ///     page 1); `nil` where SyncTeX found nothing. Entries that are out of range or go backwards are ignored.
    ///   - totalPages: pages in the PDF; 0 yields no spans.
    /// - Returns: one entry per placement, `nil` where the section has no usable page.
    public static func spans(placements: [HeadingPlacement?], totalPages: Int) -> [PageSpan?] {
        var result = [PageSpan?](repeating: nil, count: placements.count)
        guard totalPages > 0 else { return result }

        var usable = [HeadingPlacement?](repeating: nil, count: placements.count)
        var lowest = 1
        for (index, placement) in placements.enumerated() {
            guard let placement, placement.page >= lowest, placement.page <= totalPages else { continue }
            usable[index] = placement
            lowest = placement.page
        }

        var next: HeadingPlacement?
        for index in stride(from: placements.count - 1, through: 0, by: -1) {
            guard let own = usable[index] else { continue }
            if let next {
                if next.page > own.page {
                    let last = next.isAtPageTop ? next.page - 1 : next.page
                    result[index] = PageSpan(first: own.page, last: max(own.page, last))
                } else {
                    result[index] = PageSpan(first: own.page, last: own.page, isApproximate: true)
                }
            } else {
                result[index] = PageSpan(first: own.page, last: totalPages)
            }
            next = own
        }
        return result
    }

    /// Widens every section's span over the sections nested in it, so a chapter reads "pages 3–12" and not
    /// just the pages up to its first subsection.
    ///
    /// - Parameters:
    ///   - levels: the nesting level of every entry of `spans` (`SectionStatistics.level`; negative for the
    ///     front matter, which has no sub-sections). A section's descendants are the entries that follow it
    ///     with a deeper level.
    ///   - spans: the result of `spans(placements:totalPages:)`.
    /// - Returns: `spans` with the same length; a span that grows is no longer approximate.
    public static func subtreeSpans(levels: [Int], spans: [PageSpan?]) -> [PageSpan?] {
        var result = spans
        let count = min(levels.count, spans.count)
        for index in 0..<count {
            guard let own = spans[index], levels[index] >= 0 else { continue }
            var last = own.last
            var next = index + 1
            while next < count, levels[next] > levels[index] {
                if let nested = spans[next], nested.last > last { last = nested.last }
                next += 1
            }
            if last > own.last { result[index] = PageSpan(first: own.first, last: last) }
        }
        return result
    }
}

import Foundation

/// Counters for one piece of a document: a section, the front matter or the whole document.
public struct StatisticsCounts: Hashable, Sendable {
    /// Words of running text (paragraphs, list items, captions, footnotes …).
    public var textWords: Int
    /// Words of headings (`\section{…}`, `\chapter{…}`, beamer frame titles …).
    public var headingWords: Int
    /// Inline formulas: `$…$`, `\(…\)`, `\begin{math}`.
    public var inlineMath: Int
    /// Displayed formulas: `$$…$$`, `\[…\]`, `equation`, `align`, `gather` … (one per environment).
    public var displayMath: Int

    public init(textWords: Int = 0, headingWords: Int = 0, inlineMath: Int = 0, displayMath: Int = 0) {
        self.textWords = textWords
        self.headingWords = headingWords
        self.inlineMath = inlineMath
        self.displayMath = displayMath
    }

    /// Text and heading words together: the number shown as "N words".
    public var words: Int { textWords + headingWords }

    /// Nothing counted at all.
    public var isEmpty: Bool { words == 0 && inlineMath == 0 && displayMath == 0 }

    public static let zero = StatisticsCounts()

    public static func + (left: StatisticsCounts, right: StatisticsCounts) -> StatisticsCounts {
        StatisticsCounts(
            textWords: left.textWords + right.textWords,
            headingWords: left.headingWords + right.headingWords,
            inlineMath: left.inlineMath + right.inlineMath,
            displayMath: left.displayMath + right.displayMath
        )
    }

    public static func - (left: StatisticsCounts, right: StatisticsCounts) -> StatisticsCounts {
        StatisticsCounts(
            textWords: left.textWords - right.textWords,
            headingWords: left.headingWords - right.headingWords,
            inlineMath: left.inlineMath - right.inlineMath,
            displayMath: left.displayMath - right.displayMath
        )
    }

    public static func += (left: inout StatisticsCounts, right: StatisticsCounts) {
        left = left + right
    }
}

/// The counts of one outline section (part … subparagraph or a beamer frame), or of the front matter.
///
/// `own` is what lies directly in the section: from its heading to the next heading of ANY level.
/// `subtree` adds the sections nested inside it (those that follow with a deeper level), which is the
/// number a reader means by "this chapter has N words".
public struct SectionStatistics: Hashable, Sendable, Identifiable {
    /// The id of the front matter row.
    public static let frontMatterID = "front-matter"

    /// `nil` for the front matter (everything before the first heading).
    public var kind: OutlineEntry.Kind?
    /// Heading title as the outline shows it (empty for the front matter).
    public var title: String
    public var isStarred: Bool
    /// File and 1-based line of the heading command (the root file, line 1, for the front matter).
    public var fileURL: URL
    public var line: Int
    /// 1-based line where the heading's title ends (equals `line` for one-line headings). SyncTeX records
    /// the line a heading finished on, so page lookups try this line first.
    public var headingEndLine: Int
    /// UTF-16 offset of the heading command in its file.
    public var offset: Int
    /// Nesting level (`OutlineEntry.Kind.level`; -1 for the front matter).
    public var level: Int
    public var own: StatisticsCounts
    public var subtree: StatisticsCounts
    /// Equals `OutlineNode.id` of the outline node of this heading, so the sidebar can look counts up.
    public let id: String
    /// Survives edits that only move the heading: file, kind, title and the n-th heading with that triple.
    /// Page numbers found at the last compile are kept under this key while the text changes.
    public var stableKey: String

    public var isFrontMatter: Bool { kind == nil }

    /// A heading section.
    init(entry: OutlineEntry, headingEndLine: Int, own: StatisticsCounts, occurrence: Int) {
        self.kind = entry.kind
        self.title = entry.title
        self.isStarred = entry.isStarred
        self.fileURL = entry.fileURL
        self.line = entry.line
        self.headingEndLine = max(headingEndLine, entry.line)
        self.offset = entry.offset
        self.level = entry.kind.level
        self.own = own
        self.subtree = own
        self.id = "\(entry.fileURL.path)#\(entry.line)#\(entry.kind.rawValue)#\(entry.title)"
        self.stableKey = "\(entry.fileURL.path)#\(entry.kind.rawValue)#\(entry.title)#\(occurrence)"
    }

    /// The front matter of the document rooted at `root`.
    init(frontMatterIn root: URL, own: StatisticsCounts) {
        self.kind = nil
        self.title = ""
        self.isStarred = false
        self.fileURL = root
        self.line = 1
        self.headingEndLine = 1
        self.offset = 0
        self.level = -1
        self.own = own
        self.subtree = own
        self.id = Self.frontMatterID
        self.stableKey = Self.frontMatterID
    }
}

/// Word, heading and formula counts of a whole LaTeX project, per outline section.
///
/// Produced by `DocumentStatistics.compute(rootFile:read:fileExists:)`; pure and `Sendable`, so the app
/// computes it off the main thread from a snapshot of its buffers.
public struct DocumentStatistics: Hashable, Sendable {
    public var rootFile: URL
    /// Everything between `\begin{document}` and the first heading: the title block, the abstract …
    public var frontMatter: SectionStatistics
    /// Headings and beamer frames in reading order (the same entries, in the same order, as the outline
    /// without its labels).
    public var sections: [SectionStatistics]
    /// Front matter plus every section. Always equals the sum of the `own` counts.
    public var totals: StatisticsCounts
    /// The .tex files that were walked, in reading order (root first).
    public var files: [URL]

    private var indexByID: [String: Int]

    init(rootFile: URL, frontMatter: SectionStatistics, sections: [SectionStatistics],
         totals: StatisticsCounts, files: [URL]) {
        self.rootFile = rootFile
        self.frontMatter = frontMatter
        self.sections = sections
        self.totals = totals
        self.files = files
        var index: [String: Int] = [:]
        for (position, section) in sections.enumerated() where index[section.id] == nil {
            index[section.id] = position
        }
        self.indexByID = index
    }

    /// Front matter first, then the sections.
    public var allSections: [SectionStatistics] { [frontMatter] + sections }

    /// The section whose id is `id` (an `OutlineNode.id`, or `SectionStatistics.frontMatterID`).
    public func section(withID id: String) -> SectionStatistics? {
        if id == SectionStatistics.frontMatterID { return frontMatter }
        guard let position = indexByID[id] else { return nil }
        return sections[position]
    }
}

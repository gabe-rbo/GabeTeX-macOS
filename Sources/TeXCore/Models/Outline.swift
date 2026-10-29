import Foundation

/// A structural element found in a source file: a sectioning command, a beamer frame, or a label.
public struct OutlineEntry: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case part, chapter, section, subsection, subsubsection, paragraph, subparagraph
        case frame      // beamer \begin{frame}{Title} / \frametitle
        case label      // \label{key}

        /// Nesting depth used to build the tree. Labels are leaves (attached to the nearest heading).
        public var level: Int {
            switch self {
            case .part: 0
            case .chapter: 1
            case .section: 2
            case .subsection: 3
            case .subsubsection: 4
            case .paragraph: 5
            case .subparagraph: 6
            case .frame: 3
            case .label: 100
            }
        }
    }

    public var kind: Kind
    /// Heading title (LaTeX source of the argument, lightly cleaned) or the label key.
    public var title: String
    public var isStarred: Bool
    public var fileURL: URL
    /// 1-based line of the command.
    public var line: Int
    /// UTF-16 offset of the command's backslash in its file.
    public var offset: Int

    public init(kind: Kind, title: String, isStarred: Bool = false, fileURL: URL, line: Int, offset: Int) {
        self.kind = kind
        self.title = title
        self.isStarred = isStarred
        self.fileURL = fileURL
        self.line = line
        self.offset = offset
    }
}

/// Tree node for SwiftUI `OutlineGroup` / `List(children:)`. `children == nil` for leaves.
public struct OutlineNode: Identifiable, Hashable, Sendable {
    public var entry: OutlineEntry
    public var children: [OutlineNode]?

    /// Stable across re-scans as long as the entry does not move.
    public var id: String { "\(entry.fileURL.path)#\(entry.line)#\(entry.kind.rawValue)#\(entry.title)" }

    public init(entry: OutlineEntry, children: [OutlineNode]? = nil) {
        self.entry = entry
        self.children = children
    }
}

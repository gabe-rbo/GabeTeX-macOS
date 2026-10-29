import Foundation

/// A `\label{key}` definition.
public struct LabelDefinition: Hashable, Sendable, Identifiable {
    public var key: String
    public var fileURL: URL
    public var line: Int                // 1-based
    /// Short human context shown in completion, e.g. "Section: Introduction" or the source line trimmed.
    public var context: String?

    public var id: String { key }

    public init(key: String, fileURL: URL, line: Int, context: String? = nil) {
        self.key = key
        self.fileURL = fileURL
        self.line = line
        self.context = context
    }
}

/// An entry of a `.bib` file.
public struct BibEntry: Hashable, Sendable, Identifiable {
    public var key: String
    public var type: String             // "article", "book", ... (lowercased, without "@")
    public var title: String?
    public var author: String?
    public var year: String?
    public var fileURL: URL
    public var line: Int                // 1-based line of the "@type{"

    public var id: String { key }

    public init(key: String, type: String, title: String? = nil, author: String? = nil, year: String? = nil, fileURL: URL, line: Int) {
        self.key = key
        self.type = type
        self.title = title
        self.author = author
        self.year = year
        self.fileURL = fileURL
        self.line = line
    }
}

/// Everything project-specific the completion engine needs.
public struct ProjectSymbols: Hashable, Sendable {
    public var labels: [LabelDefinition]
    public var bibEntries: [BibEntry]
    /// Commands defined in the project (\newcommand, \renewcommand, \DeclareMathOperator, \def, \NewDocumentCommand ...).
    public var customCommands: [CompletionItem]
    /// Environments defined in the project (\newenvironment, \newtheorem, \NewDocumentEnvironment ...).
    public var customEnvironments: [String]
    /// Project files, as paths relative to the root file's directory, using "/" (e.g. "sections/intro.tex", "figs/plot.pdf").
    public var projectFiles: [String]

    public init(
        labels: [LabelDefinition] = [],
        bibEntries: [BibEntry] = [],
        customCommands: [CompletionItem] = [],
        customEnvironments: [String] = [],
        projectFiles: [String] = []
    ) {
        self.labels = labels
        self.bibEntries = bibEntries
        self.customCommands = customCommands
        self.customEnvironments = customEnvironments
        self.projectFiles = projectFiles
    }

    public static let empty = ProjectSymbols()
}

/// A reference from one source file to another file.
public struct IncludeReference: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case input              // \input{file}           — resolved relative to the root file's directory
        case include            // \include{file}         — idem, ".tex" appended
        case subfile            // \subfile{file}         — relative to the *including* file's directory
        case importFile         // \import{dir}{file}     — `directory` holds dir
        case subimport          // \subimport{dir}{file}  — dir relative to the including file
        case bibliography       // \bibliography{a,b}     — one reference per comma-separated item, ".bib" appended
        case addbibresource     // \addbibresource{refs.bib}
        case includegraphics    // \includegraphics[...]{file}
        case includepdf         // \includepdf[...]{file}
        case lstinputlisting    // \lstinputlisting{file}
        case inputminted        // \inputminted{lang}{file}
        case usepackage         // \usepackage{a,b}       — one reference per package (local .sty may exist)
        case documentclass      // \documentclass{cls}
    }

    public var kind: Kind
    /// The argument exactly as written (one item for comma lists), e.g. "sections/intro".
    public var argument: String
    /// For \import / \subimport: the directory argument.
    public var directory: String?
    /// 1-based line.
    public var line: Int
    /// UTF-16 range of `argument` in the source text.
    public var range: NSRange

    public init(kind: Kind, argument: String, directory: String? = nil, line: Int, range: NSRange) {
        self.kind = kind
        self.argument = argument
        self.directory = directory
        self.line = line
        self.range = range
    }
}

/// TeXShop-style magic comments found in the first lines of a file:
/// `% !TEX root = ../main.tex`, `% !TEX program = xelatex` (also `TS-program`), `% !TEX spellcheck = pt_BR`.
/// Keys are case-insensitive ("!TeX" also accepted).
public struct MagicComments: Hashable, Sendable {
    public var root: String?
    public var program: String?
    public var spellcheck: String?
    public var bibProgram: String?      // % !BIB program = biber   /  % !TEX bib = biber

    public init(root: String? = nil, program: String? = nil, spellcheck: String? = nil, bibProgram: String? = nil) {
        self.root = root
        self.program = program
        self.spellcheck = spellcheck
        self.bibProgram = bibProgram
    }
}

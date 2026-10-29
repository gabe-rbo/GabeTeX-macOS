import Foundation

/// A position in a source file. Both components are **1-based**; `column` counts UTF-16 code units
/// (the unit NSString/NSTextView use), which is also what TeX's `-file-line-error` and chktex report
/// for ASCII text.
public struct SourcePosition: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int = 1) {
        self.line = line
        self.column = column
    }

    public static func < (a: SourcePosition, b: SourcePosition) -> Bool {
        (a.line, a.column) < (b.line, b.column)
    }

    public var description: String { "\(line):\(column)" }
}

/// A file + position, e.g. the result of an inverse SyncTeX search or a "go to label" request.
public struct SourceLocation: Hashable, Sendable {
    public var fileURL: URL
    public var line: Int            // 1-based
    public var column: Int?         // 1-based, nil when unknown

    public init(fileURL: URL, line: Int, column: Int? = nil) {
        self.fileURL = fileURL
        self.line = line
        self.column = column
    }
}

public enum DiagnosticSeverity: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    /// Informational (e.g. "Label(s) may have changed. Rerun").
    case info = 0
    /// Overfull/underfull boxes.
    case badbox = 1
    case warning = 2
    case error = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum DiagnosticSource: String, Sendable, Hashable, Codable {
    case tex          // the TeX engine log
    case latexmk      // latexmk itself (e.g. "Missing input file")
    case bibtex
    case biber
    case makeindex
    case chktex
    case structure    // TeXCore.StructureLinter (unbalanced braces, \begin/\end mismatch) — instant, in-editor
}

/// One problem reported about the document. Produced by TeXToolchain (log parser, chktex) and
/// TeXCore (StructureLinter); consumed by EditorKit (squiggles + gutter) and the app (Issues panel).
public struct Diagnostic: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var severity: DiagnosticSeverity
    public var source: DiagnosticSource
    /// One-line human readable message, e.g. "Undefined control sequence \\foo".
    public var message: String
    /// Optional multi-line context (e.g. the `l.12 ...` lines of a TeX error).
    public var detail: String?
    /// Absolute, standardized URL **in project space** (never a shadow/build path). nil if unknown.
    public var fileURL: URL?
    /// 1-based line, nil if unknown.
    public var line: Int?
    /// 1-based UTF-16 column, nil if unknown.
    public var column: Int?
    /// Length in UTF-16 units of the offending span, if known.
    public var length: Int?
    /// Name of a file TeX could not find (e.g. "tikz-cd.sty"), used to offer a package install.
    public var missingFile: String?

    public init(
        id: UUID = UUID(),
        severity: DiagnosticSeverity,
        source: DiagnosticSource,
        message: String,
        detail: String? = nil,
        fileURL: URL? = nil,
        line: Int? = nil,
        column: Int? = nil,
        length: Int? = nil,
        missingFile: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.source = source
        self.message = message
        self.detail = detail
        self.fileURL = fileURL
        self.line = line
        self.column = column
        self.length = length
        self.missingFile = missingFile
    }
}

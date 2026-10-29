import Foundation

/// A "New Project…" template. Data lives in `Templates/ProjectTemplates.swift`.
///
/// File contents may use the placeholders `{{TITLE}}`, `{{AUTHOR}}` and `{{DATE}}` (ISO date),
/// replaced by `instantiate(title:author:date:)`.
public struct ProjectTemplate: Identifiable, Hashable, Sendable {
    public var id: String
    /// Localized display name (use `String(localized:)` in the data file).
    public var name: String
    /// Localized one-line description.
    public var summary: String
    /// SF Symbol name for the template picker.
    public var symbolName: String
    /// Default engine raw value ("pdflatex", "xelatex", "lualatex").
    public var engine: String
    /// Relative path of the root document, e.g. "main.tex".
    public var mainFile: String
    /// Relative path (using "/") → file contents. Directories are created as needed.
    public var files: [String: String]

    public init(id: String, name: String, summary: String, symbolName: String, engine: String = "pdflatex", mainFile: String = "main.tex", files: [String: String]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.engine = engine
        self.mainFile = mainFile
        self.files = files
    }

    /// Returns `files` with placeholders substituted.
    public func instantiate(title: String, author: String, date: Date = Date()) -> [String: String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let isoDate = formatter.string(from: date)
        return files.mapValues {
            $0.replacingOccurrences(of: "{{TITLE}}", with: title)
              .replacingOccurrences(of: "{{AUTHOR}}", with: author)
              .replacingOccurrences(of: "{{DATE}}", with: isoDate)
        }
    }
}

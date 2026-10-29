import Foundation

/// A completion candidate.
///
/// `insertText` uses a small snippet syntax (parsed by `Snippet`):
///   - `${1:placeholder}` / `$1` — tab stops, visited in increasing order (defaults may contain `\`, `{`, `}`)
///   - `$0` — final cursor position (defaults to the end)
///   - a real newline character (U+000A) — the editor re-indents the following line to the current
///     line's indentation
///   - a real tab character (U+0009) — one indentation level (the editor converts it to the configured indent)
///   - `$` preceded by a backslash is never a tab stop: `\$` is LaTeX's dollar sign and both characters
///     are kept verbatim. Any other `$` not followed by a digit or `{` is literal text.
///
/// Backslash sequences such as `\n`, `\t` are ordinary LaTeX (`\newcommand`, `\textbf`) and are
/// **never** interpreted as escapes.
public struct CompletionItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case command        // \frac
        case environment    // itemize (after \begin{)
        case label          // eq:main (after \ref{)
        case citation       // knuth1984 (after \cite{)
        case file           // sections/intro (after \input{)
        case package        // amsmath (after \usepackage{)
        case snippet        // multi-token templates
    }

    public var kind: Kind
    /// Text shown in the list and matched against the typed prefix (e.g. "\\frac", "itemize", "eq:main").
    public var label: String
    /// Snippet inserted in place of `CompletionResult.replacementRange`.
    public var insertText: String
    /// Secondary text (description, bib title, label context...).
    public var detail: String?
    /// Package providing the command/environment, if not in the LaTeX kernel (e.g. "amsmath").
    public var package: String?

    public var id: String { "\(kind.rawValue):\(label)" }

    public init(kind: Kind, label: String, insertText: String? = nil, detail: String? = nil, package: String? = nil) {
        self.kind = kind
        self.label = label
        self.insertText = insertText ?? label
        self.detail = detail
        self.package = package
    }
}

/// What the editor should show at a given cursor position.
public struct CompletionResult: Hashable, Sendable {
    /// UTF-16 range that is replaced when an item is accepted (usually the typed prefix, possibly
    /// extended over an auto-inserted closing brace).
    public var replacementRange: NSRange
    /// The text typed so far that items were filtered with (e.g. "\\fr", "ite", "eq:").
    public var prefix: String
    /// Ranked, best first.
    public var items: [CompletionItem]

    public init(replacementRange: NSRange, prefix: String, items: [CompletionItem]) {
        self.replacementRange = replacementRange
        self.prefix = prefix
        self.items = items
    }
}

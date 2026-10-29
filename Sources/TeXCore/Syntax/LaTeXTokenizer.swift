import Foundation

/// Token classes used for syntax highlighting. EditorKit maps each to a color.
public enum LaTeXTokenKind: String, Sendable, Hashable, CaseIterable {
    case command            // \foo, \\, \{ — outside math
    case structureCommand   // \part \chapter \section ... \paragraph, \begin, \end, \documentclass, \usepackage
    case environmentName    // "itemize" in \begin{itemize} / \end{itemize}
    case mathDelimiter      // $  $$  \(  \)  \[  \]  and \begin/\end of math environments' delimiters
    case math               // ordinary content inside math mode
    case mathCommand        // \alpha, \frac ... inside math mode
    case comment            // % ... end of line
    case magicComment       // % !TEX ... lines
    case brace              // { }
    case bracket            // [ ]
    case specialCharacter   // & ~ ^ _ #
    case verbatim           // \verb|..|, verbatim / lstlisting / minted / comment environments' bodies
    case referenceArgument  // argument of \label \ref \eqref \cref \cite* \input \include \includegraphics \usepackage ...
}

public struct LaTeXToken: Hashable, Sendable {
    public var kind: LaTeXTokenKind
    /// UTF-16 range in the tokenized text.
    public var range: NSRange

    public init(kind: LaTeXTokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

/// Fast single-pass LaTeX lexer for highlighting.
///
/// Requirements (see ARCHITECTURE.md): O(n) over UTF-16, ~100 KB in well under 10 ms (release);
/// tracks math mode across lines (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`, and math environments such as
/// equation, align, gather, multline, flalign, alignat, eqnarray, math, displaymath — starred too);
/// tokens are sorted, non-overlapping; plain text produces no tokens.
public struct LaTeXTokenizer: Sendable {
    public init() {}

    public func tokenize(_ text: String) -> [LaTeXToken] {
        var engine = TokenizerEngine(units: Array(text.utf16))
        return engine.run()
    }

    /// Tokenizes `text` (UTF-16 offsets refer to this string).
    public func tokenize(_ text: NSString) -> [LaTeXToken] {
        let length = text.length
        var units = [unichar](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&units, range: NSRange(location: 0, length: length)) }
        var engine = TokenizerEngine(units: units)
        return engine.run()
    }
}

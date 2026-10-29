import Foundation

/// Instant structural checks run on every edit (no TeX involved):
/// unbalanced `{}` (ignoring `\{` `\}` and comments/verbatim), `\begin{x}` … `\end{y}` mismatches,
/// unclosed inline math `$` at end of paragraph, `\end` without `\begin`.
/// Diagnostics use `source: .structure`.
///
/// The linter is deliberately conservative — a valid document must never produce a diagnostic:
/// - comments, verbatim bodies, `\verb`, `\url` and `\iffalse` blocks are ignored;
/// - `\newcommand` / `\newenvironment` / `\def` bodies are not analysed (they may hold half an environment);
/// - nothing after `\end{document}` is analysed;
/// - unclosed `\begin` and stray `\end` are only reported in files containing `\begin{document}`
///   (section files may legitimately open or close environments of the including file);
/// - brace checks are skipped when the file changes category codes (`\catcode`).
public enum StructureLinter {
    public static func diagnostics(in text: String, fileURL: URL) -> [Diagnostic] {
        let src = MaskedSource(text)
        let walk = StructureWalker.walk(src)
        var result: [(offset: Int, diagnostic: Diagnostic)] = []

        func add(_ severity: DiagnosticSeverity, _ message: String, offset: Int, length: Int) {
            let position = src.position(at: offset)
            result.append((offset, Diagnostic(severity: severity, source: .structure, message: message, fileURL: fileURL,
                                              line: position.line, column: position.column, length: max(1, length))))
        }

        if !src.hasCatcode {
            for offset in walk.strayClosingBraces {
                add(.error, String(localized: "Unmatched closing brace “}”"), offset: offset, length: 1)
            }
            if walk.reachedEnd {
                for brace in walk.openBraces {
                    add(.error, String(localized: "Missing closing brace “}” for this “{”"), offset: brace.offset, length: 1)
                }
            }
        }

        for mismatch in walk.mismatches {
            let openName = mismatch.open.name
            let openLine = src.line(at: mismatch.open.offset)
            let message = String(localized: "“\\begin{\(openName)}” (line \(openLine)) is closed by “\\end{\(mismatch.closeName)}”")
            add(.error, message, offset: mismatch.offset, length: mismatch.end - mismatch.offset)
        }

        if walk.hasBeginDocument {
            for stray in walk.strayEnds {
                add(.error, String(localized: "“\\end{\(stray.name)}” has no matching “\\begin”"),
                    offset: stray.offset, length: stray.end - stray.offset)
            }
            if walk.reachedEnd {
                for open in walk.openEnvironments {
                    add(.error, String(localized: "Environment “\(open.name)” is never closed"),
                        offset: open.offset, length: open.end - open.offset)
                }
            }
        }

        for offset in walk.unclosedDollars {
            add(.warning, String(localized: "Inline math is not closed: missing “$” before the end of the paragraph"),
                offset: offset, length: 1)
        }

        return result.sorted { $0.offset < $1.offset }.map { $0.diagnostic }
    }
}

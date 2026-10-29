import Foundation
import TeXCore

/// Runs `chktex` on in-memory text (via stdin) and returns `.chktex` diagnostics.
public struct ChkTeXLinter: Sendable {
    public let distribution: TeXDistribution
    /// chktex warning numbers that are not reported (default: `defaultSuppressions`).
    public var suppressedWarnings: Set<Int>

    public init(distribution: TeXDistribution) {
        self.init(distribution: distribution, suppressedWarnings: Self.defaultSuppressions)
    }

    public init(distribution: TeXDistribution, suppressedWarnings: Set<Int>) {
        self.distribution = distribution
        self.suppressedWarnings = suppressedWarnings
    }

    /// Warnings that are mostly noise for a mathematician's documents. Each entry: why it is off.
    public static let defaultSuppressions: Set<Int> = [
        1,  // "Command terminated with space" — fires on every intentional `\LaTeX\ ` / `\ldots ` idiom.
        3,  // "You should enclose the previous parenthesis with {}" — fires on ordinary math like `f(x)^2`.
        8,  // "Wrong length of dash" — hyphenated names, number ranges in math and `--` in code are fine.
        9,  // "‘)’ expected, found ‘]’" — half-open intervals [0,1) are everyday mathematics; brace
            // balance is checked precisely by TeXCore's StructureLinter instead.
        10, // "Solo ‘)’ found" — same: (0,1] and ]a,b[ interval notations.
        12, // "Interword spacing (\ ) should perhaps be used" — every "e.g." / "i.e." in the text.
        13, // "Intersentence spacing (\@) should perhaps be used" — capitals before periods ("in H. ").
        15, // "No match found for ‘(’" — intervals again (and the StructureLinter covers braces).
        17, // "Number of ‘(’ doesn't match the number of ‘)’" — end-of-file summary of the same.
        24, // "Delete this space to maintain correct pagereferences" — `text \label{…}` is harmless.
        30, // "Multiple spaces detected in output" — alignment spaces in source are a style choice.
        36, // "You should put a space in front of parenthesis" — wrong for math and citations.
        37, // "You should avoid spaces in front of parenthesis" — idem.
        38, // "You should not use punctuation in front of quotes" — British vs. American convention.
        39, // "Double space found" — invisible in output, noisy while typing.
        40, // "You should put punctuation outside inner/inside display math mode" — mathematical
            // convention puts the period inside display math.
        41, // "You ought to not use primitive TeX in LaTeX code" — `\def` in preambles is common practice.
        44, // "User Regex: …" — chktexrc's opinionated table-rule regexes (booktabs advice).
        46, // "Use \( … \) instead of $ … $" — `$…$` is standard and robust.
    ]

    /// Runs chktex. Returns [] when chktex is missing or fails (linting is best effort).
    public func lint(text: String, fileURL: URL) async -> [Diagnostic] {
        guard let chktex = distribution.url(for: .chktex) else { return [] }
        let arguments = Self.arguments(suppressing: suppressedWarnings)
        guard let output = try? await ProcessRunner.run(chktex, arguments: arguments,
                                                        environment: distribution.processEnvironment,
                                                        stdin: Data(text.utf8), timeout: .seconds(20)),
              !output.cancelled, !output.timedOut else { return [] }
        return Self.parse(output: output.stdoutText, text: text, fileURL: fileURL, suppressed: suppressedWarnings)
    }

    /// `chktex -q -I0 -v0 -f '%l:%c:%d:%k:%n:%m<newline>' -n<k>…` (reads stdin). The format must end with a
    /// real newline character: chktex does not interpret a backslash-n escape (verified with chktex 1.7.x).
    static func arguments(suppressing suppressed: Set<Int>) -> [String] {
        ["-q", "-I0", "-v0", "-f", "%l:%c:%d:%k:%n:%m\n"] + suppressed.sorted().map { "-n\($0)" }
    }

    /// Parses `line:column:length:kind:number:message` lines. chktex counts columns and lengths in bytes
    /// (it is not UTF-8 aware); they are converted to UTF-16 units using `text`.
    static func parse(output: String, text: String, fileURL: URL, suppressed: Set<Int> = []) -> [Diagnostic] {
        let sourceLines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        var result: [Diagnostic] = []
        for raw in output.split(separator: "\n") {
            let fields = raw.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, let line = Int(fields[0]), let column = Int(fields[1]),
                  let number = Int(fields[4]), !suppressed.contains(number) else { continue }
            let length = Int(fields[2]) ?? 1
            let kind = fields[3].trimmingCharacters(in: .whitespaces)
            let message = fields[5].trimmingCharacters(in: .whitespaces)
            let severity: DiagnosticSeverity = kind.lowercased() == "error" ? .warning : .info
            var span = (column: column, length: length)
            if line >= 1, line <= sourceLines.count {
                span = utf16Span(byteColumn: column, byteLength: length, in: sourceLines[line - 1])
            }
            result.append(Diagnostic(severity: severity, source: .chktex,
                                     message: message.isEmpty ? "chktex \(number)" : message,
                                     detail: "chktex \(kind.lowercased()) \(number)", fileURL: fileURL.standardizedFileURL,
                                     line: line, column: span.column, length: max(span.length, 1)))
        }
        return result
    }

    /// Converts a 1-based byte column + byte length on `line` to a 1-based UTF-16 column + length.
    static func utf16Span(byteColumn: Int, byteLength: Int, in line: Substring) -> (column: Int, length: Int) {
        /// UTF-16 units of the scalars that start before `byteOffset`.
        func utf16Offset(ofByte byteOffset: Int) -> Int {
            var bytes = 0
            var units = 0
            for scalar in line.unicodeScalars {
                if bytes >= byteOffset { break }
                bytes += String(scalar).utf8.count
                units += scalar.utf16.count
            }
            return units
        }
        let start = utf16Offset(ofByte: byteColumn - 1)
        let end = utf16Offset(ofByte: byteColumn - 1 + max(byteLength, 0))
        return (start + 1, max(end - start, 1))
    }
}

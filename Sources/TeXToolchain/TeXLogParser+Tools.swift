import Foundation
import TeXCore

/// What `latexmk`'s own output (stdout/stderr) reports beyond the TeX log.
public struct LatexmkOutputSummary: Sendable, Hashable {
    /// Files latexmk reported as missing ("Latexmk: Missing input file 'x.sty' …"), in order, unique.
    public var missingFiles: [String]
    /// Problems not visible in the TeX log, e.g. a bibliography tool that could not run at all.
    public var diagnostics: [Diagnostic]

    public init(missingFiles: [String] = [], diagnostics: [Diagnostic] = []) {
        self.missingFiles = missingFiles
        self.diagnostics = diagnostics
    }
}

extension TeXLogParser {
    /// Parses BibTeX `.blg` / biber `.blg` output.
    ///
    /// BibTeX: `… ---line N of file F` (errors), `Warning--…` optionally followed by `--line N of file F`,
    /// `I couldn't open database file F`, `I couldn't open style file F`, `… ---while reading file F`.
    /// Biber: `[ms] Module.pm:N> WARN|ERROR - message`, with `BibTeX subsystem: <tmp>/refs.bib_123.utf8, line N, …`
    /// mapped back to the project's `refs.bib`. `source` is used for every diagnostic (pass `.bibtex` or `.biber`;
    /// the format is detected from the content either way).
    public static func parseBibliographyLog(_ text: String, source: DiagnosticSource, mapPath: (String) -> URL?) -> [Diagnostic] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        let isBiber = lines.prefix(5).contains { $0.contains("> INFO - This is Biber") || $0.hasPrefix("INFO - This is Biber") }
            || (source == .biber && !lines.prefix(2).contains { $0.hasPrefix("This is BibTeX") })
        let result = isBiber ? parseBiber(lines, source: source, mapPath: mapPath)
                             : parseBibTeX(lines, source: source, mapPath: mapPath)
        return normalized(result)
    }

    private static func parseBibTeX(_ lines: [Substring], source: DiagnosticSource, mapPath: (String) -> URL?) -> [Diagnostic] {
        var result: [Diagnostic] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let r = line.range(of: "---line ") {
                // I was expecting a `,' or a `}'---line 11 of file refs.bib
                let message = String(line[line.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let (lineNo, file) = parseLineOfFile(line[r.upperBound...])
                var detail: [String] = []
                var j = i + 1
                while j < lines.count, j < i + 8 {
                    let l = lines[j]
                    if l.hasPrefix(" : ") || l == " :" || l.hasPrefix("(Error may have been") || l.hasPrefix("I'm skipping whatever remains") {
                        detail.append(String(l).trimmingTrailingSpaces())
                        j += 1
                    } else { break }
                }
                result.append(Diagnostic(severity: .error, source: source,
                                         message: message.isEmpty ? String(line) : message,
                                         detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
                                         fileURL: file.flatMap(mapPath), line: lineNo))
                i = j
                continue
            }
            if line.hasPrefix("Warning--") {
                let message = String(line.dropFirst("Warning--".count)).trimmingCharacters(in: .whitespaces)
                var lineNo: Int?, file: String?
                if i + 1 < lines.count, lines[i + 1].hasPrefix("--line ") {
                    (lineNo, file) = parseLineOfFile(lines[i + 1].dropFirst("--line ".count))
                    i += 1
                }
                result.append(Diagnostic(severity: .warning, source: source, message: message,
                                         fileURL: file.flatMap(mapPath), line: lineNo))
                i += 1
                continue
            }
            if line.hasPrefix("I couldn't open database file ") {
                let name = String(line.dropFirst("I couldn't open database file ".count)).trimmingCharacters(in: .whitespaces)
                result.append(Diagnostic(severity: .error, source: source, message: String(line), missingFile: name))
            } else if line.hasPrefix("I couldn't open style file ") {
                let name = String(line.dropFirst("I couldn't open style file ".count)).trimmingCharacters(in: .whitespaces)
                result.append(Diagnostic(severity: .error, source: source, message: String(line), missingFile: name))
            } else if let r = line.range(of: "---while reading file ") {
                // I found no \citation commands---while reading file main.aux
                let message = String(line[line.startIndex..<r.lowerBound])
                let file = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                result.append(Diagnostic(severity: .error, source: source, message: message, fileURL: mapPath(file)))
            } else if line.hasPrefix("I couldn't open file name ") || line.hasPrefix("I couldn't open auxiliary file") {
                result.append(Diagnostic(severity: .error, source: source, message: String(line)))
            }
            i += 1
        }
        return result
    }

    /// "11 of file refs.bib" → (11, "refs.bib").
    private static func parseLineOfFile(_ text: Substring) -> (Int?, String?) {
        let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
        let lineNo = Int(digits)
        guard let r = text.range(of: " of file ") else { return (lineNo, nil) }
        let file = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (lineNo, file.isEmpty ? nil : file)
    }

    private static func parseBiber(_ lines: [Substring], source: DiagnosticSource, mapPath: (String) -> URL?) -> [Diagnostic] {
        var result: [Diagnostic] = []
        for line in lines {
            // [123] Utils.pm:410> WARN - message
            let body: Substring
            if let r = line.range(of: "> ") { body = line[r.upperBound...] } else { body = line }
            let severity: DiagnosticSeverity
            let message: Substring
            if body.hasPrefix("WARN - ") {
                severity = .warning
                message = body.dropFirst("WARN - ".count)
            } else if body.hasPrefix("ERROR - ") {
                severity = .error
                message = body.dropFirst("ERROR - ".count)
            } else {
                continue
            }
            var text = String(message).trimmingCharacters(in: .whitespaces)
            var fileURL: URL?
            var lineNo: Int?
            // BibTeX subsystem: /tmp/biber_tmp_x/refs.bib_12345.utf8, line 8, syntax error: …
            if let r = text.range(of: "BibTeX subsystem: ") {
                let rest = text[r.upperBound...]
                if let comma = rest.firstIndex(of: ",") {
                    let tmpPath = String(rest[rest.startIndex..<comma])
                    fileURL = mapPath(originalBibName(fromBiberTemp: tmpPath))
                    let afterPath = rest[rest.index(after: comma)...].trimmingLeadingSpaces()
                    if afterPath.hasPrefix("line ") {
                        let digits = afterPath.dropFirst(5).prefix(while: { $0.isNumber })
                        lineNo = Int(digits)
                        if let comma2 = afterPath.firstIndex(of: ",") {
                            text = "BibTeX subsystem: " + String(afterPath[afterPath.index(after: comma2)...]).trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            } else if let r = text.range(of: #"\(([^()]+\.bib)\)"#, options: .regularExpression) {
                // Datamodel: article entry 'x' (refs.bib): Missing mandatory field 'journal'
                let name = String(text[r].dropFirst().dropLast())
                fileURL = mapPath(name)
            }
            result.append(Diagnostic(severity: severity, source: source, message: text, fileURL: fileURL, line: lineNo))
        }
        return result
    }

    /// User-facing explanation for a biber step that could not run (no .blg was produced).
    public static var biberFailureMessage: String {
        String(localized: "Biber failed to run. Your TeX distribution’s biber appears to be broken — run “sudo tlmgr update biber” or reinstall MacTeX, or use “backend=bibtex” with biblatex.")
    }

    /// biber copies data sources to a temporary "<name>_<pid>.utf8" file; recover "<name>".
    static func originalBibName(fromBiberTemp path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".utf8") { name = String(name.dropLast(5)) }
        if let underscore = name.lastIndex(of: "_"), name[name.index(after: underscore)...].allSatisfy(\.isNumber),
           underscore != name.startIndex {
            name = String(name[name.startIndex..<underscore])
        }
        return name
    }

    /// Parses latexmk's stdout/stderr: missing input files and bibliography/index tools that failed to run
    /// (no `.blg`/`.ilg` to parse), plus fatal `xdvipdfmx` errors.
    public static func parseLatexmkOutput(_ text: String) -> LatexmkOutputSummary {
        var summary = LatexmkOutputSummary()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var toolLines: [String: [String]] = [:]       // "biber" → its own stderr lines ("biber: …")
        var failedTools: [(tool: String, message: String)] = []
        var inErrorSummary = false
        for raw in lines {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if let r = line.range(of: #"Missing input file:? '([^']+)'"#, options: .regularExpression) {
                let quoted = line[r]
                if let open = quoted.firstIndex(of: "'") {
                    let name = String(quoted[quoted.index(after: open)...].dropLast())
                    if !name.isEmpty, !summary.missingFiles.contains(name) { summary.missingFiles.append(name) }
                }
                continue
            }
            for tool in ["biber", "bibtex", "makeindex"] where line.hasPrefix("\(tool): ") || line.hasPrefix("\(tool) error") {
                toolLines[tool, default: []].append(String(line))
            }
            if line.hasPrefix("Collected error summary") { inErrorSummary = true; continue }
            if inErrorSummary {
                // "  biber /path/main: Could not open biber log file '/path/main.blg'"
                let trimmed = line.trimmingLeadingSpaces()
                if trimmed.isEmpty { continue }
                for tool in ["biber", "bibtex", "makeindex"] where trimmed.hasPrefix(tool + " ") {
                    if let colon = trimmed.range(of: ": ") {
                        let message = String(trimmed[colon.upperBound...])
                        if message.contains("Could not open") || message.contains("gave return code") && !message.contains("Bibtex errors") {
                            failedTools.append((tool, message))
                        }
                    }
                }
                continue
            }
            if line.hasPrefix("xdvipdfmx:fatal:") {
                summary.diagnostics.append(Diagnostic(severity: .error, source: .latexmk,
                                                      message: String(line.dropFirst("xdvipdfmx:fatal:".count)).trimmingCharacters(in: .whitespaces)))
            }
        }
        for (tool, message) in failedTools {
            let source: DiagnosticSource = tool == "biber" ? .biber : tool == "bibtex" ? .bibtex : .makeindex
            let detail = (toolLines[tool] ?? []) + [message]
            let text: String
            switch tool {
            case "biber": text = TeXLogParser.biberFailureMessage
            case "bibtex": text = String(localized: "BibTeX failed to run; the bibliography was not generated.")
            default: text = String(localized: "makeindex failed to run; the index was not generated.")
            }
            summary.diagnostics.append(Diagnostic(severity: .error, source: source, message: text,
                                                  detail: detail.joined(separator: "\n")))
        }
        return summary
    }
}

import Foundation
import TeXCore

/// Parses TeX `.log` files produced with `-file-line-error` (see ARCHITECTURE.md §Log parser).
///
/// The log is expected to be unwrapped (`max_print_line=10000`, which `TeXDistribution.processEnvironment`
/// sets). The parser keeps a **file stack** from the `(file` / `)` tokens TeX prints when it opens and
/// closes input files, so messages without a file name are attributed to the innermost project file.
/// Lines that belong to an error block, a warning, a bad-box display or a runaway argument are not
/// scanned for parentheses (they contain source text that is not balanced).
public enum TeXLogParser {
    /// - Parameters:
    ///   - log: full log text.
    ///   - mapPath: maps a path as written in the log (relative to the compile directory, or absolute)
    ///     to a project URL; return nil for files outside the project (they are then attributed to the
    ///     nearest project file on the file stack, or left without a file).
    /// - Returns: deduplicated diagnostics, errors first, then by file and line.
    public static func parse(log: String, mapPath: (String) -> URL?) -> [Diagnostic] {
        withoutActuallyEscaping(mapPath) { mapPath in
            var parser = LogParser(log: log, mapPath: mapPath)
            parser.run()
            return normalized(parser.diagnostics)
        }
    }

    /// Removes duplicates and sorts: errors first (severity descending), then by file path, line, column.
    /// Drops TeX's follow-up "Emergency stop." when a more specific error exists.
    public static func normalized(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        struct Key: Hashable {
            var severity: DiagnosticSeverity, source: DiagnosticSource, path: String?
            var line: Int?, column: Int?, message: String
        }
        let hasSpecificError = diagnostics.contains { $0.severity == .error && !isFollowUpError($0.message) }
        var seen = Set<Key>()
        var result: [Diagnostic] = []
        for d in diagnostics {
            if hasSpecificError && d.severity == .error && isFollowUpError(d.message) { continue }
            let key = Key(severity: d.severity, source: d.source, path: d.fileURL?.path, line: d.line, column: d.column, message: d.message)
            if seen.insert(key).inserted { result.append(d) }
        }
        return result.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            let pa = a.fileURL?.path ?? "\u{10FFFF}", pb = b.fileURL?.path ?? "\u{10FFFF}"
            if pa != pb { return pa < pb }
            let la = a.line ?? Int.max, lb = b.line ?? Int.max
            if la != lb { return la < lb }
            return (a.column ?? 0) < (b.column ?? 0)
        }
    }

    static func isFollowUpError(_ message: String) -> Bool {
        message == "Emergency stop." || message.hasPrefix("==> Fatal error occurred")
    }

    /// Extensions that mark a `(token` in the log as a file being opened.
    static let fileExtensions: Set<String> = [
        "tex", "sty", "cls", "cfg", "def", "clo", "fd", "aux", "toc", "lof", "lot", "bbl", "out", "nav", "snm",
        "vrb", "ind", "idx", "ltx", "dtx", "ins", "bib", "bst", "mkii", "mkiv", "lua", "ldf", "bbx", "cbx", "lbx",
        "dbx", "cnf", "dict", "enc", "fdd", "pgf", "tikz", "pdf_tex", "eps_tex", "mtx", "gls", "glo", "tdo",
        "lol", "loa", "thm", "xmpdata", "w18",
    ]
}

/// One entry of the TeX file stack.
private enum StackEntry {
    case file(String)
    case other
}

/// The stateful single-pass parser behind `TeXLogParser.parse`.
private struct LogParser {
    let lines: [Substring]
    let mapPath: (String) -> URL?
    var stack: [StackEntry] = []
    var diagnostics: [Diagnostic] = []
    private var mapCache: [String: URL?] = [:]
    private var pendingRunaway: String?
    private var lastClosedProjectFile: URL?
    private var missingCharacters: [(font: String, chars: [String], file: URL?)] = []

    init(log: String, mapPath: @escaping (String) -> URL?) {
        var text = log
        text.makeContiguousUTF8()
        let u = text.utf8
        let ranges = u.withContiguousStorageIfAvailable(ByteScan.lineRanges) ?? []
        // Index offsetting is O(1) on a contiguous UTF-8 string; line breaks are ASCII, so every range
        // starts and ends on a character boundary.
        self.lines = ranges.map { r in
            Substring(u[u.index(u.startIndex, offsetBy: r.lowerBound)..<u.index(u.startIndex, offsetBy: r.upperBound)])
        }
        self.mapPath = mapPath
    }

    // MARK: Driver

    mutating func run() {
        var i = 0
        while i < lines.count {
            i = handleLine(at: i)
        }
        flushMissingCharacters()
    }

    /// Handles the line at `i` and returns the index of the next line to process.
    private mutating func handleLine(at i: Int) -> Int {
        let line = lines[i]
        guard let first = line.utf8.first else { return i + 1 }

        if first == UInt8(ascii: "!") {
            return parseError(at: i, file: nil, lineNumber: nil, message: Substring(line.dropFirst()).trimmingLeadingSpaces())
        }
        if let fle = LogParser.matchFileLineError(line) {
            return parseError(at: i, file: fle.path, lineNumber: fle.line, message: fle.message)
        }
        if first == UInt8(ascii: "L") || first == UInt8(ascii: "P") || first == UInt8(ascii: "C") {
            if let header = LogParser.warningHeader(line) {
                return parseWarning(at: i, headerLength: header)
            }
        }
        if first == UInt8(ascii: "O") || first == UInt8(ascii: "U") {
            if line.utf8HasPrefix("Overfull \\") || line.utf8HasPrefix("Underfull \\") {
                return parseBadBox(at: i)
            }
        }
        if first == UInt8(ascii: "R"), line.utf8HasPrefix("Runaway "), line.utf8.last == UInt8(ascii: "?") {
            // "Runaway argument?" / "Runaway definition?" / "Runaway text?" + the runaway tokens on the next line.
            if i + 1 < lines.count { pendingRunaway = String(lines[i + 1]).trimmingCharacters(in: .whitespaces) }
            return i + 2
        }
        if first == UInt8(ascii: "M"), line.utf8HasPrefix("Missing character: There is no ") {
            recordMissingCharacter(line)
            return i + 1
        }
        // "pdfTeX warning", "LuaTeX warning", "XeTeX warning" (cheap byte pre-filter first).
        if let offset = line.utf8Offset(of: "TeX warning") {
            let before = line.utf8Slice(0, offset)
            let engineStart: Int? = ["pdf", "Lua", "Xe"].first(where: { before.hasSuffix($0) }).map { offset - $0.utf8.count }
            if let engineStart {
                processParentheses(line.utf8Slice(0, engineStart))
                return parseEngineWarning(at: i, text: line.utf8Slice(engineStart))
            }
        }
        processParentheses(line)
        return i + 1
    }

    // MARK: File stack

    private mutating func mapped(_ path: String) -> URL? {
        if let cached = mapCache[path] { return cached }
        let url = mapPath(path)
        mapCache[path] = url
        return url
    }

    /// The innermost file on the stack that belongs to the project; when no project file is open (e.g.
    /// "File ended while scanning use of …" after the file was closed), the project file closed last.
    private mutating func currentProjectFile() -> URL? {
        for entry in stack.reversed() {
            if case .file(let path) = entry, let url = mapped(path) { return url }
        }
        return lastClosedProjectFile
    }

    /// The innermost file on the stack (project or not).
    private func currentFilePath() -> String? {
        for entry in stack.reversed() {
            if case .file(let path) = entry { return path }
        }
        return nil
    }

    /// Updates the file stack from the `(` and `)` in an ordinary log line.
    private mutating func processParentheses(_ line: Substring) {
        line.withUTF8Bytes { bytes in
            var k = 0
            while k < bytes.count {
                let c = bytes[k]
                if c == ByteScan.openParen {
                    if let (name, end) = LogParser.fileName(in: bytes, from: k + 1) {
                        stack.append(.file(name))
                        k = end
                        continue
                    }
                    stack.append(.other)
                } else if c == ByteScan.closeParen {
                    if let entry = stack.popLast(), case .file(let path) = entry, let url = mapped(path) {
                        lastClosedProjectFile = url
                    }
                }
                k += 1
            }
        }
    }

    /// Reads a file name that TeX printed right after `(` (at byte offset `start` of a line). Returns the
    /// name and the offset just past it, or nil when the token does not look like a file.
    static func fileName(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> (String, Int)? {
        let count = bytes.count
        guard start < count else { return nil }
        func string(_ from: Int, _ to: Int) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: bytes[from..<to]), as: UTF8.self)
        }
        if bytes[start] == ByteScan.quote {
            // ("./my file.tex"
            guard let close = ByteScan.find(ByteScan.quote, in: bytes, from: start + 1) else { return nil }
            guard looksLikeFile(bytes, start + 1, close) else { return nil }
            return (string(start + 1, close), close + 1)
        }
        // The run up to the next parenthesis (or end of line).
        var runEnd = start
        while runEnd < count, bytes[runEnd] != ByteScan.openParen, bytes[runEnd] != ByteScan.closeParen { runEnd += 1 }
        guard runEnd > start, bytes[start] != ByteScan.space else { return nil }
        // TeX does not quote names containing spaces: take the longest prefix that ends (at a space or at
        // the end of the run) with a known file extension; otherwise the first word.
        var best: Int?
        var firstBreak: Int?
        for cursor in (start + 1)...runEnd {
            let isBreak = cursor == runEnd || bytes[cursor] == ByteScan.space || bytes[cursor] == ByteScan.tab
            guard isBreak else { continue }
            if firstBreak == nil { firstBreak = cursor }
            if hasKnownExtension(bytes, start, cursor) { best = cursor }
        }
        let end = best ?? firstBreak ?? runEnd
        guard looksLikeFile(bytes, start, end) else { return nil }
        return (string(start, end), end)
    }

    /// `looksLikeFile` on the bytes `[start, end)`.
    static func looksLikeFile(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        let length = end - start
        guard length > 0 else { return false }
        let first = bytes[start]
        let second: UInt8 = length > 1 ? bytes[start + 1] : 0
        let third: UInt8 = length > 2 ? bytes[start + 2] : 0
        let pathLike = first == ByteScan.slash
            || (first == ByteScan.dot && second == ByteScan.slash)
            || (first == ByteScan.dot && second == ByteScan.dot && third == ByteScan.slash)
            || (first == UInt8(ascii: "~") && second == ByteScan.slash)
        if pathLike { return length > 2 }
        return hasKnownExtension(bytes, start, end)
    }

    /// `hasKnownExtension` on the bytes `[start, end)`: the part after the last dot (1–8 ASCII
    /// characters, no slash) is one of `TeXLogParser.fileExtensions` (case-insensitive).
    static func hasKnownExtension(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        var dot = end - 1
        let limit = max(start + 1, end - 9)
        while dot >= limit, bytes[dot] != ByteScan.dot {
            if bytes[dot] == ByteScan.slash { return false }
            dot -= 1
        }
        guard dot >= limit, end - dot - 1 >= 1 else { return false }
        var ext = ""
        for k in (dot + 1)..<end {
            var c = bytes[k]
            guard c < 0x80 else { return false }
            if c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") { c += 32 }
            ext.unicodeScalars.append(Unicode.Scalar(c))
        }
        return TeXLogParser.fileExtensions.contains(ext)
    }

    static func looksLikeFile(_ name: String) -> Bool {
        if name.hasPrefix("./") || name.hasPrefix("../") || name.hasPrefix("/") || name.hasPrefix("~/") {
            return name.count > 2
        }
        return hasKnownExtension(Substring(name))
    }

    static func hasKnownExtension(_ name: Substring) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 8, !ext.contains("/") else { return false }
        return TeXLogParser.fileExtensions.contains(ext.lowercased())
    }

    // MARK: Message starts

    /// `path:123: message` (from -file-line-error). The path must look like a file.
    static func matchFileLineError(_ line: Substring) -> (path: String, line: Int, message: Substring)? {
        // Byte offsets of the first ":<digits>:" followed by a space or the end of the line.
        let match: (colon: Int, afterColon: Int, value: Int)? = line.withUTF8Bytes { bytes in
            guard let f = bytes.first, f != ByteScan.space, f != ByteScan.openParen, f != UInt8(ascii: "\\") else { return nil }
            var from = 0
            while let colon = ByteScan.find(ByteScan.colon, in: bytes, from: from) {
                var d = colon + 1
                var value = 0
                var digits = 0
                while d < bytes.count, let digit = asciiDigit(bytes[d]) {
                    if digits < 9 { value = value * 10 + digit }
                    digits += 1
                    d += 1
                }
                if digits > 0, d < bytes.count, bytes[d] == ByteScan.colon,
                   d + 1 == bytes.count || bytes[d + 1] == ByteScan.space {
                    return (colon, d + 1, value)
                }
                from = colon + 1
            }
            return nil
        }
        guard let match else { return nil }
        let path = String(line.utf8Slice(0, match.colon))
        guard looksLikeFile(path) || path.contains("/") else { return nil }
        let message = match.afterColon >= line.utf8.count ? Substring("") : line.utf8Slice(match.afterColon + 1)
        return (path, match.value, message.trimmingLeadingSpaces())
    }

    private static func asciiDigit(_ c: UInt8) -> Int? {
        c >= 48 && c <= 57 ? Int(c - 48) : nil
    }

    /// Length of the warning header ("LaTeX Warning: ", "Package hyperref Warning: ", …) or nil.
    static func warningHeader(_ line: Substring) -> Int? {
        if line.utf8HasPrefix("LaTeX Warning: ") { return "LaTeX Warning: ".utf8.count }
        if line.utf8HasPrefix("LaTeX Font Warning: ") { return "LaTeX Font Warning: ".utf8.count }
        if line.utf8HasPrefix("LaTeX3 Warning: ") { return "LaTeX3 Warning: ".utf8.count }
        guard line.utf8HasPrefix("Package ") || line.utf8HasPrefix("Class ") || line.utf8HasPrefix("LaTeX ") else { return nil }
        let headEnd: Int
        let headerEnd: Int
        if let offset = line.utf8Offset(of: " Warning: ") {
            headEnd = offset
            headerEnd = offset + " Warning: ".utf8.count
        } else if line.utf8HasSuffix(" Warning:") {
            headEnd = line.utf8.count - " Warning:".utf8.count
            headerEnd = line.utf8.count
        } else {
            return nil
        }
        // "Package <name> Warning:" — the name is a single word (may contain dots/dashes).
        let words = line.utf8Slice(0, headEnd).split(separator: " ")
        guard words.count == 2 else { return nil }
        return headerEnd
    }

    /// Lines that start a new message (used to bound look-ahead).
    static func startsMessage(_ line: Substring) -> Bool {
        guard let f = line.utf8.first else { return false }
        if f == UInt8(ascii: "!") { return true }
        if matchFileLineError(line) != nil { return true }
        if warningHeader(line) != nil { return true }
        if line.utf8HasPrefix("Overfull \\") || line.utf8HasPrefix("Underfull \\") { return true }
        if line.utf8HasPrefix("Runaway ") { return true }
        return false
    }

    static func isBlank(_ line: Substring) -> Bool {
        line.utf8.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
    }

    /// `(fontspec)     text` → "text"; nil if the line is not a `(name)`-prefixed continuation.
    static func continuationText(_ line: Substring) -> Substring? {
        guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { return nil }
        let name = line[line.index(after: line.startIndex)..<close]
        guard !name.isEmpty, !name.contains(" "), name.count <= 40 else { return nil }
        let rest = line[line.index(after: close)...]
        return rest.trimmingLeadingSpaces()
    }

    // MARK: Errors

    private mutating func parseError(at i: Int, file: String?, lineNumber: Int?, message rawMessage: Substring) -> Int {
        var message = String(rawMessage).trimmingCharacters(in: .whitespaces)
        var next = i + 1
        // Multi-line package errors: "(fontspec)    The font … cannot be found;"
        while next < lines.count, let cont = LogParser.continuationText(lines[next]) {
            message += (message.isEmpty ? "" : " ") + cont.trimmingCharacters(in: .whitespaces)
            next += 1
        }
        if message.hasPrefix("==> Fatal error occurred") || message.isEmpty {
            pendingRunaway = nil
            return next
        }
        if message.hasPrefix("LaTeX Error: ") { message.removeFirst("LaTeX Error: ".count) }
        // "Package fontspec Error: msg" → "fontspec: msg" (same style as package warnings).
        if message.hasPrefix("Package ") || message.hasPrefix("Class "), let r = message.range(of: " Error: ") {
            let words = message[message.startIndex..<r.lowerBound].split(separator: " ")
            if words.count == 2 { message = "\(words[1]): " + message[r.upperBound...] }
        } else if message.hasPrefix("Package ") || message.hasPrefix("Class "), message.hasSuffix(" Error:") {
            let words = message.dropLast(" Error:".count).split(separator: " ")
            if words.count == 2 { message = "\(words[1]):" }
        }
        var messageTail: String?
        if message.count > 120, let cut = LogParser.sentenceBreak(in: message) {
            messageTail = String(message[cut...]).trimmingCharacters(in: .whitespaces)
            message = String(message[..<cut])
        }

        // Find the `l.N` context line before the next message.
        var contextLine: Int?
        var j = next
        while j < lines.count && j < i + 40 {
            let l = lines[j]
            if l.hasPrefix("l."), LogParser.lineContextNumber(l) != nil { contextLine = j; break }
            if LogParser.startsMessage(l) { break }
            j += 1
        }
        let topLine: Substring? = next < lines.count && !LogParser.isBlank(lines[next]) ? lines[next] : nil

        var detailLines: [String] = []
        if let messageTail, !messageTail.isEmpty { detailLines.append(messageTail) }
        if let runaway = pendingRunaway { detailLines.append("Runaway argument: " + runaway) }
        var end: Int
        var lineFromContext: Int?
        var sourceText: Substring?
        if let c = contextLine {
            let l = lines[c]
            lineFromContext = LogParser.lineContextNumber(l)
            sourceText = LogParser.lineContextText(l)
            // Context = from the first context line (skipping LaTeX's help preamble) to l.N + its continuation.
            var firstContext = c
            while firstContext > next, !LogParser.isBlank(lines[firstContext - 1]) { firstContext -= 1 }
            end = c + 1
            // The continuation (rest of the source line) is indented; it may be all spaces.
            if end < lines.count, lines[end].hasPrefix(" ") { end += 1 }
            for k in firstContext..<end where !LogParser.isBlank(lines[k]) {
                detailLines.append(String(lines[k]).trimmingTrailingSpaces())
            }
        } else {
            end = next
            while end < lines.count && end < next + 8 && !LogParser.isBlank(lines[end]) && !LogParser.startsMessage(lines[end]) {
                detailLines.append(String(lines[end]).trimmingTrailingSpaces())
                end += 1
            }
        }
        // Skip TeX's help text (ends with a blank line) so its parentheses do not touch the file stack.
        // TeX always writes that blank line; a line starting with `)` (a file being closed) also ends the
        // skip, so a truncated or hand-written log cannot lose a file-stack pop.
        if contextLine != nil {
            var k = end
            while k < lines.count && k < end + 12 && !lines[k].isEmpty && lines[k].utf8.first != ByteScan.closeParen
                    && !LogParser.startsMessage(lines[k]) { k += 1 }
            end = k
        }

        // Undefined control sequence: append the offending token (end of the top context line).
        if message.hasPrefix("Undefined control sequence") {
            let candidate = topLine.flatMap { LogParser.trailingControlSequence(in: $0) }
                ?? sourceText.flatMap { LogParser.trailingControlSequence(in: $0) }
            message = "Undefined control sequence"
            if let cs = candidate { message += " " + cs }
        }

        // Where: file:line → that file; else the innermost project file with the l.N line.
        var url: URL?
        var lineNo: Int?
        var detailPrefix: String?
        if let file, let mappedURL = mapped(file) {
            url = mappedURL
            lineNo = lineNumber
        } else if let file {
            url = currentProjectFile()
            detailPrefix = "\(file):\(lineNumber.map(String.init) ?? "?")"
        } else {
            let top = currentFilePath()
            if let top, let mappedURL = mapped(top) {
                url = mappedURL
                lineNo = lineFromContext
            } else {
                url = currentProjectFile()
                if let top, let n = lineFromContext { detailPrefix = "\(top):\(n)" }
            }
        }
        var column: Int?
        var length: Int?
        if lineNo != nil, let text = sourceText, let span = LogParser.errorSpan(in: text) {
            column = span.column
            length = span.length
        }
        if let detailPrefix { detailLines.insert(detailPrefix, at: 0) }

        diagnostics.append(Diagnostic(
            severity: .error, source: .tex, message: message,
            detail: detailLines.isEmpty ? nil : detailLines.joined(separator: "\n"),
            fileURL: url, line: lineNo, column: column, length: length,
            missingFile: LogParser.missingFile(in: message)
        ))
        pendingRunaway = nil
        return max(end, i + 1)
    }

    /// Index just past the first "; " or ". " after the first 20 characters (to split long messages).
    static func sentenceBreak(in message: String) -> String.Index? {
        guard message.count > 20 else { return nil }
        let searchStart = message.index(message.startIndex, offsetBy: 20)
        let candidates = ["; ", ". "].compactMap { message.range(of: $0, range: searchStart..<message.endIndex)?.lowerBound }
        guard let first = candidates.min() else { return nil }
        return message.index(after: first)
    }

    static func lineContextNumber(_ line: Substring) -> Int? {
        guard line.hasPrefix("l.") else { return nil }
        let digits = line.dropFirst(2).prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let after = line.dropFirst(2 + digits.count)
        guard after.isEmpty || after.hasPrefix(" ") else { return nil }
        return Int(digits)
    }

    /// The source text TeX shows in `l.N <text>` (up to the error point).
    static func lineContextText(_ line: Substring) -> Substring? {
        guard let n = lineContextNumber(line) else { return nil }
        let prefixCount = 2 + String(n).count
        var rest = line.dropFirst(prefixCount)
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        if rest.hasSuffix("^^M") { rest = rest.dropLast(3) }
        return rest
    }

    /// `\foo` at the end of `text` (ignoring trailing spaces), or nil.
    static func trailingControlSequence(in text: Substring) -> String? {
        var t = text
        while let last = t.last, last == " " { t = t.dropLast() }
        guard !t.isEmpty else { return nil }
        let chars = Array(t.unicodeScalars)
        var k = chars.count - 1
        let isLetter: (Unicode.Scalar) -> Bool = { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || $0 == "@" }
        if isLetter(chars[k]) {
            while k >= 0 && isLetter(chars[k]) { k -= 1 }
            guard k >= 0, chars[k] == "\\" else { return nil }
            return String(String.UnicodeScalarView(chars[k...]))
        }
        if k >= 1 && chars[k - 1] == "\\" { return "\\" + String(chars[k]) }
        return nil
    }

    /// 1-based UTF-16 column and length of the last token TeX read on the error line: a control word,
    /// a whole `\cmd[..]{..}` group when the text ends with `}`, a word, or a single character.
    /// nil when TeX truncated the context ("...").
    static func errorSpan(in text: Substring) -> (column: Int, length: Int)? {
        guard !text.hasPrefix("..."), !text.isEmpty else { return nil }
        let u = Array(text.utf16)
        var end = u.count
        while end > 0 && u[end - 1] == 0x20 { end -= 1 }
        guard end > 0 else { return nil }
        let isLetter: (UInt16) -> Bool = { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) || $0 == 0x40 }
        let backslash: UInt16 = 0x5C
        var start = end - 1
        let last = u[end - 1]
        if last == 0x7D { // "}"
            var depth = 0
            var k = end - 1
            var open: Int?
            while k >= 0 {
                if u[k] == 0x7D && (k == 0 || u[k - 1] != backslash) { depth += 1 }
                else if u[k] == 0x7B && (k == 0 || u[k - 1] != backslash) {
                    depth -= 1
                    if depth == 0 { open = k; break }
                }
                k -= 1
            }
            if let open {
                start = open
                // Optional arguments and a star between the command and the brace.
                var p = open
                while p > 0 && u[p - 1] == 0x5D { // "]"
                    guard let o = u[0..<(p - 1)].lastIndex(of: 0x5B) else { break }
                    p = o
                }
                if p > 0 && u[p - 1] == 0x2A { p -= 1 } // "*"
                var q = p
                while q > 0 && isLetter(u[q - 1]) { q -= 1 }
                if q < p && q > 0 && u[q - 1] == backslash { start = q - 1 }
            }
        } else if isLetter(last) {
            var k = end - 1
            while k > 0 && isLetter(u[k - 1]) { k -= 1 }
            start = (k > 0 && u[k - 1] == backslash) ? k - 1 : k
        } else if end >= 2 && u[end - 2] == backslash {
            start = end - 2
        }
        return (start + 1, end - start)
    }

    static func missingFile(in message: String) -> String? {
        // LaTeX Error: File `x.sty' not found.  /  Package pdftex.def Error: File `a.pdf' not found: …
        if let r = message.range(of: "File `"), let close = message[r.upperBound...].firstIndex(of: "'"),
           message[close...].hasPrefix("' not found") {
            return String(message[r.upperBound..<close])
        }
        // I can't find file `x'.
        if let r = message.range(of: "I can't find file `"), let close = message[r.upperBound...].firstIndex(of: "'") {
            return String(message[r.upperBound..<close])
        }
        // Font \x=ecrm1000 at 10.0pt not loadable: Metric (TFM) file not found.
        if message.hasSuffix("Metric (TFM) file not found."), let eq = message.firstIndex(of: "=") {
            let name = message[message.index(after: eq)...].prefix(while: { $0 != " " })
            if !name.isEmpty { return String(name) + ".tfm" }
        }
        return nil
    }

    // MARK: Warnings

    private mutating func parseWarning(at i: Int, headerLength: Int) -> Int {
        let line = lines[i]
        let header = String(Substring(line.utf8.prefix(headerLength))).trimmingCharacters(in: .whitespaces)
        var text = String(Substring(line.utf8.dropFirst(headerLength))).trimmingCharacters(in: .whitespaces)
        var next = i + 1
        while next < lines.count && next < i + 20 {
            let l = lines[next]
            if LogParser.isBlank(l) || LogParser.startsMessage(l) { break }
            if let cont = LogParser.continuationText(l) {
                text += (text.isEmpty ? "" : " ") + cont.trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix(" "), LogParser.isWarningContinuation(l.trimmingLeadingSpaces()) {
                text += (text.isEmpty ? "" : " ") + l.trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
            next += 1
        }
        var lineNo: Int?
        if let r = text.range(of: " on input line ") {
            let digits = text[r.upperBound...].prefix(while: { $0.isASCII && $0.isNumber })
            if let n = Int(digits) {
                lineNo = n
                text.removeSubrange(r.lowerBound..<digits.endIndex)
            }
        }
        var message = text
        if header.hasPrefix("Package ") || header.hasPrefix("Class ") {
            // Keep the package name: "hyperref: Token not allowed in a PDF string (Unicode): removing `math shift'."
            let name = header.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if !name.isEmpty { message = "\(name): \(text)" }
        }
        let severity: DiagnosticSeverity = LogParser.isInformational(text) ? .info : .warning
        diagnostics.append(Diagnostic(severity: severity, source: .tex, message: message,
                                      fileURL: currentProjectFile(), line: lineNo))
        return next
    }

    /// An indented line after a warning that continues it (`^^J\@spaces…` in LaTeX's warnings), as opposed
    /// to TeX's own output resuming: a file being opened `(…` or a page number `[12`.
    static func isWarningContinuation(_ trimmed: Substring) -> Bool {
        guard let first = trimmed.first else { return false }
        if first == "(" { return false }
        if first == "[" {
            let next = trimmed.dropFirst().first
            return !(next.map { $0.isASCII && $0.isNumber } ?? false)
        }
        return true
    }

    static func isInformational(_ text: String) -> Bool {
        let patterns = ["Label(s) may have changed", "Rerun", "rerun", "There were undefined references",
                        "There were undefined citations", "There were multiply-defined labels",
                        "Some font shapes were not available", "Size substitutions with differences",
                        "Citation(s) may have changed", "Please (re)run", "Writing file", "Tab has been converted"]
        return patterns.contains { text.contains($0) }
    }

    /// pdfTeX/LuaTeX/XeTeX warnings: one line, optionally followed by `<…>` / `l.N` context.
    private mutating func parseEngineWarning(at i: Int, text: Substring) -> Int {
        var next = i + 1
        var lineNo: Int?
        var detail: [String] = []
        var j = next
        while j < lines.count && j < next + 6 {
            let l = lines[j]
            if l.hasPrefix("<") || l.hasPrefix(" ") {
                if !LogParser.isBlank(l) { detail.append(String(l).trimmingTrailingSpaces()) }
                j += 1
                continue
            }
            if let n = LogParser.lineContextNumber(l) {
                lineNo = n
                detail.append(String(l).trimmingTrailingSpaces())
                next = j + 1
                if next < lines.count, lines[next].hasPrefix(" "), !LogParser.isBlank(lines[next]) { next += 1 }
            }
            break
        }
        var topURL: URL?
        if let top = currentFilePath() { topURL = mapped(top) }
        let fileURL = topURL ?? currentProjectFile()
        let useLine = lineNo != nil && topURL != nil
        diagnostics.append(Diagnostic(severity: .warning, source: .tex,
                                      message: String(text).trimmingCharacters(in: .whitespaces),
                                      detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
                                      fileURL: fileURL, line: useLine ? lineNo : nil))
        return next
    }

    // MARK: Bad boxes

    private mutating func parseBadBox(at i: Int) -> Int {
        var text = String(lines[i]).trimmingCharacters(in: .whitespaces)
        var lineNo: Int?
        if let r = text.range(of: #"at lines (\d+)--(\d+)"#, options: .regularExpression) {
            let digits = text[r].dropFirst("at lines ".count).prefix(while: { $0.isNumber })
            lineNo = Int(digits)
        } else if let r = text.range(of: #"at line (\d+)"#, options: .regularExpression) {
            lineNo = Int(text[r].dropFirst("at line ".count))
        }
        let inlineBox = text.hasSuffix("[]")
        if inlineBox { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        // Box display: optional blank line, then the box contents up to the next blank line.
        var next = i + 1
        var detail: [String] = []
        if !inlineBox {
            if next < lines.count && LogParser.isBlank(lines[next]) { next += 1 }
            var count = 0
            while next < lines.count && count < 6 && !LogParser.isBlank(lines[next]) && !LogParser.startsMessage(lines[next]) {
                let l = lines[next]
                let trimmed = l.trimmingLeadingSpaces()
                // Box displays start with "[]" or a font identifier ("\OT1/cmr/m/n/10 …").
                guard trimmed.hasPrefix("[]") || trimmed.hasPrefix("\\") || l.contains("[]") else { break }
                let t = String(l).trimmingCharacters(in: .whitespaces)
                if t != "[]" && !t.isEmpty { detail.append(t) }
                next += 1
                count += 1
            }
        }
        diagnostics.append(Diagnostic(severity: .badbox, source: .tex, message: text,
                                      detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
                                      fileURL: currentProjectFile(), line: lineNo))
        return next
    }

    // MARK: Missing characters

    private mutating func recordMissingCharacter(_ line: Substring) {
        // Missing character: There is no á ("E1) in font nullfont!
        // Missing character: There is no ∂ (U+2202) in font cmr10!
        let body = line.dropFirst("Missing character: There is no ".count)
        guard let inFont = body.range(of: " in font ", options: .backwards) else { return }
        var charPart = body[body.startIndex..<inFont.lowerBound]
        if let paren = charPart.range(of: " (", options: .backwards) { charPart = charPart[charPart.startIndex..<paren.lowerBound] }
        var font = String(body[inFont.upperBound...])
        if font.hasSuffix("!") { font.removeLast() }
        let file = currentProjectFile()
        let ch = String(charPart)
        if let idx = missingCharacters.firstIndex(where: { $0.font == font }) {
            if !missingCharacters[idx].chars.contains(ch) { missingCharacters[idx].chars.append(ch) }
        } else {
            missingCharacters.append((font, [ch], file))
        }
    }

    private mutating func flushMissingCharacters() {
        for entry in missingCharacters {
            let list = entry.chars.prefix(20).joined(separator: " ") + (entry.chars.count > 20 ? " …" : "")
            diagnostics.append(Diagnostic(severity: .warning, source: .tex,
                                          message: String(localized: "Missing character(s) in font \(entry.font): \(list)"),
                                          fileURL: entry.file))
        }
    }
}

extension Substring {
    func trimmingLeadingSpaces() -> Substring {
        var s = self
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        return s
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var s = Substring(self)
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return String(s)
    }
}

import Foundation

/// Tolerant BibTeX/BibLaTeX parser: extracts entry keys plus title/author/year.
/// Skips @comment, @preamble, @string and free text between entries; handles braces/quotes nesting and
/// both `{}` and `()` delimiters. Top-level `%` comment lines are ignored (so a commented-out
/// `% @article{...}` is not an entry). Values are returned without outer delimiters, without the
/// protective inner braces, and with whitespace collapsed.
public enum BibParser {
    public static func entries(in text: String, fileURL: URL) -> [BibEntry] {
        var parser = Parser(units: Array(text.utf16), fileURL: fileURL)
        return parser.run()
    }

    private struct Parser {
        let u: [UInt16]
        let n: Int
        let fileURL: URL
        var lineStarts: [Int] = [0]
        var entries: [BibEntry] = []

        init(units: [UInt16], fileURL: URL) {
            self.u = units
            self.n = units.count
            self.fileURL = fileURL
            var i = 0
            while i < n {
                if u[i] == 10 {
                    lineStarts.append(i + 1)
                } else if u[i] == 13 {
                    if i + 1 < n && u[i + 1] == 10 { i += 1 }
                    lineStarts.append(i + 1)
                }
                i += 1
            }
        }

        func line(at offset: Int) -> Int {
            var lo = 0
            var hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }

        mutating func run() -> [BibEntry] {
            var i = 0
            while i < n {
                let c = u[i]
                if c == 37 { // top-level comment line
                    while i < n && !isLineBreak(u[i]) { i += 1 }
                } else if c == 64 { // @
                    i = entry(from: i)
                } else {
                    i += 1
                }
            }
            return entries
        }

        /// True when `index` starts a line (after optional blanks) holding `@` + letter.
        func startsEntryLine(_ index: Int) -> Bool {
            var k = index
            while k < n && isHSpace(u[k]) { k += 1 }
            return k + 1 < n && u[k] == 64 && isASCIILetter(u[k + 1])
        }

        /// Start of the next line that begins an entry, after `from`.
        func nextEntryLineStart(after from: Int) -> Int? {
            var k = from
            while k < n {
                if isLineBreak(u[k]) && startsEntryLine(k + 1) {
                    var s = k + 1
                    while s < n && isHSpace(u[s]) { s += 1 }
                    return s
                }
                k += 1
            }
            return nil
        }

        mutating func entry(from start: Int) -> Int {
            var i = start + 1
            while i < n && isTeXWhitespace(u[i]) { i += 1 }
            let typeStart = i
            while i < n && (isASCIILetter(u[i]) || isASCIIDigit(u[i]) || u[i] == 95 || u[i] == 45) { i += 1 }
            let type = utf16String(u, typeStart..<i).lowercased()
            while i < n && isTeXWhitespace(u[i]) { i += 1 }
            guard !type.isEmpty, i < n, u[i] == 123 || u[i] == 40 else { return max(i, start + 1) }
            let open = u[i]
            let close: UInt16 = open == 123 ? 125 : 41
            if type == "comment" || type == "preamble" || type == "string" {
                return skipGroup(from: i, open: open) ?? (nextEntryLineStart(after: i) ?? n)
            }
            return parseEntry(type: type, offset: start, bodyStart: i + 1, close: close)
        }

        /// Skips a balanced group starting at `from`; returns the index after the closing delimiter.
        func skipGroup(from: Int, open: UInt16) -> Int? {
            if open == 123 { return matchBrace(from: from) }
            var braces = 0
            var inQuote = false
            var i = from + 1
            while i < n {
                let c = u[i]
                if c == 92 { i += 2; continue }
                if c == 123 { braces += 1 }
                else if c == 125 { braces -= 1 }
                else if c == 34 && braces <= 0 { inQuote.toggle() }
                else if c == 41 && braces <= 0 && !inQuote { return i + 1 }
                else if isLineBreak(c) && (braces > 0 || inQuote) && startsEntryLine(i + 1) { return nil }
                i += 1
            }
            return nil
        }

        mutating func parseEntry(type: String, offset: Int, bodyStart: Int, close: UInt16) -> Int {
            var i = bodyStart
            let keyStart = i
            while i < n && u[i] != 44 && u[i] != close && u[i] != 123 && u[i] != 61 { i += 1 }
            let key = utf16String(u, TeXArguments.trimmed(u, keyStart..<i))
            var fields: [String: String] = [:]
            guard !key.isEmpty, i < n else { return i }
            if u[i] == close {
                append(type: type, key: key, fields: fields, offset: offset)
                return i + 1
            }
            guard u[i] == 44 else { return i }   // malformed header
            i += 1
            while i < n {
                while i < n && (isTeXWhitespace(u[i]) || u[i] == 44) { i += 1 }
                if i >= n { break }
                if u[i] == close {
                    i += 1
                    break
                }
                if u[i] == 64 { break }   // next entry starts: this one was left unterminated
                let nameStart = i
                while i < n && u[i] != 61 && u[i] != 44 && u[i] != close && !isTeXWhitespace(u[i]) { i += 1 }
                let name = utf16String(u, nameStart..<i).lowercased()
                while i < n && isTeXWhitespace(u[i]) { i += 1 }
                guard i < n, u[i] == 61 else {
                    while i < n && u[i] != 44 && u[i] != close && u[i] != 64 { i += 1 }
                    continue
                }
                i += 1
                guard let parsed = parseValue(from: i, close: close) else {
                    append(type: type, key: key, fields: fields, offset: offset)
                    return nextEntryLineStart(after: i) ?? n
                }
                i = parsed.end
                if fields[name] == nil { fields[name] = parsed.value }
            }
            append(type: type, key: key, fields: fields, offset: offset)
            return i
        }

        mutating func append(type: String, key: String, fields: [String: String], offset: Int) {
            var year = fields["year"]
            if year == nil, let date = fields["date"], date.count >= 4 { year = String(date.prefix(4)) }
            entries.append(BibEntry(key: key, type: type, title: fields["title"], author: fields["author"] ?? fields["editor"],
                                    year: year, fileURL: fileURL, line: line(at: offset)))
        }

        /// Parses `value (# value)*`. Returns nil when the text ends or the next entry starts inside it.
        func parseValue(from start: Int, close: UInt16) -> (value: String, end: Int)? {
            var i = start
            var pieces: [String] = []
            while true {
                while i < n && isTeXWhitespace(u[i]) { i += 1 }
                guard i < n else { return nil }
                let c = u[i]
                if c == 123 {
                    guard let end = matchBrace(from: i) else { return nil }
                    pieces.append(clean(i + 1, end - 1, keepEdges: true))
                    i = end
                } else if c == 34 {
                    var k = i + 1
                    var depth = 0
                    while k < n {
                        let d = u[k]
                        if d == 92 { k += 2; continue }
                        if d == 123 { depth += 1 }
                        else if d == 125 { depth -= 1 }
                        else if d == 34 && depth <= 0 { break }
                        else if isLineBreak(d) && depth > 0 && startsEntryLine(k + 1) { return nil }
                        k += 1
                    }
                    guard k < n else { return nil }
                    pieces.append(clean(i + 1, k, keepEdges: true))
                    i = k + 1
                } else {
                    let s = i
                    while i < n && u[i] != 44 && u[i] != 35 && u[i] != close && !isTeXWhitespace(u[i]) { i += 1 }
                    pieces.append(clean(s, i, keepEdges: true))
                }
                while i < n && isTeXWhitespace(u[i]) { i += 1 }
                if i < n && u[i] == 35 {
                    i += 1
                    continue
                }
                return (pieces.count == 1 ? pieces[0].trimmingCharacters(in: .whitespaces) : collapse(pieces.joined()), i)
            }
        }

        /// Index just past the `}` matching the `{` at `open`; nil when unbalanced up to the next entry / EOF.
        func matchBrace(from open: Int) -> Int? {
            var depth = 0
            var i = open
            while i < n {
                let c = u[i]
                if c == 92 { i += 2; continue }
                if c == 123 {
                    depth += 1
                } else if c == 125 {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                } else if isLineBreak(c) && startsEntryLine(i + 1) {
                    return nil
                }
                i += 1
            }
            return nil
        }

        /// Text of `[a, b)` without brace characters, whitespace collapsed. With `keepEdges`, leading and
        /// trailing whitespace survives as a single space (needed when pieces are concatenated with `#`).
        func clean(_ a: Int, _ b: Int, keepEdges: Bool = false) -> String {
            var out: [UInt16] = []
            out.reserveCapacity(max(0, b - a))
            var pendingSpace = keepEdges && a < b && isTeXWhitespace(u[a])
            var i = a
            while i < b {
                let c = u[i]
                if c == 92, i + 1 < b, u[i + 1] == 123 || u[i + 1] == 125 {   // \{ \} keep the brace
                    if pendingSpace { out.append(32); pendingSpace = false }
                    out.append(u[i + 1])
                    i += 2
                    continue
                }
                if c == 123 || c == 125 {
                    i += 1
                    continue
                }
                if isTeXWhitespace(c) {
                    pendingSpace = keepEdges || !out.isEmpty
                } else {
                    if pendingSpace { out.append(32); pendingSpace = false }
                    out.append(c)
                }
                i += 1
            }
            if keepEdges && pendingSpace { out.append(32) }
            return String(decoding: out, as: UTF16.self)
        }

        /// Collapses runs of whitespace and trims the ends.
        func collapse(_ text: String) -> String {
            var out: [UInt16] = []
            var pendingSpace = false
            for c in text.utf16 {
                if isTeXWhitespace(c) {
                    pendingSpace = !out.isEmpty
                } else {
                    if pendingSpace { out.append(32); pendingSpace = false }
                    out.append(c)
                }
            }
            return String(decoding: out, as: UTF16.self)
        }
    }
}

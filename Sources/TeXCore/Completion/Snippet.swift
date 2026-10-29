import Foundation

/// A parsed snippet (see `CompletionItem` for the syntax).
public struct Snippet: Hashable, Sendable {
    /// Expanded text: placeholders replaced by their default text. Everything else (including `\$`,
    /// newlines and tabs) is kept verbatim; the editor applies indentation when inserting.
    public var text: String
    /// Tab stops in visiting order ($1, $2, …), as UTF-16 ranges relative to the start of `text`.
    /// Only the first occurrence of an index is listed (later occurrences are mirrors, see `mirrors`).
    public var tabStops: [NSRange]
    /// Final cursor offset ($0), relative to the start of `text`; nil → end of text.
    public var finalCursor: Int?
    /// For each entry of `tabStops` (same order), the ranges of its mirrors: later occurrences of the same
    /// index. Mirrors are expanded with the placeholder's default text; an editor may keep them in sync
    /// while the first occurrence is being edited. Empty when the snippet has no mirrors.
    public var mirrors: [[NSRange]]

    public init(text: String, tabStops: [NSRange] = [], finalCursor: Int? = nil, mirrors: [[NSRange]] = []) {
        self.text = text
        self.tabStops = tabStops
        self.finalCursor = finalCursor
        self.mirrors = mirrors
    }

    /// Parses `${1:default}` (the default may contain balanced braces, backslashes and nested
    /// placeholders), `${1}`, `$1` and `$0`. Backslash sequences are never escapes; a `$` preceded by a
    /// backslash (`\$`) and a `$` not followed by a digit or `{` stay literal. An unterminated `${` is
    /// treated as literal text.
    public init(parsing source: String) {
        let units = Array(source.utf16)
        // Pass 1 learns the default text of each index (mirrors written as plain `$1` reuse it).
        var first = SnippetParser(units: units, defaults: [:])
        _ = first.parse()
        var second = SnippetParser(units: units, defaults: first.defaults)
        let result = second.parse()
        var stops: [NSRange] = []
        var mirrorRanges: [[NSRange]] = []
        for index in result.occurrences.keys.filter({ $0 > 0 }).sorted() {
            guard let ranges = result.occurrences[index], let head = ranges.first else { continue }
            stops.append(head)
            mirrorRanges.append(Array(ranges.dropFirst()))
        }
        self.init(
            text: String(decoding: result.output, as: UTF16.self),
            tabStops: stops,
            finalCursor: result.finalCursor,
            mirrors: mirrorRanges.contains(where: { !$0.isEmpty }) ? mirrorRanges : []
        )
    }
}

/// Recursive-descent parser behind `Snippet(parsing:)`.
private struct SnippetParser {
    let u: [UInt16]
    var defaults: [Int: [UInt16]]
    var output: [UInt16] = []
    var occurrences: [Int: [NSRange]] = [:]
    var finalCursor: Int?

    init(units: [UInt16], defaults: [Int: [UInt16]]) {
        self.u = units
        self.defaults = defaults
    }

    struct Result {
        var output: [UInt16]
        var occurrences: [Int: [NSRange]]
        var finalCursor: Int?
    }

    mutating func parse() -> Result {
        parseSequence(from: 0, to: u.count)
        return Result(output: output, occurrences: occurrences, finalCursor: finalCursor)
    }

    /// Parses `u[from..<to]`, appending to `output`. Backslashes are ordinary characters (`\newcommand`,
    /// `\textbf`); a `$` right after a backslash is LaTeX's dollar sign and is kept as is.
    mutating func parseSequence(from start: Int, to end: Int) {
        var i = start
        while i < end {
            let c = u[i]
            if c == 36 && !(i > 0 && u[i - 1] == 92) {
                if let next = placeholder(at: i, end: end) {
                    i = next
                    continue
                }
            }
            output.append(c)
            i += 1
        }
    }

    /// Tries to parse a placeholder at `i` (a `$`). Returns the index after it, or nil to treat `$` literally.
    mutating func placeholder(at i: Int, end: Int) -> Int? {
        guard i + 1 < end else { return nil }
        let d = u[i + 1]
        if isASCIIDigit(d) {
            var k = i + 1
            var index = 0
            while k < end && isASCIIDigit(u[k]) {
                index = index * 10 + Int(u[k] - 48)
                k += 1
            }
            insert(index: index, defaultText: nil)
            return k
        }
        guard d == 123 else { return nil }
        // ${N}  or  ${N:default}
        var k = i + 2
        guard k < end, isASCIIDigit(u[k]) else { return nil }
        var index = 0
        while k < end && isASCIIDigit(u[k]) {
            index = index * 10 + Int(u[k] - 48)
            k += 1
        }
        guard k < end else { return nil }
        if u[k] == 125 {
            insert(index: index, defaultText: nil)
            return k + 1
        }
        guard u[k] == 58 else { return nil }
        // Default: up to the matching close brace (escaped characters are copied verbatim).
        let bodyStart = k + 1
        var depth = 1
        var m = bodyStart
        while m < end {
            let c = u[m]
            if c == 92 { m += 2; continue }
            if c == 123 { depth += 1 }
            else if c == 125 {
                depth -= 1
                if depth == 0 { break }
            }
            m += 1
        }
        guard m < end, u[m] == 125 else { return nil }
        insert(index: index, defaultText: (bodyStart, m))
        return m + 1
    }

    /// Records an occurrence of `index`; `defaultText` is the source range of an explicit default.
    mutating func insert(index: Int, defaultText: (Int, Int)?) {
        let location = output.count
        if let (a, b) = defaultText {
            parseSequence(from: a, to: b)
            if defaults[index] == nil { defaults[index] = Array(output[location...]) }
        } else if let known = defaults[index] {
            output.append(contentsOf: known)
        }
        if index == 0 {
            if finalCursor == nil { finalCursor = location }
        } else {
            occurrences[index, default: []].append(NSRange(location: location, length: output.count - location))
        }
    }
}

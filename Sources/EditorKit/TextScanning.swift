import Foundation

/// Small, allocation-light scanning helpers over NSString (UTF-16) used by the editing behaviours.
/// All offsets are UTF-16. Pure functions — no AppKit.
nonisolated enum TextScan {
    static let backslash: unichar = 92      // \
    static let percent: unichar = 37        // %
    static let openBrace: unichar = 123     // {
    static let closeBrace: unichar = 125    // }
    static let openBracket: unichar = 91    // [
    static let closeBracket: unichar = 93   // ]
    static let openParen: unichar = 40      // (
    static let closeParen: unichar = 41     // )
    static let dollar: unichar = 36         // $
    static let space: unichar = 32
    static let tab: unichar = 9
    static let newline: unichar = 10
    static let carriageReturn: unichar = 13
    static let star: unichar = 42
    static let at: unichar = 64
    static let comma: unichar = 44

    static func isHorizontalSpace(_ c: unichar) -> Bool { c == space || c == tab }
    static func isLineBreak(_ c: unichar) -> Bool { c == newline || c == carriageReturn }
    static func isWhitespace(_ c: unichar) -> Bool { isHorizontalSpace(c) || isLineBreak(c) }
    static func isASCIILetter(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    static func isCommandLetter(_ c: unichar) -> Bool { isASCIILetter(c) || c == at }
    static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

    /// Characters that make it "sensible" to auto-insert a closing bracket before them.
    static func allowsAutoCloseBefore(_ c: unichar) -> Bool {
        isWhitespace(c) || c == closeBrace || c == closeBracket || c == closeParen || c == dollar
            || c == comma || c == 46 /* . */ || c == 59 /* ; */ || c == 58 /* : */ || c == percent
    }

    /// Word-like character for diagnostics/word extents: letters, digits, combining marks, `@`, `_`, `'`, `-`.
    static func isWordCharacter(_ c: unichar) -> Bool {
        if isASCIILetter(c) || isDigit(c) || c == at || c == 95 { return true }
        if c < 128 { return false }
        guard let scalar = Unicode.Scalar(UInt32(c)) else { return true } // surrogate halves: part of a word
        let props = scalar.properties
        return props.isAlphabetic || props.numericType != nil || props.generalCategory == .nonspacingMark
    }

    /// Number of consecutive backslashes immediately before `offset`.
    static func backslashRun(before offset: Int, in text: NSString) -> Int {
        var i = offset - 1
        var count = 0
        while i >= 0, text.character(at: i) == backslash {
            count += 1
            i -= 1
        }
        return count
    }

    /// True when the character at `offset` is escaped by an odd number of backslashes.
    static func isEscaped(_ offset: Int, in text: NSString) -> Bool {
        backslashRun(before: offset, in: text) % 2 == 1
    }

    /// Offset of the first unescaped `%` in `range`, if any.
    static func commentStart(in range: NSRange, of text: NSString) -> Int? {
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            if text.character(at: i) == percent, !isEscaped(i, in: text) { return i }
            i += 1
        }
        return nil
    }

    /// Length of the run of spaces/tabs starting at `range.location` (bounded by the range).
    static func leadingWhitespaceLength(in range: NSRange, of text: NSString) -> Int {
        var i = range.location
        let end = NSMaxRange(range)
        while i < end, isHorizontalSpace(text.character(at: i)) { i += 1 }
        return i - range.location
    }

    /// True when every character of `range` is a space or tab.
    static func isBlank(_ range: NSRange, in text: NSString) -> Bool {
        leadingWhitespaceLength(in: range, of: text) == range.length
    }

    // MARK: - Environments

    /// If `head` (the text of a line up to the caret) ends with `\begin{name}` followed only by argument
    /// groups (`[..]`, `{..}`) and spaces, returns `name`. Ignores a `\begin` inside a comment.
    static func environmentOpened(atEndOf head: NSString) -> String? {
        var end = head.length
        while end > 0, isHorizontalSpace(head.character(at: end - 1)) { end -= 1 }
        guard end > 0 else { return nil }
        // Strip trailing argument groups, innermost-last: … \begin{name}[opt]{arg}
        var guardCount = 0
        while end > 0, guardCount < 16 {
            guardCount += 1
            let last = head.character(at: end - 1)
            let open: unichar
            if last == closeBracket { open = openBracket } else if last == closeBrace { open = openBrace } else { break }
            // find the matching opener scanning backwards with nesting
            var depth = 0
            var i = end - 1
            var found = -1
            while i >= 0 {
                let c = head.character(at: i)
                if c == last, !isEscaped(i, in: head) { depth += 1 }
                else if c == open, !isEscaped(i, in: head) {
                    depth -= 1
                    if depth == 0 { found = i; break }
                }
                i -= 1
            }
            guard found >= 0 else { return nil }
            // Is this group the `{name}` right after `\begin`?
            if open == openBrace {
                let beginLength = 6 // "\begin"
                if found >= beginLength,
                   head.substring(with: NSRange(location: found - beginLength, length: beginLength)) == "\\begin",
                   !isEscaped(found - beginLength, in: head) {
                    let nameRange = NSRange(location: found + 1, length: end - 1 - (found + 1))
                    let name = head.substring(with: nameRange).trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !name.contains("{"), !name.contains("}"), !name.contains("\\") else { return nil }
                    let lineStartToBegin = NSRange(location: 0, length: found - beginLength)
                    if commentStart(in: lineStartToBegin, of: head) != nil { return nil }
                    return name
                }
            }
            end = found
            while end > 0, isHorizontalSpace(head.character(at: end - 1)) { end -= 1 }
        }
        return nil
    }

    /// Counts uncommented `\begin{name}` and `\end{name}` occurrences in the whole text.
    static func environmentBalance(_ name: String, in text: NSString) -> (begins: Int, ends: Int) {
        (count("\\begin{\(name)}", in: text), count("\\end{\(name)}", in: text))
    }

    private static func count(_ needle: String, in text: NSString) -> Int {
        var total = 0
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.length > 0 {
            let found = text.range(of: needle, options: .literal, range: searchRange)
            guard found.location != NSNotFound else { break }
            if !isEscaped(found.location, in: text), !isInComment(found.location, in: text) {
                total += 1
            }
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: text.length - next)
        }
        return total
    }

    /// True when an unescaped `%` precedes `offset` on its line.
    static func isInComment(_ offset: Int, in text: NSString) -> Bool {
        var start = offset
        while start > 0, !isLineBreak(text.character(at: start - 1)) { start -= 1 }
        return commentStart(in: NSRange(location: start, length: offset - start), of: text) != nil
    }

    // MARK: - Command arguments

    /// The command whose brace argument contains `offset` on the same line, e.g. for `\ref{eq:a|}`
    /// returns ("ref", range of "eq:a", range of the whole `{…}` content). Optional `[…]` arguments and a
    /// `*` between the command and the brace are skipped.
    static func enclosingArgument(at offset: Int, in text: NSString, lineRange: NSRange)
        -> (command: String, content: NSRange)? {
        let lineStart = lineRange.location
        let lineEnd = NSMaxRange(lineRange)
        guard offset >= lineStart, offset <= lineEnd else { return nil }
        // opening brace before offset with no unbalanced braces in between
        var i = offset - 1
        var depth = 0
        var open = -1
        while i >= lineStart {
            let c = text.character(at: i)
            if c == closeBrace, !isEscaped(i, in: text) { depth += 1 }
            else if c == openBrace, !isEscaped(i, in: text) {
                if depth == 0 { open = i; break }
                depth -= 1
            }
            i -= 1
        }
        guard open >= 0 else { return nil }
        // closing brace after offset
        var j = offset
        depth = 0
        var close = lineEnd
        while j < lineEnd {
            let c = text.character(at: j)
            if c == openBrace, !isEscaped(j, in: text) { depth += 1 }
            else if c == closeBrace, !isEscaped(j, in: text) {
                if depth == 0 { close = j; break }
                depth -= 1
            }
            j += 1
        }
        guard let command = commandName(endingBefore: open, in: text, lowerBound: lineStart) else { return nil }
        return (command, NSRange(location: open + 1, length: close - open - 1))
    }

    /// Name of the command (without backslash) that owns an argument starting at `position`
    /// (skipping `*` and `[…]` groups backwards).
    static func commandName(endingBefore position: Int, in text: NSString, lowerBound: Int) -> String? {
        var k = position - 1
        // skip optional arguments and star
        var guardCount = 0
        while k >= lowerBound, guardCount < 8 {
            guardCount += 1
            let c = text.character(at: k)
            if c == closeBracket {
                var d = 0
                var m = k
                var found = -1
                while m >= lowerBound {
                    let ch = text.character(at: m)
                    if ch == closeBracket { d += 1 } else if ch == openBracket { d -= 1; if d == 0 { found = m; break } }
                    m -= 1
                }
                guard found >= 0 else { return nil }
                k = found - 1
            } else if c == star || isHorizontalSpace(c) {
                k -= 1
            } else {
                break
            }
        }
        var nameStart = k
        while nameStart >= lowerBound, isCommandLetter(text.character(at: nameStart)) { nameStart -= 1 }
        guard nameStart >= lowerBound, nameStart < k, text.character(at: nameStart) == backslash,
              !isEscaped(nameStart, in: text) else { return nil }
        return text.substring(with: NSRange(location: nameStart + 1, length: k - nameStart))
    }

    /// The comma-separated item of `content` that contains `offset`, trimmed, with its range.
    static func listItem(at offset: Int, in content: NSRange, of text: NSString) -> (String, NSRange)? {
        var start = offset
        while start > content.location, text.character(at: start - 1) != comma { start -= 1 }
        var end = offset
        while end < NSMaxRange(content), text.character(at: end) != comma { end += 1 }
        let raw = NSRange(location: start, length: end - start)
        let item = text.substring(with: raw).trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return nil }
        return (item, raw)
    }

    // MARK: - Completion triggers

    /// If the caret directly follows `\` + at least one letter, the offset of that backslash.
    static func commandPrefixStart(before caret: Int, in text: NSString) -> Int? {
        var i = caret
        while i > 0, isCommandLetter(text.character(at: i - 1)) { i -= 1 }
        guard i < caret, i > 0, text.character(at: i - 1) == backslash, !isEscaped(i - 1, in: text) else { return nil }
        return i - 1
    }

    /// True when the caret is inside the (unclosed so far) brace argument of a command on the same line,
    /// e.g. `\ref{eq:`, `\cite{a,b`, `\begin{ite`, `\usepackage[utf8]{inp`.
    static func isInCommandArgument(caret: Int, in text: NSString, lineStart: Int) -> Bool {
        var i = caret - 1
        while i >= lineStart {
            let c = text.character(at: i)
            if c == openBrace, !isEscaped(i, in: text) {
                return commandName(endingBefore: i, in: text, lowerBound: lineStart) != nil
            }
            if c == closeBrace || c == backslash || c == percent || c == dollar { return false }
            i -= 1
        }
        return false
    }

    // MARK: - Words

    /// Extent of the token starting at `offset` for diagnostics without a length: a `\command`,
    /// a word, or a single composed character.
    static func tokenExtent(at offset: Int, in text: NSString, limit: Int) -> NSRange {
        guard offset < limit else { return NSRange(location: offset, length: 0) }
        let c = text.character(at: offset)
        if c == backslash {
            var j = offset + 1
            while j < limit, isCommandLetter(text.character(at: j)) { j += 1 }
            if j == offset + 1, j < limit { j += text.rangeOfComposedCharacterSequence(at: j).length }
            return NSRange(location: offset, length: min(j, limit) - offset)
        }
        if isWordCharacter(c) {
            var j = offset
            while j < limit, isWordCharacter(text.character(at: j)) { j += 1 }
            let r = text.rangeOfComposedCharacterSequences(for: NSRange(location: offset, length: j - offset))
            return NSRange(location: r.location, length: min(NSMaxRange(r), limit) - r.location)
        }
        let r = text.rangeOfComposedCharacterSequence(at: offset)
        return NSRange(location: r.location, length: min(NSMaxRange(r), limit) - r.location)
    }

    /// Detects the dominant line terminator: the first one found (default `\n`).
    static func lineEnding(of text: NSString) -> String {
        let length = min(text.length, 1 << 20)
        var i = 0
        while i < length {
            let c = text.character(at: i)
            if c == newline { return "\n" }
            if c == carriageReturn { return i + 1 < text.length && text.character(at: i + 1) == newline ? "\r\n" : "\r" }
            i += 1
        }
        return "\n"
    }
}

extension NSRange {
    nonisolated var end: Int { location + length }

    /// Clamps the range into `0...length`.
    nonisolated func clamped(to length: Int) -> NSRange {
        let loc = Swift.max(0, Swift.min(location, length))
        let end = Swift.max(loc, Swift.min(location + self.length, length))
        return NSRange(location: loc, length: end - loc)
    }

    nonisolated func containsOrTouches(_ offset: Int) -> Bool {
        offset >= location && offset <= location + length
    }
}

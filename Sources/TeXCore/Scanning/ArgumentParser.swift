import Foundation

/// Parsing of command arguments on a masked buffer (comments and verbatim already blanked).
enum TeXArguments {
    /// Longest argument we are willing to scan; bounds the cost of an unclosed brace.
    static let maxArgumentLength = 60_000

    /// Result of `parse`.
    struct Call {
        /// Position just after the control word (and optional star).
        var start: Int
        var isStarred = false
        /// `[...]` groups (content ranges, brackets excluded), in order of appearance.
        var optionals: [Range<Int>] = []
        /// `{...}` groups (content ranges, braces excluded), in order.
        var mandatory: [Range<Int>] = []
        /// Position just after the last parsed group.
        var end: Int
    }

    /// Skips spaces, tabs and line breaks.
    static func skipWhitespace(_ u: [UInt16], _ from: Int) -> Int {
        var i = from
        while i < u.count && isTeXWhitespace(u[i]) { i += 1 }
        return i
    }

    /// Content range of the `{...}` group opening at `open` and the index just past its `}`.
    static func braced(_ u: [UInt16], open: Int, limit: Int = maxArgumentLength) -> (content: Range<Int>, end: Int)? {
        let n = u.count
        guard open < n, u[open] == 123 else { return nil }
        var depth = 0
        var k = open
        let stop = min(n, open + limit)
        while k < stop {
            let c = u[k]
            if c == 92 {
                k += 2
                continue
            }
            if c == 123 {
                depth += 1
            } else if c == 125 {
                depth -= 1
                if depth == 0 { return ((open + 1)..<k, k + 1) }
            }
            k += 1
        }
        return nil
    }

    /// Content range of the `[...]` group opening at `open` (braces inside are skipped).
    static func bracketed(_ u: [UInt16], open: Int, limit: Int = 4_000) -> (content: Range<Int>, end: Int)? {
        let n = u.count
        guard open < n, u[open] == 91 else { return nil }
        var braces = 0
        var k = open + 1
        let stop = min(n, open + limit)
        while k < stop {
            let c = u[k]
            if c == 92 {
                k += 2
                continue
            }
            if c == 123 { braces += 1 }
            else if c == 125 { braces -= 1 }
            else if c == 93 && braces <= 0 { return ((open + 1)..<k, k + 1) }
            k += 1
        }
        return nil
    }

    /// Parses `[*] ([...])* {...}` repeated for `mandatoryCount` mandatory groups. Optional groups may
    /// precede each mandatory one. Returns nil when not even one mandatory argument is present.
    static func parse(_ u: [UInt16], from: Int, mandatoryCount: Int, allowStar: Bool = true) -> Call? {
        var i = skipWhitespace(u, from)
        var call = Call(start: from, end: from)
        if allowStar && i < u.count && u[i] == 42 {
            call.isStarred = true
            i += 1
        }
        call.start = i
        var found = 0
        while found < mandatoryCount {
            i = skipWhitespace(u, i)
            while i < u.count && u[i] == 91, let group = bracketed(u, open: i) {
                call.optionals.append(group.content)
                i = skipWhitespace(u, group.end)
            }
            guard i < u.count, u[i] == 123, let group = braced(u, open: i) else { break }
            call.mandatory.append(group.content)
            call.end = group.end
            i = group.end
            found += 1
        }
        return found == 0 ? nil : call
    }

    /// Splits `range` at top-level commas, trimming whitespace; empty items are dropped.
    static func splitList(_ u: [UInt16], _ range: Range<Int>) -> [Range<Int>] {
        var items: [Range<Int>] = []
        var depth = 0
        var itemStart = range.lowerBound
        var k = range.lowerBound
        func flush(_ end: Int) {
            var a = itemStart
            var b = end
            while a < b && isTeXWhitespace(u[a]) { a += 1 }
            while b > a && isTeXWhitespace(u[b - 1]) { b -= 1 }
            if a < b { items.append(a..<b) }
        }
        while k < range.upperBound {
            let c = u[k]
            if c == 92 { k += 2; continue }
            if c == 123 { depth += 1 } else if c == 125 { depth -= 1 } else if c == 44 && depth == 0 {
                flush(k)
                itemStart = k + 1
            }
            k += 1
        }
        flush(range.upperBound)
        return items
    }

    /// `range` without leading / trailing whitespace.
    static func trimmed(_ u: [UInt16], _ range: Range<Int>) -> Range<Int> {
        var a = range.lowerBound
        var b = range.upperBound
        while a < b && isTeXWhitespace(u[a]) { a += 1 }
        while b > a && isTeXWhitespace(u[b - 1]) { b -= 1 }
        return a..<b
    }

    /// A control sequence name at `i` (`\foo` or `\,`): returns the name including the backslash and the end.
    static func controlSequence(_ u: [UInt16], at i: Int) -> (name: String, end: Int)? {
        let n = u.count
        guard i + 1 < n, u[i] == 92 else { return nil }
        if isCommandLetter(u[i + 1]) {
            var j = i + 2
            while j < n && isCommandLetter(u[j]) { j += 1 }
            return (utf16String(u, i..<j), j)
        }
        return (utf16String(u, i..<(i + 2)), i + 2)
    }

    /// A definable command name: a backslash followed by letters only.
    static func isLetterCommandName(_ name: String) -> Bool {
        guard name.hasPrefix("\\"), name.count >= 2 else { return false }
        return name.utf16.dropFirst().allSatisfy { isASCIILetter($0) }
    }
}

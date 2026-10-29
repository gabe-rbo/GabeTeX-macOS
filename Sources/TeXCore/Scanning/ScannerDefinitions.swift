import Foundation

/// Parsers for user definitions (`\newcommand`, `\newenvironment`, ...) used by `LaTeXScanner`.
enum ScannerDefinitions {
    static let detail = String(localized: "Defined in project")

    // MARK: Commands

    /// Command name written either as `{\foo}` or `\foo` at `p`; returns the name (with backslash) and the
    /// position after it.
    static func commandName(_ u: [UInt16], at p: Int) -> (name: String, end: Int)? {
        guard p < u.count else { return nil }
        if u[p] == 123 {
            guard let group = TeXArguments.braced(u, open: p, limit: 200) else { return nil }
            let inner = TeXArguments.trimmed(u, group.content)
            guard inner.count >= 2, u[inner.lowerBound] == 92,
                  let cs = TeXArguments.controlSequence(u, at: inner.lowerBound), cs.end == inner.upperBound
            else { return nil }
            return (cs.name, group.end)
        }
        if u[p] == 92 { return TeXArguments.controlSequence(u, at: p) }
        return nil
    }

    static func item(name: String, placeholders: [(open: String, close: String)]) -> CompletionItem? {
        guard TeXArguments.isLetterCommandName(name) else { return nil }
        var text = name
        for (index, ph) in placeholders.enumerated() {
            text += "\(ph.open)${\(index + 1):arg}\(ph.close)"
        }
        return CompletionItem(kind: .command, label: name, insertText: text, detail: detail)
    }

    static func braces(_ count: Int) -> [(open: String, close: String)] {
        Array(repeating: (open: "{", close: "}"), count: max(0, count))
    }

    /// `\newcommand{\foo}[2][default]{...}` and friends.
    static func newCommand(_ u: [UInt16], from j: Int) -> CompletionItem? {
        var p = TeXArguments.skipWhitespace(u, j)
        if p < u.count && u[p] == 42 { p = TeXArguments.skipWhitespace(u, p + 1) }
        guard let (name, afterName) = commandName(u, at: p) else { return nil }
        var q = TeXArguments.skipWhitespace(u, afterName)
        var count = 0
        var hasDefault = false
        if q < u.count, u[q] == 91, let group = TeXArguments.bracketed(u, open: q, limit: 20) {
            count = Int(utf16String(u, TeXArguments.trimmed(u, group.content))) ?? 0
            q = TeXArguments.skipWhitespace(u, group.end)
            if q < u.count, u[q] == 91, TeXArguments.bracketed(u, open: q) != nil { hasDefault = true }
        }
        return item(name: name, placeholders: braces(count - (hasDefault ? 1 : 0)))
    }

    /// `\def\foo#1#2{...}`.
    static func plainDef(_ u: [UInt16], from j: Int) -> CompletionItem? {
        let p = TeXArguments.skipWhitespace(u, j)
        guard p < u.count, u[p] == 92, let cs = TeXArguments.controlSequence(u, at: p) else { return nil }
        var k = cs.end
        var highest = 0
        let stop = min(u.count, k + 80)
        while k < stop {
            let c = u[k]
            if c == 123 { return item(name: cs.name, placeholders: braces(highest)) }
            if c == 35, k + 1 < u.count, isASCIIDigit(u[k + 1]) {
                highest = max(highest, Int(u[k + 1] - 48))
                k += 2
                continue
            }
            if isLineBreak(c) && k + 1 < u.count && isLineBreak(u[k + 1]) { return nil }
            k += 1
        }
        return nil
    }

    /// `\DeclareMathOperator{\Hom}{Hom}`.
    static func mathOperator(_ u: [UInt16], from j: Int) -> CompletionItem? {
        var p = TeXArguments.skipWhitespace(u, j)
        if p < u.count && u[p] == 42 { p = TeXArguments.skipWhitespace(u, p + 1) }
        guard let (name, _) = commandName(u, at: p) else { return nil }
        return item(name: name, placeholders: [])
    }

    /// `\NewDocumentCommand{\foo}{m o m}{...}`.
    static func documentCommand(_ u: [UInt16], from j: Int) -> CompletionItem? {
        let p = TeXArguments.skipWhitespace(u, j)
        guard let (name, afterName) = commandName(u, at: p) else { return nil }
        let q = TeXArguments.skipWhitespace(u, afterName)
        guard q < u.count, u[q] == 123, let spec = TeXArguments.braced(u, open: q, limit: 400) else {
            return item(name: name, placeholders: [])
        }
        return item(name: name, placeholders: signature(u, spec.content))
    }

    /// `\DeclarePairedDelimiter{\abs}{\lvert}{\rvert}` and the `X` variants (`\DeclarePairedDelimiterX{\f}[2]{..}{..}{..}`).
    static func pairedDelimiter(_ u: [UInt16], from j: Int, hasCount: Bool) -> CompletionItem? {
        let p = TeXArguments.skipWhitespace(u, j)
        guard let (name, afterName) = commandName(u, at: p) else { return nil }
        var count = 1
        if hasCount {
            let q = TeXArguments.skipWhitespace(u, afterName)
            count = 1
            if q < u.count, u[q] == 91, let group = TeXArguments.bracketed(u, open: q, limit: 20) {
                count = Int(utf16String(u, TeXArguments.trimmed(u, group.content))) ?? 1
            }
        }
        return item(name: name, placeholders: braces(count))
    }

    /// xparse argument specification → placeholders for the mandatory arguments.
    static func signature(_ u: [UInt16], _ range: Range<Int>) -> [(open: String, close: String)] {
        var result: [(open: String, close: String)] = []
        var k = range.lowerBound
        let end = range.upperBound
        func skipBraced() {
            while k < end && isTeXWhitespace(u[k]) { k += 1 }
            if k < end, u[k] == 123, let group = TeXArguments.braced(u, open: k, limit: 400) { k = group.end }
        }
        while k < end {
            let c = u[k]
            k += 1
            switch c {
            case 109, 118: // m v
                result.append((open: "{", close: "}"))
            case 114, 82: // r R
                if k + 1 < end {
                    result.append((open: String(utf16CodeUnits: [u[k]], count: 1), close: String(utf16CodeUnits: [u[k + 1]], count: 1)))
                    k += 2
                }
                if c == 82 { skipBraced() }
            case 79: skipBraced()               // O{default}
            case 100: k += 2                    // d<>
            case 68: k += 2; skipBraced()       // D<>{default}
            case 116: k += 1                    // t<token>
            case 101, 117, 62: skipBraced()     // e{..} u{..} >{..}
            case 69: skipBraced(); skipBraced() // E{..}{..}
            default: break                      // o s + ! and whitespace
            }
        }
        return result
    }

    // MARK: Environments

    /// Names defined by an environment-defining command: first mandatory argument (after star / options).
    static func environmentNames(_ u: [UInt16], from j: Int, isList: Bool) -> [String] {
        guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1), let first = call.mandatory.first else { return [] }
        let ranges: [Range<Int>]
        if isList {
            var parts: [Range<Int>] = []
            for item in TeXArguments.splitList(u, first) {
                // thmtools allows "a b" too.
                var start = item.lowerBound
                for k in item.lowerBound...item.upperBound {
                    if k == item.upperBound || isTeXWhitespace(u[k]) {
                        if k > start { parts.append(start..<k) }
                        start = k + 1
                    }
                }
            }
            ranges = parts
        } else {
            ranges = [TeXArguments.trimmed(u, first)]
        }
        return ranges.compactMap { range in
            guard !range.isEmpty else { return nil }
            let name = utf16String(u, range)
            if name.contains("\\") || name.contains("#") || name.contains(" ") || name.contains("{") { return nil }
            return name
        }
    }
}

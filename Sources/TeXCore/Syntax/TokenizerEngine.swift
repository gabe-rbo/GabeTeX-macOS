import Foundation

/// The single-pass lexer behind `LaTeXTokenizer`. Works on a UTF-16 buffer; never touches `String`
/// indices in the hot loop (control words are the only thing converted to `String`).
struct TokenizerEngine {
    private let u: [UInt16]
    private let n: Int
    private var tokens: [LaTeXToken] = []

    // Math state: 0 none, 1 `$`, 2 `$$`, 3 `\(`, 4 `\[`, 5 math environment.
    private var mathMode: UInt8 = 0
    private var mathEnvName = ""
    private var runStart = 0
    /// Number of open `{` groups when the current `$…$` started: a `$` seen inside a deeper group
    /// (`$a \text{if $b$ then} c$`) belongs to a nested formula and must not close the outer one.
    private var mathBraceDepth = 0

    // "Argument chaining": whether a `[` / `{` right here is an argument of the previous command.
    // 0 none, 1 after a control word (spaces allowed), 2 after an argument group (no spaces).
    private var chain: UInt8 = 0
    private var braceFlags: [Bool] = []
    private var bracketDepths: [Int] = []

    private enum ArgKind { case reference, verbatim }
    private struct PendingArg { var open: Int; var close: Int; var kind: ArgKind }
    private var pendingArgs: [PendingArg] = []

    init(units: [UInt16]) {
        self.u = units
        self.n = units.count
    }

    // MARK: Driver

    mutating func run() -> [LaTeXToken] {
        tokens.reserveCapacity(n / 6 + 4)
        var i = 0
        while i < n {
            switch u[i] {
            case 92: i = backslash(i)
            case 37: i = comment(i)
            case 36: i = dollar(i)
            case 123: i = openBrace(i)
            case 125: i = closeBrace(i)
            case 91: i = openBracket(i)
            case 93: i = closeBracket(i)
            case 38, 126, 94, 95, 35:
                add(.specialCharacter, i, i + 1)
                chain = 0
                i += 1
            case 10, 13: i = newline(i)
            case 32, 9:
                if chain == 2 { chain = 0 }
                i += 1
            default:
                chain = 0
                i += 1
            }
        }
        if mathMode != 0 { flushMathRun(upTo: n) }
        return tokens
    }

    // MARK: Emission

    @inline(__always)
    private mutating func add(_ kind: LaTeXTokenKind, _ start: Int, _ end: Int) {
        if mathMode != 0 { flushMathRun(upTo: start) }
        tokens.append(LaTeXToken(kind: kind, range: NSRange(location: start, length: end - start)))
        if mathMode != 0 { runStart = end }
    }

    private mutating func flushMathRun(upTo stop: Int) {
        var a = runStart
        var b = stop
        while a < b && isTeXWhitespace(u[a]) { a += 1 }
        while b > a && isTeXWhitespace(u[b - 1]) { b -= 1 }
        if a < b {
            tokens.append(LaTeXToken(kind: .math, range: NSRange(location: a, length: b - a)))
        }
        runStart = stop
    }

    private func commandKind() -> LaTeXTokenKind { mathMode != 0 ? .mathCommand : .command }

    // MARK: Comments and line breaks

    private mutating func comment(_ i: Int) -> Int {
        var j = i + 1
        while j < n && u[j] != 10 && u[j] != 13 { j += 1 }
        add(isMagicComment(start: i, end: j) ? .magicComment : .comment, i, j)
        chain = 0
        return j
    }

    private func isMagicComment(start: Int, end: Int) -> Bool {
        var k = start - 1
        while k >= 0 && isHSpace(u[k]) { k -= 1 }
        if k >= 0 && !isLineBreak(u[k]) { return false }
        k = start + 1
        while k < end && isHSpace(u[k]) { k += 1 }
        guard k < end, u[k] == 33 else { return false }
        k += 1
        let wordStart = k
        while k < end && isASCIILetter(u[k]) { k += 1 }
        guard k - wordStart == 3 else { return false }
        let w0 = asciiLower(u[wordStart]), w1 = asciiLower(u[wordStart + 1]), w2 = asciiLower(u[wordStart + 2])
        let isTeX = w0 == 116 && w1 == 101 && w2 == 120   // tex
        let isBib = w0 == 98 && w1 == 105 && w2 == 98     // bib
        return isTeX || isBib
    }

    private mutating func newline(_ i: Int) -> Int {
        var j = i + 1
        if u[i] == 13 && j < n && u[j] == 10 { j += 1 }
        var k = j
        while k < n && isHSpace(u[k]) { k += 1 }
        if k < n && isLineBreak(u[k]) {
            // Blank line: paragraph break.
            chain = 0
            bracketDepths.removeAll(keepingCapacity: true)
            if mathMode == 1 || mathMode == 3 {
                flushMathRun(upTo: i)
                mathMode = 0
            }
        } else if chain == 2 {
            chain = 0
        }
        return j
    }

    // MARK: Math delimiters

    private mutating func dollar(_ i: Int) -> Int {
        chain = 0
        switch mathMode {
        case 0:
            if i + 1 < n && u[i + 1] == 36 {
                add(.mathDelimiter, i, i + 2)
                mathMode = 2
                runStart = i + 2
                return i + 2
            }
            add(.mathDelimiter, i, i + 1)
            mathMode = 1
            mathBraceDepth = braceFlags.count
            runStart = i + 1
            return i + 1
        case 1:
            add(.mathDelimiter, i, i + 1)
            if braceFlags.count <= mathBraceDepth { mathMode = 0 }
            return i + 1
        case 2:
            if i + 1 < n && u[i + 1] == 36 {
                add(.mathDelimiter, i, i + 2)
                mathMode = 0
                return i + 2
            }
            add(.mathDelimiter, i, i + 1)
            return i + 1
        default:
            add(.mathDelimiter, i, i + 1)   // nested inline math inside \text{...}
            return i + 1
        }
    }

    // MARK: Braces and brackets

    private mutating func openBrace(_ i: Int) -> Int {
        if !pendingArgs.isEmpty {
            while let top = pendingArgs.last, top.open < i { pendingArgs.removeLast() }
            if let top = pendingArgs.last, top.open == i {
                pendingArgs.removeLast()
                add(.brace, i, i + 1)
                if top.close > i + 1 {
                    add(top.kind == .reference ? .referenceArgument : .verbatim, i + 1, top.close)
                }
                add(.brace, top.close, top.close + 1)
                chain = 2
                return top.close + 1
            }
        }
        braceFlags.append(chain != 0)
        add(.brace, i, i + 1)
        chain = 0
        return i + 1
    }

    private mutating func closeBrace(_ i: Int) -> Int {
        let wasArgument = braceFlags.popLast() ?? false
        add(.brace, i, i + 1)
        chain = wasArgument ? 2 : 0
        return i + 1
    }

    private mutating func openBracket(_ i: Int) -> Int {
        if chain != 0 {
            add(.bracket, i, i + 1)
            bracketDepths.append(braceFlags.count)
        }
        chain = 0
        return i + 1
    }

    private mutating func closeBracket(_ i: Int) -> Int {
        while let d = bracketDepths.last, d > braceFlags.count { bracketDepths.removeLast() }
        if let d = bracketDepths.last, d == braceFlags.count {
            bracketDepths.removeLast()
            add(.bracket, i, i + 1)
            chain = 2
        } else {
            chain = 0
        }
        return i + 1
    }

    // MARK: Commands

    private mutating func backslash(_ i: Int) -> Int {
        guard i + 1 < n else {
            add(commandKind(), i, i + 1)
            chain = 0
            return i + 1
        }
        let d = u[i + 1]
        if isCommandLetter(d) {
            var j = i + 2
            while j < n && isCommandLetter(u[j]) { j += 1 }
            return controlWord(start: i, nameEnd: j)
        }
        if isLineBreak(d) {
            add(commandKind(), i, i + 1)
            chain = 0
            return i + 1
        }
        var end = i + 2
        if isHighSurrogate(d) && end < n && isLowSurrogate(u[end]) { end += 1 }
        switch d {
        case 40: // \(
            if mathMode == 0 {
                add(.mathDelimiter, i, end)
                mathMode = 3
                runStart = end
                chain = 0
                return end
            }
        case 41: // \)
            if mathMode == 3 {
                add(.mathDelimiter, i, end)
                mathMode = 0
                chain = 0
                return end
            }
        case 91: // \[
            if mathMode == 0 {
                add(.mathDelimiter, i, end)
                mathMode = 4
                runStart = end
                chain = 0
                return end
            }
        case 93: // \]
            if mathMode == 4 {
                add(.mathDelimiter, i, end)
                mathMode = 0
                chain = 0
                return end
            }
        default:
            break
        }
        add(commandKind(), i, end)
        chain = d == 92 ? 1 : 0     // `\\[2pt]` takes an optional argument
        return end
    }

    private mutating func controlWord(start i: Int, nameEnd j: Int) -> Int {
        let name = String(decoding: u[(i + 1)..<j], as: UTF16.self)
        guard let info = LaTeXSyntax.commandInfo(name) else {
            add(commandKind(), i, j)
            chain = 1
            return j
        }
        switch info.special {
        case .begin: return beginOrEnd(start: i, nameEnd: j, isBegin: true)
        case .end: return beginOrEnd(start: i, nameEnd: j, isBegin: false)
        case .verb:
            if let next = inlineVerbatim(start: i, nameEnd: j, name: name) { return next }
        case .url:
            add(commandKind(), i, j)
            chain = 1
            if let group = rawBraceGroup(from: j) {
                pendingArgs.append(PendingArg(open: group.open, close: group.close, kind: .verbatim))
            }
            return j
        case .none:
            break
        }
        var end = j
        if info.allowsStar && end < n && u[end] == 42 { end += 1 }
        add(info.isStructure ? .structureCommand : commandKind(), i, end)
        chain = 1
        if info.takesReference, let group = referenceGroup(from: end) {
            pendingArgs.append(PendingArg(open: group.open, close: group.close, kind: .reference))
        }
        return end
    }

    // MARK: \begin / \end

    private mutating func beginOrEnd(start i: Int, nameEnd j: Int, isBegin: Bool) -> Int {
        var k = j
        while k < n && isHSpace(u[k]) { k += 1 }
        guard let parsed = LaTeXSyntax.environmentName(u, open: k) else {
            add(.structureCommand, i, j)
            chain = 1
            return j
        }
        let name = utf16String(u, parsed.name)
        var commandKind: LaTeXTokenKind = .structureCommand
        var entersMath = false
        var leavesMath = false
        if isBegin {
            if mathMode == 0 && LaTeXSyntax.mathEnvironments.contains(name) {
                commandKind = .mathDelimiter
                entersMath = true
            }
        } else if mathMode == 5 && mathEnvName == name {
            commandKind = .mathDelimiter
            leavesMath = true
        }
        add(commandKind, i, j)
        add(.brace, k, k + 1)
        if !parsed.name.isEmpty { add(.environmentName, parsed.name.lowerBound, parsed.name.upperBound) }
        add(.brace, parsed.end - 1, parsed.end)
        if entersMath {
            mathMode = 5
            mathEnvName = name
            runStart = parsed.end
        } else if leavesMath {
            mathMode = 0
            mathEnvName = ""
        }
        chain = isBegin ? 2 : 0
        if isBegin && LaTeXSyntax.verbatimEnvironments.contains(name) {
            return verbatimBody(name: name, from: parsed.end)
        }
        return parsed.end
    }

    private mutating func verbatimBody(name: String, from p: Int) -> Int {
        let opening = LaTeXSyntax.verbatimOpening(u, name: name, from: p)
        if let options = opening.options {
            add(.bracket, options.lowerBound, options.lowerBound + 1)
            add(.bracket, options.upperBound - 1, options.upperBound)
        }
        if let language = opening.language {
            add(.brace, language.lowerBound, language.lowerBound + 1)
            add(.brace, language.upperBound - 1, language.upperBound)
        }
        let end = LaTeXSyntax.verbatimEnd(u, name: name, from: opening.bodyStart)
        if end > opening.bodyStart { add(.verbatim, opening.bodyStart, end) }
        chain = 0
        return end
    }

    // MARK: \verb

    private mutating func inlineVerbatim(start i: Int, nameEnd j: Int, name: String) -> Int? {
        var k = j
        if name != "lstinline" && k < n && u[k] == 42 { k += 1 }     // \verb*
        guard k < n else { return nil }
        let delimiter = u[k]
        if isTeXWhitespace(delimiter) { return nil }
        if name == "lstinline" && (delimiter == 123 || delimiter == 91) { return nil }
        var m = k + 1
        while m < n && u[m] != delimiter && !isLineBreak(u[m]) { m += 1 }
        guard m < n, u[m] == delimiter else { return nil }
        add(commandKind(), i, k)
        add(.verbatim, k, m + 1)
        chain = 0
        return m + 1
    }

    // MARK: Look-ahead for special arguments

    /// `{...}` following (optional whitespace, then) an arbitrary run of `[...]` groups, on a best-effort
    /// basis: gives up at comments, blank lines and very long groups.
    private func referenceGroup(from start: Int) -> (open: Int, close: Int)? {
        var j = start
        var groups = 0
        while groups < 4 {
            var newlines = 0
            while j < n && isTeXWhitespace(u[j]) {
                if u[j] == 10 { newlines += 1 }
                j += 1
            }
            if newlines > 1 || j >= n { return nil }
            if u[j] == 91 {
                guard let close = matching(open: j, opener: 91, closer: 93, limit: 600) else { return nil }
                j = close + 1
                groups += 1
                continue
            }
            if u[j] == 123 {
                guard let close = matching(open: j, opener: 123, closer: 125, limit: 3000) else { return nil }
                return (j, close)
            }
            return nil
        }
        return nil
    }

    /// Raw `{...}` group (URLs): braces counted, nothing else interpreted.
    private func rawBraceGroup(from start: Int) -> (open: Int, close: Int)? {
        var j = start
        while j < n && isHSpace(u[j]) { j += 1 }
        guard j < n, u[j] == 123 else { return nil }
        var depth = 0
        var k = j
        let stop = min(n, j + 2000)
        while k < stop {
            let c = u[k]
            if c == 123 { depth += 1 } else if c == 125 {
                depth -= 1
                if depth == 0 { return (j, k) }
            } else if isLineBreak(c) {
                // A URL group never contains a blank line.
                var t = k + 1
                if c == 13 && t < n && u[t] == 10 { t += 1 }
                while t < n && isHSpace(u[t]) { t += 1 }
                if t >= n || isLineBreak(u[t]) { return nil }
            }
            k += 1
        }
        return nil
    }

    /// Index of the delimiter closing the group opened at `open`; honours `\x` escapes and nested
    /// braces, gives up at an unescaped `%` or a blank line.
    private func matching(open: Int, opener: UInt16, closer: UInt16, limit: Int) -> Int? {
        var depth = 0
        var braces = 0
        var k = open
        let stop = min(n, open + limit)
        while k < stop {
            let c = u[k]
            if c == 92 { k += 2; continue }
            if c == 37 { return nil }
            if c == 123 && opener != 123 { braces += 1 }
            else if c == 125 && opener != 123 { braces -= 1 }
            else if c == opener { depth += 1 }
            else if c == closer && (opener == 123 || braces <= 0) {
                depth -= 1
                if depth == 0 { return k }
            } else if c == 10 || c == 13 {
                var t = k + 1
                if c == 13 && t < n && u[t] == 10 { t += 1 }
                while t < n && isHSpace(u[t]) { t += 1 }
                if t >= n || isLineBreak(u[t]) { return nil }
            }
            k += 1
        }
        return nil
    }
}

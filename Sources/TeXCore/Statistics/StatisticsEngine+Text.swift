import Foundation

// The text walk: letters, digits and commands. Math and environments are in `StatisticsEngine+Environments.swift`.
extension StatisticsEngine {
    // MARK: Main loop

    /// Walks `[start, end)` of the current file (the masked text: comments and verbatim are blank).
    func walk(_ start: Int, _ end: Int) {
        let u = self.u
        let limit = min(end, u.count)
        var i = start
        while i < limit {
            let c = u[i]
            if c < 128 {
                if isASCIILetter(c) {
                    if word.letter() { countWord() }
                    i += 1
                } else if isASCIIDigit(c) {
                    if word.digit() { countWord() }
                    i += 1
                } else {
                    switch c {
                    case 92: // backslash
                        let next = command(at: i)
                        i = next > i ? next : i + 1
                    case 36: // $
                        let next = dollar(at: i)
                        i = next > i ? next : i + 1
                    case 123, 125: // braces never split a word: Poincar{\'e}, \textbf{foo}bar
                        i += 1
                    case 45:
                        word.joiner(.hyphen)
                        i += 1
                    case 39:
                        word.joiner(.apostrophe)
                        i += 1
                    case 44, 46:
                        word.joiner(.numberSeparator)
                        i += 1
                    case 34:
                        i = doubleQuote(at: i)
                    default:
                        word.separator()
                        i += 1
                    }
                }
                continue
            }

            var value = UInt32(c)
            var length = 1
            if isHighSurrogate(c), i + 1 < limit, isLowSurrogate(u[i + 1]) {
                value = 0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(u[i + 1]) - 0xDC00)
                length = 2
            }
            if let scalar = Unicode.Scalar(value) {
                switch WordClassifier.classify(scalar) {
                case .letter: if word.letter() { countWord() }
                case .digit: if word.digit() { countWord() }
                case .mark: break
                case .ideograph:
                    word.separator()
                    countWord()
                    word.separator()
                case .hyphen: word.joiner(.hyphen)
                case .apostrophe: word.joiner(.apostrophe)
                case .other: word.separator()
                }
            } else {
                word.separator()
            }
            i += length
        }
    }

    /// Counts the words of a heading argument as heading words.
    func walkHeading(_ range: Range<Int>) {
        let wasHeading = inHeading
        word.separator()
        inHeading = true
        walk(range.lowerBound, range.upperBound)
        inHeading = wasHeading
        word.separator()
    }

    /// Babel shorthands keep a word together: `Sch"on` ("a "o "u "s), `Wort"=Trenner` ("- "= "|). Elsewhere a
    /// straight quote is punctuation.
    func doubleQuote(at i: Int) -> Int {
        let u = self.u
        if word.isInsideLetters, i + 1 < u.count {
            let next = u[i + 1]
            if isASCIILetter(next) { return i + 1 }
            if next == 45 || next == 61 || next == 124 {
                word.joiner(.hyphen)
                return i + 2
            }
        }
        word.separator()
        return i + 1
    }

    // MARK: Commands

    func command(at i: Int) -> Int {
        let u = self.u
        let n = u.count
        guard i + 1 < n else {
            word.separator()
            return n
        }
        let d = u[i + 1]
        guard isCommandLetter(d) else { return controlSymbol(at: i, symbol: d) }
        var j = i + 2
        while j < n && isCommandLetter(u[j]) { j += 1 }
        sweep(upTo: i)
        let name = String(decoding: u[(i + 1)..<j], as: UTF16.self)
        return controlWord(name, start: i, nameEnd: j)
    }

    func controlWord(_ name: String, start i: Int, nameEnd j: Int) -> Int {
        let u = self.u
        let n = u.count
        switch StatisticsRules.action(for: name) {
        case .unknown:
            word.separator()
            return skipAttachedOptions(from: j)

        case .separator:
            word.separator()
            return skipOverlay(from: j)

        case .heading:
            guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1), let title = call.mandatory.first else {
                word.separator()
                return j
            }
            walkHeading(title)
            noteHeadingEnd(commandStart: i, endOffset: call.end)
            return call.end

        case .frameTitle:
            word.separator()
            var p = skipOverlay(from: j)
            if p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p) { p = group.end }
            guard p < n, u[p] == 123, let group = TeXArguments.braced(u, open: p) else { return p }
            walkHeading(group.content)
            noteHeadingEnd(commandStart: i, endOffset: group.end)
            return group.end

        case .begin:
            return beginEnvironment(start: i, nameEnd: j)

        case .end:
            word.separator()
            var k = j
            while k < n && isHSpace(u[k]) { k += 1 }
            guard let parsed = LaTeXSyntax.environmentName(u, open: k) else { return j }
            if utf16String(u, parsed.name) == "document" { endDocument() }
            return parsed.end

        case .include:
            return includeCommand(start: i, nameEnd: j, arguments: (name == "import" || name == "subimport") ? 2 : 1)

        case .ignoreArguments(let count):
            word.separator()
            return skipArguments(from: j, mandatory: count)

        case .definition(let bodies):
            word.separator()
            return skipDefinition(from: j, bodies: bodies) ?? j

        case .plainDefinition:
            word.separator()
            return skipPlainDefinition(from: j) ?? j

        case .newTheorem:
            word.separator()
            return handleNewTheorem(from: j)

        case .declareTheorem:
            word.separator()
            return handleDeclareTheorem(from: j)

        case .letter:
            if word.letter() { countWord() }
            return skipSpaceNoPar(j)

        case .accent:
            let p = skipSpaceNoPar(j)
            if let end = accentBase(at: p) {
                if word.letter() { countWord() }
                return end
            }
            word.separator()
            return j

        case .texorpdfstring:
            word.separator()
            guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 2), call.mandatory.count == 2 else { return j }
            walk(call.mandatory[0].lowerBound, call.mandatory[0].upperBound)
            word.separator()
            return call.end

        case .caption(let typeArguments):
            word.separator()
            return captionText(from: j, typeArguments: typeArguments)

        case .subCaption:
            word.separator()
            return subCaptionText(from: j)

        case .cmidrule:
            word.separator()
            var p = j
            if p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 40) { p = group.end }
            if p < n, u[p] == 40 {
                var k = p + 1
                while k < n, k < p + 12, u[k] != 41 { k += 1 }
                if k < n, u[k] == 41 { p = k + 1 }
            }
            if p < n, u[p] == 123, let group = TeXArguments.braced(u, open: p, limit: 40) { p = group.end }
            return p
        }
    }

    /// `\caption*[short title]{text}` and `\captionof{figure}[short title]{text}`: the text counts, also inside a
    /// figure or a table, whose other contents do not.
    func captionText(from j: Int, typeArguments: Int) -> Int {
        let u = self.u
        let n = u.count
        var p = j
        if p < n, u[p] == 42 { p += 1 }
        for _ in 0..<typeArguments {
            let q = skipSpaceNoPar(p)
            guard q < n, u[q] == 123, let group = TeXArguments.braced(u, open: q) else { return j }
            p = group.end
        }
        var q = skipSpaceNoPar(p)
        if q < n, u[q] == 91, let option = TeXArguments.bracketed(u, open: q) { q = skipSpaceNoPar(option.end) }
        guard q < n, u[q] == 123, let group = TeXArguments.braced(u, open: q) else { return p }
        walkCaption(group.content)
        return group.end
    }

    /// `\subfloat[caption]{…}`, `\subfloat[list entry][caption]{…}`, `\subfigure[caption]{…}`: the caption is the
    /// last `[option]`; the braced content is read by the walk as it is (inside a float: not counted).
    func subCaptionText(from j: Int) -> Int {
        let u = self.u
        let n = u.count
        var end = j
        var caption: Range<Int>?
        var q = skipSpaceNoPar(j)
        var found = 0
        while found < 2, q < n, u[q] == 91, let option = TeXArguments.bracketed(u, open: q) {
            caption = option.content
            end = option.end
            q = skipSpaceNoPar(option.end)
            found += 1
        }
        if let caption { walkCaption(caption) }
        return end
    }

    /// Reads a caption's text as counted text, wherever it sits.
    func walkCaption(_ range: Range<Int>) {
        let saved = excluded
        excluded = 0
        word.separator()
        walk(range.lowerBound, range.upperBound)
        word.separator()
        excluded = saved
    }

    /// `\input{file}` & co.: walks the file here, in reading order.
    func includeCommand(start i: Int, nameEnd j: Int, arguments: Int) -> Int {
        word.separator()
        let u = self.u
        var end = skipArguments(from: j, mandatory: arguments)
        guard includeIndex < includes.count else { return end }
        let reference = includes[includeIndex]
        let location = reference.range.location
        guard location > i else { return end }
        var belongsHere = location < end
        if !belongsHere && end == j {
            // The TeX primitive form `\input file.tex`.
            var k = j
            while k < u.count && isTeXWhitespace(u[k]) { k += 1 }
            belongsHere = k == location
        }
        guard belongsHere else { return end }
        let target = includeTargets[includeIndex]
        includeIndex += 1
        end = max(end, location + reference.range.length)
        descend(into: target, counted: true)
        return end
    }

    // MARK: Control symbols

    func controlSymbol(at i: Int, symbol d: UInt16) -> Int {
        let u = self.u
        let n = u.count
        switch d {
        case 92: // \\ and its star and [length]
            word.separator()
            var p = i + 2
            if p < n, u[p] == 42 { p += 1 }
            if p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 100) { p = group.end }
            return p
        case 40: // \(
            return delimitedMath(at: i, close: 41, display: false)
        case 91: // \[
            return delimitedMath(at: i, close: 93, display: true)
        case 45, 47, 64: // \-  \/  \@ are invisible: the word goes on
            return i + 2
        case 39, 96, 94, 34, 126, 61, 46: // accents  \'  \`  \^  \"  \~  \=  \.
            if let end = accentBase(at: i + 2) {
                if word.letter() { countWord() }
                return end
            }
            word.separator()
            return i + 2
        default:
            word.separator()
            if isHighSurrogate(d), i + 2 < n, isLowSurrogate(u[i + 2]) { return i + 3 }
            return i + 2
        }
    }

    /// The letter an accent sits on: `e`, `{e}`, `\i`, `{\i}`. Returns the offset after it.
    func accentBase(at p: Int) -> Int? {
        let u = self.u
        let n = u.count
        guard p < n else { return nil }
        let c = u[p]
        if isASCIILetter(c) { return p + 1 }
        if c >= 128, !isHighSurrogate(c), !isLowSurrogate(c), let scalar = Unicode.Scalar(c),
           WordClassifier.classify(scalar) == .letter {
            return p + 1
        }
        if c == 92 { return dotlessBase(at: p) }
        if c == 123 {
            var k = p + 1
            while k < n && isHSpace(u[k]) { k += 1 }
            var after: Int?
            if k < n, isASCIILetter(u[k]) {
                after = k + 1
            } else if k < n, u[k] == 92 {
                after = dotlessBase(at: k)
            }
            guard var m = after else { return nil }
            while m < n && isHSpace(u[m]) { m += 1 }
            guard m < n, u[m] == 125 else { return nil }
            return m + 1
        }
        return nil
    }

    /// `\i` and `\j` (the dotless letters) at `p`.
    private func dotlessBase(at p: Int) -> Int? {
        let u = self.u
        let n = u.count
        guard p + 1 < n, u[p] == 92, u[p + 1] == 105 || u[p + 1] == 106 else { return nil }
        if p + 2 < n, isCommandLetter(u[p + 2]) { return nil }
        return p + 2
    }

    // MARK: Arguments

    /// Skips spaces and at most one line break (TeX's own rule: a blank line is a paragraph, not a gap).
    func skipSpaceNoPar(_ from: Int) -> Int {
        let u = self.u
        let n = u.count
        var p = from
        while p < n, isHSpace(u[p]) { p += 1 }
        guard p < n, isLineBreak(u[p]), !source.isParagraphBreak(afterLineBreakAt: p) else { return p }
        var q = p + 1
        if u[p] == 13, q < n, u[q] == 10 { q += 1 }
        while q < n, isHSpace(u[q]) { q += 1 }
        return q
    }

    /// `<1-3>` right after a command name (beamer overlay specification).
    func overlayEnd(_ open: Int) -> Int? {
        let u = self.u
        let n = u.count
        guard open < n, u[open] == 60 else { return nil }
        var k = open + 1
        let stop = min(n, open + 40)
        while k < stop {
            let c = u[k]
            if c == 62 { return k > open + 1 ? k + 1 : nil }
            // digits, letters, - + , | : @ . * and space
            let allowed = isASCIILetter(c) || isASCIIDigit(c) || c == 45 || c == 43 || c == 44 || c == 124
                || c == 58 || c == 64 || c == 46 || c == 42 || c == 32
            if !allowed { return nil }
            k += 1
        }
        return nil
    }

    func skipOverlay(from j: Int) -> Int {
        if j < u.count, u[j] == 60, let end = overlayEnd(j) { return end }
        return j
    }

    /// `[options]` and `<overlays>` glued to the command name (`\includegraphics[width=3cm]`, `\only<2>`).
    func skipAttachedOptions(from j: Int) -> Int {
        let u = self.u
        let n = u.count
        var p = j
        while p < n {
            if u[p] == 60, let end = overlayEnd(p) {
                p = end
            } else if u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 300),
                      !u[group.content].contains(where: isLineBreak) {
                p = group.end
            } else {
                break
            }
        }
        return p
    }

    /// Skips `[*]`, the options and `count` mandatory `{…}` arguments of a command whose arguments are not text.
    /// Returns the offset after what was skipped (just `j` when the arguments are missing).
    func skipArguments(from j: Int, mandatory count: Int, trailingOptions: Bool = true) -> Int {
        let u = self.u
        let n = u.count
        var p = j
        if p < n, u[p] == 42 { p += 1 }
        var done = j
        var found = 0
        while found < count {
            var q = skipSpaceNoPar(p)
            while q < n {
                if u[q] == 91, let group = TeXArguments.bracketed(u, open: q) {
                    q = skipSpaceNoPar(group.end)
                } else if u[q] == 60, let end = overlayEnd(q) {
                    q = skipSpaceNoPar(end)
                } else {
                    break
                }
            }
            guard q < n, u[q] == 123, let group = TeXArguments.braced(u, open: q) else { break }
            p = group.end
            done = group.end
            found += 1
        }
        if found == count, trailingOptions { done = skipAttachedOptions(from: done) }
        return done
    }

    // MARK: Definitions

    /// `\newcommand{\foo}[2][x]{body}` & co. Returns the offset after the last body, or nil when malformed.
    func skipDefinition(from j: Int, bodies: Int) -> Int? {
        let u = self.u
        let n = u.count
        var p = TeXArguments.skipWhitespace(u, j)
        if p < n, u[p] == 42 { p = TeXArguments.skipWhitespace(u, p + 1) }
        if p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 200) {
            p = TeXArguments.skipWhitespace(u, group.end)            // \newmdtheoremenv[options]{name}
        }
        if p < n, u[p] == 123 {
            guard let group = TeXArguments.braced(u, open: p, limit: 300) else { return nil }
            p = group.end
        } else if p < n, u[p] == 92, let cs = TeXArguments.controlSequence(u, at: p) {
            p = cs.end
        } else {
            return nil
        }
        p = TeXArguments.skipWhitespace(u, p)
        var optionals = 0
        while optionals < 3, p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 400) {
            p = TeXArguments.skipWhitespace(u, group.end)
            optionals += 1
        }
        var end = p
        var remaining = bodies
        var lastEnd: Int?
        while remaining > 0 {
            guard end < n, u[end] == 123, let body = TeXArguments.braced(u, open: end) else { break }
            lastEnd = body.end
            end = TeXArguments.skipWhitespace(u, body.end)
            remaining -= 1
        }
        return lastEnd
    }

    /// `\def\foo#1#2{body}`.
    func skipPlainDefinition(from j: Int) -> Int? {
        let u = self.u
        let n = u.count
        let p = TeXArguments.skipWhitespace(u, j)
        guard p < n, u[p] == 92, let cs = TeXArguments.controlSequence(u, at: p) else { return nil }
        var k = cs.end
        let stop = min(n, k + 120)
        while k < stop, u[k] != 123 {
            if isLineBreak(u[k]), source.isParagraphBreak(afterLineBreakAt: k) { return nil }
            k += 1
        }
        guard k < stop, let body = TeXArguments.braced(u, open: k) else { return nil }
        return body.end
    }

    /// `\newtheorem{name}[counter]{Title}[within]`: `name` becomes an environment with a titled `[option]`.
    func handleNewTheorem(from j: Int) -> Int {
        let u = self.u
        let n = u.count
        var p = TeXArguments.skipWhitespace(u, j)
        if p < n, u[p] == 42 { p = TeXArguments.skipWhitespace(u, p + 1) }
        guard p < n, u[p] == 123, let name = TeXArguments.braced(u, open: p, limit: 200) else { return j }
        let trimmed = TeXArguments.trimmed(u, name.content)
        if !trimmed.isEmpty { titledEnvironments.insert(utf16String(u, trimmed)) }
        var end = name.end
        p = TeXArguments.skipWhitespace(u, end)
        if p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 200) {
            end = group.end
            p = TeXArguments.skipWhitespace(u, end)
        }
        if p < n, u[p] == 123, let title = TeXArguments.braced(u, open: p, limit: 400) {
            end = title.end
            p = TeXArguments.skipWhitespace(u, end)
            if p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 200) { end = group.end }
        }
        return end
    }

    /// `\declaretheorem[options]{name, name}` (thmtools).
    func handleDeclareTheorem(from j: Int) -> Int {
        let u = self.u
        let n = u.count
        var p = TeXArguments.skipWhitespace(u, j)
        if p < n, u[p] == 42 { p = TeXArguments.skipWhitespace(u, p + 1) }
        if p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 600) {
            p = TeXArguments.skipWhitespace(u, group.end)
        }
        guard p < n, u[p] == 123, let names = TeXArguments.braced(u, open: p, limit: 300) else { return j }
        for item in TeXArguments.splitList(u, names.content) {
            for part in utf16String(u, item).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                titledEnvironments.insert(String(part))
            }
        }
        return names.end
    }
}

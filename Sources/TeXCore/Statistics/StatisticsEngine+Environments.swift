import Foundation

// Environments and formulas.
extension StatisticsEngine {
    // MARK: \begin

    /// `\begin{name}` at `i`; returns where the walk continues (the environment's body is read as text unless
    /// it is a formula, a picture or a bibliography).
    func beginEnvironment(start i: Int, nameEnd j: Int) -> Int {
        word.separator()
        let u = self.u
        let n = u.count
        var k = j
        while k < n && isHSpace(u[k]) { k += 1 }
        guard let parsed = LaTeXSyntax.environmentName(u, open: k) else { return j }
        let name = utf16String(u, parsed.name)
        let afterName = parsed.end

        if name == "document" {
            beginDocument()
            return afterName
        }

        if LaTeXSyntax.mathEnvironments.contains(name) {
            // A blank line cannot occur inside a formula (TeX would stop with an error): an `\end` that only
            // follows after one means the environment is still being typed, and its body counts as text.
            if let range = findEnvironmentEnd(name, from: afterName, nested: false, stopAtParagraph: true) {
                countMath(display: name != "math")
                return range.upperBound
            }
            return afterName
        }

        if StatisticsRules.skippedEnvironments.contains(name) {
            if let range = findEnvironmentEnd(name, from: afterName, nested: true, stopAtParagraph: false) {
                return range.upperBound
            }
            return afterName
        }

        if name == "frame" { return beginFrame(start: i, afterName: afterName) }

        if StatisticsRules.floatEnvironments.contains(name),
           let range = findEnvironmentEnd(name, from: afterName, nested: true, stopAtParagraph: false) {
            // Only the captions inside count. A float that is never closed (still being typed) is read as text.
            let bodyStart = min(range.lowerBound, argumentsEnd(of: name, afterName: afterName))
            excluded += 1
            walk(bodyStart, range.lowerBound)
            excluded -= 1
            word.separator()
            return range.upperBound
        }

        return argumentsEnd(of: name, afterName: afterName)
    }

    /// Where the body of an ordinary environment starts: its `[options]` and specification arguments are not text.
    private func argumentsEnd(of name: String, afterName: Int) -> Int {
        var p = skipOverlay(from: afterName)
        let titled = titledEnvironments.contains(name)
            || (name.hasSuffix("*") && titledEnvironments.contains(String(name.dropLast())))
        if !titled { p = skipAttachedOptions(from: p) }
        let specification = StatisticsRules.environmentArguments[name] ?? 0
        if specification > 0 {
            p = skipArguments(from: p, mandatory: specification,
                              trailingOptions: !StatisticsRules.environmentsWithTitleOption.contains(name))
        }
        return p
    }

    /// `\begin{frame}<overlay>[options]{Title}{Subtitle}`: titles are heading words.
    private func beginFrame(start i: Int, afterName: Int) -> Int {
        let u = self.u
        let n = u.count
        var p = skipOverlay(from: afterName)
        if p < n, u[p] == 91, let group = TeXArguments.bracketed(u, open: p) { p = group.end }
        var titles = 0
        while titles < 2 {
            let q = skipSpaceNoPar(p)
            guard q < n, u[q] == 123, let group = TeXArguments.braced(u, open: q) else { break }
            walkHeading(group.content)
            noteHeadingEnd(commandStart: i, endOffset: group.end)
            p = group.end
            titles += 1
        }
        return p
    }

    // MARK: Formulas

    /// `$…$` and `$$…$$` at `i`.
    func dollar(at i: Int) -> Int {
        word.separator()
        let u = self.u
        let display = i + 1 < u.count && u[i + 1] == 36
        let bodyStart = i + (display ? 2 : 1)
        if let end = findDollarClose(from: bodyStart, display: display) {
            countMath(display: display)
            return end
        }
        return bodyStart        // never closed (still being typed): not a formula, the text goes on
    }

    /// `\(…\)` (`close` = `)`) and `\[…\]` (`close` = `]`) at `i`.
    func delimitedMath(at i: Int, close: UInt16, display: Bool) -> Int {
        word.separator()
        let u = self.u
        let n = u.count
        var k = i + 2
        while k < n {
            let c = u[k]
            if c == 92 {
                if k + 1 < n, u[k + 1] == close {
                    countMath(display: display)
                    return k + 2
                }
                k += 2
                continue
            }
            if isLineBreak(c), source.isParagraphBreak(afterLineBreakAt: k) { break }
            k += 1
        }
        return i + 2
    }

    /// Offset after the `$` / `$$` that closes a formula opened before `from`. A `$` inside braces belongs to
    /// a nested text group (`$x \text{if $y$}$`); a blank line ends the search.
    private func findDollarClose(from: Int, display: Bool) -> Int? {
        let u = self.u
        let n = u.count
        var depth = 0
        var k = from
        while k < n {
            let c = u[k]
            if c == 92 {
                k += 2
                continue
            }
            if c == 123 {
                depth += 1
            } else if c == 125 {
                if depth > 0 { depth -= 1 }
            } else if c == 36, depth == 0 {
                if !display { return k + 1 }
                if k + 1 < n, u[k + 1] == 36 { return k + 2 }
            } else if isLineBreak(c), source.isParagraphBreak(afterLineBreakAt: k) {
                return nil
            }
            k += 1
        }
        return nil
    }

    // MARK: Matching \end

    /// The range of the `\end{name}` that closes an environment whose body starts at `from`.
    func findEnvironmentEnd(_ name: String, from: Int, nested: Bool, stopAtParagraph: Bool) -> Range<Int>? {
        let u = self.u
        let n = u.count
        var depth = 1
        var k = from
        while k < n {
            let c = u[k]
            if c == 92 {
                guard k + 1 < n else { return nil }
                guard isCommandLetter(u[k + 1]) else {
                    k += 2
                    continue
                }
                var e = k + 2
                while e < n && isCommandLetter(u[e]) { e += 1 }
                let length = e - k - 1
                let isEnd = length == 3 && u[k + 1] == 101 && u[k + 2] == 110 && u[k + 3] == 100                       // end
                let isBegin = length == 5 && u[k + 1] == 98 && u[k + 2] == 101 && u[k + 3] == 103
                    && u[k + 4] == 105 && u[k + 5] == 110                                                             // begin
                if isEnd || (nested && isBegin) {
                    var q = e
                    while q < n && isHSpace(u[q]) { q += 1 }
                    if let parsed = LaTeXSyntax.environmentName(u, open: q), utf16String(u, parsed.name) == name {
                        if isEnd {
                            depth -= 1
                            if depth == 0 { return k..<parsed.end }
                        } else {
                            depth += 1
                        }
                        k = parsed.end
                        continue
                    }
                }
                k = e
                continue
            }
            if stopAtParagraph, isLineBreak(c), source.isParagraphBreak(afterLineBreakAt: k) { return nil }
            k += 1
        }
        return nil
    }
}

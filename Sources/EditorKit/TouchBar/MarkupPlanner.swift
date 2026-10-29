import Foundation
import TeXCore

/// Is a caret position in math mode? Asks the LaTeX tokenizer directly instead of the highlighter's tokens,
/// which can lag behind the text for a moment on large documents.
///
/// Probe technique: a digit is appended to the text **before** the caret and tokenized; the caret is in math
/// mode exactly when the tokenizer classifies that digit as math (`$x|` → `$x0` → math; `$x$|` → `$x$0` →
/// prose). Only the prefix matters because the tokenizer is a single forward pass. O(n) per call — used for
/// taps, never per keystroke.
nonisolated enum MathModeProbe {
    /// Longer prefixes are answered from existing tokens instead (`isMath(at:tokens:)`).
    static let prefixLimit = 1_500_000

    static func isMath(at offset: Int, in text: NSString) -> Bool {
        let n = max(0, min(offset, text.length))
        var units = [unichar](repeating: 0, count: n + 1)
        if n > 0 { text.getCharacters(&units, range: NSRange(location: 0, length: n)) }
        units[n] = 0x30 // "0": never extends a control word, plain prose outside math
        let probe = units.withUnsafeBufferPointer { buffer -> NSString in
            guard let base = buffer.baseAddress else { return "" }
            return NSString(characters: base, length: n + 1)
        }
        let tokens = LaTeXTokenizer().tokenize(probe)
        guard let last = tokens.last, last.range.location <= n, n < last.range.location + last.range.length else {
            return false
        }
        return last.kind == .math || last.kind == .mathCommand
    }

    /// The same question answered from existing tokens (the rule of the highlighter).
    static func isMath(at offset: Int, tokens: [LaTeXToken]) -> Bool {
        func kind(containing position: Int) -> LaTeXTokenKind? {
            guard position >= 0 else { return nil }
            var lo = 0, hi = tokens.count
            while lo < hi {
                let mid = (lo + hi) / 2
                let r = tokens[mid].range
                if r.location + r.length <= position { lo = mid + 1 } else { hi = mid }
            }
            guard lo < tokens.count, tokens[lo].range.location <= position else { return nil }
            return tokens[lo].kind
        }
        let before = kind(containing: offset - 1)
        let after = kind(containing: offset)
        let mathKinds: Set<LaTeXTokenKind> = [.math, .mathCommand]
        if let before, mathKinds.contains(before) { return true }
        if let after, mathKinds.contains(after) { return true }
        return before == .mathDelimiter && after == .mathDelimiter
    }
}

/// Decides how a `LaTeXMarkupAction` changes the text around the selection. Pure (no AppKit), so the rules
/// can be reasoned about — and checked — independently of the text view.
nonisolated struct MarkupPlanner {
    nonisolated enum Plan: Equatable {
        /// Insert `snippet` (snippet syntax: `$1`, `$0`, `\n` re-indented, `\t` = one indent level) in place of
        /// `range` through the snippet engine (tab stops).
        case snippet(range: NSRange, snippet: String)
        /// Replace `range` with `text`, then select `selection` (post-edit offsets). `normalCaret` is where a
        /// Vim normal-mode cursor goes; `expectsTyping` means the user fills something in next.
        case replace(range: NSRange, text: String, selection: NSRange, normalCaret: Int, expectsTyping: Bool)
        case toggleComment
        /// Makes no sense here (e.g. inline math inside math).
        case refuse
    }

    let text: NSString
    let selection: NSRange
    let indentUnit: String
    let lineEnding: String
    /// Whether the caret (`selection.location`) is in math mode.
    let mathAtLocation: Bool
    /// Whether `selection.location - 1` is in math mode (only needed right after a `$`).
    let mathBeforeLocation: Bool

    private func isMath(_ offset: Int) -> Bool {
        offset == location ? mathAtLocation : (offset == location - 1 ? mathBeforeLocation : false)
    }

    private var location: Int { selection.location }
    private var selected: String { selection.length > 0 ? text.substring(with: selection) : "" }

    func plan(_ action: LaTeXMarkupAction) -> Plan {
        switch action {
        case .toggleComment:
            return .toggleComment

        case .inlineMath:
            if isMath(location) { return .refuse }
            let gap = dollarSeparators()
            if selection.length == 0 {
                let caret = location + gap.before.utf16.count + 1
                return .replace(range: selection, text: gap.before + "$$" + gap.after,
                                selection: NSRange(location: caret, length: 0), normalCaret: caret, expectsTyping: true)
            }
            return wrapInline(prefix: gap.before + "$", suffix: "$" + gap.after)

        case .displayMath(let kind):
            if isMath(location) { return .refuse }
            let parts = Self.displayMathParts(kind)
            if selection.length == 0 { return blockSnippet(parts.snippet) }
            return blockWrap(open: parts.open, close: parts.close, itemize: false)

        case .fraction:
            switch mathPlacement() {
            case .inMath:
                if selection.length == 0 { return .snippet(range: selection, snippet: "\\frac{$1}{$2}$0") }
                return insertTyping(before: "\\frac{" + selected + "}{", after: "}")
            case .merged(let offset):
                return .snippet(range: NSRange(location: offset, length: 0), snippet: "\\frac{$1}{$2}$0")
            case .text:
                let gap = dollarSeparators()
                if selection.length == 0 {
                    return .snippet(range: selection, snippet: gap.before + "$\\frac{$1}{$2}$$0" + gap.after)
                }
                return insertTyping(before: gap.before + "$\\frac{" + selected + "}{", after: "}$" + gap.after)
            }

        case .superscript:
            return script(math: "^", text: "textsuperscript")

        case .subscript:
            return script(math: "_", text: "textsubscript")

        case .mathCommand(let command):
            guard !command.isEmpty else { return .refuse }
            switch mathPlacement() {
            case .inMath:
                return insertAtom(command + separator(after: command, at: selection.location + selection.length),
                                  range: selection)
            case .merged(let offset):
                // `$x$|` → `$x\alpha$|`: the caret stays after the closing dollar.
                let length = command.utf16.count
                return .replace(range: NSRange(location: offset, length: 0), text: command,
                                selection: NSRange(location: offset + length + 1, length: 0),
                                normalCaret: offset + length - 1, expectsTyping: false)
            case .text:
                let gap = dollarSeparators()
                return insertAtom(gap.before + "$" + command + "$" + gap.after, range: selection)
            }

        case .environment(let name):
            guard !name.isEmpty else { return .refuse }
            if selection.length == 0 { return blockSnippet("\\begin{" + Self.environmentInsertText(name)) }
            let args = Self.plainArguments(of: name)
            return blockWrap(open: "\\begin{\(name)}" + args, close: "\\end{\(name)}",
                             itemize: name == "itemize" || name == "enumerate")

        case .section(let name):
            guard !name.isEmpty else { return .refuse }
            if selection.length == 0 { return blockSnippet("\\\(name){$1}$0") }
            return blockInline(prefix: "\\\(name){", suffix: "}")

        case .textStyle(let style):
            let command = isMath(location) ? style.mathCommand : style.textCommand
            if selection.length == 0 { return .snippet(range: selection, snippet: "\\\(command){$1}$0") }
            return wrapInline(prefix: "\\\(command){", suffix: "}")
        }
    }

    // MARK: - Math placement

    private nonisolated enum MathPlacement {
        case inMath
        /// Text mode right after an inline formula's closing `$`: insert before that dollar.
        case merged(Int)
        case text
    }

    private func mathPlacement() -> MathPlacement {
        if isMath(location) { return .inMath }
        if let offset = mergeOffset() { return .merged(offset) }
        return .text
    }

    /// `$x$|` (no selection): the offset of that closing dollar. `$$` and `\$` never merge, so two formulas
    /// never become `$…$$…$` (which TeX would read as display math).
    private func mergeOffset() -> Int? {
        guard selection.length == 0, location >= 1, text.character(at: location - 1) == Self.dollar else { return nil }
        if location >= 2, text.character(at: location - 2) == Self.dollar { return nil }
        if isEscaped(location - 1) { return nil }
        return isMath(location - 1) ? location - 1 : nil
    }

    private func script(math op: String, text command: String) -> Plan {
        switch mathPlacement() {
        case .inMath:
            if selection.length == 0 { return .snippet(range: selection, snippet: op + "{$1}$0") }
            return wrapInline(prefix: op + "{", suffix: "}")
        case .merged(let offset):
            return .snippet(range: NSRange(location: offset, length: 0), snippet: op + "{$1}$0")
        case .text:
            if selection.length == 0 { return .snippet(range: selection, snippet: "\\\(command){$1}$0") }
            return wrapInline(prefix: "\\\(command){", suffix: "}")
        }
    }

    /// Spaces that keep a new `$…$` from touching a neighbouring dollar (`$x$$y$` would read as display math).
    private func dollarSeparators() -> (before: String, after: String) {
        let end = selection.location + selection.length
        let before = location > 0 && text.character(at: location - 1) == Self.dollar && !isEscaped(location - 1) ? " " : ""
        let after = end < text.length && text.character(at: end) == Self.dollar ? " " : ""
        return (before, after)
    }

    /// A space when a control word would otherwise run into a following letter (`\alpha` + `x`).
    private func separator(after inserted: String, at offset: Int) -> String {
        guard let last = inserted.utf16.last, Self.isASCIILetter(last), offset < text.length,
              Self.isASCIILetter(text.character(at: offset)) else { return "" }
        return " "
    }

    // MARK: - Shapes

    /// Replaces the selection with `inserted`; the caret goes after it (Vim: on its last character).
    private func insertAtom(_ inserted: String, range: NSRange) -> Plan {
        let end = range.location + inserted.utf16.count
        let lastStart = (inserted as NSString).rangeOfComposedCharacterSequence(at: max(0, inserted.utf16.count - 1)).location
        return .replace(range: range, text: inserted, selection: NSRange(location: end, length: 0),
                        normalCaret: range.location + lastStart, expectsTyping: false)
    }

    /// Wraps the selection; the wrapped text stays selected (another style can be applied right away).
    private func wrapInline(prefix: String, suffix: String) -> Plan {
        let body = selected
        let start = location + prefix.utf16.count
        return .replace(range: selection, text: prefix + body + suffix,
                        selection: NSRange(location: start, length: body.utf16.count),
                        normalCaret: location, expectsTyping: false)
    }

    /// Replaces the selection with `before + after`; the caret goes between them.
    private func insertTyping(before: String, after: String) -> Plan {
        let caret = location + before.utf16.count
        return .replace(range: selection, text: before + after, selection: NSRange(location: caret, length: 0),
                        normalCaret: caret, expectsTyping: true)
    }

    /// A snippet that must stand on its own line(s): a line break is added before it when text precedes the
    /// caret on its line, and after it when text follows (spaces at the junction are absorbed).
    private func blockSnippet(_ body: String) -> Plan {
        let lineStart = lineStartOffset(location)
        let lineEnd = lineContentEnd(location)
        var start = location
        while start > lineStart, isHorizontalSpace(text.character(at: start - 1)) { start -= 1 }
        var end = location
        while end < lineEnd, isHorizontalSpace(text.character(at: end)) { end += 1 }
        var snippet = body
        var rangeStart = location
        var rangeEnd = location
        if start > lineStart {
            snippet = "\n" + snippet
            rangeStart = start
        }
        if end < lineEnd {
            snippet += "\n"
            rangeEnd = end
        }
        return .snippet(range: NSRange(location: rangeStart, length: rangeEnd - rangeStart), snippet: snippet)
    }

    /// Wraps the selection inline (`\section{…}`) and puts the result on its own line.
    private func blockInline(prefix: String, suffix: String) -> Plan {
        let lineStart = lineStartOffset(location)
        let endLine = lineContentEnd(selection.location + selection.length)
        var start = location
        while start > lineStart, isHorizontalSpace(text.character(at: start - 1)) { start -= 1 }
        var end = selection.location + selection.length
        while end < endLine, isHorizontalSpace(text.character(at: end)) { end += 1 }
        let indent = leadingWhitespace(ofLineStartingAt: lineStart)
        let before = start > lineStart ? lineEnding + indent : ""
        let after = end < endLine ? lineEnding + indent : ""
        let body = selected
        let replacement = before + prefix + body + suffix + after
        let commandStart = start + before.utf16.count
        let bodyStart = commandStart + prefix.utf16.count
        return .replace(range: NSRange(location: start, length: end - start), text: replacement,
                        selection: NSRange(location: bodyStart, length: body.utf16.count),
                        normalCaret: commandStart, expectsTyping: false)
    }

    /// Wraps the selected lines in a block (`\begin{x}` … `\end{x}`, `\[` … `\]`): the block starts and ends on
    /// lines of its own at the indentation of the first selected line, and the body is indented one level.
    /// A selection that ends with a line break keeps it after the block. List environments get `\item`s.
    private func blockWrap(open: String, close: String, itemize: Bool) -> Plan {
        let newline = lineEnding
        let firstLineStart = lineStartOffset(location)
        let baseIndent = leadingWhitespace(ofLineStartingAt: firstLineStart)
        let leadRange = NSRange(location: firstLineStart, length: location - firstLineStart)
        let leadIsBlank = isBlank(leadRange)
        var start = location
        if leadIsBlank {
            start = firstLineStart
        } else {
            while start > firstLineStart, isHorizontalSpace(text.character(at: start - 1)) { start -= 1 }
        }
        let selectionEnd = selection.location + selection.length
        var bodyEnd = selectionEnd
        var terminator = ""
        if bodyEnd > start, isLineBreak(text.character(at: bodyEnd - 1)) {
            if bodyEnd - 1 > start, text.character(at: bodyEnd - 1) == Self.lineFeed,
               text.character(at: bodyEnd - 2) == Self.carriageReturn {
                terminator = "\r\n"
                bodyEnd -= 2
            } else {
                terminator = text.substring(with: NSRange(location: bodyEnd - 1, length: 1))
                bodyEnd -= 1
            }
        }
        var end = selectionEnd
        var suffix = ""
        if terminator.isEmpty {
            let lineEnd = lineContentEnd(selectionEnd)
            while end < lineEnd, isHorizontalSpace(text.character(at: end)) { end += 1 }
            if end < lineEnd { suffix = newline + baseIndent }
        }

        var lines = Self.splitLines(text.substring(with: NSRange(location: start, length: bodyEnd - start)))
        if !leadIsBlank, !lines.isEmpty {
            lines[0] = baseIndent + lines[0].drop { $0 == " " || $0 == "\t" }
        }
        var bodyLines = lines.map { line -> String in
            guard !line.allSatisfy({ $0 == " " || $0 == "\t" }) else { return "" }
            guard itemize else { return indentUnit + line }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let content = line.dropFirst(indent.count)
            return content.hasPrefix("\\item") ? indentUnit + line : indentUnit + indent + "\\item " + content
        }
        let isEmptyBody = bodyLines.allSatisfy(\.isEmpty)
        if isEmptyBody { bodyLines = [baseIndent + indentUnit + (itemize ? "\\item " : "")] }

        let prefix = leadIsBlank ? "" : newline
        let head = prefix + baseIndent + open + newline
        let bodyText = bodyLines.joined(separator: newline)
        let replacement = head + bodyText + newline + baseIndent + close + terminator + suffix
        let bodyStart = start + head.utf16.count
        let bodyLength = bodyText.utf16.count
        let newSelection: NSRange
        if isEmptyBody {
            newSelection = NSRange(location: bodyStart + bodyLength, length: 0)
        } else {
            let leading = bodyText.utf16.prefix { $0 == Self.space || $0 == Self.tab }.count
            newSelection = NSRange(location: bodyStart + leading, length: bodyLength - leading)
        }
        return .replace(range: NSRange(location: start, length: end - start), text: replacement,
                        selection: newSelection,
                        normalCaret: isEmptyBody ? newSelection.location : start + prefix.utf16.count + baseIndent.utf16.count,
                        expectsTyping: isEmptyBody)
    }

    // MARK: - Catalog

    static func displayMathParts(_ kind: LaTeXMarkupAction.DisplayMath) -> (open: String, close: String, snippet: String) {
        switch kind {
        case .brackets:
            return ("\\[", "\\]", "\\[\n\t$0\n\\]")
        case .equation, .equationStar, .align, .alignStar:
            let name = kind.rawValue
            return ("\\begin{\(name)}", "\\end{\(name)}", "\\begin{" + environmentInsertText(name))
        }
    }

    /// What follows `\begin{` for an environment: the completion catalog's snippet (arguments, body
    /// placeholders) or a plain body.
    static func environmentInsertText(_ name: String) -> String {
        if let item = CompletionCatalog.environments.first(where: { $0.label == name }) {
            return item.insertText
        }
        return "\(name)}\n\t$0\n\\end{\(name)}"
    }

    /// The catalog's arguments of an environment with placeholders replaced by their defaults (`[htbp]`).
    static func plainArguments(of name: String) -> String {
        let insert = environmentInsertText(name)
        let head = name + "}"
        guard insert.hasPrefix(head) else { return "" }
        let rest = insert.dropFirst(head.count)
        let arguments = rest.prefix { $0 != "\n" }
        guard !arguments.isEmpty else { return "" }
        return Snippet(parsing: String(arguments)).text
    }

    // MARK: - Text helpers (UTF-16)

    private static let dollar: unichar = 36
    private static let backslash: unichar = 92
    private static let space: unichar = 32
    private static let tab: unichar = 9
    private static let lineFeed: unichar = 10
    private static let carriageReturn: unichar = 13

    static func isASCIILetter(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private func isHorizontalSpace(_ c: unichar) -> Bool { c == Self.space || c == Self.tab }
    private func isLineBreak(_ c: unichar) -> Bool { c == Self.lineFeed || c == Self.carriageReturn }

    private func isEscaped(_ offset: Int) -> Bool {
        var count = 0
        var i = offset - 1
        while i >= 0, text.character(at: i) == Self.backslash {
            count += 1
            i -= 1
        }
        return count % 2 == 1
    }

    private func lineStartOffset(_ offset: Int) -> Int {
        var i = min(offset, text.length)
        while i > 0, !isLineBreak(text.character(at: i - 1)) { i -= 1 }
        return i
    }

    private func lineContentEnd(_ offset: Int) -> Int {
        var i = min(offset, text.length)
        while i < text.length, !isLineBreak(text.character(at: i)) { i += 1 }
        return i
    }

    private func leadingWhitespace(ofLineStartingAt lineStart: Int) -> String {
        var i = lineStart
        while i < text.length, isHorizontalSpace(text.character(at: i)) { i += 1 }
        return text.substring(with: NSRange(location: lineStart, length: i - lineStart))
    }

    private func isBlank(_ range: NSRange) -> Bool {
        var i = range.location
        while i < range.location + range.length {
            if !isHorizontalSpace(text.character(at: i)) { return false }
            i += 1
        }
        return true
    }

    /// Splits on `\r\n`, `\n` and `\r` (terminators dropped).
    static func splitLines(_ string: String) -> [String] {
        var lines: [String] = []
        var current: [unichar] = []
        let units = Array(string.utf16)
        var i = 0
        while i < units.count {
            let c = units[i]
            if c == lineFeed || c == carriageReturn {
                lines.append(String(decoding: current, as: UTF16.self))
                current = []
                if c == carriageReturn, i + 1 < units.count, units[i + 1] == lineFeed { i += 1 }
            } else {
                current.append(c)
            }
            i += 1
        }
        lines.append(String(decoding: current, as: UTF16.self))
        return lines
    }
}

import Foundation

/// The "word at an offset" lookup behind `EditorController.word(at:)` and "Show in PDF".
/// Pure UTF-16 scanning over `NSString` — no AppKit.
///
/// Rules (documented contract):
/// - A *word* is a maximal run of letters, digits and combining marks. Apostrophes, hyphens, `_`, `@`
///   outside command names and every other symbol end a word. Scanning is by composed character
///   sequences, so decomposed accents (`c` + U+0327), surrogate pairs and emoji sequences never get cut;
///   an emoji (even with variation selectors / ZWJ) is not a word character.
/// - A control word (`\section`, `\textbf`, `\@ifnextchar`) is a word whose text is the command name
///   **without** the backslash (letters and `@`, as TeX reads it under `\makeatletter`); the returned range
///   excludes the backslash. A control word ends where its letters end, so `\alpha1` has the words
///   `alpha` and `1`. A backslash escaped by another one (`\\alpha`) is a line break, not a command start.
/// - Position rule: the word *at* the offset wins (the character right after the offset belongs to it —
///   for `\command` the backslash counts as part of the command); otherwise the word that ends exactly at
///   the offset; otherwise nil. So `foo|`, `foo|.` and `foo| bar` give `foo`, `foo |bar` gives `bar`, and
///   an offset between two separators gives nil. Offsets are clamped to the text; an offset inside a
///   composed character is moved to its start.
nonisolated extension TextScan {
    /// Longest stretch (UTF-16 units) scanned on each side of the offset, so a pathological one-line file
    /// cannot make a lookup linear in the file size.
    private static let maxWordUnits = 512

    static func word(at offset: Int, in text: NSString) -> (word: String, range: NSRange)? {
        let length = text.length
        guard length > 0 else { return nil }
        var boundary = max(0, min(offset, length))
        if boundary < length { boundary = text.rangeOfComposedCharacterSequence(at: boundary).location }

        // 1. The word that starts at, or contains, the character after the offset.
        if boundary < length {
            if text.character(at: boundary) == backslash {
                if let range = controlWord(startingAtBackslash: boundary, in: text) {
                    return (text.substring(with: range), range)
                }
            } else if isWordCluster(at: boundary, in: text), let range = wordRange(containing: boundary, in: text) {
                return (text.substring(with: range), range)
            }
        }
        // 2. The word that ends exactly at the offset.
        if boundary > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: boundary - 1).location
            if isWordCluster(at: previous, in: text), let range = wordRange(containing: previous, in: text) {
                return (text.substring(with: range), range)
            }
        }
        return nil
    }

    // MARK: - Pieces

    /// The name range of the control word whose (unescaped) backslash is at `backslashOffset`.
    private static func controlWord(startingAtBackslash backslashOffset: Int, in text: NSString) -> NSRange? {
        guard !isEscaped(backslashOffset, in: text) else { return nil }
        let start = backslashOffset + 1
        guard start < text.length, isCommandLetter(text.character(at: start)) else { return nil }
        var end = start
        while end < text.length, isCommandLetter(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The word containing the word-character cluster that starts at `position` (a control word's name
    /// when the cluster sits inside one).
    private static func wordRange(containing position: Int, in text: NSString) -> NSRange? {
        let length = text.length
        // Inside a control word? (letters and `@` back to an unescaped backslash)
        if isCommandLetter(text.character(at: position)) {
            var nameStart = position
            while nameStart > 0, isCommandLetter(text.character(at: nameStart - 1)) { nameStart -= 1 }
            if nameStart > 0, text.character(at: nameStart - 1) == backslash, !isEscaped(nameStart - 1, in: text) {
                var nameEnd = position
                while nameEnd < length, isCommandLetter(text.character(at: nameEnd)) { nameEnd += 1 }
                return NSRange(location: nameStart, length: nameEnd - nameStart)
            }
        }
        // A plain word: extend over word clusters in both directions.
        var start = position
        var budget = maxWordUnits
        while start > 0, budget > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: start - 1)
            guard isWordCluster(at: previous.location, in: text) else { break }
            start = previous.location
            budget -= previous.length
        }
        var end = position
        budget = maxWordUnits
        while end < length, budget > 0 {
            guard isWordCluster(at: end, in: text) else { break }
            let cluster = text.rangeOfComposedCharacterSequence(at: end)
            end = cluster.end
            budget -= cluster.length
        }
        guard end > start else { return nil }
        // The run may begin with a control word glued to text (`\alpha1`, `\textbfção`): the name ends at
        // its last ASCII letter, what follows is a word of its own.
        if start > 0, text.character(at: start - 1) == backslash, !isEscaped(start - 1, in: text),
           isCommandLetter(text.character(at: start)) {
            var nameEnd = start
            while nameEnd < end, isCommandLetter(text.character(at: nameEnd)) { nameEnd += 1 }
            if position < nameEnd { return NSRange(location: start, length: nameEnd - start) }
            start = nameEnd
        }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// True when the composed character starting at `position` is a letter, digit or combining mark
    /// (judged by its first scalar, so an emoji followed by a variation selector is not a word).
    private static func isWordCluster(at position: Int, in text: NSString) -> Bool {
        let unit = text.character(at: position)
        if unit < 0x80 { return isASCIILetter(unit) || isDigit(unit) }
        var value = UInt32(unit)
        if UTF16.isLeadSurrogate(unit), position + 1 < text.length {
            let next = text.character(at: position + 1)
            guard UTF16.isTrailSurrogate(next) else { return false }
            value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(next) - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(value) else { return false }   // lone surrogate
        let properties = scalar.properties
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        case .decimalNumber, .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
}

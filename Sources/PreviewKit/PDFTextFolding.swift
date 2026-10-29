import Foundation

/// Pure text helpers behind the precise PDF <-> source sync (no PDFKit, no AppKit; safe on any thread).
///
/// Page text coming out of PDFKit and words coming out of the LaTeX source never look exactly alike: PDFs
/// contain ligature glyphs ("ﬁ"), typographic quotes, soft hyphens and line-end hyphenation; the source contains
/// `\'e`, `{\c c}`, `\textbf{…}` and comments. `PDFTextFolding` brings both sides to one comparable form
/// (lowercase, no diacritics, ligatures expanded) while remembering which original UTF-16 offsets every folded
/// unit came from, so a match can be turned back into a range of the original page string.
nonisolated enum PDFTextFolding {
    static let space: UInt16 = 0x20
    static let newline: UInt16 = 0x0A
    static let hyphen: UInt16 = 0x2D
    static let apostrophe: UInt16 = 0x27

    /// Folded text plus, for every folded UTF-16 unit, the half-open range of the original text it came from.
    struct Folded: Sendable {
        var units: [UInt16] = []
        var starts: [Int] = []
        var ends: [Int] = []
    }

    // MARK: Folding

    /// Case-, diacritic-, ligature- and width-insensitive form of `text`.
    ///
    /// - Letters are lowercased, accents removed (`é` -> `e`, `ç` -> `c`), compatibility forms expanded
    ///   (`ﬁ` -> `fi`, `ﬃ` -> `ffi`, full-width letters, math alphanumerics), `ß` -> `ss`, `æ` -> `ae`, `ø` -> `o`, …
    /// - Soft hyphens and other invisible format characters disappear; every kind of space becomes a plain space and
    ///   every kind of line break a single `\n` (a CR LF pair counts once).
    /// - Typographic quotes become `'` / `"`, Unicode hyphens (U+2010, U+2011) become `-`.
    static func fold(_ text: String) -> Folded {
        var out = Folded()
        let capacity = text.utf16.count
        out.units.reserveCapacity(capacity)
        out.starts.reserveCapacity(capacity)
        out.ends.reserveCapacity(capacity)
        var offset = 0
        for character in text {
            let end = offset + character.utf16.count
            if let ascii = character.asciiValue {
                switch ascii {
                case 0x41...0x5A: append(UInt16(ascii) + 32, from: offset, to: end, in: &out)
                case 0x0A, 0x0D: append(newline, from: offset, to: end, in: &out)
                case 0x09, 0x0B, 0x0C, 0x20: append(space, from: offset, to: end, in: &out)
                case 0x00...0x1F, 0x7F: break
                default: append(UInt16(ascii), from: offset, to: end, in: &out)
                }
            } else {
                appendGeneral(character, from: offset, to: end, in: &out)
            }
            offset = end
        }
        return out
    }

    private static func append(_ unit: UInt16, from start: Int, to end: Int, in out: inout Folded) {
        out.units.append(unit)
        out.starts.append(start)
        out.ends.append(end)
    }

    private static func appendGeneral(_ character: Character, from start: Int, to end: Int, in out: inout Folded) {
        for scalar in String(character).decomposedStringWithCompatibilityMapping.unicodeScalars {
            if scalar.value == 0x85 {
                append(newline, from: start, to: end, in: &out)
                continue
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format, .control, .surrogate, .privateUse, .unassigned:
                continue
            case .spaceSeparator:
                append(space, from: start, to: end, in: &out)
                continue
            case .lineSeparator, .paragraphSeparator:
                append(newline, from: start, to: end, in: &out)
                continue
            default:
                break
            }
            for lowered in scalar.properties.lowercaseMapping.unicodeScalars {
                for unit in mapSpecial(lowered) {
                    append(unit, from: start, to: end, in: &out)
                }
            }
        }
    }

    /// Letters without a Unicode decomposition, quotes and hyphens, reduced to their plain counterparts.
    private static func mapSpecial(_ scalar: Unicode.Scalar) -> [UInt16] {
        switch scalar.value {
        case 0xDF: return [0x73, 0x73]                       // ß -> ss
        case 0xE6: return [0x61, 0x65]                       // æ -> ae
        case 0x153: return [0x6F, 0x65]                      // œ -> oe
        case 0xF8: return [0x6F]                             // ø -> o
        case 0x111, 0xF0: return [0x64]                      // đ, ð -> d
        case 0x142: return [0x6C]                            // ł -> l
        case 0x131: return [0x69]                            // ı -> i
        case 0xFE: return [0x74, 0x68]                       // þ -> th
        case 0x2018, 0x2019, 0x201A, 0x201B, 0x2B9, 0x2BC, 0x2032: return [apostrophe]
        case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033: return [0x22]
        case 0x2010, 0x2011: return [hyphen]
        default: return Array(String(scalar).utf16)
        }
    }

    /// `true` for letters and digits of already folded text (surrogate halves count as letters).
    static func isWordUnit(_ unit: UInt16) -> Bool {
        if unit < 0x80 {
            return (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A)
        }
        if unit >= 0xD800 && unit <= 0xDFFF { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// Like `isWordUnit`, for the *original* page text: combining marks belong to the letter they sit on.
    static func isWordCharacterUnit(_ unit: UInt16) -> Bool {
        if isWordUnit(unit) { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    static func isBreakOrSpace(_ unit: UInt16) -> Bool { unit == space || unit == newline }

    // MARK: Words and context of the original page text

    /// Presentation ligatures expanded, invisible characters dropped, exotic spaces made plain. Case and accents are
    /// kept: this is the form handed to the app (`PDFSyncClick.word`).
    static func cleaned(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFB00: out.append(contentsOf: "ff".unicodeScalars)
            case 0xFB01: out.append(contentsOf: "fi".unicodeScalars)
            case 0xFB02: out.append(contentsOf: "fl".unicodeScalars)
            case 0xFB03: out.append(contentsOf: "ffi".unicodeScalars)
            case 0xFB04: out.append(contentsOf: "ffl".unicodeScalars)
            case 0xFB05, 0xFB06: out.append(contentsOf: "st".unicodeScalars)
            case 0xAD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: continue
            case 0xA0, 0x2007, 0x2009, 0x202F: out.append(" ")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// `range` shrunk so that it neither starts nor ends with a character that is not a letter or a digit
    /// (punctuation, spaces, the hyphen and line break PDFKit puts into the word before a line-end hyphenation).
    /// `nil` when nothing is left.
    static func trimmedWordRange(in text: NSString, range: NSRange) -> NSRange? {
        let bounds = NSRange(location: 0, length: text.length)
        let clamped = NSIntersectionRange(range, bounds)
        guard clamped.length > 0 else { return nil }
        var start = clamped.location
        var end = clamped.location + clamped.length
        while start < end, !isWordCharacterUnit(text.character(at: start)) { start += 1 }
        while end > start, !isWordCharacterUnit(text.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The run of letters/digits around `index` (inner apostrophes allowed: "don't"). Used when PDFKit's own word
    /// selection is unusable.
    static func wordRange(in text: NSString, at index: Int) -> NSRange? {
        guard index >= 0, index < text.length, isWordCharacterUnit(text.character(at: index)) else { return nil }
        func isInnerApostrophe(_ position: Int) -> Bool {
            guard position > 0, position < text.length - 1 else { return false }
            let unit = text.character(at: position)
            return (unit == 0x27 || unit == 0x2019)
                && isWordCharacterUnit(text.character(at: position - 1))
                && isWordCharacterUnit(text.character(at: position + 1))
        }
        var start = index
        while start > 0, isWordCharacterUnit(text.character(at: start - 1)) || isInnerApostrophe(start - 1) { start -= 1 }
        var end = index + 1
        while end < text.length, isWordCharacterUnit(text.character(at: end)) || isInnerApostrophe(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// About `limit` UTF-16 units of page text right before and right after `range`, as the app wants them:
    /// every whitespace run (line breaks included) is one space, a line-end hyphenation ("infor-⏎mation") is
    /// joined, presentation ligatures are expanded, and a word cut in half by the limit is dropped.
    static func context(in text: String, around range: NSRange, limit: Int = 40) -> (before: String, after: String) {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let end = min(max(range.location + range.length, location), ns.length)

        var beforeStart = max(0, location - limit)
        var afterEnd = min(ns.length, end + limit)
        // Do not split surrogate pairs.
        if beforeStart > 0, beforeStart < ns.length { beforeStart = ns.rangeOfComposedCharacterSequence(at: beforeStart).location }
        if afterEnd < ns.length, afterEnd > 0 { afterEnd = ns.rangeOfComposedCharacterSequence(at: afterEnd - 1).upperBound }

        var before = ns.substring(with: NSRange(location: beforeStart, length: location - beforeStart))
        var after = ns.substring(with: NSRange(location: end, length: afterEnd - end))

        if beforeStart > 0, isWordCharacterUnit(ns.character(at: beforeStart - 1)),
           let first = before.utf16.first, isWordCharacterUnit(first) {
            before = String(before.drop(while: { $0.utf16.allSatisfy(isWordCharacterUnit) }))
        }
        if afterEnd < ns.length, isWordCharacterUnit(ns.character(at: afterEnd)),
           let last = after.utf16.last, isWordCharacterUnit(last) {
            var characters = Array(after)
            while let tail = characters.last, tail.utf16.allSatisfy(isWordCharacterUnit) { characters.removeLast() }
            after = String(characters)
        }
        // The word itself may be one half of a hyphenated word: "infor-⏎" + [mation] + " ..." / "..." + [infor] + "-⏎mation".
        let first = location < ns.length ? ns.character(at: location) : 0
        let last = end > location ? ns.character(at: end - 1) : 0
        let startsLowercase = Unicode.Scalar(first)?.properties.isLowercase ?? false
        let endsWithLetter = Unicode.Scalar(last)?.properties.isAlphabetic ?? false
        return (tidy(before, followedByLowercaseLetter: startsLowercase), tidy(after, previousIsLetter: endsWithLetter))
    }

    /// Collapses whitespace, joins line-end hyphenation, expands ligatures. `previousIsLetter` / `followedByLowercaseLetter`
    /// tell what lies just outside the text (a hyphenation can straddle the edge).
    static func tidy(_ text: String, previousIsLetter: Bool = false, followedByLowercaseLetter: Bool = false) -> String {
        let scalars = Array(cleaned(text).unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        var pendingSpace = false
        func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "\n" || scalar == "\r" || scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value == 0x85
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.properties.isWhitespace {
                pendingSpace = true
                index += 1
                continue
            }
            // "infor-" + line break + "mation": drop the hyphen and the break.
            let previousIsAlphabetic = out.last?.properties.isAlphabetic ?? previousIsLetter
            if scalar == "-", previousIsAlphabetic, !pendingSpace {
                var probe = index + 1
                var sawBreak = false
                while probe < scalars.count, scalars[probe].properties.isWhitespace {
                    if isLineBreak(scalars[probe]) { sawBreak = true }
                    probe += 1
                }
                let nextIsLowercase = probe < scalars.count ? scalars[probe].properties.isLowercase : followedByLowercaseLetter
                if sawBreak, nextIsLowercase {
                    index = probe
                    continue
                }
            }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
            index += 1
        }
        return String(out)
    }

    // MARK: LaTeX source -> plain words

    /// What a piece of LaTeX source says as plain text, good enough to compare with PDF text: comments, command
    /// names and braces vanish, accent commands keep their letter (`\'e`, `\'{e}`, `{\c c}`, `\~a`, `\"o` ->
    /// e, e, c, a, o), `\ss`, `\ae`, `\o`, `\l`, `\i` give their letters, `~` and math shifts become spaces.
    /// Arguments of commands stay (`\textbf{foo}` -> `foo`).
    static func plainText(fromLaTeX source: String) -> String {
        let s = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
            (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
        }
        func skipSpaces() {
            while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
        }
        /// Reads the argument of an accent command: `{x}`, `x`, `\i`, `\j`. Appends its letters.
        func appendAccentArgument() {
            skipSpaces()
            guard i < s.count else { return }
            if s[i] == "{" {
                i += 1
                while i < s.count, s[i] != "}" {
                    if s[i] == "\\" {
                        i += 1
                        var name = String.UnicodeScalarView()
                        while i < s.count, isASCIILetter(s[i]) { name.append(s[i]); i += 1 }
                        if name.count == 1 || name.isEmpty { out.append(contentsOf: name) } // \i, \j
                        continue
                    }
                    out.append(s[i])
                    i += 1
                }
                if i < s.count { i += 1 }
            } else if s[i] == "\\" {
                i += 1
                var name = String.UnicodeScalarView()
                while i < s.count, isASCIILetter(s[i]) { name.append(s[i]); i += 1 }
                if name.count == 1 { out.append(contentsOf: name) }
            } else {
                out.append(s[i])
                i += 1
            }
        }
        let accentSymbols: Set<Unicode.Scalar> = ["'", "`", "^", "\"", "~", "=", "."]
        let accentLetters: Set<String> = ["c", "v", "u", "H", "k", "r", "d", "b", "t", "G"]
        let letterCommands: [String: String] = [
            "ss": "ss", "ae": "ae", "AE": "AE", "oe": "oe", "OE": "OE", "o": "o", "O": "O", "l": "l", "L": "L",
            "i": "i", "j": "j", "aa": "a", "AA": "A",
        ]

        while i < s.count {
            let c = s[i]
            switch c {
            case "%":
                while i < s.count, s[i] != "\n" { i += 1 }
            case "\\":
                i += 1
                guard i < s.count else { break }
                let d = s[i]
                if isASCIILetter(d) {
                    var name = String.UnicodeScalarView()
                    while i < s.count, isASCIILetter(s[i]) { name.append(s[i]); i += 1 }
                    let word = String(name)
                    if let replacement = letterCommands[word] {
                        out.append(contentsOf: replacement.unicodeScalars)
                    } else if accentLetters.contains(word) {
                        appendAccentArgument()
                        continue
                    }
                    // Any other command: the name disappears (and one space after it).
                    if i < s.count, s[i] == " " { i += 1 }
                } else if accentSymbols.contains(d) {
                    i += 1
                    appendAccentArgument()
                } else {
                    switch d {
                    case "%", "&", "$", "#", "_": out.append(d)
                    case "{", "}": break
                    default: out.append(" ")
                    }
                    i += 1
                }
            case "{", "}":
                i += 1
            case "~", "$", "&", "^", "_":
                out.append(" ")
                i += 1
            default:
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    /// Word tokens (runs of letters/digits) of `text` after folding, in reading order. `latex` runs the text
    /// through `plainText(fromLaTeX:)` first.
    static func tokens(of text: String, latex: Bool) -> [String] {
        let prepared = latex ? plainText(fromLaTeX: text) : text
        return tokens(ofFolded: fold(prepared).units)
    }

    static func tokens(ofFolded units: [UInt16]) -> [String] {
        var result: [String] = []
        var start: Int?
        for (index, unit) in units.enumerated() {
            if isWordUnit(unit) {
                if start == nil { start = index }
            } else if let begin = start {
                result.append(String(decoding: units[begin..<index], as: UTF16.self))
                start = nil
            }
        }
        if let begin = start { result.append(String(decoding: units[begin...], as: UTF16.self)) }
        return result
    }
}

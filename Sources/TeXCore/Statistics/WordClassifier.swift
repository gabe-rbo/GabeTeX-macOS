import Foundation

/// What a character does to the word being built.
enum WordClassifier {
    enum CharacterClass: Equatable {
        case letter
        case digit
        /// Combining marks and invisible format characters: they continue a word and never start one.
        case mark
        /// Han and kana: every character counts as a word of its own (these scripts have no spaces).
        case ideograph
        case hyphen
        case apostrophe
        case other
    }

    static func classify(_ scalar: Unicode.Scalar) -> CharacterClass {
        let value = scalar.value
        switch value {
        case 0x2010, 0x2011: return .hyphen                         // ‐ and the non-breaking hyphen
        case 0x2019, 0x02BC: return .apostrophe                     // ’ ʼ
        case 0x00AD, 0x200C, 0x200D, 0xFEFF: return .mark           // soft hyphen, ZWNJ, ZWJ, BOM
        case 0x30FB: return .other                                  // ・
        case 0x3041...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return .ideograph
        default: break
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return .letter
        case .decimalNumber:
            return .digit
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return .mark
        default:
            return .other
        }
    }
}

/// Tracks whether the characters seen so far form one word, so that "state-of-the-art", "don’t",
/// "3.14" and "COVID-19" count once while "pages 10--20" counts twice.
///
/// Rules (documented in `DocumentStatistics`):
/// - a word is a run of letters and digits; combining marks continue it;
/// - a hyphen (`-`, U+2010, U+2011) or an apostrophe (`'`, `’`) joins two characters when a letter or digit
///   follows it directly (`--` and `---` therefore separate);
/// - `.` and `,` join two digits (`3.14`, `1,5`, `1.000`);
/// - anything else ends the word.
struct WordState {
    enum Joiner {
        case hyphen
        case apostrophe
        case numberSeparator
    }

    private(set) var inWord = false
    private(set) var lastWasDigit = false
    private var pending: Joiner?

    /// True while the word is made of letters only and nothing is waiting to be joined: where the babel
    /// shorthands `"a`, `"-` … continue a word.
    var isInsideLetters: Bool { inWord && !lastWasDigit && pending == nil }

    /// A letter arrived. Returns true when it starts a new word.
    mutating func letter() -> Bool {
        var started = !inWord
        if pending == .numberSeparator { started = true }           // "3.a": the number ended at the dot
        inWord = true
        lastWasDigit = false
        pending = nil
        return started
    }

    /// A digit arrived. Returns true when it starts a new word.
    mutating func digit() -> Bool {
        let started = !inWord
        inWord = true
        lastWasDigit = true
        pending = nil
        return started
    }

    /// A character that joins what is on both sides of it, when a letter or digit follows.
    mutating func joiner(_ kind: Joiner) {
        if inWord, pending == nil, kind != .numberSeparator || lastWasDigit {
            pending = kind
        } else {
            separator()
        }
    }

    /// Whitespace, punctuation, a command, a formula … the word (if any) is over.
    mutating func separator() {
        inWord = false
        lastWasDigit = false
        pending = nil
    }
}

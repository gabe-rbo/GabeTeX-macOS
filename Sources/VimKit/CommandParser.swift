import Foundation

/// Result of parsing the pending key sequence.
enum ParseOutcome {
    /// More keys are needed.
    case incomplete
    /// The sequence is not a valid command; discard it.
    case invalid
    /// An unknown Ctrl combination: the host should handle it.
    case passThrough
    case done(VimCommand)
}

private enum MotionParse {
    case ok(VimMotion, Int)
    case incomplete
    case none
}

/// Parses `["x] [count] (operator [count] (motion | object | operator) | motion | command)` from a key list.
/// The whole pending sequence is re-parsed after every key, which keeps the state machine trivial.
struct CommandParser {
    let keys: [VimKey]
    let visual: Bool
    private var pos = 0

    init(keys: [VimKey], visual: Bool) {
        self.keys = keys
        self.visual = visual
    }

    // MARK: Entry point

    mutating func parse() -> ParseOutcome {
        var register: Character?
        var count: Int?
        while true {
            guard let k = key(pos) else { return .incomplete }
            if k.isChar("\"") {
                guard let r = key(pos + 1) else { return .incomplete }
                guard let s = r.plain, s.count == 1, let ch = s.first, Self.validRegister(ch) else { return .invalid }
                register = ch
                pos += 2
                continue
            }
            if let d = Self.digit(k), d != 0 || count != nil {
                count = min((count ?? 0) * 10 + d, 99_999_999)
                pos += 1
                continue
            }
            break
        }
        guard let k = key(pos) else { return .incomplete }
        let inner = visual ? parseVisual(k) : parseNormal(k)
        switch inner {
        case .done(var c):
            c.register = register
            if let a = count, let b = c.count { c.count = min(a * b, 99_999_999) } else { c.count = count ?? c.count }
            return .done(c)
        default:
            return inner
        }
    }

    // MARK: Helpers

    private func key(_ i: Int) -> VimKey? { i >= 0 && i < keys.count ? keys[i] : nil }

    static func digit(_ k: VimKey) -> Int? {
        guard let c = k.plain, c.utf8.count == 1, let b = c.utf8.first, b >= 48 && b <= 57 else { return nil }
        return Int(b) - 48
    }

    static func validRegister(_ c: Character) -> Bool {
        if c.isLetter && c.isASCII { return true }
        if c.isNumber && c.isASCII { return true }
        return "\"-_+*/.:%#".contains(c)
    }

    private func done(_ a: VimAction, count: Int? = nil) -> ParseOutcome {
        .done(VimCommand(action: a, register: nil, count: count))
    }

    private func simple(_ s: VimSimple) -> ParseOutcome { done(.simple(s)) }

    static func object(for k: VimKey, around: Bool) -> VimTextObject? {
        guard let c = k.plain else { return nil }
        switch c {
        case "w": return .word(big: false, around: around)
        case "W": return .word(big: true, around: around)
        case "p": return .paragraph(around: around)
        case "(", ")", "b": return .pair(open: "(", close: ")", around: around)
        case "{", "}", "B": return .pair(open: "{", close: "}", around: around)
        case "[", "]": return .pair(open: "[", close: "]", around: around)
        case "<", ">": return .pair(open: "<", close: ">", around: around)
        case "\"": return .quote("\"", around: around)
        case "'": return .quote("'", around: around)
        case "`": return .quote("`", around: around)
        case "$": return .math(around: around)
        case "e": return .environment(around: around)
        default: return nil
        }
    }

    // MARK: Motions

    private func parseMotion(at i: Int) -> MotionParse {
        guard let k = key(i) else { return .incomplete }
        if let s = k.special {
            switch s {
            case .left: return .ok(.left, 1)
            case .right: return .ok(.right, 1)
            case .up: return .ok(.up, 1)
            case .down: return .ok(.down, 1)
            case .home: return .ok(.lineStart, 1)
            case .end: return .ok(.lineEnd, 1)
            case .backspace: return .ok(.wrapLeft, 1)
            case .enter: return .ok(.nextLineFirstNonBlank, 1)
            case .pageDown: return .ok(.pageDown, 1)
            case .pageUp: return .ok(.pageUp, 1)
            default: return .none
            }
        }
        guard let c = k.character else { return .none }
        if k.control {
            switch c.lowercased() {
            case "d": return .ok(.halfPageDown, 1)
            case "u": return .ok(.halfPageUp, 1)
            case "f": return .ok(.pageDown, 1)
            case "b": return .ok(.pageUp, 1)
            case "h": return .ok(.wrapLeft, 1)
            case "j", "n": return .ok(.down, 1)
            case "p": return .ok(.up, 1)
            case "m": return .ok(.nextLineFirstNonBlank, 1)
            default: return .none
            }
        }
        switch c {
        case "h": return .ok(.left, 1)
        case "l": return .ok(.right, 1)
        case "j": return .ok(.down, 1)
        case "k": return .ok(.up, 1)
        case " ": return .ok(.wrapRight, 1)
        case "0": return .ok(.lineStart, 1)
        case "^": return .ok(.firstNonBlank, 1)
        case "$": return .ok(.lineEnd, 1)
        case "|": return .ok(.column, 1)
        case "+": return .ok(.nextLineFirstNonBlank, 1)
        case "-": return .ok(.prevLineFirstNonBlank, 1)
        case "_": return .ok(.currentLineFirstNonBlank, 1)
        case "w": return .ok(.wordForward(big: false), 1)
        case "W": return .ok(.wordForward(big: true), 1)
        case "b": return .ok(.wordBackward(big: false), 1)
        case "B": return .ok(.wordBackward(big: true), 1)
        case "e": return .ok(.wordEnd(big: false), 1)
        case "E": return .ok(.wordEnd(big: true), 1)
        case "G": return .ok(.fileBottom, 1)
        case "{": return .ok(.paragraphBackward, 1)
        case "}": return .ok(.paragraphForward, 1)
        case "%": return .ok(.matchPair, 1)
        case ";": return .ok(.repeatFind(reverse: false), 1)
        case ",": return .ok(.repeatFind(reverse: true), 1)
        case "H": return .ok(.screenTop, 1)
        case "M": return .ok(.screenMiddle, 1)
        case "L": return .ok(.screenBottom, 1)
        case "*": return .ok(.searchWord(forward: true), 1)
        case "#": return .ok(.searchWord(forward: false), 1)
        case "n": return .ok(.searchNext(reverse: false), 1)
        case "N": return .ok(.searchNext(reverse: true), 1)
        case "/": return .ok(.searchCommand(forward: true), 1)
        case "?": return .ok(.searchCommand(forward: false), 1)
        case "f", "F", "t", "T":
            guard let a = key(i + 1) else { return .incomplete }
            guard let s = a.plain, !s.isEmpty else { return .none }
            let kind: FindKind = c == "f" ? .forward : c == "F" ? .backward : c == "t" ? .tillForward : .tillBackward
            return .ok(.find(kind, s), 2)
        case "'", "`":
            guard let a = key(i + 1) else { return .incomplete }
            guard let s = a.plain, s.count == 1, let ch = s.first else { return .none }
            return .ok(.mark(ch, linewise: c == "'"), 2)
        case "g":
            guard let a = key(i + 1) else { return .incomplete }
            guard !a.control, a.special == nil, let s = a.character else { return .none }
            switch s {
            case "g": return .ok(.fileTop, 2)
            case "e": return .ok(.wordEndBackward(big: false), 2)
            case "E": return .ok(.wordEndBackward(big: true), 2)
            case "_": return .ok(.lastNonBlank, 2)
            case "j": return .ok(.down, 2)
            case "k": return .ok(.up, 2)
            case "0": return .ok(.lineStart, 2)
            case "^": return .ok(.firstNonBlank, 2)
            case "$": return .ok(.lineEnd, 2)
            default: return .none
            }
        default: return .none
        }
    }

    // MARK: Operators

    private enum OpParse {
        case none
        case incomplete
        case op(VimOperator, keys: Int, doubled: String)
    }

    private func operatorAt(_ i: Int) -> OpParse {
        guard let k = key(i), let c = k.plain else { return .none }
        switch c {
        case "d": return .op(.delete, keys: 1, doubled: "d")
        case "c": return .op(.change, keys: 1, doubled: "c")
        case "y": return .op(.yank, keys: 1, doubled: "y")
        case ">": return .op(.shiftRight, keys: 1, doubled: ">")
        case "<": return .op(.shiftLeft, keys: 1, doubled: "<")
        case "g":
            guard let n = key(i + 1) else { return .incomplete }
            switch n.plain {
            case "u": return .op(.lowercase, keys: 2, doubled: "u")
            case "U": return .op(.uppercase, keys: 2, doubled: "U")
            case "~": return .op(.toggleCase, keys: 2, doubled: "~")
            default: return .none
            }
        default: return .none
        }
    }

    // MARK: Normal mode

    private mutating func parseNormal(_ k: VimKey) -> ParseOutcome {
        if k.isSpecial(.escape) || k.isCtrl("c") || k.isCtrl("[") { return .invalid }

        switch operatorAt(pos) {
        case .incomplete: return .incomplete
        case .op(let op, let n, let doubled):
            pos += n
            var count2: Int?
            while let t = key(pos), let d = Self.digit(t), d != 0 || count2 != nil {
                count2 = min((count2 ?? 0) * 10 + d, 99_999_999)
                pos += 1
            }
            guard let t = key(pos) else { return .incomplete }
            if t.isSpecial(.escape) || t.isCtrl("c") || t.isCtrl("[") { return .invalid }
            // Doubled operator: dd, >>, guu / gugu …
            if t.isChar(doubled) { return done(.operatorLines(op), count: count2) }
            if op.isGPrefixed, t.isChar("g") {
                guard let n2 = key(pos + 1) else { return .incomplete }
                if n2.isChar(doubled) { return done(.operatorLines(op), count: count2) }
            }
            // Text objects.
            if t.isChar("i") || t.isChar("a") {
                guard let o = key(pos + 1) else { return .incomplete }
                if let obj = Self.object(for: o, around: t.isChar("a")) {
                    return done(.operatorObject(op, obj), count: count2)
                }
                return .invalid
            }
            switch parseMotion(at: pos) {
            case .ok(let m, _): return done(.operatorMotion(op, m), count: count2)
            case .incomplete: return .incomplete
            case .none: return .invalid
            }
        case .none: break
        }

        switch parseMotion(at: pos) {
        case .ok(let m, _): return done(.motion(m))
        case .incomplete: return .incomplete
        case .none: break
        }

        if let special = k.special {
            switch special {
            case .delete: return simple(.deleteChar)
            case .tab: return simple(.noop)
            default: return .invalid
            }
        }
        guard let c = k.character else { return .invalid }
        if k.control {
            switch c.lowercased() {
            case "r": return simple(.redo)
            case "a": return simple(.increment(1))
            case "x": return simple(.increment(-1))
            case "v", "o", "i", "e", "y", "g", "l", "w", "t", "z": return simple(.noop)
            default: return .passThrough
            }
        }
        switch c {
        case "x": return simple(.deleteChar)
        case "X": return simple(.deleteCharBefore)
        case "D": return simple(.deleteToEnd)
        case "C": return simple(.changeToEnd)
        case "s": return simple(.substituteChar)
        case "S": return simple(.substituteLine)
        case "Y": return simple(.yankLine)
        case "p": return simple(.put(after: true, cursorAfter: false))
        case "P": return simple(.put(after: false, cursorAfter: false))
        case "J": return simple(.join(spaces: true))
        case "u": return simple(.undo)
        case ".": return simple(.repeatChange)
        case "i": return simple(.insert(.before))
        case "a": return simple(.insert(.after))
        case "I": return simple(.insert(.lineStart))
        case "A": return simple(.insert(.lineEnd))
        case "o": return simple(.insert(.openBelow))
        case "O": return simple(.insert(.openAbove))
        case "R": return simple(.replaceMode)
        case "~": return simple(.toggleCaseChar)
        case "v": return simple(.startVisual(.visual))
        case "V": return simple(.startVisual(.visualLine))
        case ":": return simple(.commandLine(":"))
        case "&": return simple(.repeatSubstitute)
        case "r":
            guard let a = key(pos + 1) else { return .incomplete }
            if a.isSpecial(.enter) { return simple(.replaceChar("\n")) }
            if let s = a.plain, !s.isEmpty { return simple(.replaceChar(s)) }
            return .invalid
        case "m":
            guard let a = key(pos + 1) else { return .incomplete }
            if let s = a.plain, s.count == 1, let ch = s.first { return simple(.setMark(ch)) }
            return .invalid
        case "q", "@":
            guard key(pos + 1) != nil else { return .incomplete }
            return simple(.noop)
        case "Z":
            guard let a = key(pos + 1) else { return .incomplete }
            if a.isChar("Z") { return simple(.writeQuit) }
            if a.isChar("Q") { return simple(.quitNoSave) }
            return .invalid
        case "z": return parseZ()
        case "g": return parseG(visual: false)
        case "[", "]":
            guard key(pos + 1) != nil else { return .incomplete }
            return simple(.noop)
        default:
            return simple(.noop)
        }
    }

    private func parseZ() -> ParseOutcome {
        guard let a = key(pos + 1) else { return .incomplete }
        if a.isSpecial(.enter) { return simple(.viewport(.cursorToTop)) }
        switch a.plain {
        case "z", ".": return simple(.viewport(.cursorToCenter))
        case "t": return simple(.viewport(.cursorToTop))
        case "b", "-": return simple(.viewport(.cursorToBottom))
        default: return simple(.noop)
        }
    }

    private func parseG(visual: Bool) -> ParseOutcome {
        guard let a = key(pos + 1) else { return .incomplete }
        switch a.plain {
        case "J": return simple(.join(spaces: false))
        case "p": return simple(.put(after: true, cursorAfter: true))
        case "P": return simple(.put(after: false, cursorAfter: true))
        case "v": return simple(.visualReselect)
        case "I": return visual ? .invalid : simple(.insert(.firstColumn))
        case "i": return visual ? .invalid : simple(.insert(.lastInsert))
        default: return .invalid
        }
    }

    // MARK: Visual mode

    private mutating func parseVisual(_ k: VimKey) -> ParseOutcome {
        if k.isSpecial(.escape) || k.isCtrl("c") || k.isCtrl("[") { return simple(.visualExit) }

        // g-prefixed operators first (gu gU g~ gJ gv gp).
        if k.isChar("g") {
            guard let a = key(pos + 1) else { return .incomplete }
            switch a.plain {
            case "u": return done(.visualOperator(.lowercase))
            case "U": return done(.visualOperator(.uppercase))
            case "~": return done(.visualOperator(.toggleCase))
            default: break
            }
        }

        switch parseMotion(at: pos) {
        case .ok(let m, _): return done(.motion(m))
        case .incomplete: return .incomplete
        case .none: break
        }

        if let special = k.special {
            switch special {
            case .delete: return done(.visualOperator(.delete))
            default: return .invalid
            }
        }
        guard let c = k.character else { return .invalid }
        if k.control {
            switch c.lowercased() {
            case "a": return simple(.increment(1))
            case "x": return simple(.increment(-1))
            case "v": return simple(.startVisual(.visual))
            default: return .passThrough
            }
        }
        switch c {
        case "d", "x": return done(.visualOperator(.delete))
        case "y": return done(.visualOperator(.yank))
        case "c", "s": return done(.visualOperator(.change))
        case ">": return done(.visualOperator(.shiftRight))
        case "<": return done(.visualOperator(.shiftLeft))
        case "~": return done(.visualOperator(.toggleCase))
        case "u": return done(.visualOperator(.lowercase))
        case "U": return done(.visualOperator(.uppercase))
        case "X", "D": return simple(.visualLinewise(.delete))
        case "Y": return simple(.visualLinewise(.yank))
        case "C", "S", "R": return simple(.visualLinewise(.change))
        case "J": return simple(.join(spaces: true))
        case "p": return simple(.put(after: true, cursorAfter: false))
        case "P": return simple(.put(after: false, cursorAfter: false))
        case "o", "O": return simple(.visualSwapEnds)
        case "v": return simple(.startVisual(.visual))
        case "V": return simple(.startVisual(.visualLine))
        case ":": return simple(.commandLine(":"))
        case "r":
            guard let a = key(pos + 1) else { return .incomplete }
            if a.isSpecial(.enter) { return simple(.replaceChar("\n")) }
            if let s = a.plain, !s.isEmpty { return simple(.replaceChar(s)) }
            return .invalid
        case "i", "a":
            guard let o = key(pos + 1) else { return .incomplete }
            if let obj = Self.object(for: o, around: c == "a") { return done(.visualObject(obj)) }
            return .invalid
        case "m":
            guard let a = key(pos + 1) else { return .incomplete }
            if let s = a.plain, s.count == 1, let ch = s.first { return simple(.setMark(ch)) }
            return .invalid
        case "z": return parseZ()
        case "g": return parseG(visual: true)
        default: return simple(.noop)
        }
    }
}

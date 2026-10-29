import Foundation
import CheckKit
import VimKit

/// Deterministic xorshift generator so a failure is reproducible.
struct XorShift {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
}

/// Describes how the session violates the cursor / selection invariants, or nil when it is fine.
func invariantViolation(_ s: VimSession) -> String? {
    let ns = s.buffer.storage
    let sel = s.buffer.vimSelection
    let len = ns.length
    if sel.location < 0 || sel.length < 0 || sel.location + sel.length > len { return "selection \(sel) outside 0..\(len)" }
    func isBreak(_ i: Int) -> Bool { i >= 0 && i < len && (ns.character(at: i) == 10 || ns.character(at: i) == 13) }
    switch s.engine.mode {
    case .normal:
        if sel.length != 0 { return "normal mode with a selection \(sel)" }
        if len == 0 { return sel.location == 0 ? nil : "cursor \(sel.location) in empty text" }
        if sel.location >= len { return "cursor \(sel.location) past the end (\(len))" }
        if isBreak(sel.location) {
            let atLineStart = sel.location == 0 || isBreak(sel.location - 1)
            if !atLineStart { return "cursor \(sel.location) on a line terminator" }
            if ns.character(at: sel.location) == 10, sel.location > 0, ns.character(at: sel.location - 1) == 13 {
                return "cursor \(sel.location) inside a CRLF"
            }
        }
        if ns.rangeOfComposedCharacterSequence(at: sel.location).location != sel.location {
            return "cursor \(sel.location) inside a composed character"
        }
    case .visual, .visualLine:
        if len > 0, sel.location < len, ns.rangeOfComposedCharacterSequence(at: sel.location).location != sel.location {
            return "selection start \(sel.location) inside a composed character"
        }
    case .insert, .replace, .commandLine:
        break
    }
    return nil
}

func fuzzChecks() {
    let texts = [
        "",
        "a",
        "abc def\nghi\n\njkl mno",
        "  indented\n\ttabbed\n",
        "a😀b e\u{301} ação\r\nfoo\r\n\r\nbar",
        "\\begin{itemize}\n  \\item $x+y$ and (a [b] {c}) \"q\"\n\\end{itemize}\n",
        "\n\n\n",
        "x",
        "one two three\nfour five six\nseven",
    ]
    let tokens: [String] = [
        "h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "^", "$", "gg", "G", "{", "}", "%", "ge", "gE", "g_",
        "fa", "Fe", "ta", "Tb", ";", ",", "H", "M", "L", "<C-d>", "<C-u>", "<C-f>", "<C-b>", "*", "#", "n", "N",
        "/e<CR>", "?o<CR>", "/\\(a<CR>", "/[<CR>", "ma", "'a", "`a", "''",
        "x", "X", "s", "S", "D", "C", "Y", "yy", "yw", "y$", "dd", "dw", "d$", "d0", "dG", "dgg", "cw", "cc", "c$",
        "p", "P", "gp", "gP", "J", "gJ", "~", "rx", "r<CR>", "r😀", "u", "<C-r>", ".", "2.", "U",
        "i", "a", "I", "A", "o", "O", "R", "gI", "gi", "<Esc>", "<Esc>", "<Esc>", "<C-o>", "<C-r>a", "<C-r>0",
        "x", "y", "z", "é", "😀", "$", "\\", "(", "{", "[", "\"", "'", "<CR>", "<BS>", "<Tab>", "<Del>", "<Left>", "<Right>",
        "v", "V", "o", "iw", "aw", "i(", "a(", "i{", "a{", "i\"", "a\"", "i$", "a$", "ie", "ae", "ip", "ap", "ib", "iB", "i[", "i<",
        "diw", "daw", "ciw", "yiw", "di(", "ci{", "da\"", "di$", "die", "dae", "cie", "dip", "yap", "vip", "vie", "vi(",
        ">>", "<<", ">j", "<k", ">ip", "gUiw", "guu", "g~w", "gUU", "gUap",
        ":s/e/X/g<CR>", ":%s/\\(a\\)/\\1\\1/g<CR>", ":2d<CR>", ":1,2j<CR>", ":$<CR>", ":'<,'>s/o/0/<CR>", ":w<CR>", ":nohlsearch<CR>",
        ":3<CR>", ":%s/$/;/<CR>", ":%s/^/> /<CR>", ":>", ":<<CR>", ":", "/", "<Up>", "<Down>", "<C-u>", "<C-w>",
        "\"ayy", "\"ap", "\"Ayw", "\"_dd", "\"+yy", "\"+p", "\"0p", "\"1p", "\".p", "\":p",
        "2", "3", "5", "10", "99", "0",
    ]
    var rng = XorShift(state: 0x9E37_79B9_7F4A_7C15)
    var reported = 0
    var steps = 0
    for text in texts {
        for runIndex in 0..<300 {
            let s = VimSession("|" + text)
            let len = (text as NSString).length
            s.buffer.vimSelection = NSRange(location: rng.below(len + 1), length: 0)
            if runIndex % 7 == 0 { s.buffer.visibleLines = 1...3 }
            var history: [String] = []
            for _ in 0..<45 {
                let t = rng.pick(tokens)
                history.append(t)
                s.feed(t)
                steps += 1
                if let problem = invariantViolation(s) {
                    if reported < 8 {
                        reported += 1
                        Check.fail("fuzz: \(problem) after \(history.joined(separator: " ")) on \(describe(text)); text now \(describe(s.text)), mode \(s.engine.mode)")
                    } else {
                        Check.fail("fuzz: violation (suppressed details)")
                    }
                    break
                }
            }
            // Whatever happened, three Esc keys bring the engine back to a sane state.
            s.feed("<Esc><Esc><Esc>")
            if s.engine.mode != .normal {
                Check.fail("fuzz: still in \(s.engine.mode) after Esc on \(describe(text)) with \(history.suffix(6).joined(separator: " "))")
            } else if let problem = invariantViolation(s) {
                Check.fail("fuzz: \(problem) after Esc on \(describe(text)) with \(history.suffix(6).joined(separator: " "))")
            } else {
                Check.expect(true)
                // Every change is undoable: from the newest state of the history, undoing everything
                // restores the original text and redoing everything returns to the newest state.
                s.feed(String(repeating: "<C-r>", count: 400))
                let finalText = s.text
                s.feed(String(repeating: "u", count: 400))
                if s.text != text {
                    Check.fail("fuzz: undo-all gave \(describe(s.text)) instead of \(describe(text)) after \(history.joined(separator: " "))")
                } else if let problem = invariantViolation(s) {
                    Check.fail("fuzz: \(problem) after undo-all of \(history.joined(separator: " "))")
                } else {
                    s.feed(String(repeating: "<C-r>", count: 400))
                    if s.text != finalText {
                        Check.fail("fuzz: redo-all gave \(describe(s.text)) instead of \(describe(finalText)) after \(history.joined(separator: " "))")
                    } else if let problem = invariantViolation(s) {
                        Check.fail("fuzz: \(problem) after redo-all of \(history.joined(separator: " "))")
                    } else {
                        Check.expect(true)
                    }
                }
            }
        }
    }
    print("  fuzz: \(steps) tokens processed")
}

import Foundation
import CheckKit
import VimKit

/// 1-based line number of the cursor.
func lineNo(_ s: VimSession) -> Int {
    1 + (s.text as NSString).substring(to: s.cursor).filter { $0 == "\n" }.count
}

func numberedLines(_ n: Int) -> String { (1...n).map(String.init).joined(separator: "\n") }

func hjklChecks() {
    vim("l", "|abc", "a|bc")
    vim("3l", "|abcdef", "abc|def")
    vim("10l", "|abc", "ab|c")
    vim("l", "ab|c", "ab|c")
    vim("h", "ab|c", "a|bc")
    vim("5h", "ab|c", "|abc")
    vim("h", "|abc", "|abc")
    vim("<Right>", "|abc", "a|bc")
    vim("<Left>", "a|bc", "|abc")
    vim("l", "|", "|")
    vim("l", "|a\nb", "|a\nb")                 // l never crosses the line end
    vim("<Space>", "a|\nb", "a\n|b")           // <Space> wraps to the next line

    // j / k keep the desired column.
    vim("j", "abcd|ef\nab\nabcdef", "abcdef\na|b\nabcdef")
    vim("jj", "abcd|ef\nab\nabcdef", "abcdef\nab\nabcd|ef")
    vim("jk", "abcd|ef\nab\nabcdef", "abcd|ef\nab\nabcdef")
    vim("k", "abc\nab|cd", "ab|c\nabcd")
    vim("j", "a|bc", "a|bc")                   // last line: no move
    vim("k", "a|bc", "a|bc")
    vim("2j", "|a\nb\nc\nd", "a\nb\n|c\nd")
    vim("5j", "|a\nb\nc", "a\nb\n|c")
    vim("$j", "|abc\nabcdef", "abc\nabcde|f")  // $ makes the column sticky at the line end
    vim("jl", "ab|cd\nx\nabcd", "abcd\n|x\nabcd")
    vim("j", "|\nabc", "\n|abc")
    vim("<Down>", "|a\nb", "a\n|b")
    vim("<Up>", "a\n|b", "|a\nb")
}

func lineMotionChecks() {
    vim("0", "ab|c", "|abc")
    vim("^", "   a|bc", "   |abc")
    vim("^", "|   ", "  | ")                   // all blank: last character
    vim("$", "|abc def", "abc de|f")
    vim("2$", "|ab\ncd\nef", "ab\nc|d\nef")
    vim("$", "a\n|\nb", "a\n|\nb")
    vim("g_", "|ab  ", "a|b  ")
    vim("3|", "|abcdef", "ab|cdef")
    vim("+", "|a\n  b", "a\n  |b")
    vim("-", "  a\n|b", "  |a\nb")
    vim("<Home>", "ab|c", "|abc")
    vim("<End>", "|abc", "ab|c")
    vim("$", "|a😀", "a|😀")                     // never inside a surrogate pair
}

func wordMotionChecks() {
    vim("w", "|foo bar", "foo |bar")
    vim("2w", "|foo bar baz", "foo bar |baz")
    vim("w", "|foo.bar", "foo|.bar")
    vim("ww", "|foo.bar", "foo.|bar")
    vim("W", "|foo.bar baz", "foo.bar |baz")
    vim("w", "foo |bar\nbaz", "foo bar\n|baz")
    vim("w", "|foo\n\nbar", "foo\n|\nbar")
    vim("ww", "|foo\n\nbar", "foo\n\n|bar")
    vim("w", "foo |bar", "foo ba|r")
    vim("b", "foo ba|r", "foo |bar")
    vim("b", "foo |bar", "|foo bar")
    vim("2b", "a b |c", "|a b c")
    vim("b", "foo\n|bar", "|foo\nbar")
    vim("b", "|foo", "|foo")
    vim("B", "a.b c.|d", "a.b |c.d")
    vim("b", "foo.ba|r", "foo.|bar")
    vim("e", "|foo bar", "fo|o bar")
    vim("ee", "|foo bar", "foo ba|r")
    vim("e", "fo|o bar", "foo ba|r")
    vim("E", "|a.b c", "a.|b c")
    vim("e", "|a.b", "a|.b")
    vim("ge", "foo ba|r", "fo|o bar")
    vim("ge", "a b |c", "a |b c")
    vim("2ge", "a b |c", "|a b c")
    vim("gE", "a.b c.|d", "a.|b c.d")
    vim("ge", "|foo", "|foo")
    vim("3w", "|a b c d", "a b c |d")
    vim("w", "|ação você", "ação |você")        // accented letters are word characters
    vim("e", "|ação você", "açã|o você")
}

func fileMotionChecks() {
    vim("G", "|a\nb\n  c", "a\nb\n  |c")
    vim("gg", "a\nb\n  |c", "|a\nb\n  c")
    vim("2G", "|a\n  b\nc", "a\n  |b\nc")
    vim("3gg", "|a\nb\nc\nd", "a\nb\n|c\nd")
    vim("9G", "|a\nb\nc", "a\nb\n|c")
    vim("G", "|a\nb\n", "a\n|b\n")              // the final line break does not create a line
    vim("gg", "x\ny|", "|x\ny")

    vim("}", "|a\nb\n\nc\nd\n\ne", "a\nb\n|\nc\nd\n\ne")
    vim("}}", "|a\nb\n\nc\nd\n\ne", "a\nb\n\nc\nd\n|\ne")
    vim("2}", "|a\nb\n\nc\nd\n\ne", "a\nb\n\nc\nd\n|\ne")
    vim("{", "a\nb\n\nc\n|d\n\ne", "a\nb\n|\nc\nd\n\ne")
    vim("}", "|a\nb", "a\n|b")                  // no blank line: end of the text
    vim("{", "a\n|b", "|a\nb")

    // %
    vim("%", "|(a [b] c)", "(a [b] c|)")
    vim("%", "(a [b] c|)", "|(a [b] c)")
    vim("%", "(a [|b] c)", "(a |[b] c)")
    vim("%", "|{ a }", "{ a |}")
    vim("%", "x |= (y)", "x = (y|)")
    vim("%", "|(a\n(b)\nc)", "(a\n(b)\nc|)")
    vim("%", "|\\{ x \\}", "\\{ x \\|}")        // \{ pairs with \} only
    vim("%", "|(abc", "|(abc")                  // unmatched: no move
}

func findMotionChecks() {
    vim("f,", "|a,b,c,d", "a|,b,c,d")
    vim("f,;", "|a,b,c,d", "a,b|,c,d")
    vim("f,;,", "|a,b,c,d", "a|,b,c,d")
    vim("2f,", "|a,b,c", "a,b|,c")
    vim("t,", "|ab,cd,ef", "a|b,cd,ef")
    vim("t,;", "|ab,cd,ef", "ab,c|d,ef")        // ; after t skips the adjacent match
    vim("F,", "a,b,|c", "a,b|,c")
    vim("T,", "a,b,cd|e", "a,b,|cde")
    vim("fz", "|abc", "|abc")                   // not found: no move
    vim("fx", "|ab\nx", "|ab\nx")               // f never leaves the line
    vim("f😀", "|ab😀c", "ab|😀c")
    vim("fç", "|ação", "a|ção")
    vim("3F.", "a.b.c.d|e", "a|.b.c.de")
}

func screenMotionChecks() {
    let doc = numberedLines(8)
    var s = VimSession("|" + doc)
    s.buffer.visibleLines = 3...6
    s.feed("H")
    Check.equal(lineNo(s), 3, "H goes to the top visible line")
    s.feed("L")
    Check.equal(lineNo(s), 6, "L goes to the bottom visible line")
    s.feed("M")
    Check.equal(lineNo(s), 4, "M goes to the middle visible line")
    s.feed("3H")
    Check.equal(lineNo(s), 5, "3H goes to the third visible line")
    s.feed("2L")
    Check.equal(lineNo(s), 5, "2L goes to the second line from the bottom")

    s = VimSession("|" + numberedLines(30))
    s.buffer.visibleLines = 1...10
    s.feed("<C-d>")
    Check.equal(lineNo(s), 6, "Ctrl-d scrolls half a page")
    s.feed("<C-u>")
    Check.equal(lineNo(s), 1, "Ctrl-u scrolls half a page back")
    s.feed("<C-f>")
    Check.equal(lineNo(s), 9, "Ctrl-f scrolls a page minus two lines")
    s.feed("<C-b>")
    Check.equal(lineNo(s), 1, "Ctrl-b scrolls back")
    s.feed("20G<C-u>")
    Check.equal(lineNo(s), 15, "Ctrl-u from line 20")
    s.feed("<C-d>")
    Check.equal(lineNo(s), 20, "Ctrl-d returns to line 20")
    s.feed("G<C-d>")
    Check.equal(lineNo(s), 30, "Ctrl-d on the last line stays")
}

func markChecks() {
    vim("majj'a", "one\n|two\nthree\nfour", "one\n|two\nthree\nfour")
    vim("majj`a", "one\nt|wo\nthree\nfour", "one\nt|wo\nthree\nfour")
    vim("ma$`a", "o|ne", "o|ne")
    vim("majG'a", "  o|ne\ntwo\nthree", "  |one\ntwo\nthree")
    vim("mbgg'b", "x\n  |y", "x\n  |y")
    vim("G''", "|a\nb\nc", "|a\nb\nc")           // '' returns to the position before the jump
    vim("d'a", "a\n|b\nc", "a\n|b\nc")           // mark not set: nothing happens
    // Marks follow edits above them.
    vim("jmaggOnew<Esc>'a", "|x\ny", "new\nx\n|y")
    vim("jjmaggd'a", "|x\ny\nz", "|")
}

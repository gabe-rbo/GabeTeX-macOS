import Foundation
import CheckKit
import VimKit

func deleteOperatorChecks() {
    vim("dw", "|foo bar", "|bar")
    vim("d2w", "|a b c", "|c")
    vim("2dw", "|a b c", "|c")
    vim("2d3w", "|a b c d e f g", "|g")
    vim("3dw", "|a b", "|")
    vim("dw", "foo |bar\nbaz", "foo| \nbaz")        // dw stops at the end of the line
    vim("dw", "foo |bar", "foo| ")
    vim("dW", "|a.b c", "|c")
    vim("db", "foo |bar", "|bar")
    vim("de", "|foo bar", "| bar")
    vim("d$", "ab|cd", "a|b")
    vim("d0", "ab|cd", "|cd")
    vim("d^", "  ab|cd", "  |cd")
    vim("D", "ab|cd", "a|b")
    vim("d$", "a\n|\nb", "a\n|\nb")
    vim("dgg", "a\nb\n|c", "|")
    vim("dG", "a\n|b\nc", "|a")
    vim("dj", "|a\nb\nc", "|c")
    vim("dk", "a\nb\n|c", "|a")
    vim("dk", "|a\nb", "|a\nb")                      // fails on the first line
    vim("dj", "a\n|b", "a\n|b")                      // fails on the last line
    vim("d}", "|a\nb\n\nc", "|\nc")                   // exclusive motion ending in column 0 becomes linewise
    vim("d%", "|(a b) c", "| c")
    vim("dfx", "|abxcd", "|cd")
    vim("dtx", "|abxcd", "|xcd")
    vim("df,", "|a,b,c", "|b,c")
    vim("dh", "ab|c", "a|c")
    vim("dl", "a|bc", "a|c")
    vim("d3l", "|abcde", "|de")
    vim("dd", "a\n|b\nc", "a\n|c")
    vim("dd", "a\n|b", "|a")
    vim("dd", "|abc", "|")
    vim("2dd", "|a\nb\nc", "|c")
    vim("3dd", "a\n|b\nc", "|a")                     // fewer lines than the count: delete what exists
    vim("2dd", "a\n|b", "a\n|b")                     // on the last line a count > 1 fails
    vim("d2d", "|a\nb\nc", "|c")
    vim("dd", "a\n    |b\n  c", "a\n  |c")
    vim("jdd", "|a\r\nb\r\nc", "a\r\n|c")
    vim("dd", "|a\n\nb", "|\nb")
    vim("dip", "|a\nb\n\nc", "|\nc")
    vim("dw", "|ação você", "|você")
}

func changeOperatorChecks() {
    vim("cwX<Esc>", "|foo bar", "|X bar")
    vim("cwX<Esc>", "|a b", "|X b")                  // one-character word
    vim("cwX<Esc>", "foo|  bar", "foo|Xbar")        // on blanks cw acts like dw
    vim("c2wX<Esc>", "|a b c", "|X c")
    vim("cWX<Esc>", "|a.b c", "|X c")
    vim("ceX<Esc>", "|foo bar", "|X bar")
    vim("cbX<Esc>", "foo |bar", "|Xbar")
    vim("cwX<Esc>", "foo |bar", "foo |X")
    vim("ccX<Esc>", "  |foo\nbar", "  |X\nbar")      // autoindent keeps the indent
    vim("SX<Esc>", "  |foo\nbar", "  |X\nbar")
    vim("ccX<Esc>", "a\n|\nb", "a\n|X\nb")
    vim("2ccX<Esc>", "|a\nb\nc", "|X\nc")
    vim("CX<Esc>", "foo |bar baz", "foo |X")
    vim("sX<Esc>", "|abc", "|Xbc")
    vim("3sX<Esc>", "|abcde", "|Xde")
    vim("sX<Esc>", "|", "|X")                        // s on an empty line still inserts
    vim("c$X<Esc>", "ab|cd", "ab|X")
    vim("c0X<Esc>", "ab|cd", "|Xcd")
    vim("cjX<Esc>", "|a\nb\nc", "|X\nc")
    vim("cl", "|abc", "|bc", mode: .insert)
    vim("cwfoo<Esc>", "|a-b", "fo|o-b")
    vim("cc", "|abc", "|", mode: .insert)
}

func yankOperatorChecks() {
    vim("yw", "foo |bar baz", "foo |bar baz")
    vim("yb", "foo |bar", "|foo bar")
    vim("y$", "a|bcd", "a|bcd")
    vim("yy", "a|bc", "a|bc")
    vim("yj", "a|b\ncd", "a|b\ncd")
    vim("yk", "ab\nc|d", "a|b\ncd")                  // cursor moves to the start of the yanked lines
    vim("y0", "ab|cd", "|abcd")
    vim("yiw", "foo b|ar", "foo |bar")
    vim("yip", "a\nb|\n\nc", "|a\nb\n\nc")
    vim("ygg", "a\nb\n|c", "|a\nb\nc")
}

func shiftOperatorChecks() {
    vim(">>", "|foo", "  |foo")
    vim(">>", "fo|o", "  |foo")
    vim("2>>", "|a\nb\nc", "  |a\n  b\nc")
    vim(">j", "|a\nb\nc", "  |a\n  b\nc")
    vim("<<", "    |foo", "  |foo")
    vim("<<", "|  foo", "|foo")
    vim("<<", "| foo", "|foo")
    vim("<<", "|foo", "|foo")
    vim(">>", "|", "|")                              // empty lines are not indented
    vim(">>>>", "|a", "    |a")
    vim("3>>", "|a\n\nb", "  |a\n\n  b")
    vim(">ip", "|a\nb\n\nc", "  |a\n  b\n\nc")
    vim(">G", "a\n|b\nc", "a\n  |b\n  c")
    vim("<k", "  a\n  |b", "|a\nb")

    var s = VimSession("|foo\nbar")
    s.engine.indentUnit = "\t"
    s.feed(">>j>>")
    Check.equal(s.text, "\tfoo\n\tbar", "indentUnit is a tab")
    s.feed("<<")
    Check.equal(s.text, "\tfoo\nbar", "<< removes one tab")

    s = VimSession("|foo")
    s.engine.indentUnit = "    "
    s.feed(">>")
    Check.equal(s.text, "    foo", "indentUnit of four spaces")
    s.feed(">>")
    Check.equal(s.text, "        foo", "second shift")
    s.feed("<<")
    Check.equal(s.text, "    foo", "unshift")
}

func caseOperatorChecks() {
    vim("gUiw", "foo |bar", "foo |BAR")
    vim("guiw", "FOO |BAR", "FOO |bar")
    vim("g~iw", "foo |Bar", "foo |bAR")
    vim("gUU", "foo |bar", "FOO |BAR")
    vim("guu", "FOO |BAR", "foo |bar")
    vim("g~~", "Fo|o", "fO|O")
    vim("gUgU", "|ab", "|AB")
    vim("gUw", "|foo bar", "|FOO bar")
    vim("gU$", "foo |bar", "foo |BAR")
    vim("g~l", "|abc", "|Abc")
    vim("gUj", "|a\nb\nc", "|A\nB\nc")
    vim("gUiw", "|ação", "|AÇÃO")
    vim("guiw", "|AÇÃO", "|ação")
    vim("gUiw", "|straße", "|STRASSE")                // length-changing mapping
    vim("g~iw", "|ação", "|AÇÃO")
    vim("gUap", "|a\nb\n\nc", "|A\nB\n\nc")
}

func countChecks() {
    vim("3x", "|abcdef", "|def")
    vim("2d2w", "|a b c d e", "|e")
    vim("2dd", "a\n|b\nc\nd", "a\n|d")
    vim("d2d", "a\n|b\nc\nd", "a\n|d")
    vim("2yyP", "|a\nb", "|a\nb\na\nb")
    vim("3ix<Esc>", "|a", "xx|xa")
    vim("2ofoo<Esc>", "|a", "a\nfoo\nfo|o")
    vim("2Ox<Esc>", "|a", "x\n|x\na")
    vim("3A!<Esc>", "|a", "a!!|!")
    vim("2I-<Esc>", "  |a", "  -|-a")
    vim("5~", "|ab", "A|B")
    vim("2J", "|a\nb\nc", "a| b\nc")
    vim("3J", "|a\nb\nc\nd", "a b| c\nd")
    vim("2rx", "|abc", "x|xc")
    vim("010G", "|1\n2", "1\n|2")                     // a leading 0 is a motion, but 10 > line count -> last line
    vim("3p", "|a", "|a")                            // nothing yanked: nothing happens
    vim("2.", "|a", "|a")                            // nothing to repeat
}

import Foundation
import CheckKit
import VimKit

func simpleEditChecks() {
    // x X
    vim("x", "a|bc", "a|c")
    vim("x", "ab|c", "a|b")
    vim("x", "a\n|\nb", "a\n|\nb")                    // x on an empty line does nothing
    vim("x", "|", "|")
    vim("X", "ab|c", "a|c")
    vim("X", "|abc", "|abc")
    vim("3x", "|abcdef", "|def")
    vim("5x", "a|bc", "|a")
    vim("x", "a|\nb", "|\nb")                          // the cursor was clamped onto 'a'
    vim("D", "ab|cd", "a|b")
    vim("2D", "a|b\ncd\nef", "|a\nef")                 // D with a count also eats the next lines
    vim("Yp", "|a\nb", "a\n|a\nb")

    // r
    vim("rx", "|abc", "|xbc")
    vim("3rx", "|abc", "xx|x")
    vim("4rx", "|abc", "|abc")                         // not enough characters: nothing happens
    vim("rx", "|", "|")
    vim("r<CR>", "ab|cd", "ab\n|d")
    vim("rç", "|abc", "|çbc")
    vim("r😀", "|abc", "|😀bc")
    vim("rx", "|😀b", "|xb")
    vim("r<Esc>x", "|abc", "|bc")                      // r<Esc> cancels

    // ~
    vim("~", "|abc", "A|bc")
    vim("3~", "|abc", "AB|C")
    vim("~", "a|B", "a|b")
    vim("~", "|", "|")
    vim("4~", "|ação", "AÇÃ|O")
    vim("~", "|1+x", "1|+x")
    vim("5~", "|ab", "A|B")

    // J gJ
    vim("J", "|foo\nbar", "foo| bar")
    vim("J", "|foo\n   bar", "foo| bar")
    vim("J", "|foo \nbar", "foo |bar")
    vim("J", "|foo\n)bar", "foo|)bar")
    vim("J", "|foo\n\nbar", "fo|o\nbar")
    vim("J", "a\n|b", "a\n|b")                        // last line: nothing to join
    vim("2J", "|a\nb\nc", "a| b\nc")
    vim("3J", "|a\nb\nc\nd", "a b| c\nd")
    vim("J", "|foo\n\t bar", "foo| bar")
    vim("gJ", "|foo\n  bar", "foo|  bar")
    vim("J", "|\nbar", "|bar")
    vim("9J", "|a\nb", "a| b")                         // a large count joins what exists
    vim("J", "|a\r\nb", "a| b")
    vim("JJ", "|a\nb\nc", "a b| c")
}

func putChecks() {
    vim("yw$p", "|foo bar", "foo barfoo| ")
    vim("yyp", "|a\nb", "a\n|a\nb")
    vim("yyP", "|a\nb", "|a\na\nb")
    vim("yy3p", "|a\nb", "a\n|a\na\na\nb")
    vim("ddp", "|a\nb", "b\n|a")
    vim("xp", "|ab", "b|a")
    vim("yl3p", "|ab", "aaa|ab")
    vim("yiwP", "|foo", "fo|ofoo")
    vim("yljp", "|a\n\nb", "a\n|a\nb")                 // p on an empty line
    vim("yygp", "|a\nb", "a\na\n|b")
    vim("yygP", "|a\nb", "a\n|a\nb")
    vim("ywgp", "|ab cd", "aab |b cd")
    vim("yyP", "a\n|b", "a\n|b\nb")
    vim("yyp", "|a\n", "a\n|a\n")
    vim("yyp", "  |a", "  a\n  |a")
    vim("p", "|a", "|a")                               // empty register
    vim("yyjp", "|a\nb", "a\nb\n|a")
    vim("yyjp", "|a\r\nb", "a\r\nb\r\n|a")             // CRLF documents keep their terminator
    vim("ylp", "|a", "a|a")
    vim("yl.", "|a", "|a")
    vim("ylp.", "|a", "aa|a")
    vim("yiw$p", "|foo bar", "foo barfo|o")
}

func undoRedoChecks() {
    vim("dwu", "|foo bar", "|foo bar")
    vim("xu", "a|bc", "a|bc")
    vim("3xu", "|abcdef", "|abcdef")                   // one undo group per change
    vim("ciwX<Esc>u", "foo b|ar baz", "foo |bar baz")
    vim("ofoo<Esc>u", "|a", "|a")
    vim("ihello<Esc>u", "|abc", "|abc")
    vim("xxxuu", "|abcdef", "|bcdef")
    vim("xxx3u", "|abcdef", "|abcdef")
    vim("xxx2u", "|abcdef", "|bcdef")
    vim("dwu<C-r>", "|foo bar", "|bar")
    vim("xxuu<C-r><C-r>", "|abcd", "|cd")
    vim("xu<C-r>", "a|bcd", "a|cd")
    vim("3ofoo<Esc>u", "|a", "|a")
    vim("ddu", "a\n|b", "a\n|b")
    vim("yypu", "|a\nb", "|a\nb")
    vim("u", "|a", "|a")                               // nothing to undo
    vim("<C-r>", "|a", "|a")
    vim(">>u", "  |a", "  |a")
    vim("Jx", "|a\nb", "a|b")
    vim("ixy<Esc>xu", "|ab", "x|yab")

    // One undo group per change, however many edits it makes.
    func groups(_ keys: String, _ text: String) -> Int { run(keys, on: text).buffer.undoGroups }
    Check.equal(groups("ciwX<Esc>", "foo b|ar"), 1, "ciw + typing")
    Check.equal(groups("3ofoo<Esc>", "|a"), 1, "3o")
    Check.equal(groups("ihello<Esc>", "|a"), 1, "insert")
    Check.equal(groups(">>", "|a\nb"), 1, ">>")
    Check.equal(groups(">j", "|a\nb"), 1, ">j shifts two lines in one group")
    Check.equal(groups("J", "|a\nb"), 1, "J")
    Check.equal(groups("ddp", "|a\nb"), 2, "dd and p are two changes")
    Check.equal(groups("gUU", "|abc"), 1, "gUU")
    Check.equal(groups(":%s/a/b/g<CR>", "|a a\na a\na"), 1, ":%s over many lines")
    Check.equal(groups("Rxyz<Esc>", "|abcdef"), 1, "replace mode")
    Check.equal(groups("x.", "|abc"), 2, "x and . are separate groups")
    Check.equal(groups("i<Esc>", "|abc"), 0, "an empty insert leaves no undo entry")
    Check.equal(groups("yyp", "|a"), 1, "yyp")
    Check.equal(groups("Vjd", "|a\nb\nc"), 1, "visual delete")
    Check.equal(groups("5ix<Esc>", "|a"), 1, "counted insert")
    let s = run("ihello", on: "|abc")
    Check.equal(s.buffer.groupDepth, 1, "the undo group stays open while inserting")
    s.feed("<Esc>")
    Check.equal(s.buffer.groupDepth, 0, "and is closed by Esc")
}

func dotRepeatChecks() {
    vim("x.", "|abcd", "|cd")
    vim("dw.", "|a b c d", "|c d")
    vim("3x.", "|abcdefgh", "|gh")
    vim("x2.", "|abcdefg", "|defg")
    vim("ciwX<Esc>w.", "|foo bar baz", "X |X baz")
    vim("cwfoo<Esc>w.", "|a b c", "foo fo|o c")
    vim("A;<Esc>j.", "|a\nb", "a;\nb|;")
    vim("ofoo<Esc>.", "|a", "a\nfoo\nfo|o")
    vim("ofoo<CR>bar<Esc>.", "|a", "a\nfoo\nbar\nfoo\nba|r")
    vim("ihi <Esc>.", "|x", "hihi|  x")
    vim("3ix<Esc>.", "|a", "xxxx|xxa")
    vim("rxl.", "|abc", "x|xc")
    vim("~.", "|abcd", "AB|cd")
    vim("J.", "|a\nb\nc", "a b| c")
    vim("dd.", "|a\nb\nc", "|c")
    vim(">>.", "|a", "    |a")
    vim("ylp.", "|a", "aa|a")
    vim("gUiww.", "|foo bar", "FOO |BAR")
    vim("vlld.", "|abcdefgh", "|gh")
    vim("Vjd.", "|a\nb\nc\nd\ne", "|e")
    vim("Vj>jj.", "|a\nb\nc\nd", "  a\n  b\n  |c\n  d")
    vim("Rxy<Esc>l.", "|abcdef", "xyx|yef")
    vim("xl" + "yl" + ".", "|ab", "|")
    vim("p.", "|a", "|a")                              // nothing to put, nothing to repeat
    vim("dap.", "|a\n\nb\n\nc", "|c")
    vim("daw.", "|a b c d", "|c d")
    vim("d2w.", "|a b c d e f", "|e f")
    vim("2dd.", "|a\nb\nc\nd\ne", "|e")
    vim("ci(X<Esc>f(l.", "(a|)(b)", "(X)(|X)")
    vim("A!<Esc>0.", "|a", "a!|!")
    vim("I-<Esc>.", "|a", "|--a")
    vim("O-<Esc>j.", "|a", "-\n|-\na")
    vim("sX<Esc>l.", "|abc", "X|Xc")
    vim("Cz<Esc>.", "|abc", "|z")
    vim("x.", "|a", "|")                               // repeat on a now empty line: nothing happens
    vim(".", "|abc", "|abc")                           // nothing to repeat
    vim("xu.", "|abc", "|bc")                          // u does not change what . repeats
}

func insertModeChecks() {
    vim("ifoo<Esc>", "|bar", "fo|obar")
    vim("afoo<Esc>", "b|ar", "bafo|or")
    vim("Ifoo<Esc>", "  |bar", "  fo|obar")
    vim("Afoo<Esc>", "|bar", "barfo|o")
    vim("ofoo<Esc>", "|a\nb", "a\nfo|o\nb")
    vim("Ofoo<Esc>", "a\n|b", "a\nfo|o\nb")
    vim("ox<Esc>", "  |a", "  a\n  |x")
    vim("Ox<Esc>", "  |a", "  |x\n  a")
    vim("ox<Esc>", "|a\r\nb", "a\r\n|x\r\nb")
    vim("ox<Esc>", "a\r\n|b", "a\r\nb\r\n|x")
    vim("gIx<Esc>", "  |a", "|x  a")
    vim("Ax<Esc>0giy<Esc>", "|ab", "abx|y")
    vim("ax<Esc>", "|", "|x")
    vim("ix<Esc>", "|", "|x")
    vim("Ax<Esc>", "a\n|\nb", "a\n|x\nb")
    vim("i", "|abc", "|abc", mode: .insert)
    vim("a", "|abc", "a|bc", mode: .insert)
    vim("a", "ab|c", "abc|", mode: .insert)
    vim("A", "|abc", "abc|", mode: .insert)
    vim("I", "  |abc", "  |abc", mode: .insert)
    vim("ix<Esc>", "|abc", "|xabc")
    vim("ixy<Esc>", "a|bc", "ax|ybc")
    vim("i<Esc>", "a|bc", "|abc")                      // Esc steps left
    vim("i<Esc>", "|abc", "|abc")
    vim("A<Esc>", "ab|c", "ab|c")
    vim("ix<BS><Esc>", "a|bc", "|abc")                 // host-handled backspace
    vim("ix<Left>y<Esc>", "a|bc", "a|yxbc")            // cursor keys are left to the host
    vim("i<Tab><Esc>", "|a", "|\ta")
    vim("ifoo<CR>bar<Esc>", "|x", "foo\nba|rx")
    vim("i<C-o>lX<Esc>", "|abc", "a|Xbc")              // Ctrl-o runs one normal command
    vim("ihello<Esc>", "|", "hell|o")
    vim("ia😀<Esc>", "|b", "a|😀b")                    // the cursor never lands inside a surrogate pair

    // R
    vim("Rxy<Esc>", "|abcdef", "x|ycdef")
    vim("Rxy<BS><Esc>", "|abcdef", "|xbcdef")
    vim("Rxyz<Esc>", "|ab", "xy|z")
    vim("3Rxy<Esc>", "|abcdefgh", "xyxyx|ygh")
    vim("R", "|abc", "|abc", mode: .replace)
    vim("Rx<CR>y<Esc>", "|abc", "x\n|yc")
    vim("Rç<Esc>", "|ação", "|çção")
    vim("R😀<Esc>", "|abc", "|😀bc")

    // Insert-mode keys belong to the host.
    let s = VimSession("|abc")
    s.feed("i")
    let n = s.consumedLog.count
    s.feed("a")
    s.feed("<Left>")
    s.feed("<BS>")
    s.feed("<CR>")
    s.feed("<Esc>")
    Check.equal(Array(s.consumedLog[n...]), [false, false, false, false, true], "printable and editing keys return false")
    Check.equal(s.engine.mode, .normal)
    let t = VimSession("|abc")
    t.feed("i<C-r>")
    Check.equal(t.consumedLog.last, true, "Ctrl-r is consumed in insert mode")

    // Registers from insert mode.
    vim("yiwA <C-r>0<Esc>", "|foo", "foo fo|o")
    vim("yiwA <C-r><C-r><Esc>", "|foo", "foo| ")        // unknown register: nothing inserted
    vim("ixy<Esc>A<C-r>.<Esc>", "|ab", "xyabx|y")      // the ". register holds the last insert
}

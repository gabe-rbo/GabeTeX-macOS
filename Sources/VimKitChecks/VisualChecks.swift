import Foundation
import CheckKit
import VimKit

func visualChecks() {
    // Selection shapes.
    var s = run("vll", on: "|abcdef")
    Check.equal(s.markedSelection, "[abc]def", "vll")
    Check.equal(s.mode, .visual)
    s = run("v", on: "a|bc")
    Check.equal(s.markedSelection, "a[b]c", "v selects the character under the cursor")
    s = run("Vj", on: "|a\nb\nc")
    Check.equal(s.selectedText, "a\nb\n", "Vj selects whole lines")
    Check.equal(s.mode, .visualLine)
    s = run("vj", on: "a|bc\ndef")
    Check.equal(s.selectedText, "bc\nde", "vj keeps the column")
    s = run("v$", on: "|ab\ncd")
    Check.equal(s.selectedText, "ab\n", "v$ includes the line break")
    s = run("vllo", on: "|abcdef")
    Check.equal(s.markedSelection, "[abc]def", "o keeps the selection")
    Check.equal(s.cursor, 0, "o moves the cursor to the other end")
    s = run("vV", on: "|a\nb")
    Check.equal(s.mode, .visualLine, "v then V switches to linewise")
    s = run("Vv", on: "|a\nb")
    Check.equal(s.mode, .visual, "V then v switches to characterwise")
    s = run("vv", on: "|ab")
    Check.equal(s.mode, .normal, "v twice leaves visual mode")
    s = run("VV", on: "|ab")
    Check.equal(s.mode, .normal, "V twice leaves visual mode")
    s = run("vll<Esc>gv", on: "|abcdef")
    Check.equal(s.selectedText, "abc", "gv reselects")
    s = run("vlw", on: "|ab cd")
    Check.equal(s.selectedText, "ab c", "motions extend the selection")
    s = run("vG", on: "|a\nb\nc")
    Check.equal(s.selectedText, "a\nb\nc", "vG")

    // Operators.
    vim("vlld", "|abcdef", "|def")
    vim("viwd", "foo b|ar baz", "foo | baz")
    vim("vjd", "a|bc\ndef", "a|f")
    vim("Vd", "a\n|b\nc", "a\n|c")
    vim("Vjd", "|a\nb\nc", "|c")
    vim("vd", "a|bc", "a|c")
    vim("vx", "a|bc", "a|c")
    vim("v$d", "|ab\ncd", "|cd")
    vim("vd", "a\n|\nb", "a\n|b")                         // deleting the line break of an empty line
    vim("vGd", "|a\nb\nc", "|")
    vim("vlllhd", "|abcdef", "|def")
    vim("vlohd", "ab|cd", "|a")
    vim("vllold", "|abcdef", "a|def")
    vim("vlcX<Esc>", "|abc", "|Xc")
    vim("vls", "|abc", "|c", mode: .insert)
    vim("vly$p", "|abc", "abca|b")
    vim("vjy", "a|b\ncd", "a|b\ncd")                       // yank leaves the cursor at the start
    vim("vD", "a|bc\ndef", "|def")                        // D works on whole lines
    vim("vlC", "|abc\ndef", "|\ndef", mode: .insert)
    vim("vlY$p", "|ab\ncd", "ab\n|ab\ncd")
    vim("v<Esc>", "a|bc", "a|bc")
    vim("vl<Esc>", "a|bc", "ab|c")
    vim("vlrx", "|abcd", "|xxcd")
    vim("vlllr😀", "|abcd", "|😀😀😀😀")

    // Shifting.
    vim("V>", "|a\nb", "  |a\nb")
    vim("Vj>", "|a\nb", "  |a\n  b")
    vim("Vj<", "  |a\n  b", "|a\nb")
    vim("V3>", "|a", "      |a")
    vim("vj>", "a|b\ncd\nef", "  |ab\n  cd\nef")

    // Case.
    vim("vl~", "|abc", "|ABc")
    vim("vlU", "|abc", "|ABc")
    vim("vlu", "|ABC", "|abC")
    vim("Vgu", "|ABC", "|abc")
    vim("VgU", "|abc", "|ABC")
    vim("vlg~", "|aBc", "|Abc")
    vim("vipU", "|a\nb\n\nc", "|A\nB\n\nc")

    // Join.
    vim("VjJ", "|a\nb\nc", "a| b\nc")
    vim("vjJ", "|a\nb\nc", "a| b\nc")
    vim("VjjJ", "|a\nb\nc", "a b| c")
    vim("vJ", "|a\nb", "a| b")                            // a one-line selection joins with the next line
    vim("VjgJ", "|a\n b", "a| b")

    // Put.
    vim("yiwwviwp0P", "|foo bar", "ba|rfoo foo")          // p swaps the register with the selection
    vim("yyjVp", "|a\nb", "a\n|a")
    vim("yiwwviwP$p", "|foo bar", "foo foofo|o")            // P keeps the register
    vim("yiwjvlp", "|foo\nab", "foo\nfo|o")
    vim("yyvlp", "|ab\ncd", "\n|ab\n\ncd")                  // a linewise register splits the line
    vim("yiwVjp", "|a\nb\nc", "|a\nc")

    // Command line from visual mode.
    vim("vj:s/a/X/<CR>", "|a\na\na", "X\n|X\na")
    let c = run("vj:", on: "|a\nb")
    Check.equal(c.engine.commandLine, ":'<,'>", "the range is pre-filled")
    Check.equal(c.engine.mode, .commandLine)
    c.feed("<Esc>")
    Check.equal(c.engine.mode, .normal)
}

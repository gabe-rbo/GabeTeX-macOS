import Foundation
import CheckKit
import VimKit

func exCommandChecks() {
    func ex(_ line: String, _ text: String = "|a") -> [VimExCommand] { run(line + "<CR>", on: text).exCommands }
    Check.equal(ex(":w"), [.write], ":w")
    Check.equal(ex(":write"), [.write], ":write")
    Check.equal(ex(":q"), [.quit], ":q")
    Check.equal(ex(":quit"), [.quit], ":quit")
    Check.equal(ex(":wq"), [.writeQuit], ":wq")
    Check.equal(ex(":x"), [.writeQuit], ":x")
    Check.equal(ex(":wq!"), [.writeQuit], ":wq!")
    Check.equal(ex(":wa"), [.writeAll], ":wa")
    Check.equal(ex(":wall"), [.writeAll], ":wall")
    Check.equal(ex(":make"), [.compile], ":make")
    Check.equal(ex(":TeX"), [.compile], ":TeX")
    Check.equal(ex(":foo bar"), [.unknown("foo bar")], "unknown commands go to the host")
    Check.equal(ex(":e other.tex"), [.unknown("e other.tex")], ":e")
    Check.equal(ex(":3", "|a\nb\nc\nd"), [.goToLine(3)], ":3")
    Check.equal(ex(":99", "|a\nb"), [.goToLine(2)], "a line number past the end clamps")
    Check.equal(run("ZZ", on: "|a").exCommands, [.writeQuit], "ZZ")
    Check.equal(run("ZQ", on: "|a").exCommands, [.quit], "ZQ")
    Check.equal(run(":w<Esc>", on: "|a").exCommands, [], "Esc cancels the command line")

    vim(":3<CR>", "|a\nb\n  c\nd", "a\nb\n  |c\nd")
    vim(":2<CR>", "a\n|b", "a\n|b")
    vim(":$<CR>", "|a\nb\nc", "a\nb\n|c")
    vim(":1<CR>", "a\nb\n|c", "|a\nb\nc")
    vim(":0<CR>", "a\nb\n|c", "|a\nb\nc")

    // :s
    vimText(":s/a/b/<CR>", "|aaa", "baa")
    vimText(":s/a/b/g<CR>", "|aaa", "bbb")
    vimText(":s/a/b/<CR>", "x\n|aa\naa", "x\nba\naa")
    vimText(":%s/a/b/g<CR>", "|aa\naa", "bb\nbb")
    vimText(":%s/a/b/<CR>", "|aa\naa", "ba\nba")
    vimText(":2,3s/x/y/<CR>", "x\nx\nx\nx", "x\ny\ny\nx")
    vimText(":.,$s/x/y/<CR>", "x\nx|\nx", "x\ny\ny")
    vimText(":s#a#b#<CR>", "|a/a", "b/a")
    vimText(":s/a/\\//<CR>", "|a", "/")
    vimText(":s/\\./,/g<CR>", "|a.b.c", "a,b,c")
    vimText(":s/a.c/X/<CR>", "|abc a.c", "X a.c")
    vimText(":%s/\\(\\w\\+\\)@\\(\\w\\+\\)/\\2 at \\1/<CR>", "|me@host\nyou@there", "host at me\nthere at you")
    vimText(":s/\\(a\\)\\(b\\)/\\2\\1/<CR>", "|abab", "baab")
    vimText(":s/foo/[&]/<CR>", "|foo", "[foo]")
    vimText(":s/foo/\\u&/<CR>", "|foo", "Foo")
    vimText(":s/foo/\\U&/<CR>", "|foo bar", "FOO bar")
    vimText(":s/\\(foo\\) \\(bar\\)/\\U\\1\\E \\2/<CR>", "|foo bar", "FOO bar")
    vimText(":s/\\w\\+/\\u&/g<CR>", "|foo bar", "Foo Bar")
    vimText(":s/a/\\r/<CR>", "|bab", "b\nb")
    vimText(":%s/^/> /<CR>", "|a\nb", "> a\n> b")
    vimText(":%s/$/;/<CR>", "|a\nb", "a;\nb;")
    vimText(":%s/x//g<CR>", "|axbxc", "abc")
    vimText(":s/\\<foo\\>/bar/g<CR>", "|foo food foo", "bar food bar")
    vimText(":s/a\\|b/X/g<CR>", "|abc", "XXc")
    vimText(":s/a\\+/X/<CR>", "|baaac", "bXc")
    vimText(":s/\\s\\+/ /g<CR>", "|a   b    c", "a b c")
    vimText(":s/\\\\textbf{\\(.\\{-}\\)}/\\1/<CR>", "|\\textbf{x} y", "x y")
    vimText(":s/a/b/<CR>", "|c", "c")                          // no match: unchanged
    vimText(":s/A/b/<CR>", "|a", "a")                          // smartcase: an upper-case letter makes it exact
    vimText(":s/A/b/i<CR>", "|a", "b")
    vimText(":s/a/b/I<CR>", "|A a", "A b")
    vimText(":s/[abc]/X/g<CR>", "|a-b-c", "X-X-X")
    vimText(":s/[^-]/X/g<CR>", "|a-b", "X-X")
    vimText(":s/(a)/X/<CR>", "|(a)", "X")                      // plain parentheses are literal in Vim's magic mode
    vimText(":s/a\\{2}/X/<CR>", "|aaa", "Xa")
    vimText(":s/\\v(a|b)+/X/<CR>", "|abab c", "X c")
    vimText(":s/.*/&&/<CR>", "|ab", "abab")
    vim(":s/a/b/<CR>", "x\n|a", "x\n|b")
    vim(":%s/a/b/g<CR>", "x\na\n|c", "x\n|b\nc")                // the cursor goes to the last substituted line
    vimText(":s/a/b/<CR>:s<CR>", "|aa", "bb")
    vimText(":s/a/b/g<CR>j&", "|aa\naa", "bb\nba")
    vimText(":s/a/b/g<CR>j:&&<CR>", "|aa\naa", "bb\nbb")

    // Visual range.
    vimText("Vj:s/a/X/<CR>", "|a\na\na", "X\nX\na")
    vimText("Vj:s/a/X/<CR>", "a\n|a\na\na", "a\nX\nX\na")

    // Other line commands.
    vimText(":2d<CR>", "a\nb\nc", "a\nc")
    vimText(":1,2d<CR>", "a\nb\nc", "c")
    vimText(":$d<CR>", "a\nb\nc", "a\nb")
    vimText(":d<CR>", "a\nb", "b")
    vimText(":2,3><CR>", "a\nb\nc\nd", "a\n  b\n  c\nd")
    vimText(":2<<CR>", "a\n    b", "a\n  b")
    vimText(":y<CR>p", "|a\nb", "a\na\nb")
    vimText(":j<CR>", "|a\nb\nc", "a b\nc")
    vimText(":1,3j<CR>", "|a\nb\nc\nd", "a b c\nd")
    vimText(":u<CR>", "|a", "a")
    vimText("x:undo<CR>", "|ab", "ab")
    vimText("xu:red<CR>", "|ab", "b")
    vimText(":d x<CR>\"xp", "|a\nb", "b\na")

    // Command-line editing.
    var s = run(":", on: "|abc")
    Check.equal(s.engine.mode, .commandLine)
    Check.equal(s.engine.commandLine, ":", "the prompt")
    s.feed("s/a")
    Check.equal(s.engine.commandLine, ":s/a")
    s.feed("<BS>")
    Check.equal(s.engine.commandLine, ":s/")
    s.feed("<C-u>")
    Check.equal(s.engine.commandLine, ":")
    s.feed("foo bar<C-w>")
    Check.equal(s.engine.commandLine, ":foo ", "Ctrl-w deletes a word")
    s.feed("<BS><BS><BS><BS><BS><BS>")
    Check.equal(s.engine.mode, .normal, "backspace on an empty command line cancels it")
    s = run("3:", on: "|a\nb\nc\nd")
    Check.equal(s.engine.commandLine, ":.,.+2", "a count pre-fills the range")
    s.feed("<Esc>")
    s = run(":s/a/b/<CR>:<Up>", on: "|a")
    Check.equal(s.engine.commandLine, ":s/a/b/", "history with <Up>")
    s.feed("<Esc>")
    s = run("yiw:<C-r>0", on: "|foo")
    Check.equal(s.engine.commandLine, ":foo", "Ctrl-r pastes a register")
    s.feed("<Esc>")
    Check.equal(s.engine.mode, .normal)
}

func searchChecks() {
    // * and #
    vim("*", "|foo bar foo baz foo", "foo bar |foo baz foo")
    vim("**", "|foo bar foo baz foo", "foo bar foo baz |foo")
    vim("***", "|foo bar foo baz foo", "|foo bar foo baz foo")          // wraps around
    vim("*", "|foo foobar foo", "foo foobar |foo")                      // whole words only
    vim("#", "foo bar |foo", "|foo bar foo")
    vim("#", "|foo bar foo", "foo bar |foo")                            // wraps backwards
    vim("*", "|a.b a.b", "a.b |a.b")                                    // punctuation
    vim("*", "x |y(z) y", "x y(z) |y")
    vim("*", "|foo", "|foo")                                            // only match: stays
    vim("2*", "|a b a b a", "a b a b |a")
    vim("*", "|ação x ação", "ação x |ação")
    vim("d*", "|foo bar foo", "|foo")

    // / ? n N
    vim("/bar<CR>", "|foo bar baz bar", "foo |bar baz bar")
    vim("/bar<CR>n", "|foo bar baz bar", "foo bar baz |bar")
    vim("/bar<CR>nn", "|foo bar baz bar", "foo |bar baz bar")               // wraps
    vim("/bar<CR>nN", "|foo bar baz bar", "foo |bar baz bar")
    vim("?bar<CR>", "foo bar baz ba|r", "foo bar baz |bar")
    vim("?bar<CR>", "foo bar|", "foo |bar")
    vim("?bar<CR>n", "foo bar baz bar|", "foo |bar baz bar")
    vim("?bar<CR>N", "foo bar baz ba|r", "foo |bar baz bar")
    vim("/zzz<CR>", "|abc", "|abc")
    vim("/<CR>", "|abc", "|abc")
    vim("/b/e<CR>", "|abcabc", "a|bcabc")
    vim("/bc/e<CR>", "|abcabc", "ab|cabc")
    vim("/bc/s+1<CR>", "|abcabc", "ab|cabc")
    vim("/c/e-1<CR>", "|abcabc", "a|bcabc")
    vim("/b/+1<CR>", "|abc\ndef\nghi", "abc\n|def\nghi")                   // line offset
    vim("/B<CR>", "|x b B", "x b |B")                                     // smartcase
    vim("/b<CR>", "|x B b", "x |B b")                                     // ignorecase
    vim("/\\<b<CR>", "|abc b", "abc |b")
    vim("/a.c<CR>", "|x abc", "x |abc")
    vim("/\\(x\\|y\\)<CR>", "|a y x", "a |y x")
    vim("/a\\+b<CR>", "|c aaab", "c |aaab")
    vim("/[<CR>", "|a[b", "a|[b")                                         // an invalid regex falls back to a literal search
    vim("/a\\/b<CR>", "|x a/b", "x |a/b")                                 // escaped delimiter
    vim("/ção<CR>", "|ação", "a|ção")
    vim("/bar<CR>cwX<Esc>", "|foo bar", "foo |X")
    vim("d/bar<CR>", "|foo bar baz", "|bar baz")
    vim("y/bar<CR>P", "|foo bar", "foo| foo bar")
    vim("d/b<CR>.", "|a b c b d", "|b d")
    vim("/foo<CR>/<CR>", "|foo foo foo", "foo foo |foo")                    // an empty pattern repeats the last one
    vim("d?b<CR>", "ab c|d", "a|d")

    // Wrapping and messages.
    var s = run("/foo<CR>", on: "foo bar |baz")
    Check.equal(s.marked, "|foo bar baz", "wraps around")
    Check.expect(s.messages.contains { $0.contains("BOTTOM") }, "a wrap message")
    s = run("/zzz<CR>", on: "|abc")
    Check.expect(s.messages.contains { $0.hasPrefix("E486") }, "pattern not found")
    s = run("n", on: "|abc")
    Check.expect(s.messages.contains { $0.hasPrefix("E35") }, "no previous pattern")
    s = VimSession("foo bar |baz")
    s.engine.wrapScan = false
    s.feed("/foo<CR>")
    Check.equal(s.marked, "foo bar |baz", "wrapscan off")
    s = VimSession("|x Foo foo")
    s.engine.ignoreCase = false
    s.feed("/foo<CR>")
    Check.equal(s.marked, "x Foo |foo", "ignorecase off")
    s = VimSession("|x Foo foo")
    s.engine.smartCase = false
    s.feed("/Foo<CR>")
    Check.equal(s.marked, "x |Foo foo", "smartcase off: still finds the first match")
    s = run("/foo<CR>", on: "|a foo")
    Check.equal(s.engine.lastSearchPattern, "foo", "the last search pattern is exposed for highlighting")
    s.feed(":noh<CR>")
    Check.equal(s.engine.lastSearchPattern, nil, ":noh hides the highlight")
    s.feed("n")
    Check.equal(s.engine.lastSearchPattern, "foo", "searching again shows it")
    s = run("/foo", on: "|a foo")
    Check.equal(s.engine.commandLine, "/foo", "the search prompt")
    s.feed("<Esc>")
    Check.equal(s.marked, "|a foo", "Esc cancels the search")
    s = run("v/foo<CR>", on: "|a foo")
    Check.equal(s.selectedText, "a f", "searching in visual mode extends the selection")
}

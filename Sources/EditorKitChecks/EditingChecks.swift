import AppKit
import CheckKit
import EditorKit
import TeXCore

func editingChecks() async {
    await Check.suite("Auto-pair: insert, type-over, backspace") {
        let (tv, _) = makeEditor("")
        type("{", tv)
        Check.equal(text(tv), "{}")
        Check.equal(caret(tv), 1)
        type("x", tv)
        Check.equal(text(tv), "{x}")
        type("}", tv)
        Check.equal(text(tv), "{x}", "typing } over the auto-inserted closer")
        Check.equal(caret(tv), 3)
        type("(", tv)
        Check.equal(text(tv), "{x}()")
        tv.deleteBackward(nil)
        Check.equal(text(tv), "{x}", "backspace removes the empty pair")
        Check.equal(caret(tv), 3)
        type("[", tv)
        type("]", tv)
        Check.equal(text(tv), "{x}[]")
        Check.equal(caret(tv), 5)
    }

    await Check.suite("Auto-pair: when not sensible") {
        let (tv, _) = makeEditor("abc", caret: 0)
        type("{", tv)
        Check.equal(text(tv), "{abc", "no closer before a letter")

        let (tv2, _) = makeEditor("\\")
        type("{", tv2)
        Check.equal(text(tv2), "\\{", "escaped brace is literal")

        let (tv3, _) = makeEditor("% comment ")
        type("{", tv3)
        Check.equal(text(tv3), "% comment {", "no pairing inside comments")

        // A closer that was not auto-inserted is never typed over.
        let (tv4, _) = makeEditor("{}", caret: 1)
        type("}", tv4)
        Check.equal(text(tv4), "{}}")
        // Backspace in a pair that was not auto-inserted deletes one character.
        let (tv5, _) = makeEditor("{}", caret: 1)
        tv5.deleteBackward(nil)
        Check.equal(text(tv5), "}")
    }

    await Check.suite("Auto-pair: math dollars and wrapping") {
        let (tv, _) = makeEditor("Let ")
        type("$", tv)
        Check.equal(text(tv), "Let $$")
        type("x", tv)
        Check.equal(text(tv), "Let $x$")
        type("$", tv)
        Check.equal(text(tv), "Let $x$", "type over the closing dollar")
        Check.equal(caret(tv), 7)

        let (tv2, _) = makeEditor("word")
        tv2.setSelectedRange(NSRange(location: 0, length: 4))
        type("{", tv2)
        Check.equal(text(tv2), "{word}", "typing an opener wraps the selection")
        Check.equal(selection(tv2), NSRange(location: 1, length: 4))
    }

    await Check.suite("\\begin{…} + Enter auto-closes") {
        let (tv, _) = makeEditor("\\begin{itemize}")
        tv.insertNewline(nil)
        Check.equal(text(tv), "\\begin{itemize}\n  \n\\end{itemize}")
        Check.equal(caret(tv), utf16Length("\\begin{itemize}\n  "))

        let (tv2, _) = makeEditor("  \\begin{tabular}{ll}")
        tv2.insertNewline(nil)
        Check.equal(text(tv2), "  \\begin{tabular}{ll}\n    \n  \\end{tabular}", "indentation + arguments")
        Check.equal(caret(tv2), utf16Length("  \\begin{tabular}{ll}\n    "))

        let closed = "\\begin{itemize}\n\\end{itemize}"
        let (tv3, _) = makeEditor(closed, caret: utf16Length("\\begin{itemize}"))
        tv3.insertNewline(nil)
        Check.equal(text(tv3), "\\begin{itemize}\n  \n\\end{itemize}", "already closed: only indents")

        let (tv4, _) = makeEditor("\\begin{center}foo", caret: utf16Length("\\begin{center}"))
        tv4.insertNewline(nil)
        Check.equal(text(tv4), "\\begin{center}\n  foo\n\\end{center}", "rest of the line moves into the body")

        let (tv5, _) = makeEditor("% \\begin{itemize}")
        tv5.insertNewline(nil)
        Check.equal(text(tv5), "% \\begin{itemize}\n", "commented \\begin is ignored")

        var config = EditorConfiguration()
        config.autoCloseEnvironments = false
        let (tv6, _) = makeEditor("\\begin{proof}", configuration: config)
        tv6.insertNewline(nil)
        Check.equal(text(tv6), "\\begin{proof}\n  ", "auto-close off")
    }

    await Check.suite("Auto-indent") {
        let (tv, _) = makeEditor("    foo")
        tv.insertNewline(nil)
        Check.equal(text(tv), "    foo\n    ")

        let (tv2, _) = makeEditor("\\newcommand{\\x}{")
        tv2.insertNewline(nil)
        Check.equal(text(tv2), "\\newcommand{\\x}{\n  ", "one level deeper after an opening brace")

        let (tv3, _) = makeEditor("\\foo{}", caret: 5)
        tv3.insertNewline(nil)
        Check.equal(text(tv3), "\\foo{\n  \n}", "Enter between braces")
        Check.equal(caret(tv3), 8)

        let (tv4, _) = makeEditor("a\r\n  b")
        tv4.insertNewline(nil)
        Check.equal(text(tv4), "a\r\n  b\r\n  ", "CRLF documents get CRLF")

        let (tv5, _) = makeEditor("x\n    ")
        tv5.insertNewline(nil)
        Check.equal(text(tv5), "x\n\n    ", "no trailing whitespace left on a blank line")

        var tabs = EditorConfiguration()
        tabs.insertSpaces = false
        let (tv6, _) = makeEditor("\\begin{document}", configuration: tabs)
        tv6.insertNewline(nil)
        Check.equal(text(tv6), "\\begin{document}\n\t\n\\end{document}", "tab indent unit")
    }

    await Check.suite("Tab / ⇧Tab") {
        let original = "a\nb\n\nc"
        let (tv, _) = makeEditor(original)
        tv.setSelectedRange(NSRange(location: 0, length: utf16Length(original)))
        tv.insertTab(nil)
        Check.equal(text(tv), "  a\n  b\n\n  c", "blank lines are not indented")
        Check.equal(selection(tv), NSRange(location: 0, length: utf16Length("  a\n  b\n\n  c")))
        tv.insertBacktab(nil)
        Check.equal(text(tv), original, "outdent restores")
        tv.insertBacktab(nil)
        Check.equal(text(tv), original, "outdent at column 0 is a no-op")

        let (tv2, _) = makeEditor("ab", caret: 1)
        tv2.insertTab(nil)
        Check.equal(text(tv2), "a b", "soft tab to the next stop")
        let (tv3, _) = makeEditor("ab", caret: 0)
        tv3.insertTab(nil)
        Check.equal(text(tv3), "  ab")
        tv3.deleteBackward(nil)
        Check.equal(text(tv3), "ab", "backspace deletes a whole soft tab")

        let (tv4, _) = makeEditor("    x", caret: 5)
        tv4.insertBacktab(nil)
        Check.equal(text(tv4), "  x")
        Check.equal(caret(tv4), 3, "caret follows the outdent")

        // Partial multi-line selection keeps covering the same text.
        let (tv5, _) = makeEditor("one\ntwo\nthree")
        tv5.setSelectedRange(NSRange(location: 1, length: 5)) // "ne\ntw"
        tv5.insertTab(nil)
        Check.equal(text(tv5), "  one\n  two\nthree")
        Check.equal(selection(tv5), NSRange(location: 3, length: 7))
        await endEvent(tv5)
        tv5.undoManager?.undo()
        Check.equal(text(tv5), "one\ntwo\nthree", "one undo reverts the indent")
    }

    await Check.suite("⌘/ comment toggle round trip") {
        let original = "  a\n    b\n\n  c"
        let (tv, buffer) = makeEditor(original)
        tv.setSelectedRange(NSRange(location: 0, length: utf16Length(original)))
        let before = buffer.changeCount
        tv.toggleComment()
        Check.equal(text(tv), "  % a\n  %   b\n\n  % c", "aligned at the common indentation")
        Check.equal(buffer.changeCount, before + 1, "one edit")
        await endEvent(tv)
        tv.toggleComment()
        Check.equal(text(tv), original, "uncomment restores")
        await endEvent(tv)
        tv.undoManager?.undo()
        Check.equal(text(tv), "  % a\n  %   b\n\n  % c", "undo the uncomment")

        let (tv2, _) = makeEditor("x = 1", caret: 2)
        tv2.toggleComment()
        Check.equal(text(tv2), "% x = 1")
        Check.equal(caret(tv2), 4, "caret moves with the text")
        tv2.toggleComment()
        Check.equal(text(tv2), "x = 1")

        let (tv3, _) = makeEditor("%no space")
        tv3.toggleComment()
        Check.equal(text(tv3), "no space", "a bare % is removed too")
    }
}

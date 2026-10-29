import AppKit
import CheckKit
import EditorKit
import TeXCore

func snippetAndBufferChecks() async {
    await Check.suite("Snippet insertion: tab stops, final cursor, single undo") {
        let (tv, buffer) = makeEditor("  x = \\fr")
        let item = CompletionItem(kind: .command, label: "\\frac", insertText: "\\frac{${1:num}}{${2:den}}$0")
        let before = buffer.changeCount
        tv.insertCompletion(item, replacing: NSRange(location: 6, length: 3))
        Check.equal(text(tv), "  x = \\frac{num}{den}")
        Check.equal(buffer.changeCount, before + 1, "one edit")
        Check.equal(selection(tv), NSRange(location: 12, length: 3), "first stop selected")
        await endEvent(tv)
        type("a", tv)
        Check.equal(text(tv), "  x = \\frac{a}{den}")
        tv.insertTab(nil)
        Check.equal(selection(tv), NSRange(location: 15, length: 3), "Tab → second stop (shifted)")
        tv.insertBacktab(nil)
        Check.equal(selection(tv), NSRange(location: 12, length: 1), "⇧Tab → back to the first stop")
        tv.insertTab(nil)
        tv.insertTab(nil)
        Check.equal(selection(tv), NSRange(location: utf16Length("  x = \\frac{a}{den}"), length: 0), "final position")
        Check.expect(tv.activeSnippetStop == nil, "session ended")
        tv.insertTab(nil)
        Check.equal(text(tv), "  x = \\frac{a}{den} ", "Tab after the session inserts a soft tab to the next stop")
    }

    await Check.suite("Snippet insertion: indentation and undo") {
        let (tv, _) = makeEditor("    \\begin{ite")
        await endEvent(tv)
        let item = CompletionItem(kind: .environment, label: "itemize",
                                  insertText: "itemize}\n\t\\item $0\n\\end{itemize}")
        tv.insertCompletion(item, replacing: NSRange(location: 11, length: 3))
        let expected = "    \\begin{itemize}\n      \\item \n    \\end{itemize}"
        Check.equal(text(tv), expected, "newline → line indentation, tab → indent unit")
        Check.equal(caret(tv), utf16Length("    \\begin{itemize}\n      \\item "))
        await endEvent(tv)
        tv.undoManager?.undo()
        Check.equal(text(tv), "    \\begin{ite", "a single undo reverts the whole insertion")

        // Literal backslash sequences and \$ are never escapes.
        let (tv2, _) = makeEditor("")
        let literal = CompletionItem(kind: .snippet, label: "cost", insertText: "\\textbf{\\$${1:10}}\\newline")
        tv2.insertCompletion(literal, replacing: NSRange(location: 0, length: 0))
        Check.equal(text(tv2), "\\textbf{\\$10}\\newline")
        Check.equal(selection(tv2), NSRange(location: 10, length: 2))

        // CRLF documents keep CRLF.
        let (tv3, _) = makeEditor("a\r\n")
        let env = CompletionItem(kind: .environment, label: "proof", insertText: "\\begin{proof}\n\t$0\n\\end{proof}")
        tv3.insertCompletion(env, replacing: NSRange(location: 3, length: 0))
        Check.equal(text(tv3), "a\r\n\\begin{proof}\r\n  \r\n\\end{proof}")
    }

    await Check.suite("Buffer swap preserves undo stacks, selections and text") {
        let editor = LaTeXTextView()
        let a = SourceBuffer(url: URL(fileURLWithPath: "/tmp/a.tex"), text: "alpha")
        let b = SourceBuffer(url: URL(fileURLWithPath: "/tmp/b.tex"), text: "beta")
        editor.attach(a)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        type("1", editor)
        await endEvent(editor)
        editor.setSelectedRange(NSRange(location: 2, length: 1))
        Check.expect(editor.undoManager === a.undoManager, "undo manager is the buffer's")

        editor.attach(b)
        Check.equal(text(editor), "beta")
        Check.expect(editor.undoManager === b.undoManager)
        Check.expect(editor.undoManager?.canUndo == false, "b has no history")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", editor)
        await endEvent(editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))

        editor.attach(a)
        Check.equal(text(editor), "alpha1")
        Check.equal(selection(editor), NSRange(location: 2, length: 1), "selection restored")
        editor.undoManager?.undo()
        Check.equal(a.text, "alpha", "undo affects a only")
        Check.equal(b.text, "xbeta")

        editor.attach(b)
        Check.equal(selection(editor), NSRange(location: 3, length: 0))
        editor.undoManager?.undo()
        Check.equal(b.text, "beta")
        editor.undoManager?.redo()
        Check.equal(b.text, "xbeta", "redo works after swapping")
        Check.expect(a.isDirty && b.isDirty)

        // Reloading the shown buffer from disk keeps the editor consistent.
        b.reload(text: "line1\nline2")
        Check.equal(text(editor), "line1\nline2")
        Check.expect(!b.isDirty)
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        tvTypeAndCheckLines(editor)
    }

    await Check.suite("Highlighting does not dirty the buffer or register undo") {
        let source = "\\section{Intro}\nText $x^2$ and \\emph{y}. % note\n\\begin{equation}\na+b\n\\end{equation}\n"
        let (tv, buffer) = makeEditor(source)
        tv.flushHighlighting()
        Check.expect(!buffer.isDirty, "not dirty")
        Check.equal(buffer.changeCount, 0)
        Check.expect(tv.undoManager?.canUndo == false, "no undo registered")
        Check.expect(!tv.syntaxTokens.isEmpty, "tokens produced")
        let lm = tv.layoutManager
        let sectionColor = lm?.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil) as? NSColor
        Check.expect(sectionColor === EditorTheme.structure, "\\section is colored as structure")
        let emph = (source as NSString).range(of: "\\emph").location
        let emphColor = lm?.temporaryAttribute(.foregroundColor, atCharacterIndex: emph + 1, effectiveRange: nil) as? NSColor
        Check.expect(emphColor === EditorTheme.command, "\\emph is colored as a command")
        let storageColor = tv.textStorage?.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        Check.expect(storageColor == NSColor.textColor, "storage attributes untouched")

        // Edits re-highlight incrementally.
        tv.setSelectedRange(NSRange(location: 16, length: 0))
        type("\\alpha ", tv)
        tv.flushHighlighting()
        let alphaColor = lm?.temporaryAttribute(.foregroundColor, atCharacterIndex: 17, effectiveRange: nil) as? NSColor
        Check.expect(alphaColor === EditorTheme.command, "typed command colored")
        Check.equal(buffer.changeCount, 7, "one change per typed character")
    }
}

/// After a reload, typing still updates the line table (gutter, cursor) correctly.
@MainActor private func tvTypeAndCheckLines(_ editor: LaTeXTextView) {
    let controller = EditorController()
    controller.bind(to: editor)
    type("\n", editor)
    editor.insertNewline(nil)
    Check.equal(controller.cursor.line, 4, "cursor line tracks edits after reload")
}

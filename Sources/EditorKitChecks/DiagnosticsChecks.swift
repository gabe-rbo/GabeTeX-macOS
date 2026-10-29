import AppKit
import CheckKit
import EditorKit
import TeXCore

private func diag(line: Int?, column: Int? = nil, length: Int? = nil, _ severity: DiagnosticSeverity = .error,
                  source: DiagnosticSource = .tex) -> Diagnostic {
    Diagnostic(severity: severity, source: source, message: "m", fileURL: URL(fileURLWithPath: "/tmp/editorkit-checks/doc.tex"),
               line: line, column: column, length: length)
}

/// The underlined range of `diagnostic`, nil when it has no anchor.
@MainActor private func range(of diagnostic: Diagnostic, in editor: LaTeXTextView) -> NSRange? {
    editor.diagnosticRanges.first { $0.diagnostic.id == diagnostic.id }?.range
}

/// Where AppKit really draws an underline: the characters carrying the temporary underline attribute.
@MainActor private func underlined(_ editor: LaTeXTextView) -> [NSRange] {
    guard let lm = editor.layoutManager, let length = editor.textStorage?.length else { return [] }
    var result: [NSRange] = []
    var index = 0
    while index < length {
        var effective = NSRange(location: 0, length: 0)
        if lm.temporaryAttribute(.underlineStyle, atCharacterIndex: index, longestEffectiveRange: &effective,
                                 in: NSRange(location: 0, length: length)) != nil {
            result.append(effective)
        }
        index = max(index + 1, NSMaxRange(effective))
    }
    return result
}

func diagnosticsChecks() async {
    await Check.suite("Diagnostics → ranges") {
        let t = "abc \\foo bar\n  hello world  \n\nend" as NSString
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 1, column: 5, length: 4), in: t), NSRange(location: 4, length: 4),
                    "column + length")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 1, column: 5), in: t), NSRange(location: 4, length: 4),
                    "column only → the \\command")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 1, column: 10), in: t), NSRange(location: 9, length: 3),
                    "column only → the word")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 2), in: t), NSRange(location: 15, length: 11),
                    "no column → trimmed line")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 3), in: t), NSRange(location: 29, length: 0), "blank line")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 1, column: 99), in: t), NSRange(location: 11, length: 1),
                    "column past the end → last character")
        Check.expect(DiagnosticRangeMapper.range(for: diag(line: 9), in: t) == nil, "line out of range")
        Check.expect(DiagnosticRangeMapper.range(for: diag(line: nil), in: t) == nil, "no line")

        let crlf = "a\r\nbcd\r\nef" as NSString
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 2, column: 2, length: 2), in: crlf), NSRange(location: 4, length: 2),
                    "CRLF column")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 2), in: crlf), NSRange(location: 3, length: 3), "CRLF line")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 3), in: crlf), NSRange(location: 8, length: 2), "CRLF last line")
        let cr = "a\rbc" as NSString
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 2), in: cr), NSRange(location: 2, length: 2), "CR line ends")

        let emoji = "😀 \\x é" as NSString // 😀 = 2 UTF-16 units
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 1, column: 4), in: emoji), NSRange(location: 3, length: 2),
                    "UTF-16 column after an emoji")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 1, column: 2), in: emoji), NSRange(location: 0, length: 2),
                    "a column inside a surrogate pair snaps to the whole character")
        Check.equal(DiagnosticRangeMapper.range(for: diag(line: 1, column: 1, length: 1), in: emoji), NSRange(location: 0, length: 2),
                    "length never splits a surrogate pair")
    }

    await Check.suite("Diagnostics in the editor follow edits") {
        let (tv, buffer) = makeEditor("first\nsecond \\bad here\nthird")
        tv.setDiagnostics([diag(line: 2, column: 8), diag(line: 3, .warning)])
        let ranges = tv.diagnosticRanges.map(\.range)
        Check.equal(ranges, [NSRange(location: 13, length: 4), NSRange(location: 23, length: 5)])
        Check.equal(tv.diagnostics(at: 14).count, 1, "lookup by offset")
        Check.expect(tv.layoutManager?.temporaryAttribute(.underlineStyle, atCharacterIndex: 14, effectiveRange: nil) != nil,
                     "underline applied as a temporary attribute")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        type("XY", tv)
        Check.equal(tv.diagnosticRanges.map(\.range), [NSRange(location: 15, length: 4), NSRange(location: 25, length: 5)],
                    "anchors shift with edits")
        Check.equal(buffer.changeCount, 2)
        Check.expect(LaTeXEditorView.diagnostics([diag(line: 1)], for: URL(fileURLWithPath: "/tmp/editorkit-checks/./doc.tex")).count == 1,
                     "filtering by standardized URL")
        Check.expect(LaTeXEditorView.diagnostics([diag(line: 1)], for: URL(fileURLWithPath: "/tmp/other.tex")).isEmpty)
    }

    await Check.suite("Diagnostics updates keep edit-tracked anchors (compile error vs structure lint)") {
        let source = (1...60).map { "line \($0) \\cmd" }.joined(separator: "\n")
        let (tv, buffer) = makeEditor(source)
        let compileError = diag(line: 50)
        tv.setDiagnostics([compileError])
        Check.equal(range(of: compileError, in: tv), (source as NSString).range(of: "line 50 \\cmd"), "mapped from line 50")

        // The user inserts three lines above the error …
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("a\nb\nc\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        let edited = text(tv) as NSString
        let moved = edited.range(of: "line 50 \\cmd")
        Check.equal(moved.location, (source as NSString).range(of: "line 50 \\cmd").location + 6, "sanity: text moved by 6 UTF-16 units")
        Check.equal(range(of: compileError, in: tv), moved, "anchor followed the insertion")

        // … and another diagnostics source (structure lint) delivers its list: same ids + one new diagnostic.
        let lint = diag(line: 20, .warning, source: .structure)    // line 20 of the *current* text
        tv.setDiagnostics([compileError, lint])
        Check.equal(range(of: compileError, in: tv), moved, "the old error stays on its moved line (53), not back on 50")
        Check.equal(range(of: lint, in: tv), edited.range(of: "line 17 \\cmd"), "the new diagnostic is mapped from its own line")
        Check.equal(tv.diagnosticRanges.count, 2)
        Check.equal(underlined(tv), [edited.range(of: "line 17 \\cmd"), moved], "underlines drawn where the anchors are")
        Check.equal(tv.diagnostics(at: moved.location + 2).map(\.id), [compileError.id], "hover lookup on the moved line")
        Check.expect(tv.diagnostics(at: (source as NSString).range(of: "line 50 \\cmd").location + 2).isEmpty,
                     "nothing at the stale line 50 offset")

        // Edits after the update keep moving both anchors.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("zz", replacementRange: NSRange(location: NSNotFound, length: 0))
        Check.equal(range(of: compileError, in: tv), NSRange(location: moved.location + 2, length: moved.length))

        // A producer that re-reports the same id at a different place wins; ids that vanish lose their anchor.
        var relocated = compileError
        relocated.line = 10
        tv.setDiagnostics([relocated, lint])
        Check.equal(range(of: relocated, in: tv), (text(tv) as NSString).range(of: "line 7 \\cmd"),
                    "same id but a new line/column from the producer is re-anchored")
        Check.equal(range(of: lint, in: tv), (text(tv) as NSString).range(of: "line 17 \\cmd"), "lint anchor kept")
        tv.setDiagnostics([lint])
        Check.equal(tv.diagnosticRanges.map(\.diagnostic.id), [lint.id], "removed ids lose their anchors")
        Check.equal(underlined(tv), [(text(tv) as NSString).range(of: "line 17 \\cmd")], "and their underlines")
        Check.equal(buffer.changeCount, 2, "diagnostics never count as edits")

        // Same input again is a no-op; an update that changes only the message keeps the position.
        tv.setDiagnostics([lint])
        var reworded = lint
        reworded.message = "new text"
        tv.setDiagnostics([reworded])
        Check.equal(tv.diagnosticRanges.first?.diagnostic.message, "new text", "latest diagnostic value shown")
        Check.equal(range(of: reworded, in: tv), (text(tv) as NSString).range(of: "line 17 \\cmd"))
    }

    await Check.suite("Diagnostics keep following edits across a buffer switch") {
        let source = (1...30).map { "row \($0) \\x" }.joined(separator: "\n")
        let (tv, buffer) = makeEditor(source)
        let error = diag(line: 20)
        tv.setDiagnostics([error])
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("p\nq\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        let moved = (text(tv) as NSString).range(of: "row 20 \\x")
        Check.equal(range(of: error, in: tv), moved)

        let other = SourceBuffer(url: URL(fileURLWithPath: "/tmp/editorkit-checks/other.tex"), text: "other\nfile")
        tv.attach(other)
        Check.equal(tv.diagnosticRanges.count, 0, "nothing for the other buffer")
        // The host hands the compile diagnostics (stale line 20) again when the tab comes back.
        tv.attach(buffer, diagnostics: [error])
        Check.equal(range(of: error, in: tv), moved, "tab round trip: still on the moved line")
        Check.equal(underlined(tv), [moved])

        // A buffer that changed while it was away (reload from disk) is mapped afresh.
        tv.attach(other)
        buffer.reload(text: source)
        tv.attach(buffer, diagnostics: [error])
        Check.equal(range(of: error, in: tv), (source as NSString).range(of: "row 20 \\x"), "text replaced meanwhile → from line/column")
    }

    await Check.suite("noteEdit / onTextChange once per edit") {
        let (tv, buffer) = makeEditor("a\nb\nc")
        var calls = 0
        tv.onTextChange = { changed in
            Check.expect(changed === buffer)
            calls += 1
        }
        @MainActor func expectOne(_ what: String, _ body: () -> Void) {
            let before = calls
            let count = buffer.changeCount
            body()
            Check.equal(calls - before, 1, what)
            Check.equal(buffer.changeCount - count, 1, "noteEdit for \(what)")
        }
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        expectOne("typing") { type("x", tv) }
        expectOne("auto-pair") { type("{", tv) }
        let before = calls
        type("}", tv)
        Check.equal(calls, before, "type-over is not an edit")
        tv.setSelectedRange(NSRange(location: 0, length: (text(tv) as NSString).length))
        expectOne("comment toggle over 3 lines") { tv.toggleComment() }
        expectOne("indent 3 lines") { tv.insertTab(nil) }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        expectOne("delete") { tv.deleteForward(nil) }
        let (tv2, buffer2) = makeEditor("\\begin{proof}")
        var calls2 = 0
        tv2.onTextChange = { _ in calls2 += 1 }
        tv2.insertNewline(nil)
        Check.equal(calls2, 1, "environment auto-close")
        tv2.insertCompletion(CompletionItem(kind: .command, label: "\\frac", insertText: "\\frac{$1}{$2}"),
                             replacing: NSRange(location: caret(tv2), length: 0))
        Check.equal(calls2, 2, "completion")
        Check.equal(buffer2.changeCount, 2)
        await endEvent(tv2)
        tv2.undoManager?.undo()
        Check.expect(calls2 >= 3, "undo reports an edit")
        Check.equal(buffer2.changeCount, calls2, "noteEdit and onTextChange stay in lockstep")
    }
}

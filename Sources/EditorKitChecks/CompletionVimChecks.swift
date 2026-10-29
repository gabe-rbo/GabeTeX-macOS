import AppKit
import CheckKit
import EditorKit
import TeXCore
import VimKit

/// A synthesized key-down event (no window needed: the editor's `keyDown` routes it to Vim/completion).
@MainActor func keyEvent(_ characters: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = [],
                         ignoringModifiers: String? = nil) -> NSEvent? {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
                     isARepeat: false, keyCode: keyCode)
}

/// Sends printable keys one by one through `keyDown` (each key is one event).
@MainActor func press(_ keys: String, _ editor: LaTeXTextView) async {
    for character in keys {
        guard let event = keyEvent(String(character)) else {
            Check.fail("could not synthesize key \(character)")
            return
        }
        editor.keyDown(with: event)
        await endEvent(editor)
    }
}

@MainActor func pressEscape(_ editor: LaTeXTextView) async {
    guard let event = keyEvent("\u{1b}", keyCode: 53) else { return Check.fail("could not synthesize Esc") }
    editor.keyDown(with: event)
    await endEvent(editor)
}

@MainActor func pressReturn(_ editor: LaTeXTextView) async {
    guard let event = keyEvent("\r", keyCode: 36) else { return Check.fail("could not synthesize Return") }
    editor.keyDown(with: event)
    await endEvent(editor)
}

func completionAndVimChecks() async {
    await Check.suite("Completion with real catalog items: \\frac (keyboard navigation, tab stops, undo)") {
        let (tv, buffer) = makeEditor("Let $x = $", caret: 9)
        type("\\fra", tv)
        await endEvent(tv)
        let controller = EditorController()
        controller.bind(to: tv)
        controller.triggerCompletion()
        let items = tv.completionItems
        guard let index = items.firstIndex(where: { $0.label == "\\frac" }) else {
            return Check.fail("\\frac offered for \\fra (got \(items.prefix(5).map(\.label)))")
        }
        Check.expect(items.allSatisfy { $0.kind == .command }, "command context")
        for _ in 0..<index { tv.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        let changes = buffer.changeCount
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))   // Tab accepts
        Check.expect(tv.completionItems.isEmpty, "popup closed after accepting")
        Check.equal(text(tv), "Let $x = \\frac{a}{b}$", "catalog snippet \\frac{${1:a}}{${2:b}}$0 (auto-paired $ kept)")
        Check.equal(buffer.changeCount, changes + 1, "acceptance is one edit")
        Check.equal(selection(tv), NSRange(location: 15, length: 1), "first stop (a) selected")
        await endEvent(tv)
        type("n", tv)
        await endEvent(tv)
        tv.insertTab(nil)
        Check.equal(selection(tv), NSRange(location: 18, length: 1), "Tab → second stop (b)")
        type("m", tv)
        Check.equal(text(tv), "Let $x = \\frac{n}{m}$")
        tv.insertTab(nil)
        Check.equal(caret(tv), 20, "Tab → $0 after the closing brace")
        Check.expect(tv.activeSnippetStop == nil, "session ended at $0")
        await endEvent(tv)
        tv.undoManager?.undo()
        tv.undoManager?.undo()
        Check.equal(text(tv), "Let $x = \\frac{a}{b}$", "typing in the stops undone")
        tv.undoManager?.undo()
        Check.equal(text(tv), "Let $x = \\fra$", "one undo removes the whole insertion")
    }

    await Check.suite("Completion with real catalog items: \\begin{fig… (auto-paired brace, multi-line body)") {
        let (tv, buffer) = makeEditor("  ")
        type("\\begin{", tv)
        Check.equal(text(tv), "  \\begin{}", "brace auto-paired")
        type("fig", tv)
        await endEvent(tv)
        tv.complete(nil)                                          // ⌥⎋
        let items = tv.completionItems
        guard let index = items.firstIndex(where: { $0.label == "figure" }) else {
            return Check.fail("figure offered for \\begin{fig (got \(items.prefix(5).map(\.label)))")
        }
        Check.expect(items.allSatisfy { $0.kind == .environment }, "environment context")
        for _ in 0..<index { tv.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        let changes = buffer.changeCount
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))   // Return accepts
        let expected = """
              \\begin{figure}[htbp]
                \\centering
                \\includegraphics[width=0.8\\linewidth]{file}
                \\caption{caption}
                \\label{fig:label}
              \\end{figure}
            """
        Check.equal(text(tv), expected, "indentation applied, auto-paired } swallowed, \\l… kept literally")
        Check.equal(buffer.changeCount, changes + 1, "one edit")
        let ns = text(tv) as NSString
        Check.equal(selection(tv), ns.range(of: "htbp"), "first stop")
        var visited: [String] = []
        for _ in 0..<4 {
            tv.insertTab(nil)
            visited.append(ns.substring(with: selection(tv)))
        }
        Check.equal(visited, ["0.8", "file", "caption", "label"], "Tab visits the stops in order")
        tv.insertTab(nil)
        Check.equal(caret(tv), NSMaxRange(ns.range(of: "fig:label}")), "$0 after the label")
        await endEvent(tv)
        tv.undoManager?.undo()
        Check.equal(text(tv), "  \\begin{fig}", "a single undo reverts the whole environment")
    }

    await Check.suite("Snippet mirrors follow the edited stop") {
        let (tv, buffer) = makeEditor("")
        let item = CompletionItem(kind: .snippet, label: "env", insertText: "\\begin{${1:env}}\n\t$0\n\\end{$1}")
        var reports = 0
        tv.onTextChange = { _ in reports += 1 }
        tv.insertCompletion(item, replacing: NSRange(location: 0, length: 0))
        Check.equal(text(tv), "\\begin{env}\n  \n\\end{env}")
        Check.equal(selection(tv), NSRange(location: 7, length: 3))
        await endEvent(tv)
        type("x", tv)
        Check.equal(text(tv), "\\begin{x}\n  \n\\end{x}", "mirror updated")
        await endEvent(tv)
        type("yz", tv)
        Check.equal(text(tv), "\\begin{xyz}\n  \n\\end{xyz}")
        tv.deleteBackward(nil)
        Check.equal(text(tv), "\\begin{xy}\n  \n\\end{xy}", "backspace mirrored")
        Check.equal(reports, 5, "one report per edit, mirror updates included")
        Check.equal(buffer.changeCount, 5)
        tv.insertTab(nil)
        Check.equal(caret(tv), utf16Length("\\begin{xy}\n  "), "$0 inside the body")
        await endEvent(tv)
        tv.undoManager?.undo()
        Check.equal(text(tv), "\\begin{x}\n  \n\\end{x}", "undo restores the stop and its mirror together")
        tv.undoManager?.undo()
        Check.equal(text(tv), "\\begin{env}\n  \n\\end{env}")
        tv.undoManager?.redo()
        Check.equal(text(tv), "\\begin{x}\n  \n\\end{x}", "redo too")
    }

    await Check.suite("Vim adapter with the real VimEngine: dd, ciw + typing + Esc, u, Ctrl-r, :w, registers") {
        var config = EditorConfiguration()
        config.vimMode = true
        config.indentWidth = 4
        let (tv, buffer) = makeEditor("alpha beta\ngamma\ndelta", caret: 0, configuration: config)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GabeTeX.EditorKitChecks.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        tv.vimPasteboard = pasteboard
        let controller = EditorController()
        controller.bind(to: tv)
        var reports = 0
        tv.onTextChange = { _ in reports += 1 }
        var exCommands: [VimExCommand] = []
        controller.onVimExCommand = { exCommands.append($0) }
        Check.equal(tv.vimEngine?.mode, .normal)
        Check.equal(tv.vimEngine?.indentUnit, "    ", "indent unit from the configuration")
        Check.equal(controller.vimMode, .normal)

        await press("d", tv)
        Check.equal(controller.vimPendingKeys, "d", "pending keys published")
        await press("d", tv)
        Check.equal(text(tv), "gamma\ndelta", "dd")
        Check.equal(reports, 1, "dd is one reported edit")
        Check.equal(buffer.changeCount, 1)
        Check.equal(controller.vimPendingKeys, "")

        await press("yiw", tv)
        Check.equal(pasteboard.string(forType: .string), "gamma", "yank bridged to the pasteboard")
        Check.equal(text(tv), "gamma\ndelta", "yank does not edit")
        Check.equal(reports, 1)

        await press("ciw", tv)
        Check.equal(text(tv), "\ndelta", "ciw deletes the word")
        Check.equal(controller.vimMode, .insert, "insert mode published")
        type("omega", tv)                                   // insert mode: the host inserts printable keys
        await endEvent(tv)
        Check.equal(text(tv), "omega\ndelta")
        await pressEscape(tv)
        Check.equal(controller.vimMode, .normal, "Esc → normal")
        Check.equal(caret(tv), 4, "cursor steps left on Esc")

        await press("u", tv)
        Check.equal(text(tv), "gamma\ndelta", "u undoes ciw + typed text as one change")
        await press("u", tv)
        Check.equal(text(tv), "alpha beta\ngamma\ndelta", "u undoes dd")
        if let redo = keyEvent("\u{12}", keyCode: 15, flags: .control, ignoringModifiers: "r") {
            tv.keyDown(with: redo)
            await endEvent(tv)
        }
        Check.equal(text(tv), "gamma\ndelta", "Ctrl-r redoes dd")

        await press(":w", tv)
        Check.equal(controller.vimMode, .commandLine)
        Check.equal(controller.vimCommandLine, ":w", "command line published")
        await pressReturn(tv)
        Check.equal(exCommands, [.write], ":w reaches onVimExCommand")
        Check.equal(controller.vimMode, .normal)
        Check.equal(text(tv), "gamma\ndelta", "normal-mode keys never type text")

        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await press("yyp", tv)
        Check.equal(pasteboard.string(forType: .string), "gamma\n", "linewise yank on the pasteboard")
        Check.equal(text(tv), "gamma\ngamma\ndelta", "yy p")
        pasteboard.clearContents()
        pasteboard.setString("zeta", forType: .string)        // copied in another app
        await press("P", tv)
        Check.equal(text(tv), "gamma\nzetagamma\ndelta", "P pastes text from the pasteboard")
        Check.equal(buffer.changeCount, reports, "noteEdit and onTextChange in lockstep")
    }
}

func commandClickChecks() async {
    await Check.suite("⌘-click resolution: include arguments and label keys") {
        let source = "intro\n\\input{sections/intro}\nsee \\eqref{eq:main} and \\cref{a,b}\n\\includegraphics[width=2cm]{fig/plot}"
        let (tv, _) = makeEditor(source)
        let ns = source as NSString
        let input = tv.includeReference(at: ns.range(of: "sections").location + 2)
        Check.equal(input?.kind, .input)
        Check.equal(input?.argument, "sections/intro")
        Check.equal(input?.line, 2, "line in document coordinates")
        Check.equal(input?.range, ns.range(of: "sections/intro"), "range in document coordinates")
        let graphic = tv.includeReference(at: ns.range(of: "plot").location)
        Check.equal(graphic?.kind, .includegraphics)
        Check.equal(graphic?.argument, "fig/plot")
        Check.equal(tv.labelKey(at: ns.range(of: "eq:main").location + 3), "eq:main")
        Check.equal(tv.labelKey(at: ns.range(of: "a,b}").location + 2), "b", "only the clicked item of a list")
        Check.expect(tv.labelKey(at: 1) == nil && tv.includeReference(at: 1) == nil, "plain text resolves to nothing")
    }
}

import AppKit
import CheckKit
import EditorKit
import TeXCore
import VimKit

// Headless Touch Bar checks (no window, nothing on screen): the bar the editor builds, its items, the
// edits its actions make (math vs text context, selections, undo, Vim) and the routing of app commands.

/// Sends printable keys through `keyDown` (Vim), one event each.
private func touchBarPress(_ keys: String, _ editor: LaTeXTextView) async {
    for character in keys {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                           context: nil, characters: String(character),
                                           charactersIgnoringModifiers: String(character), isARepeat: false,
                                           keyCode: 0) else {
            return Check.fail("could not synthesize key \(character)")
        }
        editor.keyDown(with: event)
        await endEvent(editor)
    }
}

/// Clicks a Touch Bar button (sends its action like a tap).
private func tap(_ item: NSTouchBarItem?) {
    guard let button = (item as? NSCustomTouchBarItem)?.view as? NSButton else {
        return Check.fail("no button in item \(String(describing: item?.identifier.rawValue))")
    }
    Check.expect(button.isEnabled, "\(item?.identifier.rawValue ?? "?") is enabled")
    _ = button.sendAction(button.action, to: button.target)
}

private func button(_ item: NSTouchBarItem?) -> NSButton? {
    (item as? NSCustomTouchBarItem)?.view as? NSButton
}

/// Picks entry `index` of the scrubber inside a popover item (like a tap on the Touch Bar).
private func pickFromPopover(_ item: NSTouchBarItem?, index: Int) {
    guard let popover = item as? NSPopoverTouchBarItem, case let content = popover.popoverTouchBar,
          let identifier = content.defaultItemIdentifiers.first,
          let scrubber = (content.item(forIdentifier: identifier) as? NSCustomTouchBarItem)?.view as? NSScrubber else {
        return Check.fail("no scrubber in popover \(String(describing: item?.identifier.rawValue))")
    }
    Check.expect((scrubber.dataSource?.numberOfItems(for: scrubber) ?? 0) > index, "scrubber has item \(index)")
    scrubber.delegate?.scrubber?(scrubber, didSelectItemAt: index)
}

/// A tap on segment `index` of a momentary segmented control (the action reads `selectedSegment` while it runs;
/// a momentary control does not keep a programmatic selection, hence the temporary tracking mode).
private func tapSegment(_ control: NSSegmentedControl, _ index: Int) {
    control.trackingMode = .selectOne
    control.selectedSegment = index
    _ = control.sendAction(control.action, to: control.target)
    control.trackingMode = .momentary
}

/// Taps option `index` (a button) of a popover item.
private func pickOption(_ item: NSTouchBarItem?, index: Int) {
    guard let popover = item as? NSPopoverTouchBarItem, case let content = popover.popoverTouchBar,
          content.defaultItemIdentifiers.indices.contains(index) else {
        return Check.fail("no option \(index) in popover \(String(describing: item?.identifier.rawValue))")
    }
    tap(content.item(forIdentifier: content.defaultItemIdentifiers[index]))
}

func touchBarChecks() async {
    typealias Item = EditorTouchBar.Item
    let unit = EditorConfiguration().indentUnit

    await Check.suite("Touch Bar: the editor's bar, identifiers and items") {
        let (tv, _) = makeEditor("Hello")
        let controller = EditorController()
        controller.bind(to: tv)
        guard let bar = tv.touchBar else { return Check.fail("makeTouchBar() returned nil") }
        Check.equal(bar.customizationIdentifier, EditorTouchBar.customizationIdentifier)
        Check.equal(bar.defaultItemIdentifiers, EditorTouchBar.defaultItemIdentifiers, "default arrangement")
        Check.expect(!bar.defaultItemIdentifiers.contains(Item.issues), "no Issues item without issues")
        Check.expect(Set(EditorTouchBar.editorItemIdentifiers).isSubset(of: Set(bar.customizationAllowedItemIdentifiers)),
                     "every editor item is customizable")
        Check.expect(!bar.defaultItemIdentifiers.contains(.characterPicker) && !bar.defaultItemIdentifiers.contains(.candidateList),
                     "no keyboard duplicates by default")
        for identifier in EditorTouchBar.editorItemIdentifiers {
            let item = bar.delegate?.touchBar?(bar, makeItemForIdentifier: identifier)
            Check.expect(item != nil, "\(identifier.rawValue) produces an item")
            Check.expect(item?.customizationLabel.isEmpty == false, "\(identifier.rawValue) has a customization label")
        }
        for identifier in bar.defaultItemIdentifiers {
            Check.expect(bar.item(forIdentifier: identifier) != nil, "bar resolves \(identifier.rawValue)")
        }
        for name in EditorTouchBar.symbolNames {
            Check.expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "SF Symbol \(name) exists")
        }
        let display = bar.item(forIdentifier: Item.displayMath) as? NSPopoverTouchBarItem
        Check.equal(display?.popoverTouchBar.defaultItemIdentifiers.count, LaTeXMarkupAction.DisplayMath.allCases.count,
                    "display math options")
        for identifier in display?.popoverTouchBar.defaultItemIdentifiers ?? [] {
            Check.expect(display?.popoverTouchBar.item(forIdentifier: identifier) != nil, "option \(identifier.rawValue)")
        }
        let sections = bar.item(forIdentifier: Item.sections) as? NSPopoverTouchBarItem
        Check.equal(sections?.popoverTouchBar.defaultItemIdentifiers.count, EditorTouchBar.sections.count)
        tv.updateTouchBarItemIdentifiers()   // NSTextView would install its rich-text items here
        Check.equal(bar.defaultItemIdentifiers, EditorTouchBar.defaultItemIdentifiers, "kept after a text-settings update")
        Check.expect(tv.touchBar === bar, "the bar is cached by the responder")
        Check.equal(Set(EditorTouchBar.greekLetters.map(\.command)).count, EditorTouchBar.greekLetters.count, "Greek unique")
        Check.equal(Set(EditorTouchBar.mathSymbols.map(\.command)).count, EditorTouchBar.mathSymbols.count, "symbols unique")
    }

    await Check.suite("Touch Bar: building and refreshing the bar never edits, dirties or registers undo") {
        let source = "Let $x$ be \\emph{nice}.\n\\begin{align}\n  a &= b\n\\end{align}\n"
        let (tv, buffer) = makeEditor(source, caret: 5)
        let controller = EditorController()
        controller.bind(to: tv)
        var reports = 0
        tv.onTextChange = { _ in reports += 1 }
        controller.onTouchBarCommand = { _ in }
        controller.onShowInPDF = { _, _ in }
        let changes = buffer.changeCount
        guard let bar = tv.touchBar else { return Check.fail("no bar") }
        for identifier in EditorTouchBar.editorItemIdentifiers {
            let item = bar.delegate?.touchBar?(bar, makeItemForIdentifier: identifier)
            if let popover = item as? NSPopoverTouchBarItem {
                for inner in popover.popoverTouchBar.defaultItemIdentifiers {
                    _ = popover.popoverTouchBar.item(forIdentifier: inner)
                }
            }
        }
        for step in 0..<6 {
            tv.setSelectedRange(NSRange(location: step * 7 % utf16Length(source), length: step % 2 * 3))
            let diagnostic = Diagnostic(severity: step % 2 == 0 ? .error : .warning, source: .tex, message: "m",
                                        fileURL: URL(fileURLWithPath: "/tmp/editorkit-checks/doc.tex"), line: 1 + step % 3)
            tv.setDiagnostics([diagnostic])
            controller.touchBarStatus = EditorTouchBarStatus(compile: step % 2 == 0 ? .running : .ready,
                                                             errorCount: step % 3, warningCount: step,
                                                             isPreviewVisible: step % 2 == 0, isPreviewDetached: step % 2 == 1)
            _ = tv.isMathMode(at: tv.selectedRange().location)
            tv.updateTouchBarItemIdentifiers()
            await endEvent(tv)
        }
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        Check.expect(!tv.performMarkup(.inlineMath), "a refused action")
        await endEvent(tv)
        Check.equal(text(tv), source, "text untouched")
        Check.equal(buffer.changeCount, changes, "no edit reported to the buffer")
        Check.expect(!buffer.isDirty, "buffer not dirty")
        Check.equal(reports, 0, "onTextChange never called")
        Check.expect(tv.undoManager?.canUndo == false, "nothing registered for undo")
    }

    await Check.suite("Touch Bar: AppKit finds the editor's bar from the first responder (offscreen window)") {
        let (tv, _) = makeEditor("text")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)   // never ordered on screen
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = tv
        window.contentView = scroll
        Check.expect(window.makeFirstResponder(tv), "editor accepts first responder")
        var responder: NSResponder? = window.firstResponder
        var found: NSTouchBar?
        while let current = responder, found == nil {
            found = current.touchBar
            responder = current.nextResponder
        }
        Check.equal(found?.customizationIdentifier, EditorTouchBar.customizationIdentifier,
                    "the first bar up the responder chain is the editor's")
        window.contentView = nil
        window.close()
    }

    await Check.suite("Touch Bar: app commands reach the host; Compile ⇄ Stop; Issues; Show in PDF") {
        let (tv, _) = makeEditor("first line\nsecond line", caret: 14)
        let controller = EditorController()
        controller.bind(to: tv)
        guard let bar = tv.touchBar else { return Check.fail("no bar") }
        let compile = bar.item(forIdentifier: Item.compile)
        Check.expect(button(compile)?.isEnabled == false, "Compile disabled without a host")

        var received: [EditorTouchBarCommand] = []
        controller.onTouchBarCommand = { received.append($0) }
        controller.touchBarStatus = EditorTouchBarStatus(compile: .ready, isPreviewVisible: true, isPreviewDetached: false)
        tap(compile)
        Check.equal(received, [.compile], "Compile reaches the handler")
        Check.equal(button(compile)?.accessibilityLabel(), String(localized: "Compile"))

        controller.touchBarStatus.compile = .running
        Check.equal(button(compile)?.accessibilityLabel(), String(localized: "Stop"), "running → Stop")
        tap(compile)
        Check.equal(received.last, .stopCompile, "Stop reaches the handler")

        controller.touchBarStatus = EditorTouchBarStatus(compile: .unavailable)
        Check.expect(button(compile)?.isEnabled == false, "nothing to compile → disabled")

        controller.touchBarStatus = EditorTouchBarStatus(compile: .ready, errorCount: 2, warningCount: 1)
        Check.equal(bar.defaultItemIdentifiers.last, Item.issues, "Issues appended (right end) with issues")
        let issues = bar.item(forIdentifier: Item.issues)
        Check.equal(button(issues)?.title, 2.formatted(), "error count shown")
        tap(issues)
        Check.equal(received.last, .nextIssue, "Issues → next issue")
        controller.touchBarStatus = EditorTouchBarStatus(compile: .ready, warningCount: 3)
        Check.equal(button(issues)?.title, 3.formatted(), "warning count when there are no errors")
        controller.touchBarStatus = EditorTouchBarStatus(compile: .ready)
        Check.equal(bar.defaultItemIdentifiers, EditorTouchBar.defaultItemIdentifiers, "Issues removed again")
        Check.expect(button(issues)?.isEnabled == false, "a customized Issues item is disabled without issues")

        controller.touchBarStatus = EditorTouchBarStatus(compile: .ready, isPreviewVisible: true, isPreviewDetached: false)
        let preview = bar.delegate?.touchBar?(bar, makeItemForIdentifier: Item.togglePreview)
        Check.equal(button(preview)?.state, .on, "preview toggle shows the state")
        tap(preview)
        Check.equal(received.last, .togglePreview)
        let window = bar.delegate?.touchBar?(bar, makeItemForIdentifier: Item.previewWindow)
        tap(window)
        Check.equal(received.last, .togglePreviewWindow)
        Check.equal(button(window)?.accessibilityLabel(), String(localized: "Open PDF in Separate Window"))
        controller.touchBarStatus.isPreviewDetached = true
        Check.equal(button(window)?.accessibilityLabel(), String(localized: "Attach PDF to Project Window"))
        controller.touchBarStatus.isPreviewDetached = nil
        Check.expect(button(window)?.isEnabled == false, "no detachable preview → disabled")

        controller.onTouchBarCommand = nil
        Check.expect(button(compile)?.isEnabled == false, "handler removed → disabled")

        let showInPDF = bar.item(forIdentifier: Item.showInPDF)
        Check.expect(button(showInPDF)?.isEnabled == false, "Show in PDF disabled without onShowInPDF")
        var shown: [(SourcePosition, String?)] = []
        controller.onShowInPDF = { shown.append(($0, $1)) }
        controller.touchBarStatus = EditorTouchBarStatus(compile: .ready)   // any host change refreshes the bar
        tap(showInPDF)
        Check.equal(shown.count, 1, "Show in PDF fires onShowInPDF")
        Check.equal(shown.first?.0, SourcePosition(line: 2, column: 4), "caret position (1-based)")
        Check.equal(shown.first?.1, controller.word(at: 14)?.word, "the word at the caret")
    }

    await Check.suite("Touch Bar: math symbols in math and text (Greek and symbol scrubbers)") {
        let (tv, _) = makeEditor("Let ")
        guard let bar = tv.touchBar else { return Check.fail("no bar") }
        pickFromPopover(bar.item(forIdentifier: Item.greekLetters), index: 0)
        Check.equal(text(tv), "Let $\\alpha$", "outside math: wrapped in $…$")
        Check.equal(caret(tv), utf16Length("Let $\\alpha$"))
        pickFromPopover(bar.item(forIdentifier: Item.greekLetters), index: 1)
        Check.equal(text(tv), "Let $\\alpha\\beta$", "right after a formula: merged into it (never $…$$…$)")
        Check.equal(caret(tv), utf16Length("Let $\\alpha\\beta$"), "caret stays after the closing $")

        let (tv2, _) = makeEditor("$x + $", caret: 5)
        tv2.performMarkup(.mathCommand("\\infty"))
        Check.equal(text(tv2), "$x + \\infty$", "inside math: the bare command")
        let (tv3, _) = makeEditor("$x$", caret: 1)
        tv3.performMarkup(.mathCommand("\\alpha"))
        Check.equal(text(tv3), "$\\alpha x$", "a space keeps \\alpha from running into a letter")
        let (tv4, _) = makeEditor("Let $x$ ")
        tv4.performMarkup(.mathCommand("\\alpha"))
        Check.equal(text(tv4), "Let $x$ $\\alpha$", "after a space: a new formula")
        let (tv5, _) = makeEditor("\\begin{align}\n  a &= b\n\\end{align}", caret: 22)
        Check.expect(tv5.isMathMode(at: 22), "align is math")
        guard let bar5 = tv5.touchBar else { return Check.fail("no bar") }
        let symbols = EditorTouchBar.mathSymbols
        guard let realIndex = symbols.firstIndex(where: { $0.command == "\\mathbb{R}" }) else { return Check.fail("ℝ") }
        pickFromPopover(bar5.item(forIdentifier: Item.mathSymbols), index: realIndex)
        Check.equal(text(tv5), "\\begin{align}\n  a &= b\\mathbb{R}\n\\end{align}", "symbol scrubber in align")
        let (tv6, _) = makeEditor("% $x", caret: 4)
        Check.expect(!tv6.isMathMode(at: 4), "comments are not math")
        let (tv7, _) = makeEditor("$x$ and \\(y\\)", caret: 11)
        Check.expect(tv7.isMathMode(at: 11) && !tv7.isMathMode(at: 3), "\\( \\) is math, after $x$ is not")
        let (tvGap, _) = makeEditor("a $y$", caret: 2)
        tvGap.performMarkup(.mathCommand("\\alpha"))
        Check.equal(text(tvGap), "a $\\alpha$ $y$", "a space before a following formula")
        let (tv8, _) = makeEditor("a word")
        tv8.setSelectedRange(NSRange(location: 2, length: 4))
        tv8.performMarkup(.mathCommand("\\pi"))
        Check.equal(text(tv8), "a $\\pi$", "a selection is replaced")
    }

    await Check.suite("Touch Bar: inline math, fraction, superscript/subscript") {
        let (tv, _) = makeEditor("word")
        tv.setSelectedRange(NSRange(location: 0, length: 4))
        Check.expect(tv.performMarkup(.inlineMath))
        Check.equal(text(tv), "$word$", "selection wrapped")
        Check.equal(selection(tv), NSRange(location: 1, length: 4), "wrapped text stays selected")
        Check.expect(!tv.performMarkup(.inlineMath), "inline math inside math is refused")
        Check.equal(text(tv), "$word$")

        let (tv2, _) = makeEditor("a ")
        tv2.performMarkup(.inlineMath)
        Check.equal(text(tv2), "a $$")
        Check.equal(caret(tv2), 3, "caret between the dollars")
        type("x$", tv2)
        Check.equal(text(tv2), "a $x$", "typing $ steps over the inserted closer")
        Check.equal(caret(tv2), 5)

        let (gap, _) = makeEditor("$x$")
        gap.performMarkup(.inlineMath)
        Check.equal(text(gap), "$x$ $$", "never $x$$$ (TeX would read $$)")
        Check.equal(caret(gap), 5)

        let (tv3, _) = makeEditor("$$", caret: 1)
        tv3.performMarkup(.fraction)
        Check.equal(text(tv3), "$\\frac{}{}$")
        Check.equal(tv3.activeSnippetStop, NSRange(location: 7, length: 0), "numerator stop")
        tv3.insertTab(nil)
        Check.equal(selection(tv3), NSRange(location: 9, length: 0), "Tab → denominator")

        let (tv4, _) = makeEditor("$a+b$")
        tv4.setSelectedRange(NSRange(location: 1, length: 1))
        tv4.performMarkup(.fraction)
        Check.equal(text(tv4), "$\\frac{a}{}+b$", "selection becomes the numerator")
        Check.equal(selection(tv4), NSRange(location: 10, length: 0), "caret in the denominator")

        let (tv5, _) = makeEditor("so ")
        tv5.performMarkup(.fraction)
        Check.equal(text(tv5), "so $\\frac{}{}$", "outside math: wrapped in $…$")
        Check.equal(tv5.activeSnippetStop, NSRange(location: 10, length: 0))

        let (tv6, _) = makeEditor("$x$", caret: 2)
        tv6.performMarkup(.superscript)
        Check.equal(text(tv6), "$x^{}$")
        Check.equal(caret(tv6), 4)
        let (tv7, _) = makeEditor("$x$")
        tv7.performMarkup(.superscript)
        Check.equal(text(tv7), "$x^{}$", "right after $x$: inside the formula")
        let (tv8, _) = makeEditor("$x1$")
        tv8.setSelectedRange(NSRange(location: 2, length: 1))
        tv8.performMarkup(.subscript)
        Check.equal(text(tv8), "$x_{1}$")
        Check.equal(selection(tv8), NSRange(location: 4, length: 1))
        let (tv9, _) = makeEditor("1")
        tv9.performMarkup(.superscript)
        Check.equal(text(tv9), "1\\textsuperscript{}", "text mode: \\textsuperscript")
    }

    await Check.suite("Touch Bar: text styles, sections, comment") {
        let (tv, _) = makeEditor("a word b")
        guard let bar = tv.touchBar else { return Check.fail("no bar") }
        tv.setSelectedRange(NSRange(location: 2, length: 4))
        guard let styles = (bar.item(forIdentifier: Item.textStyle) as? NSCustomTouchBarItem)?.view as? NSSegmentedControl else {
            return Check.fail("text style control")
        }
        Check.equal(styles.segmentCount, LaTeXMarkupAction.TextStyle.allCases.count)
        Check.equal(styles.trackingMode, .momentary)
        tapSegment(styles, 0)
        Check.equal(text(tv), "a \\textbf{word} b", "Bold wraps the selection")
        Check.equal(selection(tv), NSRange(location: 10, length: 4))
        tapSegment(styles, 1)
        Check.equal(text(tv), "a \\textbf{\\textit{word}} b", "styles nest on the kept selection")

        let (tv2, _) = makeEditor("$v$")
        tv2.setSelectedRange(NSRange(location: 1, length: 1))
        tv2.performMarkup(.textStyle(.bold))
        Check.equal(text(tv2), "$\\mathbf{v}$", "math: \\mathbf")
        let (tv3, _) = makeEditor("a ")
        tv3.performMarkup(.textStyle(.emphasis))
        Check.equal(text(tv3), "a \\emph{}")
        Check.equal(tv3.activeSnippetStop, NSRange(location: 8, length: 0))

        let (tv4, _) = makeEditor("")
        guard let bar4 = tv4.touchBar else { return Check.fail("no bar") }
        pickOption(bar4.item(forIdentifier: Item.sections), index: 0)
        Check.equal(text(tv4), "\\section{}")
        Check.equal(tv4.activeSnippetStop, NSRange(location: 9, length: 0))
        let (tv5, _) = makeEditor("Intro")
        tv5.setSelectedRange(NSRange(location: 0, length: 5))
        tv5.performMarkup(.section("subsection"))
        Check.equal(text(tv5), "\\subsection{Intro}")
        Check.equal(selection(tv5), NSRange(location: 12, length: 5))
        let (tv6, _) = makeEditor("text more", caret: 4)
        tv6.performMarkup(.section("section"))
        Check.equal(text(tv6), "text\n\\section{}\nmore", "a heading gets its own line")

        let (tv7, _) = makeEditor("x")
        tv7.performMarkup(.toggleComment)
        Check.equal(text(tv7), "% x")
    }

    await Check.suite("Touch Bar: environments and display math (snippets and line wrapping)") {
        let (tv, _) = makeEditor("")
        guard let bar = tv.touchBar else { return Check.fail("no bar") }
        guard let theorem = EditorTouchBar.environments.firstIndex(of: "theorem") else { return Check.fail("theorem") }
        pickFromPopover(bar.item(forIdentifier: Item.environments), index: theorem)
        Check.equal(text(tv), "\\begin{theorem}\n\(unit)\n\\end{theorem}")
        Check.equal(caret(tv), utf16Length("\\begin{theorem}\n\(unit)"), "caret in the body")

        let (tv2, _) = makeEditor("Text here", caret: 4)
        tv2.performMarkup(.environment("proof"))
        Check.equal(text(tv2), "Text\n\\begin{proof}\n\(unit)\n\\end{proof}\nhere", "own lines, spaces absorbed")

        let (tv3, _) = makeEditor("a\nb\n")
        tv3.setSelectedRange(NSRange(location: 0, length: 4))
        tv3.performMarkup(.environment("proof"))
        Check.equal(text(tv3), "\\begin{proof}\n\(unit)a\n\(unit)b\n\\end{proof}\n", "lines wrapped and indented")
        Check.equal(selection(tv3), NSRange(location: utf16Length("\\begin{proof}\n\(unit)"),
                                            length: utf16Length("a\n\(unit)b")), "body selected")

        let (tv4, _) = makeEditor("x\ny")
        tv4.setSelectedRange(NSRange(location: 0, length: 3))
        tv4.performMarkup(.environment("itemize"))
        Check.equal(text(tv4), "\\begin{itemize}\n\(unit)\\item x\n\(unit)\\item y\n\\end{itemize}", "list items")

        let (tv5, _) = makeEditor("  a\n  b")
        tv5.setSelectedRange(NSRange(location: 0, length: 7))
        tv5.performMarkup(.environment("lemma"))
        Check.equal(text(tv5), "  \\begin{lemma}\n  \(unit)a\n  \(unit)b\n  \\end{lemma}", "indentation kept")

        let (tv6, _) = makeEditor("\\includegraphics{x}")
        tv6.setSelectedRange(NSRange(location: 0, length: 19))
        tv6.performMarkup(.environment("figure"))
        Check.equal(text(tv6), "\\begin{figure}[htbp]\n\(unit)\\includegraphics{x}\n\\end{figure}", "catalog arguments")

        let (tv7, _) = makeEditor("a\r\nb")
        tv7.setSelectedRange(NSRange(location: 0, length: 4))
        tv7.performMarkup(.environment("proof"))
        Check.equal(text(tv7), "\\begin{proof}\r\n\(unit)a\r\n\(unit)b\r\n\\end{proof}", "CRLF kept")

        let (tv8, _) = makeEditor("")
        guard let bar8 = tv8.touchBar else { return Check.fail("no bar") }
        pickOption(bar8.item(forIdentifier: Item.displayMath), index: 0)
        Check.equal(text(tv8), "\\[\n\(unit)\n\\]")
        Check.equal(caret(tv8), utf16Length("\\[\n\(unit)"))

        let (tv9, _) = makeEditor("x = 1")
        tv9.setSelectedRange(NSRange(location: 0, length: 5))
        tv9.performMarkup(.displayMath(.equation))
        Check.equal(text(tv9), "\\begin{equation}\n\(unit)x = 1\n\\end{equation}")
        Check.expect(!tv9.performMarkup(.displayMath(.align)), "display math inside math is refused")

        let (tv10, _) = makeEditor("")
        tv10.performMarkup(.displayMath(.align))
        Check.equal(text(tv10), "\\begin{align}\n\(unit)lhs &= rhs \\\\\n\(unit)\n\\end{align}", "catalog align snippet")
        Check.equal(tv10.activeSnippetStop, NSRange(location: utf16Length("\\begin{align}\n\(unit)"), length: 3), "lhs selected")
    }

    await Check.suite("Touch Bar: one undoable edit per action") {
        let (tv, buffer) = makeEditor("a word b")
        tv.setSelectedRange(NSRange(location: 2, length: 4))
        let before = buffer.changeCount
        tv.performMarkup(.textStyle(.bold))
        Check.equal(buffer.changeCount, before + 1, "one reported edit")
        await endEvent(tv)
        Check.equal(tv.undoManager?.undoActionName, LaTeXMarkupAction.TextStyle.bold.localizedName, "undo action name")
        tv.undoManager?.undo()
        Check.equal(text(tv), "a word b", "undo restores the text")
        tv.undoManager?.redo()
        Check.equal(text(tv), "a \\textbf{word} b", "redo")

        let (tv2, _) = makeEditor("x\ny")
        tv2.setSelectedRange(NSRange(location: 0, length: 3))
        tv2.performMarkup(.environment("enumerate"))
        await endEvent(tv2)
        tv2.undoManager?.undo()
        Check.equal(text(tv2), "x\ny", "undo a wrapped environment")

        let (tv3, _) = makeEditor("Let ")
        tv3.performMarkup(.fraction)
        await endEvent(tv3)
        Check.equal(tv3.undoManager?.undoActionName, LaTeXMarkupAction.fraction.localizedName)
        tv3.undoManager?.undo()
        Check.equal(text(tv3), "Let ", "undo a snippet insertion")
    }

    await Check.suite("Touch Bar: Vim modes") {
        var config = EditorConfiguration()
        config.vimMode = true
        let (tv, _) = makeEditor("ab", caret: 0, configuration: config)
        let controller = EditorController()
        controller.bind(to: tv)
        Check.equal(tv.vimEngine?.mode, .normal)
        tv.performMarkup(.mathCommand("\\alpha"))
        Check.equal(text(tv), "$\\alpha$ab", "inserted before the cursor")
        Check.equal(tv.vimEngine?.mode, .normal, "stays in normal mode")
        Check.equal(caret(tv), 7, "cursor on the last inserted character")
        await endEvent(tv)
        await touchBarPress("u", tv)
        Check.equal(text(tv), "ab", "u undoes the Touch Bar edit")
        Check.equal(tv.vimEngine?.mode, .normal)

        tv.performMarkup(.fraction)
        Check.equal(text(tv), "$\\frac{}{}$ab")
        Check.equal(tv.vimEngine?.mode, .insert, "something to fill in → insert mode")
        Check.equal(controller.vimMode, .insert, "mode published")
        Check.equal(tv.activeSnippetStop, NSRange(location: 7, length: 0), "snippet session kept")
        type("1", tv)
        Check.equal(text(tv), "$\\frac{1}{}$ab", "typing goes into the numerator")
        await endEvent(tv)

        let (tv2, _) = makeEditor("one two", caret: 0, configuration: config)
        await touchBarPress("vee", tv2)
        Check.equal(tv2.vimEngine?.mode, .visual)
        Check.equal(selection(tv2), NSRange(location: 0, length: 7), "visual selection")
        tv2.performMarkup(.textStyle(.italic))
        Check.equal(text(tv2), "\\textit{one two}", "visual selection wrapped")
        Check.equal(tv2.vimEngine?.mode, .normal, "back to normal mode")
        Check.equal(caret(tv2), 0, "cursor at the start of the change")

        let (tv3, _) = makeEditor("x", caret: 0, configuration: config)
        await touchBarPress(":", tv3)
        Check.equal(tv3.vimEngine?.mode, .commandLine)
        Check.expect(!tv3.performMarkup(.mathCommand("\\beta")), "no edit while typing a command line")
        Check.equal(text(tv3), "x")
        Check.equal(tv3.vimEngine?.mode, .commandLine, "command line untouched")
    }
}

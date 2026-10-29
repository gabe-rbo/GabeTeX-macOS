import AppKit
import CheckKit
import EditorKit
import TeXCore

// Checks for the two-way sync support of the editor: `word(at:)`, `reveal` + its flash, `goTo`'s
// highlight, ⌘-click → Show in PDF and the "Show in PDF" context-menu item. All headless: events are
// synthesized and passed straight to the view (nothing is shown); the flash is also rendered off-screen
// with `cacheDisplay` to prove it is really painted (and removed again).

// MARK: - Helpers

/// What the editor reported through its callbacks.
@MainActor private final class SyncRecorder {
    var shown: [(position: SourcePosition, word: String?)] = []
    var references: [IncludeReference] = []
    var labels: [String] = []

    func attach(to controller: EditorController) {
        controller.onShowInPDF = { [unowned self] position, word in self.shown.append((position, word)) }
        controller.onOpenReference = { [unowned self] reference in self.references.append(reference) }
        controller.onOpenLabel = { [unowned self] key in self.labels.append(key) }
    }
}

/// An editor inside a (never shown) scroll view, so scrolling and centering are real.
@MainActor private func makeScrolledEditor(
    _ source: String, size: NSSize = NSSize(width: 520, height: 300),
    configuration: EditorConfiguration = EditorConfiguration()
) -> (scroll: LaTeXEditorScrollView, tv: LaTeXTextView, buffer: SourceBuffer, controller: EditorController) {
    let scroll = LaTeXEditorScrollView(configuration: configuration)
    scroll.frame = NSRect(origin: .zero, size: size)
    scroll.layoutSubtreeIfNeeded()
    let tv = scroll.editor
    let buffer = SourceBuffer(url: URL(fileURLWithPath: "/tmp/editorkit-checks/sync.tex"), text: source)
    tv.attach(buffer)
    let controller = EditorController()
    controller.bind(to: tv)
    return (scroll, tv, buffer, controller)
}

/// Waits (polling) until `condition` holds; false on timeout.
@MainActor private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor private func pause(_ milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

/// Rect of a character in view coordinates.
@MainActor private func glyphRect(ofCharacter index: Int, in tv: LaTeXTextView) -> NSRect? {
    guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
    lm.ensureLayout(for: tc)
    let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
    let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
    return rect.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
}

/// A point on the left quarter of a character (a click there puts the caret before it).
@MainActor private func clickPoint(forCharacter index: Int, in tv: LaTeXTextView) -> NSPoint? {
    guard let rect = glyphRect(ofCharacter: index, in: tv) else { return nil }
    return NSPoint(x: rect.minX + rect.width * 0.25, y: rect.midY)
}

@MainActor private func mouseEvent(_ type: NSEvent.EventType, at viewPoint: NSPoint, in view: NSView,
                                   flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent? {
    NSEvent.mouseEvent(with: type, location: view.convert(viewPoint, to: nil), modifierFlags: flags,
                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                       eventNumber: 0, clickCount: clickCount, pressure: 1)
}

// MARK: - word(at:)

@MainActor private func expectWord(_ source: String, _ offset: Int, _ expected: String?, _ range: NSRange? = nil,
                                   file: StaticString = #fileID, line: UInt = #line) {
    let (tv, _) = makeEditor(source, caret: 0)
    let controller = EditorController()
    controller.bind(to: tv)
    let found = controller.word(at: offset)
    Check.equal(found?.word, expected, "word(at: \(offset)) in \(source.debugDescription)", file: file, line: line)
    if let range {
        Check.equal(found?.range, range, "range of word(at: \(offset)) in \(source.debugDescription)", file: file, line: line)
    }
}

private func wordChecks() async {
    await Check.suite("word(at:): words, accents, control words, punctuation, UTF-16") {
        // Plain words and the "at or right before" rule.
        expectWord("Hello world", 0, "Hello", NSRange(location: 0, length: 5))
        expectWord("Hello world", 3, "Hello")
        expectWord("Hello world", 5, "Hello", NSRange(location: 0, length: 5))     // offset at the word end
        expectWord("Hello world", 6, "world", NSRange(location: 6, length: 5))
        expectWord("Hello world", 11, "world", NSRange(location: 6, length: 5))    // end of the text
        expectWord("Hello world", -4, "Hello")                                     // clamped
        expectWord("Hello world", 99, "world")
        // Between words / punctuation.
        expectWord("foo. bar", 3, "foo", NSRange(location: 0, length: 3))          // before the dot: the word ending here
        expectWord("foo. bar", 4, nil)                                             // after the dot, before the space
        expectWord("foo. bar", 5, "bar")
        expectWord("foo  bar", 3, "foo")                                           // right after a word, before spaces
        expectWord("foo  bar", 4, nil)                                             // between two spaces
        expectWord("foo  bar", 5, "bar")
        expectWord("(x)", 0, nil)
        expectWord("(x)", 1, "x")
        expectWord("(x)", 2, "x")
        expectWord("(x)", 3, nil)
        expectWord("", 0, nil)
        // Apostrophes, hyphens, underscores and dots end a word; digits are word characters.
        expectWord("don't", 1, "don", NSRange(location: 0, length: 3))
        expectWord("don't", 4, "t", NSRange(location: 4, length: 1))
        expectWord("well-known", 4, "well")
        expectWord("well-known", 7, "known", NSRange(location: 5, length: 5))
        expectWord("page 42.", 6, "42", NSRange(location: 5, length: 2))
        expectWord("page 42.", 7, "42")
        expectWord("page 42.", 8, nil)
        expectWord("abc123def", 4, "abc123def", NSRange(location: 0, length: 9))
        expectWord("x_1", 1, "x")
        expectWord("x_1", 2, "1", NSRange(location: 2, length: 1))
        expectWord("αβγ δ", 1, "αβγ", NSRange(location: 0, length: 3))
        // Line terminators.
        expectWord("foo\r\nbar", 3, "foo")
        expectWord("foo\r\nbar", 4, nil)                                          // between \r and \n: after a line break
        expectWord("foo\r\nbar", 5, "bar", NSRange(location: 5, length: 3))
        // Portuguese accents, precomposed and decomposed.
        expectWord("Introdução e mais", 7, "Introdução", NSRange(location: 0, length: 10))
        expectWord("Introdução e mais", 10, "Introdução")
        expectWord("Introdução e mais", 11, "e", NSRange(location: 11, length: 1))
        let decomposed = "Introduc\u{327}a\u{303}o e mais"
        expectWord(decomposed, 0, decomposed.components(separatedBy: " ")[0], NSRange(location: 0, length: 12))
        expectWord(decomposed, 8, decomposed.components(separatedBy: " ")[0], NSRange(location: 0, length: 12))  // inside "ç"
        expectWord(decomposed, 12, decomposed.components(separatedBy: " ")[0])
        // Control words: the name without the backslash, wherever the offset is on it.
        let section = "\\section{Introdução}"
        for offset in [0, 1, 4, 7, 8] {
            expectWord(section, offset, "section", NSRange(location: 1, length: 7))
        }
        expectWord(section, 9, "Introdução", NSRange(location: 9, length: 10))
        expectWord("\\textbf{Olá}", 10, "Olá", NSRange(location: 8, length: 3))
        expectWord("\\textbf{Olá}", 11, "Olá")
        expectWord("\\alpha1", 0, "alpha", NSRange(location: 1, length: 5))
        expectWord("\\alpha1", 3, "alpha", NSRange(location: 1, length: 5))
        expectWord("\\alpha1", 6, "1", NSRange(location: 6, length: 1))            // the name ends at its last letter
        expectWord("\\alpha1", 7, "1")
        expectWord("\\textbfção", 2, "textbf", NSRange(location: 1, length: 6))
        expectWord("\\textbfção", 8, "ção", NSRange(location: 7, length: 3))
        expectWord("\\@ifnextchar{x}", 5, "@ifnextchar", NSRange(location: 1, length: 11))
        expectWord("\\\\alpha1", 4, "alpha1", NSRange(location: 2, length: 6))     // `\\` is a line break, not a command
        expectWord("\\\\alpha1", 0, nil)
        expectWord("\\\\alpha1", 1, nil)
        expectWord("a\\%b", 1, "a")                                                // `\%` is not a word
        expectWord("a\\%b", 2, nil)
        expectWord("a\\%b", 3, "b")
        // Emoji and surrogate pairs: offsets are UTF-16, an offset inside a pair moves to its start.
        expectWord("a😀b", 1, "a", NSRange(location: 0, length: 1))
        expectWord("a😀b", 2, "a")
        expectWord("a😀b", 3, "b", NSRange(location: 3, length: 1))
        expectWord("a😀b", 4, "b")
        expectWord("😀 olá", 0, nil)
        expectWord("😀 olá", 1, nil)
        expectWord("😀 olá", 2, nil)
        expectWord("😀 olá", 3, "olá", NSRange(location: 3, length: 3))
        expectWord("👩\u{200D}💻code", 5, "code", NSRange(location: 5, length: 4))
        expectWord("👩\u{200D}💻code", 2, nil)
        expectWord("❤️x", 0, nil)                                                  // emoji + variation selector
        expectWord("❤️x", 2, "x")
        // No editor behind the controller.
        Check.expect(EditorController().word(at: 0) == nil, "a controller without an editor finds nothing")
    }
}

// MARK: - reveal

private func revealChecks() async {
    await Check.suite("reveal: caret at the range start, vertical centering, x offset kept") {
        let lines = (1...300).map { "Line \($0): the quick brown fox" }.joined(separator: "\n")
        let ns = lines as NSString
        let (scroll, tv, buffer, controller) = makeScrolledEditor(lines)
        let clip = scroll.contentView
        let lineStart = ns.range(of: "Line 150:").location
        let quick = ns.range(of: "quick", options: [], range: NSRange(location: lineStart, length: 40))

        // On macOS 26 the floating ruler makes AppKit keep the clip view's x negative (-ruler thickness).
        scroll.reflectScrolledClipView(clip)
        let x0 = clip.bounds.origin.x
        print("    (clip view x offset in this environment: \(x0))")
        let textBefore = text(tv)
        let changeBefore = buffer.changeCount

        controller.reveal(quick)
        Check.equal(selection(tv), NSRange(location: quick.location, length: 0), "caret at the start of the range")
        Check.equal(clip.bounds.origin.x, x0, "the clip view's x offset is never forced to 0")
        if let rect = glyphRect(ofCharacter: quick.location, in: tv) {
            let insets = clip.contentInsets
            let b = clip.bounds
            let center = b.minY + insets.top + (b.height - insets.top - insets.bottom) / 2
            Check.expect(abs(rect.midY - center) <= 1.5, "the target line is vertically centered (line at \(rect.midY), center \(center))")
        } else {
            Check.fail("no glyph rect for the target")
        }
        Check.expect(!buffer.isDirty && buffer.changeCount == changeBefore, "reveal leaves the buffer clean")
        Check.expect(!buffer.undoManager.canUndo && !buffer.undoManager.canRedo, "reveal registers no undo")
        Check.equal(text(tv), textBefore, "reveal never edits the text")
        Check.equal(controller.cursor, SourcePosition(line: 150, column: quick.location - lineStart + 1), "controller cursor follows")

        // Without flash: caret and scroll only.
        controller.reveal(NSRange(location: ns.range(of: "Line 20:").location, length: 4), flash: false)
        Check.expect(tv.flashedRange == nil, "flash: false draws nothing")
        Check.equal(controller.cursor.line, 20)
        // An empty range flashes its line's content; a blank line has nothing to flash.
        let line30 = ns.range(of: "Line 30:")
        controller.reveal(NSRange(location: line30.location + 5, length: 0))
        Check.equal(tv.flashedRange, NSRange(location: line30.location, length: NSMaxRange(ns.range(of: "fox", options: [], range: NSRange(location: line30.location, length: 40))) - line30.location),
                    "an empty range flashes the content of its line")
        // Ranges are clamped; a position in the middle of a surrogate pair moves to its start.
        controller.reveal(NSRange(location: 1_000_000, length: 5))
        Check.equal(selection(tv), NSRange(location: ns.length, length: 0), "past the end → end of the text")
        Check.expect(tv.flashedRange == nil, "nothing to flash past the end")
        let (emoji, _, _, emojiController) = makeScrolledEditor("a😀b")
        emojiController.reveal(NSRange(location: 2, length: 1), flash: false)
        Check.equal(emoji.editor.selectedRange(), NSRange(location: 1, length: 0), "caret snaps to a composed character boundary")
        // Nothing attached: harmless.
        let bare = LaTeXTextView()
        let bareController = EditorController()
        bareController.bind(to: bare)
        bareController.reveal(NSRange(location: 0, length: 3))
        Check.expect(bare.flashedRange == nil)
    }

    await Check.suite("reveal: horizontal scroll only when a non-wrapping line needs it") {
        var config = EditorConfiguration()
        config.wrapLines = false
        let tail = (0..<200).map { _ in "abcdefghij" }.joined(separator: " ")
        let source = "short line\n" + tail + " TARGET end"
        let (scroll, tv, _, controller) = makeScrolledEditor(source, size: NSSize(width: 420, height: 200), configuration: config)
        let target = (source as NSString).range(of: "TARGET")
        controller.reveal(target)
        let clip = scroll.contentView
        if let rect = glyphRect(ofCharacter: target.location, in: tv) {
            Check.expect(rect.minX >= clip.bounds.minX && rect.maxX <= clip.bounds.maxX,
                         "the target is within the visible columns (x \(rect.minX)…\(rect.maxX), clip \(clip.bounds.minX)…\(clip.bounds.maxX))")
        } else {
            Check.fail("no glyph rect for the target")
        }
        // Back to the short line: still reachable (and the offset never jumps to a forced 0 when it is not needed).
        controller.reveal(NSRange(location: 0, length: 5))
        if let rect = glyphRect(ofCharacter: 0, in: tv) {
            Check.expect(rect.minX >= clip.bounds.minX && rect.maxX <= clip.bounds.maxX, "the start of the text is visible again")
        }
    }

    await Check.suite("reveal: flash lifecycle (fade, replacement, buffer swap, edits, Reduce Motion)") {
        let lines = (1...200).map { "Line \($0): the quick brown fox" }.joined(separator: "\n")
        let ns = lines as NSString
        let (_, tv, buffer, controller) = makeScrolledEditor(lines)
        tv.revealFlashOptions = RevealFlashOptions(hold: .milliseconds(150), fade: .milliseconds(600), reduceMotion: false)
        let first = ns.range(of: "quick", options: [], range: NSRange(location: ns.range(of: "Line 50:").location, length: 40))
        let second = ns.range(of: "brown", options: [], range: NSRange(location: ns.range(of: "Line 120:").location, length: 40))

        Check.expect(tv.flashedRange == nil && tv.flashIntensity == 0, "idle before any reveal")
        controller.reveal(first)
        Check.equal(tv.flashedRange, first)
        Check.expect(tv.flashIntensity > 0.95, "starts at full strength")
        await pause(350)                                   // 350 ms in: fading
        Check.equal(tv.flashedRange, first, "still showing while fading")
        let fading = tv.flashIntensity
        Check.expect(fading > 0 && fading < 0.95, "the highlight fades (\(fading))")
        controller.reveal(second)                          // replaces the first flash
        Check.equal(tv.flashedRange, second, "a second reveal replaces the first flash")
        Check.expect(tv.flashIntensity > 0.95, "the new flash starts at full strength")
        await pause(450)                                   // the first flash would have ended 50 ms ago
        Check.equal(tv.flashedRange, second, "the cancelled first flash cannot remove the second")
        Check.expect(tv.flashIntensity > 0 && tv.flashIntensity < 0.95, "the second flash is fading on its own clock")
        Check.expect(await waitUntil { tv.flashedRange == nil }, "the flash removes itself")
        Check.equal(tv.flashIntensity, 0)
        Check.expect(!buffer.isDirty && !buffer.undoManager.canUndo, "a whole flash cycle leaves buffer and undo untouched")

        // Buffer swap cancels it (and the new buffer shows nothing).
        controller.reveal(first)
        Check.expect(tv.flashedRange != nil)
        let other = SourceBuffer(url: URL(fileURLWithPath: "/tmp/editorkit-checks/other.tex"), text: "other buffer text")
        tv.attach(other)
        Check.expect(tv.flashedRange == nil, "a buffer swap cancels the flash")
        tv.attach(buffer)
        Check.expect(tv.flashedRange == nil, "…and it does not come back with the old buffer")
        await pause(120)
        Check.expect(tv.flashedRange == nil, "the cancelled flash's timer did nothing later")
        tv.detachCurrentBuffer()
        controller.reveal(first)
        Check.expect(tv.flashedRange == nil, "no buffer shown → nothing happens")
        tv.attach(buffer)

        // A character edit drops it; so does a new reveal with flash: false.
        controller.reveal(first)
        tv.setSelectedRange(NSRange(location: first.location, length: 0))
        type("x", tv)
        Check.expect(tv.flashedRange == nil, "typing cancels the flash")
        controller.reveal(first)
        controller.reveal(second, flash: false)
        Check.expect(tv.flashedRange == nil, "reveal(flash: false) cancels a running flash")
        await endEvent(tv)

        // Reduce Motion: constant strength, then gone — no fade.
        tv.revealFlashOptions = RevealFlashOptions(reducedMotionDuration: .milliseconds(500), reduceMotion: true)
        controller.reveal(first)
        await pause(150)
        Check.equal(tv.flashedRange, first)
        Check.equal(tv.flashIntensity, 1, "with Reduce Motion the highlight does not fade")
        Check.expect(await waitUntil { tv.flashedRange == nil }, "…and is removed after its short display time")
        Check.equal(tv.flashIntensity, 0)
    }

    await Check.suite("goTo(highlight: true) uses the reveal flash over the line content") {
        let source = "alpha\n    indented line   \n\nomega"
        let ns = source as NSString
        let (_, tv, buffer, controller) = makeScrolledEditor(source)
        controller.goTo(line: 2, column: 6, highlight: true)
        let content = ns.range(of: "indented line")
        Check.equal(tv.flashedRange, content, "the line's content without indentation or trailing blanks")
        Check.equal(controller.cursor, SourcePosition(line: 2, column: 6), "caret at the requested column")
        controller.goTo(line: 1, highlight: false)
        Check.expect(tv.flashedRange == nil, "highlight: false cancels and shows nothing")
        Check.equal(controller.cursor, SourcePosition(line: 1, column: 1))
        controller.goTo(line: 3, highlight: true)
        Check.expect(tv.flashedRange == nil, "a blank line has nothing to flash")
        controller.goTo(line: 99, column: 99, highlight: true)
        Check.equal(controller.cursor.line, 4, "line clamped")
        Check.equal(tv.flashedRange, ns.range(of: "omega"))
        Check.expect(!buffer.isDirty && !buffer.undoManager.canUndo, "goTo never dirties the buffer")
    }
}

// MARK: - Painting

private func paintingChecks() async {
    await Check.suite("reveal flash is painted behind wrapped text, in Light and Dark, and removed on cancel") {
        var config = EditorConfiguration()
        config.highlightCurrentLine = false
        config.wrapLines = true
        let source = (0..<70).map { "word\($0)" }.joined(separator: " ")
        let (_, tv, _, controller) = makeScrolledEditor(source, size: NSSize(width: 360, height: 700), configuration: config)
        tv.revealFlashOptions = RevealFlashOptions(hold: .seconds(30), fade: .seconds(1), reduceMotion: false)
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return Check.fail("no layout manager") }
        let ns = source as NSString
        lm.ensureLayout(for: tc)
        // One space glyph (ink-free) in the middle of every wrapped line fragment.
        var samples: [NSPoint] = []
        let origin = tv.textContainerOrigin
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let last = NSMaxRange(chars) - 1
            var i = chars.location + chars.length / 2
            while i < last, ns.character(at: i) != 32 { i += 1 }
            guard i < last, ns.character(at: i) == 32 else { return }
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1),
                                                                    actualCharacterRange: nil), in: tc)
            samples.append(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y))
        }
        Check.expect(samples.count >= 3, "the test line wraps onto several fragments (\(samples.count))")
        guard let lastSample = samples.last else { return }
        let below = NSPoint(x: lastSample.x, y: lastSample.y + 80)        // empty page area under the text
        let area = NSRect(x: 0, y: 0, width: tv.bounds.width, height: lastSample.y + 120)

        @MainActor func colors(at points: [NSPoint]) -> [[CGFloat]]? {
            guard let rep = tv.bitmapImageRepForCachingDisplay(in: area) else { return nil }
            tv.cacheDisplay(in: area, to: rep)
            let scale = CGFloat(rep.pixelsWide) / area.width
            return points.map { point in
                let color = rep.colorAt(x: Int(point.x * scale), y: Int((point.y - area.minY) * scale))?
                    .usingColorSpace(.sRGB)
                guard let color else { return [-1, -1, -1, -1] }
                return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            }
        }
        @MainActor func differs(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
            zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } > 0.04
        }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            tv.appearance = NSAppearance(named: name)
            controller.reveal(NSRange(location: 0, length: 0), flash: false)
            guard let baseline = colors(at: samples + [below]) else { return Check.fail("cannot render the view off-screen") }

            controller.reveal(NSRange(location: 0, length: ns.length), flash: true)
            guard let flashed = colors(at: samples + [below]) else { return Check.fail("cannot render the view off-screen") }
            for (index, _) in samples.enumerated() {
                Check.expect(differs(baseline[index], flashed[index]), "\(name.rawValue): line fragment \(index) is tinted by the flash")
            }
            Check.expect(!differs(baseline[samples.count], flashed[samples.count]), "\(name.rawValue): nothing is painted outside the range")

            // Only the first word: the other fragments stay clean.
            controller.reveal(ns.range(of: "word0"), flash: true)
            if let partial = colors(at: samples + [below]), partial.count == samples.count + 1 {
                Check.expect(!differs(baseline[samples.count - 1], partial[samples.count - 1]),
                             "\(name.rawValue): lines outside the flashed range are not tinted")
            }

            controller.reveal(NSRange(location: 0, length: ns.length), flash: true)
            controller.reveal(NSRange(location: 0, length: 0), flash: false)      // cancel
            if let cleared = colors(at: samples + [below]) {
                for index in samples.indices {
                    Check.expect(!differs(baseline[index], cleared[index]), "\(name.rawValue): the flash is gone after cancelling (fragment \(index))")
                }
            }
        }
        tv.appearance = nil
    }
}

// MARK: - ⌘-click and the context menu

private func clickChecks() async {
    let source = "Hello brave world\n\\input{chapters/one} and \\ref{eq:a} then \\cite{key,other} end\nIntrodução simples"
    let ns = source as NSString

    await Check.suite("⌘-click on ordinary text → caret + onShowInPDF; references keep their callbacks") {
        let (_, tv, buffer, controller) = makeScrolledEditor(source)
        let recorder = SyncRecorder()
        recorder.attach(to: controller)
        tv.setSelectedRange(NSRange(location: 0, length: 5))                      // an existing selection

        // Ordinary text.
        let brave = ns.range(of: "brave")
        guard let point = clickPoint(forCharacter: brave.location + 2, in: tv),
              let down = mouseEvent(.leftMouseDown, at: point, in: tv, flags: .command),
              let drag = mouseEvent(.leftMouseDragged, at: NSPoint(x: point.x + 120, y: point.y + 30), in: tv, flags: .command),
              let up = mouseEvent(.leftMouseUp, at: point, in: tv, flags: .command) else {
            return Check.fail("could not synthesize mouse events")
        }
        tv.mouseDown(with: down)
        Check.equal(recorder.shown.count, 1, "one Show in PDF report")
        Check.equal(recorder.shown.first?.position, SourcePosition(line: 1, column: brave.location + 3), "position of the click")
        Check.equal(recorder.shown.first?.word, "brave", "the word under the click")
        Check.equal(selection(tv), NSRange(location: brave.location + 2, length: 0), "the caret moved to the click (selection collapsed)")
        Check.equal(controller.cursor, SourcePosition(line: 1, column: brave.location + 3))
        Check.expect(recorder.references.isEmpty && recorder.labels.isEmpty, "the other callbacks stay silent")
        tv.mouseDragged(with: drag)
        Check.equal(selection(tv), NSRange(location: brave.location + 2, length: 0), "⌘-click does not start a selection drag")
        tv.mouseUp(with: up)
        Check.equal(selection(tv), NSRange(location: brave.location + 2, length: 0), "…nor does the mouse-up change it")
        Check.expect(!buffer.isDirty && !buffer.undoManager.canUndo, "no edit, no undo")

        // Accented word on the last line.
        let intro = ns.range(of: "Introdução")
        if let p = clickPoint(forCharacter: intro.location + 7, in: tv),
           let event = mouseEvent(.leftMouseDown, at: p, in: tv, flags: .command) {
            tv.mouseDown(with: event)
            Check.equal(recorder.shown.last?.word, "Introdução")
            Check.equal(recorder.shown.last?.position, SourcePosition(line: 3, column: 8))
        } else {
            Check.fail("no click point for the accented word")
        }

        // An include argument still opens the file reference (and does not report Show in PDF).
        let shownBefore = recorder.shown.count
        if let p = clickPoint(forCharacter: ns.range(of: "chapters").location + 2, in: tv),
           let event = mouseEvent(.leftMouseDown, at: p, in: tv, flags: .command) {
            tv.mouseDown(with: event)
            Check.equal(recorder.references.count, 1, "\\input{…} fires onOpenReference")
            Check.equal(recorder.references.first?.argument, "chapters/one")
            Check.equal(recorder.shown.count, shownBefore, "…and not onShowInPDF")
        } else {
            Check.fail("no click point for the include argument")
        }
        // A \ref key still jumps to its label.
        if let p = clickPoint(forCharacter: ns.range(of: "eq:a").location + 1, in: tv),
           let event = mouseEvent(.leftMouseDown, at: p, in: tv, flags: .command) {
            tv.mouseDown(with: event)
            Check.equal(recorder.labels, ["eq:a"], "\\ref{…} fires onOpenLabel")
            Check.equal(recorder.shown.count, shownBefore, "…and not onShowInPDF")
        } else {
            Check.fail("no click point for the ref key")
        }
        Check.equal(tv.citationKey(at: ns.range(of: "other").location + 1), "other", "cite keys are recognised")
        Check.expect(tv.citationKey(at: brave.location) == nil, "ordinary text is not a cite key")
    }

    await Check.suite("⌘-click on a cite key, and without a handler, is left to AppKit") {
        let (_, tv, _, controller) = makeScrolledEditor(source)
        let recorder = SyncRecorder()
        recorder.attach(to: controller)
        // (`handleCommandClick` is what `mouseDown` calls first; false means "let NSTextView have it".)
        if let p = clickPoint(forCharacter: ns.range(of: "key").location + 1, in: tv) {
            Check.expect(!tv.handleCommandClick(at: p), "a \\cite key is not consumed")
            Check.expect(recorder.shown.isEmpty, "…and does not report Show in PDF")
            controller.onShowInPDF = nil
            if let q = clickPoint(forCharacter: ns.range(of: "world").location + 1, in: tv) {
                Check.expect(!tv.handleCommandClick(at: q), "without an onShowInPDF handler ordinary text is not consumed")
            }
            controller.onShowInPDF = { [unowned recorder] position, word in recorder.shown.append((position, word)) }
            if let q = clickPoint(forCharacter: ns.range(of: "world").location + 1, in: tv) {
                Check.expect(tv.handleCommandClick(at: q), "with a handler it is consumed")
                Check.equal(recorder.shown.last?.word, "world")
            }
        } else {
            Check.fail("no click point")
        }
    }

    await Check.suite("Context menu: \"Show in PDF\" (⇧⌘J) on top, reports the clicked position") {
        let (_, tv, _, controller) = makeScrolledEditor(source)
        let recorder = SyncRecorder()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let world = ns.range(of: "world")
        guard let point = clickPoint(forCharacter: world.location + 1, in: tv),
              let rightClick = mouseEvent(.rightMouseDown, at: point, in: tv) else {
            return Check.fail("could not synthesize the right click")
        }
        // Without a handler there is nothing to show in the PDF: no item.
        let plain = tv.menu(for: rightClick)
        Check.expect(plain?.items.contains { $0.title == "Show in PDF" } != true, "no item while onShowInPDF is unset")

        recorder.attach(to: controller)
        guard let menu = tv.menu(for: rightClick), let item = menu.items.first else {
            return Check.fail("no context menu")
        }
        Check.equal(item.title, "Show in PDF", "the first item")
        Check.equal(item.keyEquivalent, "j", "key equivalent hint")
        Check.equal(item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]), [.command, .shift], "⇧⌘J")
        Check.expect(menu.items.count > 2 && menu.items[1].isSeparatorItem, "followed by a separator")
        Check.expect(menu.items.dropFirst().allSatisfy { $0.title != "Show in PDF" }, "exactly one item")
        // Asking again never stacks a second copy.
        let again = tv.menu(for: rightClick)
        Check.equal(again?.items.filter { $0.title == "Show in PDF" }.count, 1, "no duplicates on repeated menus")

        if let action = item.action {
            Check.expect(NSApp.sendAction(action, to: item.target, from: item), "the item's action is handled")
        } else {
            Check.fail("the item has no action")
        }
        Check.equal(recorder.shown.count, 1)
        Check.equal(recorder.shown.first?.position, SourcePosition(line: 1, column: world.location + 1 + 1), "the clicked position")
        Check.equal(recorder.shown.first?.word, "world")
    }
}

// MARK: - Entry

func revealAndSyncChecks() async {
    await wordChecks()
    await revealChecks()
    await paintingChecks()
    await clickChecks()
}

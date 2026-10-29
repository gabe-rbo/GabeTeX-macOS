import AppKit
import CheckKit
import EditorKit
import TeXCore

/// Helpers for headless editor checks: no window is ever created or shown.

/// A configured editor showing a fresh buffer with `text` and the caret at `caret` (default: end).
func makeEditor(_ text: String, caret: Int? = nil, configuration: EditorConfiguration = EditorConfiguration())
    -> (LaTeXTextView, SourceBuffer) {
    let editor = LaTeXTextView(configuration: configuration)
    let buffer = SourceBuffer(url: URL(fileURLWithPath: "/tmp/editorkit-checks/doc.tex"), text: text)
    editor.attach(buffer)
    let length = (text as NSString).length
    editor.setSelectedRange(NSRange(location: caret ?? length, length: 0))
    return (editor, buffer)
}

/// Types characters one by one like the keyboard does (`insertText` per character).
func type(_ string: String, _ editor: LaTeXTextView) {
    for character in string {
        editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

/// Ends the current "event" the way AppKit does: lets the main run loop turn, so the undo manager closes
/// its automatic per-event group itself (closing it by hand leaves NSUndoManager waiting for a run-loop
/// callback and the next registration raises). Groups opened explicitly (Vim) stay open, as in the app.
func endEvent(_ editor: LaTeXTextView) async {
    editor.breakUndoCoalescing()
    guard let undo = editor.undoManager else { return }
    var spins = 0
    repeat {
        try? await Task.sleep(for: .milliseconds(2))
        spins += 1
    } while undo.groupingLevel > 0 && spins < 3
}

func text(_ editor: LaTeXTextView) -> String {
    editor.textStorage?.string ?? ""
}

func caret(_ editor: LaTeXTextView) -> Int {
    editor.selectedRange().location
}

func selection(_ editor: LaTeXTextView) -> NSRange {
    editor.selectedRange()
}

func utf16Length(_ s: String) -> Int {
    (s as NSString).length
}

/// Milliseconds spent in `body`.
func measure(_ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    body()
    let d = clock.now - start
    let c = d.components
    return (Double(c.seconds) + Double(c.attoseconds) * 1e-18) * 1000
}

func ms(_ value: Double) -> String {
    String(format: "%.2f ms", value)
}

import AppKit
import CheckKit
import EditorKit
import TeXCore

// Headless checks for EditorKit — owned by the EditorKit agent. Run: swift run EditorKitChecks
// Text views are created without windows (nothing is shown on screen). Editing actions are invoked
// directly (insertText, insertNewline, insertTab …, as NSTextView's key bindings would); Vim keys are
// synthesized NSEvents passed to `keyDown`; event boundaries let the run loop close undo groups.

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

await Check.suite("SourceBuffer") {
    let buffer = SourceBuffer(url: URL(fileURLWithPath: "/tmp/x.tex"), text: "hello")
    Check.expect(!buffer.isDirty)
    buffer.noteEdit()
    Check.expect(buffer.isDirty)
    buffer.markSaved()
    Check.expect(!buffer.isDirty)
}

await editingChecks()
await snippetAndBufferChecks()
await diagnosticsChecks()
await completionAndVimChecks()
await commandClickChecks()
await revealAndSyncChecks()
await performanceChecks()
await keyboardChecks()
await touchBarChecks()
await touchBarPDFChecks()
await presentationChecks()
await shortcutsAndCompletionChecks()

Check.finish()

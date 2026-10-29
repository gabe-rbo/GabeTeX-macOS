import Foundation
import CheckKit
import VimKit

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

func stateChecks() {
    // Labels and defaults.
    Check.equal(VimMode.normal.label, "NORMAL")
    Check.equal(VimMode.insert.label, "INSERT")
    Check.equal(VimMode.visual.label, "VISUAL")
    Check.equal(VimMode.visualLine.label, "V-LINE")
    Check.equal(VimMode.replace.label, "REPLACE")
    Check.equal(VimMode.commandLine.label, "COMMAND")
    Check.equal(VimMode.allCases.count, 6)
    let fresh = VimEngine()
    Check.equal(fresh.mode, .normal)
    Check.equal(fresh.pendingKeys, "")
    Check.equal(fresh.commandLine, nil)
    Check.equal(fresh.indentUnit, "  ", "default indentUnit is two spaces")
    Check.equal(VimKey.ctrl("r"), VimKey("r", control: true))
    Check.equal(VimKey.escape, VimKey(special: .escape))

    // Pending keys for the status bar.
    var s = run("2d", on: "|abc")
    Check.equal(s.engine.pendingKeys, "2d")
    s.feed("<Esc>")
    Check.equal(s.engine.pendingKeys, "", "Esc clears a pending command")
    s = run("\"a2y", on: "|abc")
    Check.equal(s.engine.pendingKeys, "\"a2y")
    s.feed("w")
    Check.equal(s.engine.pendingKeys, "")
    vim("d<Esc>x", "|abc", "|bc")
    vim("2<Esc>x", "|abc", "|bc")
    vim("dq", "|abc", "|abc")                          // an invalid operator-pending key aborts the command
    vim("dqx", "|abc", "|bc")

    // Mode notifications.
    s = run("i<Esc>v<Esc>V<Esc>:<Esc>Rx<Esc>", on: "|abc")
    Check.equal(s.modeChanges, [.insert, .normal, .visual, .normal, .visualLine, .normal, .commandLine, .normal, .replace, .normal])

    // setMode.
    s = VimSession("ab|c")
    s.engine.setMode(.insert, in: s.buffer)
    Check.equal(s.engine.mode, .insert)
    s.buffer.vimReplace(s.buffer.vimSelection, with: "X")   // the host types
    s.feed("<Esc>")
    Check.equal(s.marked, "ab|Xc", "typing after setMode(.insert), then Esc")
    s = VimSession("|abc")
    s.feed("a")
    s.engine.setMode(.normal, in: s.buffer)
    Check.equal(s.marked, "a|bc", "setMode(.normal) does not move the cursor")
    s.feed("x")
    Check.equal(s.text, "ac")
    s = VimSession("|abcdef")
    s.buffer.vimSelection = NSRange(location: 1, length: 3)
    s.engine.setMode(.visual, in: s.buffer)
    Check.equal(s.engine.mode, .visual)
    Check.equal(s.selectedText, "bcd", "setMode(.visual) adopts the host selection")
    s.feed("d")
    Check.equal(s.text, "aef")
    s = VimSession("a\n|b\nc")
    s.engine.setMode(.visualLine, in: s.buffer)
    Check.equal(s.selectedText, "b\n")
    s = VimSession("|abc")
    s.engine.setMode(.commandLine, in: s.buffer)
    Check.equal(s.engine.commandLine, ":")
    s.feed("<Esc>")
    Check.equal(s.engine.mode, .normal)
    s = VimSession("|abc")
    s.engine.setMode(.replace, in: s.buffer)
    s.feed("x<Esc>")
    Check.equal(s.text, "xbc", "setMode(.replace)")
    s = VimSession("|abc")
    s.feed("d")
    s.engine.setMode(.insert, in: s.buffer)
    Check.equal(s.engine.pendingKeys, "", "setMode discards pending keys")

    // The host moves the cursor (mouse) or edits the text between keys.
    s = VimSession("|abcdef")
    s.feed("l")
    s.buffer.vimSelection = NSRange(location: 4, length: 0)
    s.feed("x")
    Check.equal(s.text, "abcdf", "a click moves the Vim cursor")
    s = VimSession("|abcdef")
    s.buffer.vimReplace(NSRange(location: 0, length: 6), with: "ab")
    s.feed("x")
    Check.equal(s.text, "a", "text replaced under the engine: the cursor is clamped")
    s = VimSession("ab|c\nxyz")
    s.feed("jk")
    Check.equal(lineNo(s), 1, "j k after a click use the clicked column")
    s = VimSession("abcdef|")
    s.feed("x")
    Check.equal(s.text, "abcde", "a click at the very end snaps to the last character")

    // Keys the engine does not handle.
    s = VimSession("|a")
    Check.equal(s.engine.handle(.ctrl("s"), in: s.buffer), false, "unknown Ctrl chords pass through")
    Check.equal(s.engine.handle(.escape, in: s.buffer), true, "Esc is consumed in normal mode")
    Check.equal(s.engine.handle(VimKey(special: .tab), in: s.buffer), true, "Tab is consumed in normal mode")
    Check.equal(s.engine.handle(VimKey("q"), in: s.buffer), true, "unmapped keys are swallowed")

    // Configuration.
    s = VimSession("  |a")
    s.engine.autoIndent = false
    s.feed("ox<Esc>")
    Check.equal(s.text, "  a\nx", "autoIndent off")
    s = VimSession("|1\n2\n3")
    s.feed("L")
    Check.equal(lineNo(s), 3, "L without visible-line information uses the whole text")
    s.feed("H")
    Check.equal(lineNo(s), 1, "H without visible-line information")
    s = VimSession("|1\n2\n3\n4\n5\n6")
    s.feed("<C-f>")
    Check.expect(lineNo(s) > 1, "Ctrl-f without visible-line information still moves")
    s.feed("<PageUp>")
    Check.equal(lineNo(s), 1, "PageUp goes back")
    let seen = Box<[VimViewportCommand]>([])
    s = VimSession("|a\nb")
    s.engine.onViewport = { seen.value.append($0) }
    s.feed("zzztzb")
    Check.equal(seen.value, [.cursorToCenter, .cursorToTop, .cursorToBottom], "zz zt zb")
    s = run("/zzz<CR>", on: "|a")
    Check.expect(s.engine.message?.hasPrefix("E486") == true, "message is exposed")
    s.feed("l")
    Check.equal(s.engine.message, nil, "and cleared by the next key")

    // Robustness.
    vim("99999999999999999999x", "|abc", "|")           // absurd counts are capped, not trapped
    vim("99999999999dd", "|a\nb", "|")                  // deletes everything that exists
    vim("d99999999w", "|a b", "|")
    vim("x", "", "|")
    vim("dd", "", "|")
    vim("p", "", "|")
    vim("J", "", "|")
    vim("u", "", "|")
    vim("o<Esc>", "", "|\n")
    vim("G", "\n\n\n", "\n\n|\n")
}

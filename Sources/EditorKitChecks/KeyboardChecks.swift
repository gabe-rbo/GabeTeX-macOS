import AppKit
import Carbon.HIToolbox
import CheckKit
@testable import EditorKit
import TeXCore
import VimKit

// Dead keys in Vim normal/visual/command-line mode (ABNT2, US-International).
//
// The layouts are loaded from the system's installed input sources (read-only: the user's active input
// source is never switched). A layout that is not installed makes its checks print a note and skip.

private typealias DeadKey = (code: UInt16, shift: Bool, expected: String)

/// Keys that are dead on the Brazilian ABNT2 layout, with the character each stands for.
private let abnt2DeadKeys: [DeadKey] = [
    (39, false, "~"),         // the ~ / ˜ key, right of ç
    (39, true, "^"),
    (33, false, "´"),         // the ´ / ` key, at the "[" position of ANSI keyboards
    (33, true, "`"),
]

/// The same for US-International (PC), where `` ` ``, `~`, `^`, `'` and `"` are dead keys.
private let usInternationalDeadKeys: [DeadKey] = [
    (50, false, "`"),
    (50, true, "~"),          // the layout itself spells this one U+02DC; the translator returns ASCII
    (22, true, "^"),          // 6 → ^, spelled U+02C6 by the layout
    (39, false, "'"),
    (39, true, "\""),
]

/// True when `UCKeyTranslate` with dead keys enabled (as the typing system uses it) leaves a dead-key state.
private func isDeadKey(_ layout: KeyboardLayoutTranslator, code: UInt16, shift: Bool) -> Bool {
    var state: UInt32 = 0
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 8)
    let status: OSStatus = layout.layoutData.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return -50 }
        return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), code, UInt16(kUCKeyActionDown),
                              shift ? 2 : 0, layout.keyboardType, 0, &state, buffer.count, &length, &buffer)
    }
    return status == noErr && state != 0
}

/// A key-down event as AppKit delivers a dead key: empty `characters`.
@MainActor private func deadKeyEvent(code: UInt16, shift: Bool) -> NSEvent? {
    keyEvent("", keyCode: code, flags: shift ? [.shift] : [])
}

func keyboardChecks() async {
    await Check.suite("Dead keys: translation helper with explicit layouts (ABNT2, US-International)") {
        let installed = Set(KeyboardLayoutTranslator.installedLayoutIDs)
        let pairs: [(ids: [String], name: String, dead: [DeadKey])] = [
            (["com.apple.keylayout.Brazilian-ABNT2"], "ABNT2", abnt2DeadKeys),
            (["com.apple.keylayout.USInternational-PC", "com.apple.keylayout.US-International-PC"], "US-International",
             usInternationalDeadKeys),
        ]
        var tested = 0
        for pair in pairs {
            guard let id = pair.ids.first(where: { installed.contains($0) }),
                  let layout = KeyboardLayoutTranslator(inputSourceID: id) else {
                print("  note: keyboard layout \(pair.ids[0]) is not installed on this Mac — \(pair.name) dead-key checks skipped")
                continue
            }
            tested += 1
            for key in pair.dead {
                Check.expect(isDeadKey(layout, code: key.code, shift: key.shift),
                             "\(pair.name): key \(key.code) shift=\(key.shift) is a dead key (so the check is meaningful)")
                Check.equal(layout.characters(forKeyCode: key.code, shift: key.shift), key.expected,
                            "\(pair.name): dead key \(key.code) shift=\(key.shift)")
            }
            // Ordinary keys are untouched.
            Check.equal(layout.characters(forKeyCode: 0), "a", "\(pair.name): a")
            Check.equal(layout.characters(forKeyCode: 0, shift: true), "A", "\(pair.name): shift-a")
            Check.equal(layout.characters(forKeyCode: 0, capsLock: true), "A", "\(pair.name): caps-lock a")
            Check.equal(layout.characters(forKeyCode: 18), "1", "\(pair.name): 1")
            Check.equal(layout.characters(forKeyCode: 40), "k", "\(pair.name): k")
            Check.equal(layout.characters(forKeyCode: UInt16(kVK_Return)), "\r", "\(pair.name): return stays a control character")

            // No dead-key state leaks from one translation into the next: the key after a dead key is the
            // plain letter (not "ã" / "é"), whatever came before.
            let before = layout.characters(forKeyCode: 0)
            for key in pair.dead {
                _ = layout.characters(forKeyCode: key.code, shift: key.shift)
                _ = layout.characters(forKeyCode: key.code, shift: key.shift)       // dead key twice
                Check.equal(layout.characters(forKeyCode: 0), before, "\(pair.name): dead key (\(key.code)) then a → a")
                Check.equal(layout.characters(forKeyCode: 14), "e", "\(pair.name): dead key (\(key.code)) then e → e")
                Check.equal(layout.characters(forKeyCode: 49), " ", "\(pair.name): dead key (\(key.code)) then space → space")
            }
        }
        if tested == 0 { print("  note: neither ABNT2 nor US-International is installed — no layout-specific dead-key checks ran") }
        // The current layout (whatever the user has selected) is readable and types something on key 0.
        if let current = KeyboardLayoutTranslator.current() {
            Check.expect(!current.layoutData.isEmpty, "current keyboard layout readable")
            Check.expect(!current.characters(forKeyCode: 0).isEmpty, "current layout types something on key 0")
        } else {
            print("  note: no current keyboard layout data (headless session?) — skipped")
        }
    }

    await Check.suite("Dead keys: Vim normal, visual and command-line modes resolve them; insert mode does not") {
        guard let abnt2 = KeyboardLayoutTranslator(inputSourceID: "com.apple.keylayout.Brazilian-ABNT2") else {
            print("  note: com.apple.keylayout.Brazilian-ABNT2 is not installed — Vim dead-key checks skipped")
            return
        }
        KeyboardLayoutTranslator.layoutOverride = abnt2
        defer { KeyboardLayoutTranslator.layoutOverride = nil }

        guard let tilde = deadKeyEvent(code: 39, shift: false), let circumflex = deadKeyEvent(code: 39, shift: true),
              let grave = deadKeyEvent(code: 33, shift: true), let acute = deadKeyEvent(code: 33, shift: false) else {
            return Check.fail("could not synthesize dead-key events")
        }
        Check.equal(tilde.characters ?? "", "", "a synthesized dead key has empty characters, like AppKit's")

        // The adapter's key conversion.
        Check.equal(VimAdapter.key(for: tilde, resolvingDeadKeys: true), VimKey("~"), "~")
        Check.equal(VimAdapter.key(for: circumflex, resolvingDeadKeys: true), VimKey("^"), "^")
        Check.equal(VimAdapter.key(for: grave, resolvingDeadKeys: true), VimKey("`"), "`")
        Check.equal(VimAdapter.key(for: acute, resolvingDeadKeys: true), VimKey("´"), "´")
        Check.expect(VimAdapter.key(for: tilde, resolvingDeadKeys: false) == nil, "insert mode: left to native composition")
        Check.expect(VimAdapter.key(for: tilde) == nil, "default: left to native composition")
        if let command = keyEvent("", keyCode: 39, flags: [.command]) {
            Check.expect(VimAdapter.key(for: command, resolvingDeadKeys: true) == nil, "⌘ is never translated")
        }
        if let a = keyEvent("a", keyCode: 0) {
            Check.equal(VimAdapter.key(for: a, resolvingDeadKeys: true), VimKey("a"), "ordinary keys keep their characters")
        }

        // Through the editor.
        var config = EditorConfiguration()
        config.vimMode = true
        let (tv, buffer) = makeEditor("abc def\n  ghi jkl\nlast", caret: 0, configuration: config)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GabeTeX.EditorKitChecks.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        tv.vimPasteboard = pasteboard
        let controller = EditorController()
        controller.bind(to: tv)

        @MainActor func send(_ event: NSEvent) async {
            tv.keyDown(with: event)
            await endEvent(tv)
        }

        await send(tilde)                                   // ~ toggles the case of the character under the caret
        Check.equal(text(tv), "Abc def\n  ghi jkl\nlast", "normal mode: dead ~ toggles case")
        Check.equal(caret(tv), 1, "…and advances")
        Check.equal(controller.vimMode, .normal)

        tv.setSelectedRange(NSRange(location: 16, length: 0))   // inside "jkl" on line 2
        await send(circumflex)                              // ^ → first non-blank
        Check.equal(caret(tv), 10, "normal mode: dead ^ goes to the first non-blank")

        // `a: the key after the dead ` must arrive as a plain "a" (no composed "à", nothing left over).
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        await press("ma", tv)                               // mark a at offset 12
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await send(grave)
        Check.equal(controller.vimPendingKeys, "`", "dead ` is pending like a typed backtick")
        await press("a", tv)
        Check.equal(caret(tv), 12, "dead ` followed by a jumps to mark a")
        Check.equal(controller.vimPendingKeys, "")
        Check.equal(text(tv), "Abc def\n  ghi jkl\nlast", "nothing was typed")

        // Visual mode.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await press("vll", tv)
        Check.equal(controller.vimMode, .visual)
        await send(tilde)
        Check.equal(text(tv), "aBC def\n  ghi jkl\nlast", "visual mode: dead ~ toggles the selection")
        Check.equal(controller.vimMode, .normal, "…and leaves visual mode")

        // Command line: ":s/^…" needs the circumflex.
        await press(":", tv)
        Check.equal(controller.vimMode, .commandLine)
        await send(circumflex)
        await send(tilde)
        Check.equal(controller.vimCommandLine, ":^~", "command line receives the dead keys")
        await pressEscape(tv)
        Check.equal(controller.vimMode, .normal)

        // A dead key Vim has no command for (´): consumed, never typed.
        let before = text(tv)
        let changes = buffer.changeCount
        await send(acute)
        Check.equal(text(tv), before, "dead ´ is not typed in normal mode")
        Check.equal(buffer.changeCount, changes)

        // Insert mode: Vim leaves dead keys alone (native composition produces á, ã, ç …).
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await press("i", tv)
        Check.equal(controller.vimMode, .insert)
        Check.expect(tv.vim?.handleKeyDown(tilde) == false, "insert mode: dead ~ not consumed by Vim")
        Check.expect(tv.vim?.handleKeyDown(circumflex) == false, "insert mode: dead ^ not consumed by Vim")
        Check.equal(text(tv), before, "insert mode: the engine inserted nothing")
        Check.equal(controller.vimMode, .insert)
        Check.equal(buffer.changeCount, changes)
        type("ã", tv)                                      // the composed result arrives through insertText
        Check.equal((text(tv) as NSString).substring(with: NSRange(location: 0, length: 1)), "ã", "composed text is inserted as before")
        await pressEscape(tv)
        Check.equal(controller.vimMode, .normal)
    }
}

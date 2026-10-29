import AppKit
import CheckKit
import EditorKit
import TeXCore

// Checks for the 1.0 command-palette round (owner: commands agent): `KeyCombo` (parsing, display, events),
// `ShortcutMap` (conflicts, reserved combinations, Replace, Restore Defaults, persistence) and the autocomplete
// keys of the editor ("Tab completes", the accept-key option, the customizable completion trigger, Vim).

/// A synthesized key-down with a real key code (`KeyCombo(event:)` reads the layout's base character from it).
@MainActor private func keyDown(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: false, keyCode: keyCode)
}

private func parse(_ text: String) -> KeyCombo? { KeyCombo(string: text) }

/// The shape of the app's real table (ids and defaults as in `CommandRegistry+Catalog.swift`).
private let sampleDefinitions: [ShortcutMap.Definition] = [
    .init(id: "file.closeTab", defaultCombo: parse("cmd+w"), isCustomizable: false),
    .init(id: "file.save", defaultCombo: parse("cmd+s")),
    .init(id: "edit.complete", defaultCombo: parse("ctrl+space")),
    .init(id: "view.quickOpen", defaultCombo: parse("cmd+p")),
    .init(id: "view.commandPalette", defaultCombo: parse("shift+cmd+p")),
    .init(id: "view.presentation", defaultCombo: parse("opt+cmd+return")),
    .init(id: "view.nextTab", defaultCombo: parse("ctrl+tab")),
    .init(id: "build.compile", defaultCombo: parse("cmd+b")),
    .init(id: "build.previousIssue", defaultCombo: parse("shift+cmd+'")),
    .init(id: "build.revealPDF", defaultCombo: nil),
    .init(id: "insert.bold", defaultCombo: nil),
    .init(id: "app.settings", defaultCombo: parse("cmd+,"), isCustomizable: false),
]

func shortcutsAndCompletionChecks() async {
    await keyComboChecks()
    await shortcutMapChecks()
    await tabCompletionChecks()
    await acceptKeyAndTriggerChecks()
}

// MARK: - KeyCombo

private func keyComboChecks() async {
    await Check.suite("KeyCombo: parsing, storage form and menu glyphs") {
        let palette = KeyCombo("p", [.command, .shift])
        Check.equal(parse("shift+cmd+p"), palette)
        Check.equal(parse("cmd+shift+P"), palette, "any modifier order and letter case")
        Check.equal(parse("Command+Shift+p"), palette, "long names")
        Check.equal(parse("⇧⌘P"), palette, "menu glyphs")
        Check.equal(palette.storageString, "shift+cmd+p", "canonical order ctrl, opt, shift, cmd")
        Check.equal(palette.displayString, "⇧⌘P")
        Check.equal(KeyCombo("a", [.command, .shift, .option, .control]).displayString, "⌃⌥⇧⌘A", "macOS glyph order")

        let trigger = KeyCombo(.space, [.control])
        Check.equal(parse("ctrl+space"), trigger)
        Check.equal(parse("control+Space"), trigger)
        Check.equal(trigger.displayString, "⌃" + String(localized: "Space"))
        Check.equal(parse("⌃" + String(localized: "Space")), trigger, "the displayed form parses back")
        Check.equal(EditorConfiguration.defaultCompletionTrigger, trigger, "⌃Space is the default trigger")

        let present = KeyCombo(.return, [.command, .option])
        Check.equal(parse("opt+cmd+return"), present)
        Check.equal(parse("alt+cmd+enter"), present, "aliases")
        Check.equal(parse("⌥⌘↩"), present)
        Check.equal(present.displayString, "⌥⌘↩")
        Check.equal(parse("cmd++")?.key, .character("+"), "the plus key")
        Check.equal(parse("⌘+")?.key, .character("+"))
        Check.equal(parse("shift+cmd+'")?.displayString, "⇧⌘'")
        Check.equal(parse("f5"), KeyCombo(.f5, []))
        Check.equal(KeyCombo(.f12, [.command]).displayString, "⌘F12")
        for text in ["", "cmd+", "cmd+ab", "hyper+x", "⌘", "cmd+shift", "ctrl+ "] {
            Check.expect(parse(text) == nil, "‘\(text)’ is not a shortcut")
        }
        for special in KeyCombo.Special.allCases {
            let combo = KeyCombo(.special(special), modifiers: [.control, .shift])
            Check.equal(parse(combo.storageString), combo, "\(special) round-trips")
            Check.equal(parse(combo.displayString), combo, "\(special) glyphs round-trip")
        }
        let encoded = try? JSONEncoder().encode([palette, present])
        Check.equal(encoded.flatMap { String(data: $0, encoding: .utf8) }, #"["shift+cmd+p","opt+cmd+return"]"#,
                    "Codable as the storage string")
        let decoded = encoded.flatMap { try? JSONDecoder().decode([KeyCombo].self, from: $0) }
        Check.equal(decoded, [palette, present])
        Check.expect((try? JSONDecoder().decode([KeyCombo].self, from: Data(#"["cmd+"]"#.utf8))) == nil,
                     "an unreadable combination fails to decode")
    }

    await Check.suite("KeyCombo: events (recording and matching)") {
        guard let shiftCmdP = keyDown("P", keyCode: 35, flags: [.command, .shift]),
              let ctrlSpace = keyDown(" ", keyCode: 49, flags: .control),
              let ctrlShiftSpace = keyDown(" ", keyCode: 49, flags: [.control, .shift]),
              let keypadEnter = keyDown("\u{3}", keyCode: 76, flags: [.command, .option, .numericPad]),
              let cmdCaps = keyDown("b", keyCode: 11, flags: [.command, .capsLock]),
              let f5 = keyDown("\u{F708}", keyCode: 96, flags: .function) else {
            return Check.fail("could not synthesize key events")
        }
        Check.equal(KeyCombo(event: shiftCmdP), KeyCombo("p", [.command, .shift]), "⇧ is a modifier, the key stays p")
        Check.equal(KeyCombo(event: ctrlSpace), KeyCombo(.space, [.control]))
        Check.equal(KeyCombo(event: keypadEnter), KeyCombo(.return, [.command, .option]), "keypad Enter = Return")
        Check.equal(KeyCombo(event: cmdCaps), KeyCombo("b", [.command]), "Caps Lock is ignored")
        Check.equal(KeyCombo(event: f5), KeyCombo(.f5, []), "Fn flag is ignored")
        Check.expect(KeyCombo(.space, [.control]).matches(ctrlSpace), "⌃Space matches")
        Check.expect(!KeyCombo(.space, [.control]).matches(ctrlShiftSpace), "extra ⇧ does not match")
        Check.expect(!KeyCombo(.space, [.control]).matches(shiftCmdP), "another key does not match")
        Check.expect(KeyCombo("p", [.command, .shift]).matches(shiftCmdP))
    }
}

// MARK: - ShortcutMap

private func shortcutMapChecks() async {
    await Check.suite("ShortcutMap: refused combinations") {
        let map = ShortcutMap(definitions: sampleDefinitions)
        Check.equal(ShortcutMap.problems(in: sampleDefinitions), [], "the sample defaults are consistent")
        let refusals: [(String, ShortcutMap.Refusal)] = [
            ("cmd+q", .reserved(.system)), ("cmd+h", .reserved(.system)), ("cmd+tab", .reserved(.system)),
            ("cmd+space", .reserved(.system)), ("cmd+`", .reserved(.system)), ("shift+cmd+4", .reserved(.system)),
            ("cmd+,", .reserved(.settings)), ("cmd+c", .reserved(.editing)), ("shift+cmd+z", .reserved(.editing)),
            ("cmd+w", .reserved(.closing)), ("opt+cmd+w", .reserved(.closing)),
            ("p", .needsModifier), ("shift+p", .needsModifier), ("return", .needsModifier), ("opt+return", .needsModifier),
            ("tab", .needsModifier), ("opt+p", .optionTypesCharacters), ("opt+shift+e", .optionTypesCharacters),
        ]
        for (text, refusal) in refusals {
            guard let combo = parse(text) else { Check.fail("parse \(text)"); continue }
            Check.equal(map.check(combo, for: "build.compile"), .refused(refusal), text)
            Check.expect(!refusal.message.isEmpty, "a message for \(text)")
        }
        for text in ["f5", "ctrl+e", "ctrl+opt+k", "opt+cmd+l", "shift+cmd+return", "cmd+f12"] {
            guard let combo = parse(text) else { Check.fail("parse \(text)"); continue }
            Check.equal(map.check(combo, for: "build.compile"), .allowed, "\(text) allowed")
        }
        Check.equal(map.check(KeyCombo("e", [.command]), for: "file.closeTab"), .refused(.notCustomizable))
        Check.equal(map.check(KeyCombo("e", [.command]), for: "no.such.command"), .refused(.unknownCommand))
        Check.equal(map.check(KeyCombo("b", [.command]), for: "build.compile"), .unchanged)
    }

    await Check.suite("ShortcutMap: conflicts, Replace and Restore Defaults") {
        var map = ShortcutMap(definitions: sampleDefinitions)
        let cmdP = KeyCombo("p", [.command])
        let cmdB = KeyCombo("b", [.command])
        Check.equal(map.combo(for: "build.compile"), cmdB)
        Check.equal(map.combo(for: "build.revealPDF"), nil)
        Check.expect(!map.hasCustomizations)

        Check.equal(map.check(cmdP, for: "build.compile"), .conflict(ids: ["view.quickOpen"], replaceable: true))
        Check.equal(map.assign(cmdP, to: "build.compile"), .conflict(ids: ["view.quickOpen"], replaceable: true),
                    "without Replace nothing changes")
        Check.equal(map.combo(for: "build.compile"), cmdB)
        Check.equal(map.assign(cmdP, to: "build.compile", replacingConflicts: true), .allowed, "Replace")
        Check.equal(map.combo(for: "build.compile"), cmdP)
        Check.equal(map.combo(for: "view.quickOpen"), nil, "the other command lost it")
        Check.expect(map.isCustomized("build.compile") && map.isCustomized("view.quickOpen"))
        Check.equal(map.commands(using: cmdP), ["build.compile"], "one owner per combination")

        Check.equal(map.restoreDefault(for: "view.quickOpen"), .conflict(ids: ["build.compile"], replaceable: true),
                    "restoring a default that is taken asks first")
        Check.equal(map.restoreDefault(for: "view.quickOpen", replacingConflicts: true), .allowed)
        Check.equal(map.combo(for: "view.quickOpen"), cmdP)
        Check.equal(map.combo(for: "build.compile"), nil)
        Check.equal(map.restoreDefault(for: "build.compile"), .allowed, "⌘B is free again")
        Check.equal(map.combo(for: "build.compile"), cmdB)
        Check.expect(!map.hasCustomizations, "back to the defaults")

        Check.equal(map.assign(nil, to: "build.compile"), .allowed, "⌫ removes a shortcut")
        Check.equal(map.combo(for: "build.compile"), nil)
        Check.expect(map.isCustomized("build.compile"))
        Check.equal(map.assign(cmdB, to: "build.compile"), .allowed)
        Check.expect(!map.isCustomized("build.compile"), "assigning the default again is no customization")
        Check.equal(map.assign(nil, to: "build.revealPDF"), .unchanged, "nothing to remove")

        let ctrlE = KeyCombo("e", [.control])
        Check.equal(map.assign(ctrlE, to: "insert.bold"), .allowed)
        Check.equal(map.assign(ctrlE, to: "build.revealPDF"), .conflict(ids: ["insert.bold"], replaceable: true))
        Check.equal(map.assign(KeyCombo("w", [.command]), to: "build.revealPDF"), .refused(.reserved(.closing)),
                    "⌘W stays with Close Tab")
        Check.equal(map.assign(KeyCombo("e", [.command]), to: "file.closeTab"), .refused(.notCustomizable))
        Check.equal(map.restoreDefault(for: "app.settings"), .refused(.notCustomizable))
        map.restoreAllDefaults()
        Check.expect(!map.hasCustomizations, "Restore Defaults (all)")
        Check.equal(map.combo(for: "insert.bold"), nil)
        for definition in sampleDefinitions {
            Check.equal(map.combo(for: definition.id), definition.defaultCombo, "\(definition.id) default")
        }
    }

    await Check.suite("ShortcutMap: persistence round-trip and damaged preferences") {
        var map = ShortcutMap(definitions: sampleDefinitions)
        map.assign(KeyCombo("r", [.command]), to: "build.compile")
        map.assign(nil, to: "view.quickOpen")
        map.assign(KeyCombo(.f6, []), to: "insert.bold")
        let data = map.encodedOverrides()
        let json = String(data: data, encoding: .utf8) ?? ""
        Check.equal(json, #"{"shortcuts":{"build.compile":"cmd+r","insert.bold":"f6","view.quickOpen":""},"version":1}"#,
                    "only the changes are stored, sorted")
        var loaded = ShortcutMap(definitions: sampleDefinitions)
        loaded.loadOverrides(from: data)
        Check.equal(loaded, map, "round trip")
        Check.equal(loaded.combo(for: "build.compile"), KeyCombo("r", [.command]))
        Check.equal(loaded.combo(for: "view.quickOpen"), nil)
        Check.equal(loaded.combo(for: "insert.bold"), KeyCombo(.f6, []))
        Check.equal(ShortcutMap(definitions: sampleDefinitions).encodedOverrides(),
                    Data(#"{"shortcuts":{},"version":1}"#.utf8), "no changes")

        let damaged = Data("""
            {"version":1,"shortcuts":{"no.such.command":"cmd+e","build.compile":"cmd+q","file.closeTab":"cmd+e",
             "view.quickOpen":"cmd+","file.save":"cmd+s","insert.bold":"ctrl+e","build.revealPDF":"ctrl+e",
             "edit.complete":"ctrl+opt+space"}}
            """.utf8)
        var repaired = ShortcutMap(definitions: sampleDefinitions)
        repaired.loadOverrides(from: damaged)
        Check.equal(repaired.combo(for: "build.compile"), KeyCombo("b", [.command]), "a reserved stored combo is ignored")
        Check.equal(repaired.combo(for: "file.closeTab"), KeyCombo("w", [.command]), "fixed commands keep theirs")
        Check.equal(repaired.combo(for: "view.quickOpen"), KeyCombo("p", [.command]), "unreadable → default")
        Check.expect(!repaired.isCustomized("file.save"), "the default stored again is no customization")
        Check.equal(repaired.combo(for: "edit.complete"), KeyCombo(.space, [.control, .option]))
        Check.equal(repaired.combo(for: "build.revealPDF"), KeyCombo("e", [.control]),
                    "a collision in stored data: the first command in menu order keeps it")
        Check.equal(repaired.combo(for: "insert.bold"), nil)
        var garbage = ShortcutMap(definitions: sampleDefinitions)
        garbage.loadOverrides(from: Data("not json".utf8))
        Check.expect(!garbage.hasCustomizations, "garbage is ignored")

        // A later version adds a command whose default the user already gave to another one: the user's choice wins.
        var old = ShortcutMap(definitions: sampleDefinitions)
        old.assign(KeyCombo("y", [.command]), to: "build.revealPDF")
        let newer = sampleDefinitions + [.init(id: "view.newFeature", defaultCombo: KeyCombo("y", [.command]))]
        var upgraded = ShortcutMap(definitions: newer)
        upgraded.loadOverrides(from: old.encodedOverrides())
        Check.equal(upgraded.combo(for: "build.revealPDF"), KeyCombo("y", [.command]))
        Check.equal(upgraded.combo(for: "view.newFeature"), nil, "the new default steps aside")
        Check.equal(upgraded.restoreDefault(for: "view.newFeature"),
                    .conflict(ids: ["build.revealPDF"], replaceable: true))

        let broken: [ShortcutMap.Definition] = [
            .init(id: "a", defaultCombo: parse("cmd+b")), .init(id: "b", defaultCombo: parse("cmd+b")),
            .init(id: "c", defaultCombo: parse("cmd+q")), .init(id: "a", defaultCombo: nil),
        ]
        Check.equal(ShortcutMap.problems(in: broken).count, 3, "duplicate default, reserved default, duplicate id")
    }
}

// MARK: - Tab completion

private func labelSymbols(_ keys: [String]) -> ProjectSymbols {
    ProjectSymbols(labels: keys.enumerated().map { index, key in
        LabelDefinition(key: key, fileURL: URL(fileURLWithPath: "/tmp/editorkit-checks/doc.tex"), line: index + 1)
    })
}

/// The suggestion Tab inserts (the rule of `CompletionController.tabChoice`): the first one, unless it would only re-type
/// the typed command (`\\sec`, the secant) — then the first one that extends it (`\\section`).
@MainActor private func tabTarget(_ text: String, caret: Int) -> String? {
    guard let result = LaTeXTextView.defaultCompletionProvider(text as NSString, caret, .empty),
          let first = result.items.first else { return nil }
    let typed = result.prefix
    func onlyRetypes(_ item: CompletionItem) -> Bool {
        let snippet = Snippet(parsing: item.insertText)
        return snippet.text == typed && snippet.tabStops.isEmpty
    }
    if !onlyRetypes(first) { return first.label }
    return result.items.first { $0.label.hasPrefix(typed) && !onlyRetypes($0) }?.label
}

private func tabCompletionChecks() async {
    await Check.suite("Tab completes: a command prefix opens the popup; Tab then accepts") {
        let (tv, buffer) = makeEditor("x \\su")
        Check.expect(tv.configuration.tabCompletes, "on by default")
        tv.insertTab(nil)
        Check.expect(!tv.completionItems.isEmpty, "popup open after Tab")
        Check.equal(text(tv), "x \\su", "opening the popup does not edit")
        Check.equal(buffer.changeCount, 0)
        guard let first = tv.completionItems.first else { return }
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))      // the Tab key while the popup is open
        Check.expect(tv.completionItems.isEmpty, "accepted")
        Check.expect(text(tv).hasPrefix("x " + first.label), "the first suggestion (\(first.label)) was inserted")
        Check.equal(buffer.changeCount, 1, "one edit")
    }

    await Check.suite("Tab completes: exactly one candidate is inserted directly (one undo)") {
        let (tv, buffer) = makeEditor("see \\ref{fig:un}", caret: utf16Length("see \\ref{fig:un"))
        tv.symbols = labelSymbols(["fig:unique", "eq:main", "sec:intro"])
        await endEvent(tv)
        tv.insertTab(nil)
        Check.expect(tv.completionItems.isEmpty, "no popup for a single candidate")
        Check.equal(text(tv), "see \\ref{fig:unique}")
        Check.equal(caret(tv), utf16Length("see \\ref{fig:unique"), "caret after the key")
        Check.equal(buffer.changeCount, 1)
        await endEvent(tv)
        tv.undoManager?.undo()
        Check.equal(text(tv), "see \\ref{fig:un}", "one undo restores the prefix")

        let (cite, _) = makeEditor("\\cite{knu}", caret: utf16Length("\\cite{knu"))
        cite.symbols = ProjectSymbols(bibEntries: ["knuth84", "knuth86", "lamport94"].map {
            BibEntry(key: $0, type: "book", fileURL: URL(fileURLWithPath: "/tmp/editorkit-checks/refs.bib"), line: 1)
        })
        cite.insertTab(nil)
        Check.equal(cite.completionItems.map(\.label), ["knuth84", "knuth86"], "inside \\cite{…}: two keys → popup")
        Check.equal(text(cite), "\\cite{knu}")

        let (empty, _) = makeEditor("\\ref{}", caret: 5)
        empty.symbols = labelSymbols(["only:one"])
        empty.insertTab(nil)
        Check.equal(text(empty), "\\ref{only:one}", "an empty \\ref{} argument completes too")
    }

    await Check.suite("Tab completes: \\begin{…} completes the environment") {
        let (tv, _) = makeEditor("\\begin{ite}", caret: utf16Length("\\begin{ite"))
        tv.insertTab(nil)
        if let index = tv.completionItems.firstIndex(where: { $0.label == "itemize" }) {
            for _ in 0..<index { tv.doCommand(by: #selector(NSResponder.moveDown(_:))) }
            tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        }
        let result = text(tv)
        Check.expect(result.hasPrefix("\\begin{itemize}"), "itemize inserted (got \(result.debugDescription))")
        Check.equal(result.components(separatedBy: "\\end{itemize}").count, 2, "exactly one \\end{itemize}")
        Check.expect(!result.contains("\\begin{itemize}}"), "the auto-paired brace was swallowed")
    }

    await Check.suite("Tab completes: elsewhere Tab indents as before") {
        let (blank, _) = makeEditor("")
        blank.insertTab(nil)
        Check.equal(text(blank), "  ", "empty line: indentation")
        Check.expect(blank.completionItems.isEmpty)

        let (word, _) = makeEditor("x")
        word.insertTab(nil)
        Check.equal(text(word), "x ", "after prose: spaces to the next indent stop")

        let (bare, _) = makeEditor("\\")
        bare.insertTab(nil)
        Check.expect(bare.completionItems.isEmpty, "a bare backslash is no prefix")
        Check.equal(text(bare), "\\ ")

        let (exact, _) = makeEditor("$\\alpha")
        exact.insertTab(nil)
        Check.expect(exact.completionItems.isEmpty, "\\alpha is complete: nothing to insert")
        Check.equal(text(exact), "$\\alpha ", "Tab indents instead")

        let (inside, _) = makeEditor("\\section", caret: 4)
        inside.insertTab(nil)
        Check.expect(inside.completionItems.isEmpty, "caret inside a command name (\\sec|tion)")
        Check.equal(text(inside), "\\sec  tion")

        let (comment, _) = makeEditor("% \\su")
        comment.insertTab(nil)
        Check.expect(comment.completionItems.isEmpty, "nothing in comments")

        let (selected, _) = makeEditor("\\su\nb")
        selected.setSelectedRange(NSRange(location: 0, length: 5))
        selected.insertTab(nil)
        Check.equal(text(selected), "  \\su\n  b", "a selection is indented")

        var off = EditorConfiguration()
        off.tabCompletes = false
        let (disabled, _) = makeEditor("x \\su", configuration: off)
        disabled.insertTab(nil)
        Check.expect(disabled.completionItems.isEmpty, "Tab completes off")
        Check.equal(text(disabled), "x \\su ")
    }

    await Check.suite("Tab completes: snippet fields") {
        let (tv, _) = makeEditor("")
        tv.insertCompletion(CompletionItem(kind: .snippet, label: "frac", insertText: "\\frac{${1:a}}{${2:b}}$0"),
                            replacing: NSRange(location: 0, length: 0))
        Check.equal(selection(tv), NSRange(location: 6, length: 1), "first field selected")
        tv.insertTab(nil)
        Check.equal(selection(tv), NSRange(location: 9, length: 1), "a selected field: Tab goes to the next one")
        await endEvent(tv)
        type("\\alph", tv)
        Check.equal(text(tv), "\\frac{a}{\\alph}")
        let top = tabTarget(text(tv), caret: 14) ?? "?"
        tv.insertTab(nil)
        Check.expect(tv.completionItems.isEmpty && text(tv).hasPrefix("\\frac{a}{" + top),
                     "a prefix just typed in a field completes to \(top) (got \(text(tv).debugDescription))")

        let (mirrored, _) = makeEditor("")
        mirrored.insertCompletion(CompletionItem(kind: .snippet, label: "env", insertText: "\\begin{${1:env}}\n\t$0\n\\end{$1}"),
                                  replacing: NSRange(location: 0, length: 0))
        await endEvent(mirrored)
        type("ite", mirrored)
        Check.equal(text(mirrored), "\\begin{ite}\n  \n\\end{ite}")
        mirrored.insertTab(nil)
        Check.expect(mirrored.completionItems.isEmpty, "no completion in a mirrored field (it would duplicate \\end)")
        Check.equal(text(mirrored), "\\begin{ite}\n  \n\\end{ite}", "Tab just moves on")
        Check.equal(caret(mirrored), utf16Length("\\begin{ite}\n  "), "to $0")
    }

    await Check.suite("Tab completes: Vim only in insert mode") {
        var config = EditorConfiguration()
        config.vimMode = true
        let (tv, _) = makeEditor("x \\su", caret: 0, configuration: config)
        Check.equal(tv.vimEngine?.mode, .normal)
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        guard let tabKey = keyDown("\t", keyCode: 48) else { return Check.fail("Tab event") }
        tv.keyDown(with: tabKey)
        await endEvent(tv)
        Check.expect(tv.completionItems.isEmpty, "normal mode: Tab is Vim's, no completion")
        Check.equal(text(tv), "x \\su", "normal mode: nothing typed")
        await press("A", tv)
        Check.equal(tv.vimEngine?.mode, .insert)
        Check.equal(caret(tv), 5)
        let before = text(tv)
        tv.insertTab(nil)
        Check.expect(!tv.completionItems.isEmpty, "insert mode: Tab completes")
        Check.equal(text(tv), before)
        await pressEscape(tv)
        Check.expect(tv.completionItems.isEmpty, "Esc closes the popup")
        Check.equal(tv.vimEngine?.mode, .insert, "the popup took that Esc")
        type("b", tv)                                       // insert mode: the host types
        let top = tabTarget(text(tv), caret: 6) ?? "?"
        tv.keyDown(with: tabKey)                            // the real key path: Vim first, then the text view
        Check.expect(tv.completionItems.isEmpty && text(tv).hasPrefix("x " + top),
                     "insert mode, Tab right after typing completes to \(top) (got \(text(tv).debugDescription))")
    }

    await Check.suite("Tab right after typing = Tab with the popup open (typed keys, then Tab)") {
        guard let tabKey = keyDown("\t", keyCode: 48), let top = tabTarget("x \\sec", caret: 6) else {
            return Check.fail("setup")
        }
        // The case of the report: `\sec` is itself a command (the secant) and the first suggestion; Tab must not
        // just re-type it but extend it (`\section`), whether or not the popup has appeared yet.
        let first = LaTeXTextView.defaultCompletionProvider("x \\sec" as NSString, 6, .empty)?.items.first?.label
        Check.equal(first, "\\sec", "\\sec (secant) comes first")
        Check.expect(top.hasPrefix("\\sec") && top != "\\sec", "Tab extends \\sec to \(top)")

        // Typed character by character (insertText, as the keyboard does), Tab as a key event at once: no run-loop
        // turn, the automatic popup is still pending (debounced).
        let (now, _) = makeEditor("x ")
        Check.expect(now.inlinePredictionType == .no, "system inline predictions are off (they take Tab)")
        Check.expect(now.mathExpressionCompletionType == .no, "math results are off")
        type("\\sec", now)
        Check.expect(now.completionItems.isEmpty, "popup not open yet")
        now.keyDown(with: tabKey)
        let reference = text(now)
        Check.expect(reference.hasPrefix("x " + top), "accepted \(top) (got \(reference.debugDescription))")
        Check.expect(now.completionItems.isEmpty)

        // The key-binding path (insertTab: through doCommand), at once.
        let (binding, _) = makeEditor("x ")
        type("\\sec", binding)
        binding.doCommand(by: #selector(NSResponder.insertTab(_:)))
        Check.equal(text(binding), reference, "doCommand(insertTab:) right after typing")

        // After one run-loop turn (still before the debounce); one undo step back to the prefix.
        let (turn, _) = makeEditor("x ")
        type("\\sec", turn)
        await endEvent(turn)
        turn.keyDown(with: tabKey)
        Check.equal(text(turn), reference, "after a run-loop turn")
        await endEvent(turn)
        turn.undoManager?.undo()
        Check.equal(text(turn), "x \\sec", "one undo removes the completion")

        // After the debounce: the automatic popup is open and Tab accepts it — the same text.
        let (late, _) = makeEditor("x ")
        type("\\sec", late)
        try? await Task.sleep(for: .milliseconds(250))
        Check.expect(!late.completionItems.isEmpty, "the automatic popup opened")
        late.keyDown(with: tabKey)
        Check.equal(text(late), reference, "Tab with the popup open")

        // Not typed just now (caret placed there): no popup was coming, so Tab opens it.
        let (placed, _) = makeEditor("x \\sec")
        placed.keyDown(with: tabKey)
        Check.expect(!placed.completionItems.isEmpty, "placed caret: the popup opens")
        Check.equal(text(placed), "x \\sec")

        // Suggestions while typing off: no popup was coming either.
        var manual = EditorConfiguration()
        manual.autoCompletion = false
        let (quiet, _) = makeEditor("x ", configuration: manual)
        type("\\sec", quiet)
        quiet.keyDown(with: tabKey)
        Check.expect(!quiet.completionItems.isEmpty, "auto-suggest off: Tab opens the popup")
        Check.equal(text(quiet), "x \\sec")

        // Return only: Tab is no accept key, so Tab completes by opening the popup (Return accepts).
        var returnOnly = EditorConfiguration()
        returnOnly.completionAcceptKeys = .returnOnly
        let (ret, _) = makeEditor("x ", configuration: returnOnly)
        type("\\sec", ret)
        ret.keyDown(with: tabKey)
        Check.expect(!ret.completionItems.isEmpty && text(ret) == "x \\sec", "Return only: the popup opens")
        ret.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        Check.equal(text(ret), reference, "…and Return accepts the same suggestion")

        // An input method composing (marked text): Tab is not taken for completion.
        let (ime, _) = makeEditor("x ")
        type("\\sec", ime)
        ime.setMarkedText("o", selectedRange: NSRange(location: 1, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        if ime.hasMarkedText() {
            ime.insertTab(nil)
            Check.expect(ime.completionItems.isEmpty && !text(ime).contains(top), "marked text: no completion")
        }

        // Inside a snippet field a complete command is done: Tab goes to the next field, popup or not.
        for wait in [false, true] {
            let (field, _) = makeEditor("")
            field.insertCompletion(CompletionItem(kind: .snippet, label: "frac", insertText: "\\frac{${1:a}}{${2:b}}$0"),
                                   replacing: NSRange(location: 0, length: 0))
            await endEvent(field)
            type("\\in", field)
            if wait {
                try? await Task.sleep(for: .milliseconds(250))
                Check.expect(!field.completionItems.isEmpty, "the automatic popup opened")
                field.keyDown(with: tabKey)
            } else {
                // Without a window AppKit's key bindings don't run: send what they send after `keyDown` declines.
                field.doCommand(by: #selector(NSResponder.insertTab(_:)))
            }
            Check.equal(text(field), "\\frac{\\in}{b}", "\\in kept (popup shown: \(wait))")
            Check.equal(selection(field), NSRange(location: 11, length: 1), "next field (popup shown: \(wait))")
            Check.expect(field.completionItems.isEmpty)
        }

        // A row the user picked is accepted as it is, even when it only re-types the text.
        let (picked, _) = makeEditor("x ")
        type("\\sec", picked)
        try? await Task.sleep(for: .milliseconds(250))
        picked.doCommand(by: #selector(NSResponder.moveDown(_:)))
        picked.doCommand(by: #selector(NSResponder.moveUp(_:)))
        picked.keyDown(with: tabKey)
        Check.equal(text(picked), "x \\sec", "the picked \\sec is accepted")
        Check.expect(picked.completionItems.isEmpty)
    }
}

// MARK: - Accept keys and trigger

private func acceptKeyAndTriggerChecks() async {
    await Check.suite("Accept completion with: Return only / Tab only") {
        var returnOnly = EditorConfiguration()
        returnOnly.completionAcceptKeys = .returnOnly
        let (tv, buffer) = makeEditor("\\fra", configuration: returnOnly)
        let controller = EditorController()
        controller.bind(to: tv)
        controller.triggerCompletion()
        Check.expect(!tv.completionItems.isEmpty)
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        Check.expect(tv.completionItems.isEmpty, "Tab closes the popup")
        Check.equal(text(tv), "\\fra  ", "…and indents instead of accepting (no re-opening)")
        tv.setSelectedRange(NSRange(location: 4, length: 2))
        tv.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.triggerCompletion()
        guard let tabKey = keyDown("\t", keyCode: 48) else { return Check.fail("Tab event") }
        tv.keyDown(with: tabKey)
        Check.expect(tv.completionItems.isEmpty, "the Tab key (popup routing) closes it too")
        Check.equal(text(tv), "\\fra  ", "not accepted")
        tv.setSelectedRange(NSRange(location: 4, length: (text(tv) as NSString).length - 4))
        tv.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.triggerCompletion()
        let changes = buffer.changeCount
        let offered = tv.completionItems.first?.label ?? "?"
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        Check.expect(tv.completionItems.isEmpty && text(tv).hasPrefix(offered),
                     "Return accepts \(offered) (got \(text(tv).debugDescription))")
        Check.equal(buffer.changeCount, changes + 1)

        var tabOnly = EditorConfiguration()
        tabOnly.completionAcceptKeys = .tabOnly
        let (tabView, _) = makeEditor("\\fra", configuration: tabOnly)
        controller.bind(to: tabView)
        controller.triggerCompletion()
        Check.expect(!tabView.completionItems.isEmpty)
        tabView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        Check.expect(tabView.completionItems.isEmpty, "Return closes the popup")
        Check.equal(text(tabView), "\\fra\n", "…and starts a new line")
        await endEvent(tabView)
        tabView.undoManager?.undo()
        Check.equal(text(tabView), "\\fra")
        controller.triggerCompletion()
        let first = tabView.completionItems.first?.label ?? "?"
        tabView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        Check.expect(tabView.completionItems.isEmpty && text(tabView).hasPrefix(first),
                     "Tab accepts \(first) (got \(text(tabView).debugDescription))")

        Check.expect(CompletionAcceptKeys.tabAndReturn.acceptsTab && CompletionAcceptKeys.tabAndReturn.acceptsReturn)
        Check.expect(!CompletionAcceptKeys.tabOnly.acceptsReturn && !CompletionAcceptKeys.returnOnly.acceptsTab)
    }

    await Check.suite("Completion trigger: customizable (⌃Space by default)") {
        let (tv, _) = makeEditor("\\fra")
        guard let ctrlSpace = keyDown(" ", keyCode: 49, flags: .control),
              let ctrlOptK = keyDown("˚", keyCode: 40, flags: [.control, .option]) else {
            return Check.fail("could not synthesize key events")
        }
        tv.keyDown(with: ctrlSpace)
        Check.expect(!tv.completionItems.isEmpty, "⌃Space opens completion")
        await pressEscape(tv)
        Check.expect(tv.completionItems.isEmpty)

        var custom = EditorConfiguration()
        custom.completionTrigger = KeyCombo("k", [.control, .option])
        tv.apply(custom)
        tv.keyDown(with: ctrlOptK)
        Check.expect(!tv.completionItems.isEmpty, "a custom trigger (⌃⌥K) opens completion")
        await pressEscape(tv)

        var none = EditorConfiguration()
        none.completionTrigger = nil
        none.autoCompletion = false
        tv.apply(none)
        tv.complete(nil)                                              // ⌥⎋ keeps working
        Check.expect(!tv.completionItems.isEmpty, "⌥⎋ / Edit ▸ Complete still work without a trigger key")
        await pressEscape(tv)
    }
}

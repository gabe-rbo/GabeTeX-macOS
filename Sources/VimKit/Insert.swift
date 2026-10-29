import Foundation

// Insert and replace sessions. In insert mode the host inserts typed text itself; the engine reconstructs
// the inserted text from the start offset and the length delta (for `.` and the `".` register).

extension VimEngine {

    // MARK: Starting

    /// Positions the cursor for `i a I A gI gi o O` and starts the session.
    func startInsert(_ kind: InsertKind, count: Int?) {
        let d = doc
        let c = cursor
        switch kind {
        case .before:
            break
        case .after:
            if c < d.contentEnd(c) { cursor = d.clusterEnd(c) }
        case .lineStart:
            cursor = d.firstNonBlankOffset(d.lineStart(c))
        case .lineEnd:
            cursor = d.contentEnd(c)
        case .firstColumn:
            cursor = d.lineStart(c)
        case .lastInsert:
            if let m = marks["^"] { cursor = max(0, min(m, d.length)) }
        case .openBelow:
            let ls = d.lineStart(c)
            let ce = d.contentEnd(c)
            let indent = autoIndent ? d.sub(ls, d.firstNonBlankOffset(ls)) : ""
            let eol = lineTerminator(d, at: c)
            replace(NSRange(location: ce, length: 0), with: eol + indent)
            cursor = ce + eol.u16 + indent.u16
        case .openAbove:
            let ls = d.lineStart(c)
            let indent = autoIndent ? d.sub(ls, d.firstNonBlankOffset(ls)) : ""
            let eol = lineTerminator(d, at: c)
            replace(NSRange(location: ls, length: 0), with: indent + eol)
            cursor = ls + indent.u16
        }
        beginInsertSession(kind: kind, count: max(1, count ?? 1), records: true)
    }

    /// The line terminator to use for new lines near `off`.
    func lineTerminator(_ d: Doc, at off: Int) -> String {
        let ce = d.contentEnd(off)
        let tl = d.terminatorLength(at: ce)
        if tl > 0 { return d.sub(ce, ce + tl) }
        if d.length > 0, d.t.range(of: "\r\n").location != NSNotFound { return "\r\n" }
        return "\n"
    }

    func beginInsertSession(kind: InsertKind, count: Int, records: Bool) {
        if replaying {
            performReplayInsert(kind: kind, count: count)
            return
        }
        openUndoGroup()
        insertSession = InsertSession(start: cursor, startLength: buf.vimText.length, count: count, kind: kind, records: records)
        switchMode(.insert)
    }

    func beginReplaceSession(count: Int, records: Bool) {
        if replaying {
            performReplayReplace(count: count)
            return
        }
        openUndoGroup()
        replaceSession = ReplaceSession(start: cursor, originals: [], typed: [], count: count, records: records)
        switchMode(.replace)
    }

    // MARK: Insert mode

    /// Restarts the session when the cursor left the typed text (arrow keys, mouse).
    private func validateInsertSession() {
        guard var s = insertSession else { return }
        let len = buf.vimText.length
        let delta = len - s.startLength
        if delta < 0 || cursor < s.start || cursor > s.start + delta {
            s.start = cursor
            s.startLength = len
            s.count = 1
            s.kind = .before
            insertSession = s
        }
    }

    func handleInsertKey(_ key: VimKey) -> Bool {
        validateInsertSession()
        if ctrlRPending {
            ctrlRPending = false
            if let ch = key.plain?.first, let reg = readRegister(ch) {
                var t = reg.text
                if reg.linewise, !t.endsWithLineBreak { t += "\n" }
                replace(NSRange(location: cursor, length: 0), with: t)
                cursor += t.u16
            }
            return true
        }
        if key.isSpecial(.escape) || key.isCtrl("[") || key.isCtrl("c") {
            finishInsertSession(stepLeft: true)
            switchMode(.normal)
            let d = doc
            cursor = d.clampNormal(cursor)
            desiredCol = nil
            return true
        }
        if key.isCtrl("r") {
            ctrlRPending = true
            return true
        }
        if key.isCtrl("o") {
            finishInsertSession(stepLeft: false)
            switchMode(.normal)
            cursor = doc.clampNormal(cursor)
            insertOneShot = true
            return true
        }
        return false
    }

    /// Ends the current insert / replace session; `stepLeft` moves the cursor back like Esc does.
    func finishInsertSession(stepLeft: Bool) {
        if replaceSession != nil {
            finishReplaceSession(stepLeft: stepLeft)
            return
        }
        guard let s = insertSession else { return }
        insertSession = nil
        var d = doc
        var text = ""
        let delta = d.length - s.startLength
        if delta > 0, s.start >= 0, s.start + delta <= d.length {
            text = d.sub(s.start, s.start + delta)
            // The host inserted this text natively: marks behind it move along.
            for (k, v) in marks where v >= s.start && k != "." && k != "^" { marks[k] = v + delta }
        }
        if !text.isEmpty && s.count > 1 {
            var copy = text
            if s.kind == .openBelow || s.kind == .openAbove {
                let ls = d.lineStart(cursor)
                let indent = autoIndent ? d.sub(ls, d.firstNonBlankOffset(ls)) : ""
                copy = lineTerminator(d, at: cursor) + indent + text
            }
            let extra = String(repeating: copy, count: s.count - 1)
            replace(NSRange(location: cursor, length: 0), with: extra)
            cursor += extra.u16
            d = doc
        }
        regs.lastInserted = text
        marks["^"] = cursor
        if s.records, var b = building {
            b.insertText = text
            lastChange = b
        }
        building = nil
        if stepLeft && cursor > d.lineStart(cursor) { cursor = d.prevCharStart(cursor) }
    }

    // MARK: Replace mode

    func handleReplaceKey(_ key: VimKey) -> Bool {
        guard var s = replaceSession else {
            switchMode(.normal)
            return true
        }
        if key.isSpecial(.escape) || key.isCtrl("[") || key.isCtrl("c") {
            finishReplaceSession(stepLeft: true)
            switchMode(.normal)
            cursor = doc.clampNormal(cursor)
            desiredCol = nil
            return true
        }
        if key.isSpecial(.backspace) || key.isCtrl("h") {
            if let last = s.typed.popLast(), let orig = s.originals.popLast() {
                let n = last.u16
                let from = max(0, cursor - n)
                replace(NSRange(location: from, length: min(n, doc.length - from)), with: orig)
                cursor = from
                replaceSession = s
            } else if cursor > doc.lineStart(cursor) {
                cursor = doc.prevCharStart(cursor)
            }
            return true
        }
        if key.isSpecial(.enter) {
            replaceTyped("\n", &s)
            replaceSession = s
            return true
        }
        if key.special == nil, !key.control, let ch = key.character, !ch.isEmpty {
            replaceTyped(ch, &s)
            replaceSession = s
            return true
        }
        return false
    }

    /// Types `ch` over the character under the cursor (or appends it at the end of the line).
    private func replaceTyped(_ ch: String, _ s: inout ReplaceSession) {
        let d = doc
        var orig = ""
        if ch != "\n", cursor < d.length, !d.isBreak(at: cursor) {
            let end = d.clusterEnd(cursor)
            orig = d.sub(cursor, end)
            replace(NSRange(location: cursor, length: end - cursor), with: ch)
        } else {
            replace(NSRange(location: cursor, length: 0), with: ch)
        }
        s.typed.append(ch)
        s.originals.append(orig)
        cursor += ch.u16
    }

    func finishReplaceSession(stepLeft: Bool) {
        guard var s = replaceSession else { return }
        replaceSession = nil
        let typed = s.typed
        let text = typed.joined()
        if s.count > 1 && !typed.isEmpty {
            for _ in 1..<s.count {
                for ch in typed { replaceTyped(ch, &s) }
            }
        }
        regs.lastInserted = text
        marks["^"] = cursor
        if s.records, var b = building {
            b.insertText = text
            lastChange = b
        }
        building = nil
        let d = doc
        if stepLeft && cursor > d.lineStart(cursor) { cursor = d.prevCharStart(cursor) }
    }

    // MARK: Dot-repeat of insert sessions

    private func performReplayInsert(kind: InsertKind, count: Int) {
        let text = replayInsertText ?? ""
        if !text.isEmpty {
            var full = text
            if count > 1 {
                var copy = text
                if kind == .openBelow || kind == .openAbove {
                    let d = doc
                    let ls = d.lineStart(cursor)
                    let indent = autoIndent ? d.sub(ls, d.firstNonBlankOffset(ls)) : ""
                    copy = lineTerminator(d, at: cursor) + indent + text
                }
                full += String(repeating: copy, count: count - 1)
            }
            replace(NSRange(location: cursor, length: 0), with: full)
            cursor += full.u16
            regs.lastInserted = text
        }
        let d = doc
        if cursor > d.lineStart(cursor) { cursor = d.prevCharStart(cursor) }
        cursor = d.clampNormal(cursor)
    }

    private func performReplayReplace(count: Int) {
        let text = replayInsertText ?? ""
        var s = ReplaceSession(start: cursor, originals: [], typed: [], count: 1, records: false)
        for _ in 0..<max(1, count) {
            for ch in text.map({ String($0) }) { replaceTyped(ch, &s) }
        }
        let d = doc
        if cursor > d.lineStart(cursor) { cursor = d.prevCharStart(cursor) }
        cursor = d.clampNormal(cursor)
    }
}

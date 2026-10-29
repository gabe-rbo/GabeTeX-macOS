import Foundation

// Single-key / non-operator commands: x X D C s S Y, r ~, i a I A o O R, v V o gv, m, :, ZZ ZQ, Ctrl-a/x …

extension VimEngine {

    /// Executes a `VimSimple` command. Returns true when the command changed the text and should be
    /// recorded for `.` (commands that merely move, undo, repeat or switch modes return false).
    func executeSimple(_ s: VimSimple, _ cmd: VimCommand) -> Bool {
        switch s {
        case .deleteChar:
            return executeOperatorMotion(cmd, .delete, .right)
        case .deleteCharBefore:
            return executeOperatorMotion(cmd, .delete, .left)
        case .deleteToEnd:
            return executeOperatorMotion(cmd, .delete, .lineEnd)
        case .changeToEnd:
            return executeOperatorMotion(cmd, .change, .lineEnd)
        case .substituteChar:
            return executeOperatorMotion(cmd, .change, .right)
        case .substituteLine:
            return executeOperatorLines(cmd, .change)
        case .yankLine:
            _ = executeOperatorLines(cmd, .yank)
            return false

        case .put(let after, let cursorAfter):
            if isVisual { return visualPut(cmd, replaceRegister: after, cursorAfter: cursorAfter) }
            guard let reg = readRegister(cmd.register), !reg.text.isEmpty else {
                notify("E353: Nothing in register \(cmd.register.map { String($0) } ?? "\"")")
                return false
            }
            return putRegister(reg, after: after, cursorAfter: cursorAfter, count: cmd.count ?? 1)

        case .join(let spaces):
            if isVisual {
                let d = doc
                let lo = min(visualAnchor, cursor), hi = max(visualAnchor, cursor)
                let lines = d.lineIndex(of: hi) - d.lineIndex(of: lo) + 1
                saveVisualMarks()
                switchMode(.normal)
                cursor = d.lineStart(lo)
                return joinLines(count: max(2, lines), spaces: spaces)
            }
            return joinLines(count: max(2, cmd.count ?? 2), spaces: spaces)

        case .undo:
            performUndo(count: cmd.count ?? 1)
            return false
        case .redo:
            performRedo(count: cmd.count ?? 1)
            return false
        case .repeatChange:
            repeatChange(count: cmd.count)
            return false

        case .insert(let kind):
            startInsert(kind, count: cmd.count)
            return true
        case .replaceMode:
            beginReplaceSession(count: max(1, cmd.count ?? 1), records: true)
            return true

        case .replaceChar(let ch):
            if isVisual { return visualReplaceChar(ch) }
            return replaceChars(ch, count: cmd.count ?? 1)
        case .toggleCaseChar:
            return toggleCaseChars(count: cmd.count ?? 1)

        case .startVisual(let m):
            if isVisual {
                if mode == m { exitVisual() } else { switchMode(m) }
            } else {
                visualAnchor = cursor
                switchMode(m)
            }
            return false
        case .visualSwapEnds:
            swap(&visualAnchor, &cursor)
            desiredCol = nil
            return false
        case .visualReselect:
            guard let lv = lastVisual else { return false }
            let d = doc
            visualAnchor = d.clampNormal(lv.anchor)
            cursor = d.clampNormal(lv.cursor)
            switchMode(lv.mode)
            desiredCol = nil
            return false
        case .visualExit:
            exitVisual()
            return false
        case .visualLinewise(let op):
            if mode != .visualLine { switchMode(.visualLine) }
            return executeVisualOperator(cmd, op) && op.modifiesText

        case .setMark(let ch):
            marks[ch] = cursor
            return false

        case .increment(let delta):
            if isVisual {
                exitVisual()
                return false
            }
            return incrementNumber(delta * max(1, cmd.count ?? 1))

        case .commandLine(let ch):
            var initial = ""
            if isVisual {
                saveVisualMarks()
                let d = doc
                switchMode(.normal)
                cursor = d.clampNormal(cursor)
                initial = "'<,'>"
            } else if let n = cmd.count {
                initial = n <= 1 ? "." : ".,.+\(n - 1)"
            }
            cmdReturnMode = .normal
            cmdPendingOperator = nil
            openCommandLine(ch, initial: initial)
            return false

        case .writeQuit:
            onExCommand?(.writeQuit)
            return false
        case .quitNoSave:
            onExCommand?(.quit)
            return false
        case .repeatSubstitute:
            executeEx("s")
            return false
        case .viewport(let v):
            onViewport?(v)
            return false
        case .noop:
            return false
        }
    }

    // MARK: r

    /// `r{char}` with a count: replaces `count` characters from the cursor (fails if the line is too short).
    func replaceChars(_ ch: String, count: Int) -> Bool {
        let d = doc
        let n = max(1, count)
        let ce = d.contentEnd(cursor)
        var p = cursor
        var k = 0
        while k < n && p < ce {
            p = d.clusterEnd(p)
            k += 1
        }
        guard k == n else { return false }
        if ch == "\n" {
            let eol = lineTerminator(d, at: cursor)
            replace(NSRange(location: cursor, length: p - cursor), with: eol)
            cursor += eol.u16
            return true
        }
        let new = String(repeating: ch, count: n)
        replace(NSRange(location: cursor, length: p - cursor), with: new)
        cursor += (n - 1) * ch.u16
        return true
    }

    /// `r{char}` on a visual selection: every character becomes `ch` (line breaks are kept).
    private func visualReplaceChar(_ ch: String) -> Bool {
        let region = visualRegion()
        saveVisualMarks()
        switchMode(.normal)
        let d = doc
        var out = ""
        var i = region.start
        while i < region.end {
            if d.isBreak(at: i) {
                let tl = max(1, d.terminatorLength(at: i))
                out += d.sub(i, i + tl)
                i += tl
            } else {
                out += ch == "\n" ? "\n" : ch
                i = d.clusterEnd(i)
            }
        }
        guard region.end > region.start else { return false }
        replace(NSRange(location: region.start, length: region.end - region.start), with: out)
        cursor = doc.clampNormal(region.start)
        desiredCol = nil
        return true
    }

    // MARK: ~

    /// `~`: toggles the case of `count` characters and moves right.
    func toggleCaseChars(count: Int) -> Bool {
        let d = doc
        let ce = d.contentEnd(cursor)
        guard cursor < ce else { return false }
        var p = cursor
        var k = 0
        while k < max(1, count) && p < ce {
            p = d.clusterEnd(p)
            k += 1
        }
        let old = d.sub(cursor, p)
        let new = mapCase(old, .toggleCase)
        let start = cursor
        if new != old { replace(NSRange(location: start, length: p - start), with: new) }
        cursor = doc.clampNormal(start + new.u16)
        desiredCol = nil
        return true
    }

    // MARK: Ctrl-a / Ctrl-x

    /// Adds `delta` to the decimal number at or after the cursor on the current line.
    func incrementNumber(_ delta: Int) -> Bool {
        let d = doc
        let ls = d.lineStart(cursor)
        let ce = d.contentEnd(cursor)
        func isDigit(_ p: Int) -> Bool {
            let u = d.unit(p)
            return u >= 48 && u <= 57
        }
        var i = cursor
        if i < ce && isDigit(i) {
            while i > ls && isDigit(i - 1) { i -= 1 }
        } else {
            while i < ce && !isDigit(i) { i += 1 }
        }
        guard i < ce else { return false }
        var e = i
        while e < ce && isDigit(e) { e += 1 }
        var start = i
        var negative = false
        if start > ls && d.unit(start - 1) == 45 {
            negative = true
            start -= 1
        }
        let digits = d.sub(i, e)
        guard let magnitude = Int(digits), magnitude < Int.max / 4 else { return false }
        let value = (negative ? -magnitude : magnitude) &+ delta
        var text = String(abs(value))
        if digits.count > 1, digits.hasPrefix("0"), text.count < digits.count {
            text = String(repeating: "0", count: digits.count - text.count) + text
        }
        if value < 0 { text = "-" + text }
        replace(NSRange(location: start, length: e - start), with: text)
        cursor = start + text.u16 - 1
        desiredCol = nil
        return true
    }
}

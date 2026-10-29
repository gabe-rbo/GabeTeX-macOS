import Foundation

// Put (`p P gp gP`, visual `p`) and join (`J gJ`).

extension VimEngine {

    /// Register text adapted to the document's line terminator.
    private func adapt(_ text: String, eol: String) -> String {
        guard eol != "\n" else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: eol)
    }

    // MARK: Put

    /// `p` / `P` (`after` selects which), with `gp` / `gP` cursor placement. Returns true when text was inserted.
    func putRegister(_ reg: Register, after: Bool, cursorAfter: Bool, count: Int) -> Bool {
        let d = doc
        let n = max(1, count)
        let eol = lineTerminator(d, at: cursor)
        var text = adapt(reg.text, eol: eol)
        guard !text.isEmpty else { return false }

        if reg.linewise {
            if !text.endsWithLineBreak { text += eol }
            var block = String(repeating: text, count: n)
            let at: Int
            let firstLine: Int
            if after {
                let le = d.lineEnd(cursor)
                if le >= d.length && !d.endsWithBreak {
                    // Last line without a terminator (or an empty document): break first, drop the final break.
                    at = d.length
                    block = eol + block.droppingTrailingBreak
                    firstLine = at + eol.u16
                } else {
                    at = le
                    firstLine = at
                }
            } else {
                at = d.lineStart(cursor)
                firstLine = at
            }
            replace(NSRange(location: at, length: 0), with: block)
            let nd = doc
            if cursorAfter {
                cursor = nd.clampNormal(at + block.u16)
            } else {
                cursor = nd.clampNormal(nd.firstNonBlank(firstLine))
            }
            desiredCol = nil
            return true
        }

        let body = String(repeating: text, count: n)
        let c = max(0, min(cursor, d.length))
        let at: Int = (after && c < d.contentEnd(c)) ? d.clusterEnd(c) : c
        replace(NSRange(location: at, length: 0), with: body)
        let nd = doc
        let multiline = body.containsLineBreak
        if cursorAfter {
            cursor = nd.clampNormal(at + body.u16)
        } else if multiline {
            cursor = nd.clampNormal(at)
        } else {
            cursor = nd.clampNormal(nd.prevCharStart(at + body.u16))
        }
        desiredCol = nil
        return true
    }

    /// Visual `p` / `P`: replaces the selection with the register. `p` puts the replaced text into the unnamed register.
    func visualPut(_ cmd: VimCommand, replaceRegister: Bool, cursorAfter: Bool) -> Bool {
        guard let reg = readRegister(cmd.register), !reg.text.isEmpty else {
            notify("E353: Nothing in register \(cmd.register.map { String($0) } ?? "\"")")
            exitVisual()
            return false
        }
        let region = visualRegion()
        saveVisualMarks()
        switchMode(.normal)
        let d = doc
        guard region.end > region.start || d.length == 0 else { return false }
        let n = max(1, cmd.count ?? 1)
        let eol = lineTerminator(d, at: region.start)
        var text = adapt(reg.text, eol: eol)
        let deleted = regionText(d, region)
        let range = NSRange(location: region.start, length: region.end - region.start)
        var replacement: String
        var caret: Int          // offset (in the new text) where the cursor goes
        var caretIsLastChar = false

        if reg.linewise {
            if !text.endsWithLineBreak { text += eol }
            let block = String(repeating: text, count: n)
            if region.linewise {
                replacement = block
                if region.end >= d.length && !d.endsWithBreak { replacement = block.droppingTrailingBreak }
                caret = region.start
            } else {
                // Characterwise selection: the line is always split around the new lines (Vim's PUT_LINE_SPLIT),
                // so whatever followed the selection ends up on its own line after them.
                replacement = eol + block
                caret = region.start + eol.u16
            }
        } else {
            let body = String(repeating: text, count: n)
            if region.linewise {
                let atEnd = region.end >= d.length && !d.endsWithBreak
                replacement = atEnd ? body : body + eol
                caret = region.start
                caretIsLastChar = !body.containsLineBreak
                if caretIsLastChar { caret = region.start + max(0, body.u16 - 1) }
            } else {
                replacement = body
                caret = region.start
                if !(body.containsLineBreak) { caretIsLastChar = true }
            }
        }
        if replaceRegister { storeDelete(deleted, linewise: region.linewise, register: nil) }
        replace(range, with: replacement)
        let nd = doc
        if cursorAfter {
            cursor = nd.clampNormal(region.start + replacement.u16)
        } else if caretIsLastChar && !region.linewise {
            cursor = nd.clampNormal(nd.prevCharStart(region.start + replacement.u16))
        } else if reg.linewise {
            cursor = nd.clampNormal(nd.firstNonBlank(caret))
        } else {
            cursor = nd.clampNormal(caret)
        }
        desiredCol = nil
        return true
    }

    // MARK: Join

    /// `J` / `gJ` on `count` lines starting at the cursor line (count is at least 2).
    /// Returns false when there is nothing to join with.
    @discardableResult
    func joinLines(count: Int, spaces: Bool) -> Bool {
        let d = doc
        let want = max(2, count)
        var lines: [(ls: Int, ce: Int)] = []
        var ls = d.lineStart(cursor)
        while lines.count < want {
            lines.append((ls, d.contentEnd(ls)))
            guard let nx = d.nextLineStart(after: ls) else { break }
            ls = nx
        }
        guard lines.count >= 2 else { return false }
        let firstText = d.sub(lines[0].ls, lines[0].ce)
        var lastChar: Character? = firstText.last
        var total = firstText.isEmpty ? 0 : 1
        var tail = ""
        var tailLen = 0
        var joinOffset = 0       // offset inside `tail` where the last join starts
        for i in 1..<lines.count {
            var t = d.sub(lines[i].ls, lines[i].ce)
            var sep = ""
            if spaces {
                t = String(t.drop(while: { $0 == " " || $0 == "\t" }))
                if !t.isEmpty, !t.hasPrefix(")"), total > 0, lastChar != " ", lastChar != "\t" {
                    sep = " "
                }
            }
            joinOffset = tailLen
            tail += sep + t
            tailLen += sep.u16 + t.u16
            if let l = (sep + t).last { lastChar = l }
            if !t.isEmpty { total += 1 }
        }
        let rangeStart = lines[0].ce
        let rangeEnd = lines[lines.count - 1].ce
        replace(NSRange(location: rangeStart, length: rangeEnd - rangeStart), with: tail)
        cursor = doc.clampNormal(rangeStart + joinOffset)
        desiredCol = nil
        return true
    }
}

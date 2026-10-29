import Foundation

// Undo / redo. The text is restored by the host buffer; the engine only decides where the cursor goes,
// using the cursor position recorded when each undo group was opened (like Vim's `uh_cursor`).

/// Where the cursor was (0-based line, character column) before an undoable change.
struct UndoCursor {
    var line: Int
    var column: Int
}

extension VimEngine {

    func performUndo(count: Int) {
        closeUndoGroup()
        stepHistory(count: count, undo: true)
    }

    func performRedo(count: Int) {
        closeUndoGroup()
        stepHistory(count: count, undo: false)
    }

    private func stepHistory(count: Int, undo: Bool) {
        var saved: UndoCursor?
        var lastOld: NSString?
        var changedAny = false
        for _ in 0..<max(1, count) {
            let old = (buf.vimText as String) as NSString
            if undo { buf.vimUndo() } else { buf.vimRedo() }
            let new = buf.vimText as String
            if new == (old as String) {
                if !changedAny { notify(undo ? "Already at oldest change" : "Already at newest change") }
                break
            }
            changedAny = true
            lastOld = old
            if undo {
                if let c = undoCursors.popLast() { redoCursors.append(c); saved = c } else { saved = nil }
            } else {
                if let c = redoCursors.popLast() { undoCursors.append(c); saved = c } else { saved = nil }
            }
        }
        guard changedAny, let old = lastOld else { return }
        placeCursorAfterHistory(old: old, saved: saved)
        desiredCol = nil
    }

    /// Positions the cursor after an undo / redo that turned `old` into the buffer's current text.
    private func placeCursorAfterHistory(old: NSString, saved: UndoCursor?) {
        let d = doc
        let a = old
        let b = d.t
        let m = min(a.length, b.length)
        var p = 0
        while p < m && a.character(at: p) == b.character(at: p) { p += 1 }
        p = d.clusterStart(p)
        var q = 0
        while q < m - p && a.character(at: a.length - 1 - q) == b.character(at: b.length - 1 - q) { q += 1 }
        let changedEnd = max(p, b.length - q)
        var line = d.lineIndex(of: p)
        let lastLine = d.lineIndex(of: changedEnd)
        guard let s = saved else {
            cursor = d.clampNormal(p)
            return
        }
        if s.line >= line && s.line <= lastLine {
            line = s.line
        } else if s.line + 1 == line && line > 0 {
            line -= 1
        }
        guard let ls = d.offset(ofLine: line) else {
            cursor = d.clampNormal(p)
            return
        }
        if s.line == line {
            cursor = d.clampNormal(d.offset(lineStart: ls, column: s.column))
        } else {
            cursor = d.clampNormal(d.firstNonBlank(ls))
        }
    }
}

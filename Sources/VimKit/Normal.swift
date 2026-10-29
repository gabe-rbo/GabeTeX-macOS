import Foundation

// Normal / visual mode: key parsing, command dispatch, operator + motion/object evaluation, dot repeat.

extension VimEngine {

    // MARK: Key handling

    func handlePendingKey(_ key: VimKey) -> Bool {
        pending.append(key)
        var parser = CommandParser(keys: pending, visual: isVisual)
        switch parser.parse() {
        case .incomplete:
            return true
        case .invalid:
            pending.removeAll()
            afterCommand()
            return true
        case .passThrough:
            pending.removeAll()
            return false
        case .done(let cmd):
            pending.removeAll()
            execute(cmd)
            afterCommand()
            return true
        }
    }

    /// Returns to insert mode after the single command of `Ctrl-o`.
    private func afterCommand() {
        guard insertOneShot else { return }
        insertOneShot = false
        if mode == .normal && pending.isEmpty && cmdPendingOperator == nil {
            beginInsertSession(kind: .before, count: 1, records: false)
        }
    }

    // MARK: Dispatch

    func execute(_ cmd: VimCommand) {
        var changed = false
        var shape: VisualShape?
        switch cmd.action {
        case .motion(let m):
            executeMotion(m, cmd)
        case .operatorMotion(let op, let m):
            changed = executeOperatorMotion(cmd, op, m) && op.modifiesText
        case .operatorObject(let op, let obj):
            changed = executeOperatorObject(cmd, op, obj) && op.modifiesText
        case .operatorLines(let op):
            changed = executeOperatorLines(cmd, op) && op.modifiesText
        case .visualOperator(let op):
            shape = currentVisualShape()
            changed = executeVisualOperator(cmd, op) && op.modifiesText
        case .visualObject(let obj):
            applyVisualObject(obj, count: cmd.count)
        case .simple(let s):
            if isVisual {
                switch s {
                case .put, .replaceChar, .join:
                    shape = currentVisualShape()
                case .visualLinewise:
                    shape = currentVisualShape()
                    shape?.mode = .visualLine
                default:
                    break
                }
            }
            changed = executeSimple(s, cmd)
        }
        if changed && !replaying {
            let rec = RepeatRecord(command: cmd, insertText: nil, visual: shape)
            if insertSession != nil || replaceSession != nil { building = rec } else { lastChange = rec }
        }
    }

    // MARK: Motions

    func executeMotion(_ m: VimMotion, _ cmd: VimCommand) {
        if case .searchCommand(let forward) = m {
            cmdReturnMode = mode
            cmdPendingOperator = cmd
            openCommandLine(forward ? "/" : "?")
            return
        }
        let old = cursor
        guard let res = evalMotion(m, count: cmd.count, op: nil) else { return }
        if res.isJump { marks["'"] = old }
        let d = doc
        if isVisual {
            var p = max(0, min(res.offset, d.length))
            if p == d.length && d.endsWithBreak { p = d.length - d.terminatorLength(endingAt: d.length) }
            cursor = p
        } else {
            cursor = d.clampNormal(res.offset)
        }
        desiredCol = res.column
    }

    private func forcesNumberedRegister(_ m: VimMotion) -> Bool {
        switch m {
        case .matchPair, .paragraphForward, .paragraphBackward, .searchPattern, .searchNext, .searchWord: return true
        case .mark(_, let linewise): return !linewise
        default: return false
        }
    }

    /// Operator + motion (`dw`, `c$`, `y}` …, also `x D C s` via their expansions).
    func executeOperatorMotion(_ cmd: VimCommand, _ op: VimOperator, _ m: VimMotion) -> Bool {
        if case .searchCommand(let forward) = m {
            cmdReturnMode = mode
            cmdPendingOperator = cmd
            openCommandLine(forward ? "/" : "?")
            return false
        }
        let d = doc
        let from = max(0, min(cursor, d.length))
        var res: MotionResult
        if let r = evalMotion(m, count: cmd.count, op: op) {
            res = r
        } else if op == .change, m == .right {
            res = MotionResult(offset: from)        // `s` / `cl` on an empty line still starts inserting
        } else {
            return false
        }
        if res.isJump { marks["'"] = from }
        let to = max(0, min(res.offset, d.length))
        var region: Region
        if res.linewise {
            let a = min(from, to), b = max(from, to)
            region = Region(start: d.lineStart(a), end: d.lineEnd(b), linewise: true, yankCursor: to < from ? to : from)
        } else {
            var s = min(from, to)
            var e = max(from, to)
            var linewise = false
            if res.inclusive {
                e = d.inclusiveEnd(e)
            } else if e > s && e == d.lineStart(e) && e < d.length {
                // Exclusive motion ending in column 0: the end moves to the previous line; from an indent it becomes linewise.
                if d.inIndent(s, extra: 0) {
                    linewise = true
                    s = d.lineStart(s)
                } else {
                    e -= d.terminatorLength(endingAt: e)
                }
            }
            region = Region(start: s, end: e, linewise: linewise, yankCursor: linewise ? from : nil)
        }
        applyOperator(op, region, register: cmd.register, count: nil, forceNumbered: forcesNumberedRegister(m))
        return true
    }

    func executeOperatorObject(_ cmd: VimCommand, _ op: VimOperator, _ obj: VimTextObject) -> Bool {
        guard let r = objectRegion(obj, count: cmd.count ?? 1) else { return false }
        if r.end <= r.start && op != .change { return false }
        var region = r
        if region.yankCursor == nil, region.linewise { region.yankCursor = region.start }
        applyOperator(op, region, register: cmd.register, count: nil)
        return true
    }

    func executeOperatorLines(_ cmd: VimCommand, _ op: VimOperator) -> Bool {
        let d = doc
        let n = max(1, cmd.count ?? 1)
        let ls = d.lineStart(cursor)
        var last = ls
        var moved = 0
        while moved < n - 1, let nx = d.nextLineStart(after: last) {
            last = nx
            moved += 1
        }
        if n > 1 && moved == 0 { return false }
        let region = Region(start: ls, end: d.lineEnd(last), linewise: true, yankCursor: cursor)
        applyOperator(op, region, register: cmd.register, count: nil)
        return true
    }

    // MARK: Visual operators

    /// The selection as a region (`end` exclusive).
    func visualRegion() -> Region {
        let d = doc
        let lo = min(visualAnchor, cursor), hi = max(visualAnchor, cursor)
        if mode == .visualLine {
            return Region(start: d.lineStart(lo), end: d.lineEnd(hi), linewise: true, yankCursor: lo)
        }
        let end = min(d.length, hi + d.cursorCharLength(at: hi))
        return Region(start: lo, end: max(lo, end), linewise: false, yankCursor: lo)
    }

    func currentVisualShape() -> VisualShape {
        let d = doc
        let r = visualRegion()
        let lastPos = r.end > r.start ? d.clusterStart(r.end - 1) : r.start
        let lines = d.lineIndex(of: lastPos) - d.lineIndex(of: r.start) + 1
        var columns = 0
        if !r.linewise {
            let ls = d.lineStart(lastPos)
            let from = lines == 1 ? r.start : ls
            var i = from
            while i < r.end { i = d.clusterEnd(i); columns += 1 }
        }
        return VisualShape(mode: mode, lines: lines, columns: columns)
    }

    func saveVisualMarks() {
        let d = doc
        let lo = min(visualAnchor, cursor), hi = max(visualAnchor, cursor)
        lastVisual = (visualAnchor, cursor, mode)
        marks["<"] = mode == .visualLine ? d.lineStart(lo) : lo
        marks[">"] = mode == .visualLine ? d.lastCharStart(inLineAt: hi) : hi
    }

    func exitVisual() {
        guard isVisual else { return }
        saveVisualMarks()
        let d = doc
        switchMode(.normal)
        cursor = d.clampNormal(cursor)
    }

    func executeVisualOperator(_ cmd: VimCommand, _ op: VimOperator) -> Bool {
        let region = visualRegion()
        saveVisualMarks()
        switchMode(.normal)
        cursor = region.start
        applyOperator(op, region, register: cmd.register, count: cmd.count, visual: true)
        return true
    }

    /// Re-creates a visual selection of the same size at the cursor (for `.` after a visual operator).
    func selectShape(_ shape: VisualShape) {
        let d = doc
        visualAnchor = cursor
        var target = cursor
        if shape.mode == .visualLine {
            var ls = d.lineStart(cursor)
            var k = 1
            while k < shape.lines, let nx = d.nextLineStart(after: ls) { ls = nx; k += 1 }
            target = ls
        } else if shape.lines == 1 {
            var p = cursor
            var k = 1
            while k < shape.columns, p < d.contentEnd(p) { p = d.clusterEnd(p); k += 1 }
            target = min(p, max(cursor, d.lastCharStart(inLineAt: p)))
        } else {
            var ls = d.lineStart(cursor)
            var k = 1
            while k < shape.lines, let nx = d.nextLineStart(after: ls) { ls = nx; k += 1 }
            target = d.offset(lineStart: ls, column: max(0, shape.columns - 1))
        }
        cursor = target
        switchMode(shape.mode)
    }

    // MARK: Dot repeat

    func repeatChange(count: Int?) {
        guard let rec = lastChange, !replaying else { return }
        replaying = true
        defer {
            replaying = false
            replayInsertText = nil
        }
        var cmd = rec.command
        if let n = count { cmd.count = n }
        replayInsertText = rec.insertText
        if let shape = rec.visual { selectShape(shape) }
        execute(cmd)
        if isVisual { exitVisual() }
    }
}

import Foundation

// Command-line mode (`:` `/` `?`) and the Ex commands.

extension VimEngine {

    // MARK: Opening / keys

    func openCommandLine(_ prefix: Character, initial: String = "") {
        cmdPrefix = prefix
        pending.removeAll()
        historyIndex = nil
        ctrlRPending = false
        searchOrigin = cursor
        switchMode(.commandLine)
        commandLine = String(prefix) + initial
    }

    func handleCommandLineKey(_ key: VimKey) -> Bool {
        if ctrlRPending {
            ctrlRPending = false
            var text: String?
            if key.isCtrl("w") {
                text = wordUnderCursor(doc, at: cursor)?.text
            } else if let ch = key.plain?.first {
                text = readRegister(ch)?.text
            }
            if var t = text {
                if t.endsWithLineBreak { t = t.droppingTrailingBreak }
                commandLine?.append(t.replacingOccurrences(of: "\n", with: " "))
            }
            return true
        }
        if key.isSpecial(.escape) || key.isCtrl("c") || key.isCtrl("[") {
            cancelCommandLine()
            return true
        }
        if key.isSpecial(.enter) || key.isCtrl("m") || key.isCtrl("j") {
            executeCommandLine()
            return true
        }
        if key.isSpecial(.backspace) || key.isCtrl("h") {
            if (commandLine?.count ?? 0) <= 1 { cancelCommandLine() } else { commandLine?.removeLast() }
            return true
        }
        if key.isCtrl("u") {
            commandLine = String(cmdPrefix)
            return true
        }
        if key.isCtrl("w") {
            guard var line = commandLine, line.count > 1 else { return true }
            while line.count > 1, line.last == " " { line.removeLast() }
            while line.count > 1, let l = line.last, l != " " { line.removeLast() }
            commandLine = line
            return true
        }
        if key.isCtrl("r") {
            ctrlRPending = true
            return true
        }
        if key.isSpecial(.up) || key.isSpecial(.down) {
            navigateHistory(older: key.isSpecial(.up))
            return true
        }
        if let ch = key.plain {
            commandLine?.append(ch)
        }
        return true
    }

    private var historyKind: Character { cmdPrefix == ":" ? ":" : "/" }

    private func navigateHistory(older: Bool) {
        let list = history[historyKind] ?? []
        guard !list.isEmpty else { return }
        var idx = historyIndex ?? list.count
        idx += older ? -1 : 1
        if idx < 0 { idx = 0 }
        if idx >= list.count {
            historyIndex = nil
            commandLine = String(cmdPrefix)
            return
        }
        historyIndex = idx
        commandLine = String(cmdPrefix) + list[idx]
    }

    func cancelCommandLine() {
        cmdPendingOperator = nil
        ctrlRPending = false
        switchMode(cmdReturnMode)
        commandLine = nil
    }

    // MARK: Execution

    func executeCommandLine() {
        let line = commandLine ?? ""
        let prefix = cmdPrefix
        let text = String(line.dropFirst())
        let pendingCmd = cmdPendingOperator
        cmdPendingOperator = nil
        if !text.isEmpty {
            var list = history[historyKind] ?? []
            list.removeAll { $0 == text }
            list.append(text)
            if list.count > 100 { list.removeFirst() }
            history[historyKind] = list
        }
        let returnMode = cmdReturnMode
        switchMode(returnMode)
        commandLine = nil
        if prefix == ":" {
            regs.lastExCommand = text
            executeEx(text)
            return
        }
        // Search.
        let forward = prefix == "/"
        var pattern = text
        var offset = ""
        if let split = splitSearch(text, delimiter: prefix) {
            pattern = split.pattern
            offset = split.offset
        }
        if pattern.isEmpty {
            guard let last = lastSearch else {
                notify("E35: No previous regular expression")
                return
            }
            pattern = last.pattern
            if text.isEmpty { offset = last.offset }
        }
        lastSearch = LastSearch(pattern: pattern, forward: forward, offset: offset)
        searchHighlightHidden = false
        var cmd = pendingCmd ?? VimCommand(action: .motion(.searchCommand(forward: forward)), register: nil, count: nil)
        switch cmd.action {
        case .motion:
            cmd.action = .motion(.searchPattern(pattern, forward: forward))
        case .operatorMotion(let op, _):
            cmd.action = .operatorMotion(op, .searchPattern(pattern, forward: forward))
        default:
            return
        }
        execute(cmd)
    }

    /// Splits `pattern/offset` at the first unescaped delimiter.
    private func splitSearch(_ text: String, delimiter: Character) -> (pattern: String, offset: String)? {
        let chars = Array(text)
        var i = 0
        var pat = ""
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                if chars[i + 1] == delimiter { pat.append(delimiter) } else { pat.append(chars[i]); pat.append(chars[i + 1]) }
                i += 2
                continue
            }
            if chars[i] == delimiter {
                return (pat, String(chars[(i + 1)...]))
            }
            pat.append(chars[i])
            i += 1
        }
        return nil
    }

    // MARK: Ranges

    private func parseAddress(_ s: inout Substring, current: Int, last: Int, failed: inout Bool) -> Int? {
        s = s.drop(while: { $0 == " " })
        guard let c = s.first else { return nil }
        var value: Int?
        if c.isASCII && c.isNumber {
            var n = 0
            while let ch = s.first, ch.isASCII, let v = ch.wholeNumberValue {
                n = min(n * 10 + v, 99_999_999)
                s.removeFirst()
            }
            value = n
        } else if c == "." {
            value = current
            s.removeFirst()
        } else if c == "$" {
            value = last
            s.removeFirst()
        } else if c == "'" {
            s.removeFirst()
            guard let m = s.first else { failed = true; return nil }
            s.removeFirst()
            guard let off = markOffset(m) else {
                notify("E20: Mark not set")
                failed = true
                return nil
            }
            value = doc.lineIndex(of: off) + 1
        } else if c == "+" || c == "-" {
            value = current
        }
        guard var v = value else { return nil }
        while true {
            s = s.drop(while: { $0 == " " })
            guard let o = s.first, o == "+" || o == "-" else { break }
            s.removeFirst()
            var n = 0
            var any = false
            while let ch = s.first, ch.isASCII, let dv = ch.wholeNumberValue {
                n = min(n * 10 + dv, 99_999_999)
                any = true
                s.removeFirst()
            }
            if !any { n = 1 }
            v += o == "+" ? n : -n
        }
        return v
    }

    /// Parses an Ex range. Returns nil on error; `given` is the number of addresses typed (0, 1 or 2).
    private func parseExRange(_ s: inout Substring) -> (first: Int, last: Int, given: Int)? {
        let d = doc
        let cur = d.lineIndex(of: cursor) + 1
        let lastLine = d.lineCount
        s = s.drop(while: { $0 == " " })
        if s.first == "%" {
            s.removeFirst()
            return (1, lastLine, 2)
        }
        var addrs: [Int] = []
        var failed = false
        while true {
            if let a = parseAddress(&s, current: cur, last: lastLine, failed: &failed) {
                addrs.append(a)
            } else if failed {
                return nil
            } else if s.first == ",", addrs.isEmpty || addrs.count % 2 == 0 {
                addrs.append(cur)
            }
            s = s.drop(while: { $0 == " " })
            if s.first == "," || s.first == ";" {
                s.removeFirst()
                let save = s
                if parseAddress(&s, current: cur, last: lastLine, failed: &failed) == nil {
                    if failed { return nil }
                    s = save
                    addrs.append(cur)
                    break
                }
                s = save
                continue
            }
            break
        }
        func clamp(_ v: Int) -> Int { max(1, min(v, lastLine)) }
        switch addrs.count {
        case 0: return (cur, cur, 0)
        case 1: return (clamp(addrs[0]), clamp(addrs[0]), 1)
        default:
            let a = clamp(addrs[addrs.count - 2]), b = clamp(addrs[addrs.count - 1])
            return (min(a, b), max(a, b), 2)
        }
    }

    // MARK: Ex commands

    private func abbreviation(_ name: String, _ full: String, _ minLength: Int) -> Bool {
        name.count >= minLength && full.hasPrefix(name)
    }

    /// Executes an Ex command line (without the leading colon).
    func executeEx(_ raw: String) {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        while s.first == ":" || s.first == " " { s.removeFirst() }
        if s.isEmpty { return }
        guard let range = parseExRange(&s) else { return }
        s = s.drop(while: { $0 == " " })
        var name = ""
        if let f = s.first, "&<>!=#@".contains(f) {
            // `>>` / `<<` repeat the shift; the others are single-character commands.
            name.append(f)
            s.removeFirst()
            if (f == ">" || f == "<") { while s.first == f { name.append(f); s.removeFirst() } }
        } else {
            while let f = s.first, f.isLetter, f.isASCII {
                name.append(f)
                s.removeFirst()
            }
            // `:ka` is `:k a`.
            if name.count == 2, name.first == "k", name != "ke" {
                s = Substring(String(name.dropFirst()) + String(s))
                name = "k"
            }
        }
        var bang = false
        if s.first == "!" { bang = true; s.removeFirst() }
        _ = bang
        let args = String(s).trimmingCharacters(in: .whitespaces)
        let d = doc

        if name.isEmpty {
            guard range.given > 0 else { return }
            gotoLine(range.last)
            return
        }
        if abbreviation(name, "substitute", 1) {
            guard let spec = parseSubstitute(String(s)) else {
                notify("E486: Pattern not found")
                return
            }
            let first = range.first - 1, last = range.last - 1
            runSubstitute(spec, lines: min(first, last)...max(first, last))
            return
        }
        if name == "&" || name == "&&" {
            guard let last = lastSubstitute else { notify("E35: No previous regular expression"); return }
            // `:&&` keeps the flags of the previous substitute; other flags (`g`, `i`, `I`) follow the `&`.
            var spec = last
            spec.global = false
            spec.ignoreCase = nil
            var flags = args.filter { $0 != " " }
            if name == "&&" { flags = "&" + flags }
            for f in flags {
                switch f {
                case "&": spec.global = last.global; spec.ignoreCase = last.ignoreCase
                case "g": spec.global.toggle()
                case "i": spec.ignoreCase = true
                case "I": spec.ignoreCase = false
                default: break
                }
            }
            runSubstitute(spec, lines: (range.first - 1)...(range.last - 1))
            return
        }
        if abbreviation(name, "nohlsearch", 3) { searchHighlightHidden = true; return }
        if abbreviation(name, "write", 1) {
            if args.isEmpty { onExCommand?(.write) } else { onExCommand?(.unknown(raw)) }
            return
        }
        if abbreviation(name, "wall", 2) { onExCommand?(.writeAll); return }
        if abbreviation(name, "wqall", 3) || abbreviation(name, "xall", 2) {
            onExCommand?(.writeAll)
            onExCommand?(.quit)
            return
        }
        if name == "wq" || abbreviation(name, "xit", 1) || abbreviation(name, "exit", 3) {
            onExCommand?(.writeQuit)
            return
        }
        if name == "update" || name == "up" || name == "upd" { onExCommand?(.write); return }
        if abbreviation(name, "quit", 1) || abbreviation(name, "close", 3) {
            onExCommand?(.quit)
            return
        }
        if abbreviation(name, "make", 3) || name == "TeX" || name == "tex" || name == "compile" {
            onExCommand?(.compile)
            return
        }
        if abbreviation(name, "delete", 1) {
            let from = range.first - 1, to = range.last - 1
            exDeleteOrYank(lines: from...to, delete: true, register: args.first)
            return
        }
        if abbreviation(name, "yank", 1) {
            exDeleteOrYank(lines: (range.first - 1)...(range.last - 1), delete: false, register: args.first)
            return
        }
        if name.first == ">" || name.first == "<" {
            let op: VimOperator = name.first == ">" ? .shiftRight : .shiftLeft
            let ls = d.offset(ofLine: range.first - 1) ?? 0
            let le = d.offset(ofLine: range.last - 1) ?? ls
            shiftLines(from: ls, to: le, right: op == .shiftRight, times: name.count)
            cursor = doc.clampNormal(doc.firstNonBlank(d.offset(ofLine: range.last - 1) ?? ls))
            return
        }
        if abbreviation(name, "undo", 1) { performUndo(count: 1); return }
        if abbreviation(name, "redo", 3) { performRedo(count: 1); return }
        if abbreviation(name, "join", 1) {
            let from = range.first - 1
            let to = range.given == 2 ? range.last - 1 : from + 1
            if let ls = d.offset(ofLine: from) {
                cursor = ls
                joinLines(count: max(2, to - from + 1), spaces: !bang)
            }
            return
        }
        if name == "k" || abbreviation(name, "mark", 2) {
            if let m = args.first, let ls = d.offset(ofLine: range.last - 1) { marks[m] = ls }
            return
        }
        if let handler = onExCommand {
            handler(.unknown(raw))
        } else {
            notify("E492: Not an editor command: \(raw)")
        }
    }

    func gotoLine(_ n: Int) {
        let d = doc
        let target = max(1, min(n, d.lineCount))
        let ls = d.offset(ofLine: target - 1) ?? d.lastLineStart
        marks["'"] = cursor
        cursor = d.clampNormal(d.firstNonBlank(ls))
        desiredCol = nil
        onExCommand?(.goToLine(target))
    }

    /// `:d` / `:y`.
    private func exDeleteOrYank(lines: ClosedRange<Int>, delete: Bool, register: Character?) {
        let d = doc
        guard let ls = d.offset(ofLine: lines.lowerBound) else { return }
        let lastStart = d.offset(ofLine: lines.upperBound) ?? d.lastLineStart
        let region = Region(start: ls, end: d.lineEnd(lastStart), linewise: true, yankCursor: ls)
        let reg: Character? = (register?.isLetter ?? false) ? register : nil
        if delete {
            applyOperator(.delete, region, register: reg, count: nil)
        } else {
            applyOperator(.yank, region, register: reg, count: nil)
        }
    }
}

import Foundation

// `:s/pattern/replacement/flags` and `&`.

struct SubstituteSpec {
    var pattern: String
    var replacement: String
    var global: Bool
    /// `i` (true) / `I` (false) flags.
    var ignoreCase: Bool?
}

extension VimEngine {

    /// Parses the text following `s` (`/pat/rep/flags`). An empty string repeats the last substitute.
    func parseSubstitute(_ rest: String) -> SubstituteSpec? {
        let chars = Array(rest)
        guard let delim = chars.first else {
            guard var last = lastSubstitute else { return nil }
            last.global = false
            return last
        }
        if delim.isLetter || delim.isNumber || delim == " " || delim == "\\" || delim == "\"" || delim == "|" {
            // `:s g` style flags without a pattern repeat the last substitute.
            if var last = lastSubstitute, rest.allSatisfy({ "&gciIe".contains($0) || $0 == " " }) {
                last.global = rest.contains("g")
                return last
            }
            return nil
        }
        var parts: [String] = []
        var cur = ""
        var i = 1
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == delim && parts.count < 2 && delim != "/" {
                    cur.append(n)         // `\#` with `#` as delimiter is a literal `#`
                } else if n == delim && parts.count < 2 {
                    cur.append(n)
                } else {
                    cur.append(c)
                    cur.append(n)
                }
                i += 2
                continue
            }
            if c == delim && parts.count < 2 {
                parts.append(cur)
                cur = ""
                i += 1
                continue
            }
            cur.append(c)
            i += 1
        }
        parts.append(cur)
        guard parts.count >= 2 else {
            // `:s/pat` — substitute with an empty replacement.
            return SubstituteSpec(pattern: parts[0], replacement: "", global: false, ignoreCase: nil)
        }
        var spec = SubstituteSpec(pattern: parts[0], replacement: parts[1], global: false, ignoreCase: nil)
        if parts.count >= 3 {
            for f in parts[2] {
                switch f {
                case "g": spec.global.toggle()
                case "i": spec.ignoreCase = true
                case "I": spec.ignoreCase = false
                case "&":
                    if let last = lastSubstitute {
                        spec.global = last.global
                        spec.ignoreCase = last.ignoreCase
                    }
                default: break
                }
            }
        }
        return spec
    }

    /// Runs a substitute on the 0-based line range. Returns false when the pattern was not found.
    @discardableResult
    func runSubstitute(_ spec: SubstituteSpec, lines: ClosedRange<Int>) -> Bool {
        var pattern = spec.pattern
        if pattern.isEmpty { pattern = lastSearch?.pattern ?? "" }
        guard !pattern.isEmpty else {
            notify("E35: No previous regular expression")
            return false
        }
        var compiled = pattern
        if let ic = spec.ignoreCase { compiled = (ic ? "\\c" : "\\C") + pattern }
        guard let re = compilePattern(compiled) else { return false }
        lastSubstitute = SubstituteSpec(pattern: pattern, replacement: spec.replacement,
                                        global: spec.global, ignoreCase: spec.ignoreCase)
        lastSearch = LastSearch(pattern: pattern, forward: lastSearch?.forward ?? true)
        searchHighlightHidden = false

        let d = doc
        // Collect line extents first; edits run from the bottom up so earlier offsets stay valid.
        var extents: [(ls: Int, ce: Int)] = []
        if var ls = d.offset(ofLine: lines.lowerBound) {
            var idx = lines.lowerBound
            while idx <= lines.upperBound {
                extents.append((ls, d.contentEnd(ls)))
                guard let nx = d.nextLineStart(after: ls) else { break }
                ls = nx
                idx += 1
            }
        }
        var subs = 0
        var changedLines = 0
        var lastChangedStart: Int?
        for e in extents.reversed() {
            let line = d.sub(e.ls, e.ce) as NSString
            let full = NSRange(location: 0, length: line.length)
            let matches: [NSTextCheckingResult]
            if spec.global {
                matches = re.matches(in: line as String, options: [], range: full)
            } else if let m = re.firstMatch(in: line as String, options: [], range: full) {
                matches = [m]
            } else {
                matches = []
            }
            if matches.isEmpty { continue }
            let out = NSMutableString()
            var pos = 0
            for m in matches {
                out.append(line.substring(with: NSRange(location: pos, length: m.range.location - pos)))
                out.append(expandReplacement(spec.replacement, match: m, in: line))
                pos = m.range.location + m.range.length
            }
            out.append(line.substring(from: pos))
            subs += matches.count
            changedLines += 1
            if lastChangedStart == nil { lastChangedStart = e.ls }
            replace(NSRange(location: e.ls, length: e.ce - e.ls), with: out as String)
        }
        guard let last = lastChangedStart else {
            notify("E486: Pattern not found: \(pattern)")
            return false
        }
        let nd = doc
        cursor = nd.clampNormal(nd.firstNonBlank(last))
        desiredCol = nil
        if subs > 2 {
            notify("\(subs) substitutions on \(changedLines) line\(changedLines == 1 ? "" : "s")")
        }
        return true
    }

    /// Expands `&`, `\1`…`\9`, `\n`, `\t`, `\u` `\U` `\l` `\L` `\e` `\E` in a replacement string.
    func expandReplacement(_ rep: String, match: NSTextCheckingResult, in text: NSString) -> String {
        enum CaseMode { case none, upper, lower }
        var persistent = CaseMode.none
        var oneShot = CaseMode.none
        var out = ""
        func group(_ i: Int) -> String {
            guard i < match.numberOfRanges else { return "" }
            let r = match.range(at: i)
            return r.location == NSNotFound ? "" : text.substring(with: r)
        }
        func append(_ s: String) {
            if s.isEmpty { return }
            var rest = Substring(s)
            if oneShot != .none, let f = rest.first {
                out += oneShot == .upper ? String(f).uppercased() : String(f).lowercased()
                rest = rest.dropFirst()
                oneShot = .none
            }
            switch persistent {
            case .none: out += rest
            case .upper: out += rest.uppercased()
            case .lower: out += rest.lowercased()
            }
        }
        let chars = Array(rep)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            if c == "&" { append(group(0)); continue }
            guard c == "\\", i < chars.count else { append(String(c)); continue }
            let n = chars[i]
            i += 1
            switch n {
            case "0"..."9": append(group(Int(n.asciiValue ?? 48) - 48))
            case "n", "r": append("\n")
            case "t": append("\t")
            case "u": oneShot = .upper
            case "l": oneShot = .lower
            case "U": persistent = .upper
            case "L": persistent = .lower
            case "e", "E": persistent = .none; oneShot = .none
            default: append(String(n))
            }
        }
        return out
    }
}

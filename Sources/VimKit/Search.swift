import Foundation

// Vim pattern -> NSRegularExpression translation, buffer searching (`/ ? n N * #`) and search offsets.

/// A Vim ("magic") pattern translated to ICU regular expression syntax.
struct VimTranslated {
    var icu: String
    /// `\c` (true) / `\C` (false) given in the pattern.
    var forceIgnoreCase: Bool?
    /// The pattern has an uppercase letter that is not part of an escape (for `smartcase`).
    var hasUpper: Bool
}

/// Translates Vim "magic" regular expression syntax into ICU syntax.
/// Unescaped `( ) | + ? { }` are literals, `\( \) \| \+ \? \= \{n,m}` are the operators; `\<` and `\>` are word boundaries.
func vimTranslatePattern(_ pattern: String) -> VimTranslated {
    let s = Array(pattern.unicodeScalars)
    var out = ""
    var veryMagic = false
    var forceCase: Bool?
    var hasUpper = false
    var atStart = true
    var i = 0

    func put(_ str: String) { out += str }
    func put(_ u: Unicode.Scalar) { out.unicodeScalars.append(u) }
    func lit(_ u: Unicode.Scalar) {
        // A literal character, escaped when it is special for ICU.
        if "\\^$.|?*+()[]{}-&#".unicodeScalars.contains(u) { put("\\") }
        put(u)
    }

    func escaped(_ n: Unicode.Scalar) {
        switch n {
        case "(": put("("); atStart = true; return
        case ")": put(")")
        case "|": put("|"); atStart = true; return
        case "+", "?": put(n)
        case "=": put("?")
        case "{":
            var body = ""
            while i < s.count, s[i] != "}" {
                if s[i] == "\\", i + 1 < s.count, s[i + 1] == "}" { i += 1; break }
                body.unicodeScalars.append(s[i])
                i += 1
            }
            if i < s.count, s[i] == "}" { i += 1 }
            var lazy = false
            if body.hasPrefix("-") { lazy = true; body.removeFirst() }
            if body.isEmpty { put("*") }
            else if body.hasPrefix(",") { put("{0\(body)}") }
            else { put("{\(body)}") }
            if lazy { put("?") }
        case "<": put("\\b(?=\\w)")
        case ">": put("\\b(?<=\\w)")
        case "s", "S", "d", "D", "w", "W": put("\\"); put(n)
        case "a": put("[A-Za-z]")
        case "A": put("[^A-Za-z]")
        case "l": put("[a-z]")
        case "L": put("[^a-z]")
        case "u": put("[A-Z]")
        case "U": put("[^A-Z]")
        case "x": put("[0-9A-Fa-f]")
        case "X": put("[^0-9A-Fa-f]")
        case "h": put("[A-Za-z_]")
        case "H": put("[^A-Za-z_]")
        case "i", "k": put("[\\w]")
        case "I", "K": put("[^\\w]")
        case "n": put("\\n")
        case "r": put("\\r")
        case "t": put("\\t")
        case "e": put("\\x1B")
        case "c": forceCase = true; return
        case "C": forceCase = false; return
        case "v": veryMagic = true; return
        case "V", "m", "M", "z": return
        case "1", "2", "3", "4", "5", "6", "7", "8", "9": put("\\"); put(n)
        case "%":
            if i < s.count, s[i] == "(" { i += 1; put("(?:"); atStart = true; return }
            if i < s.count, s[i] == "^" { i += 1; put("^") }
            else if i < s.count, s[i] == "$" { i += 1; put("$") }
            else if i < s.count { i += 1 }
        default:
            if n.properties.isAlphabetic || n.properties.numericType != nil { put(n) } else { lit(n) }
        }
        atStart = false
    }

    while i < s.count {
        let c = s[i]
        i += 1
        if c == "\\" {
            guard i < s.count else { put("\\\\"); atStart = false; break }
            let n = s[i]
            i += 1
            escaped(n)
            continue
        }
        if veryMagic, "()|+?={}<>".unicodeScalars.contains(c) {
            escaped(c)
            continue
        }
        switch c {
        case "^":
            if atStart { put("^"); continue }
            put("\\^")
        case "$":
            var isEnd = i >= s.count
            if !isEnd, s[i] == "\\", i + 1 < s.count, s[i + 1] == ")" || s[i + 1] == "|" || s[i + 1] == "n" { isEnd = true }
            if !isEnd, veryMagic, s[i] == ")" || s[i] == "|" { isEnd = true }
            put(isEnd ? "$" : "\\$")
        case "*":
            put(atStart ? "\\*" : "*")
        case ".":
            put(".")
        case "(", ")", "|", "+", "?", "{", "}":
            put("\\"); put(c)
        case "[":
            var j = i
            if j < s.count, s[j] == "^" { j += 1 }
            if j < s.count, s[j] == "]" { j += 1 }
            while j < s.count, s[j] != "]" {
                if s[j] == "\\", j + 1 < s.count { j += 1 }
                j += 1
            }
            if j >= s.count {
                put("\\[")
                break
            }
            var set = "["
            var k = i
            if s[k] == "^" { set += "^"; k += 1 }
            if s[k] == "]" { set += "\\]"; k += 1 }
            while k < j {
                let u = s[k]
                if u == "\\", k + 1 < j {
                    let e = s[k + 1]
                    k += 2
                    switch e {
                    case "n": set += "\\n"
                    case "t": set += "\\t"
                    case "r": set += "\\r"
                    case "e": set += "\\x1B"
                    case "\\": set += "\\\\"
                    case "]", "^", "-": set += "\\"; set.unicodeScalars.append(e)
                    default: set += "\\\\"; set.unicodeScalars.append(e)
                    }
                    continue
                }
                if u == "[" || u == "&" { set += "\\" }
                if u.properties.isUppercase { hasUpper = true }
                set.unicodeScalars.append(u)
                k += 1
            }
            set += "]"
            put(set)
            i = j + 1
        default:
            if c.properties.isUppercase { hasUpper = true }
            lit(c)
        }
        atStart = false
    }
    return VimTranslated(icu: out, forceIgnoreCase: forceCase, hasUpper: hasUpper)
}

extension VimEngine {

    /// Compiles a Vim pattern; falls back to a literal search when the pattern is not a valid regular expression.
    func compilePattern(_ pattern: String, useSmartCase: Bool = true) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        let t = vimTranslatePattern(pattern)
        var ignore = ignoreCase
        if ignore && useSmartCase && smartCase && t.hasUpper { ignore = false }
        if let f = t.forceIgnoreCase { ignore = f }
        let key = "\(ignore ? 1 : 0)|\(pattern)"
        if let cached = regexCache[key] { return cached }
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if ignore { opts.insert(.caseInsensitive) }
        let re = (try? NSRegularExpression(pattern: t.icu, options: opts))
            ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: opts))
        if let re {
            if regexCache.count > 64 { regexCache.removeAll() }
            regexCache[key] = re
        }
        return re
    }

    /// Finds the `count`-th match of `pattern` after (or before) the offset `c`, wrapping around when `wrapScan`.
    func findMatch(pattern: String, forward: Bool, from c: Int, count: Int, useSmartCase: Bool = true) -> NSRange? {
        guard let re = compilePattern(pattern, useSmartCase: useSmartCase) else {
            if pattern.isEmpty { notify("E35: No previous regular expression") }
            return nil
        }
        let text = buf.vimText
        let len = text.length
        var pos = max(0, min(c, len))
        var found: NSRange?
        var wrapped = false
        let opts: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        for _ in 0..<max(1, count) {
            var m: NSRange?
            if forward {
                let d = Doc(text)
                let start = min(len, d.clusterEnd(pos))
                if start <= len {
                    m = re.firstMatch(in: text as String, options: opts, range: NSRange(location: start, length: len - start))?.range
                }
                if m == nil && wrapScan {
                    m = re.firstMatch(in: text as String, options: opts, range: NSRange(location: 0, length: len))?.range
                    if m != nil { wrapped = true }
                }
            } else {
                let all = re.matches(in: text as String, options: [], range: NSRange(location: 0, length: len))
                m = all.last(where: { $0.range.location < pos })?.range
                if m == nil && wrapScan, let l = all.last?.range {
                    m = l
                    wrapped = true
                }
            }
            guard let hit = m else {
                notify("E486: Pattern not found: \(pattern)")
                return nil
            }
            found = hit
            pos = hit.location
        }
        if wrapped { notify(forward ? "search hit BOTTOM, continuing at TOP" : "search hit TOP, continuing at BOTTOM") }
        searchHighlightHidden = false
        return found
    }

    /// Turns a match into a motion result, applying a search offset (`e`, `e+1`, `s-1`, `+2` …).
    func searchResult(_ d: Doc, match: NSRange, offset: String) -> MotionResult {
        let start = d.clusterStart(match.location)
        var off = offset.trimmingCharacters(in: .whitespaces)
        if off.isEmpty { return MotionResult(offset: start, isJump: true) }
        var base = start
        var inclusive = false
        var linewise = false
        var lineDelta = 0
        func number(_ s: Substring) -> Int {
            if s.isEmpty { return 0 }
            if s == "+" { return 1 }
            if s == "-" { return -1 }
            return Int(s) ?? 0
        }
        var kind: Character = "s"
        if let f = off.first, f == "e" || f == "s" || f == "b" {
            kind = f == "e" ? "e" : "s"
            off.removeFirst()
        } else { kind = "l" }
        let n = number(Substring(off))
        switch kind {
        case "e":
            inclusive = true
            let endPos = max(match.location, match.location + match.length)
            base = match.length > 0 ? d.prevCharStart(min(endPos, d.length)) : start
            var p = base
            var k = abs(n)
            while k > 0 {
                p = n > 0 ? min(d.clusterEnd(p), d.length) : d.prevCharStart(p)
                k -= 1
            }
            base = p
        case "s":
            var p = base
            var k = abs(n)
            while k > 0 {
                p = n > 0 ? min(d.clusterEnd(p), d.length) : d.prevCharStart(p)
                k -= 1
            }
            base = p
        default:
            linewise = true
            lineDelta = n
        }
        if linewise {
            var ls = d.lineStart(start)
            var k = abs(lineDelta)
            while k > 0 {
                guard let nx = lineDelta > 0 ? d.nextLineStart(after: ls) : d.prevLineStart(before: ls) else { break }
                ls = nx
                k -= 1
            }
            return MotionResult(offset: d.firstNonBlank(ls), linewise: true, isJump: true)
        }
        return MotionResult(offset: base, inclusive: inclusive, isJump: true)
    }
}

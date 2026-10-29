import Foundation

/// Where the cursor is, as far as completion is concerned.
enum CompletionContext {
    enum FileKind {
        /// `\input`, `\subfile`: `.tex` files, extension kept.
        case texWithExtension
        /// `\include`: `.tex` files, extension dropped.
        case texWithoutExtension
        case image
        case pdf
        /// `\bibliography{a,b}`: `.bib` files without extension (list).
        case bibliography
        /// `\addbibresource{refs.bib}`.
        case bibResource
    }

    /// `\fr|` — the command starts at `start` (the backslash).
    case command(start: Int)
    /// `\begin{ite|` / `\end{|`: the name being typed starts at `itemStart`.
    case environment(isEnd: Bool, itemStart: Int)
    case label(itemStart: Int)
    case citation(itemStart: Int)
    case package(itemStart: Int)
    case file(FileKind, itemStart: Int)

    // MARK: Command name tables

    private static let labelCommands: Set<String> = [
        "ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "vref", "Vref", "labelcref",
        "cpageref", "Cpageref", "crefrange", "Crefrange", "hyperref",
    ]
    /// Label commands whose argument is a comma separated list.
    private static let labelListCommands: Set<String> = ["cref", "Cref", "labelcref", "cpageref", "Cpageref"]

    private enum Argument {
        case environment(isEnd: Bool)
        case label(isList: Bool)
        case citation
        case package
        case file(FileKind)
    }

    private static func argument(forCommand name: String) -> Argument? {
        switch name {
        case "begin": return .environment(isEnd: false)
        case "end": return .environment(isEnd: true)
        case "usepackage", "RequirePackage": return .package
        case "input", "subfile": return .file(.texWithExtension)
        case "include": return .file(.texWithoutExtension)
        case "includegraphics": return .file(.image)
        case "includepdf": return .file(.pdf)
        case "bibliography": return .file(.bibliography)
        case "addbibresource": return .file(.bibResource)
        default: break
        }
        if labelCommands.contains(name) { return .label(isList: labelListCommands.contains(name)) }
        if LaTeXSyntax.isCiteLike(name) { return .citation }
        return nil
    }

    // MARK: Detection

    /// Analyses the masked text around `cursor`. Comments and verbatim are blanked in `u`, so they never
    /// produce a context.
    static func detect(_ u: [UInt16], cursor: Int) -> CompletionContext? {
        let n = u.count
        guard cursor >= 0, cursor <= n else { return nil }

        // 1. `\letters` immediately before the cursor.
        var j = cursor
        while j > 0 && isCommandLetter(u[j - 1]) { j -= 1 }
        if j > 0 && u[j - 1] == 92 {
            var backslashes = 0
            var k = j - 1
            while k >= 0 && u[k] == 92 { backslashes += 1; k -= 1 }
            return backslashes % 2 == 1 ? .command(start: j - 1) : nil
        }

        // 2. Inside the braces of a known command's argument.
        let lowest = max(0, cursor - 2_500)
        var k = cursor
        var breaks = 0
        while k > lowest {
            let c = u[k - 1]
            if c == 123 { break }
            if c == 125 || c == 92 { return nil }
            if isLineBreak(c) {
                if !(c == 13 && k < n && u[k] == 10) { breaks += 1 }
                if breaks >= 2 { return nil }
            } else if !isHSpace(c) {
                breaks = 0
            }
            k -= 1
        }
        guard k > lowest, u[k - 1] == 123 else { return nil }
        let open = k - 1

        func skipSpacesBack(_ position: Int) -> Int {
            var q = position
            while q > 0 && isHSpace(u[q - 1]) { q -= 1 }
            return q
        }

        var p = skipSpacesBack(open)
        var groups = 0
        while p > 0 && u[p - 1] == 93 && groups < 4 {
            var depth = 0
            var q = p - 1
            let floor = max(0, p - 600)
            var found = -1
            while q >= floor {
                let c = u[q]
                if c == 93 { depth += 1 }
                else if c == 91 {
                    depth -= 1
                    if depth == 0 { found = q; break }
                }
                q -= 1
            }
            guard found >= 0 else { return nil }
            p = skipSpacesBack(found)
            groups += 1
        }
        if p > 0 && u[p - 1] == 42 { p -= 1 }
        let nameEnd = p
        var nameStart = p
        while nameStart > 0 && isCommandLetter(u[nameStart - 1]) { nameStart -= 1 }
        guard nameStart < nameEnd, nameStart > 0, u[nameStart - 1] == 92 else { return nil }
        var backslashes = 0
        var b = nameStart - 1
        while b >= 0 && u[b] == 92 { backslashes += 1; b -= 1 }
        guard backslashes % 2 == 1 else { return nil }
        let name = utf16String(u, nameStart..<nameEnd)
        guard let argument = argument(forCommand: name) else { return nil }

        // Start of the item being typed.
        func itemStart(isList: Bool) -> Int {
            var start = open + 1
            if isList {
                var q = cursor
                while q > open + 1 {
                    if u[q - 1] == 44 { start = q; break }
                    q -= 1
                }
            }
            while start < cursor && isTeXWhitespace(u[start]) { start += 1 }
            return start
        }

        switch argument {
        case .environment(let isEnd): return .environment(isEnd: isEnd, itemStart: itemStart(isList: false))
        case .label(let isList): return .label(itemStart: itemStart(isList: isList))
        case .citation: return .citation(itemStart: itemStart(isList: true))
        case .package: return .package(itemStart: itemStart(isList: true))
        case .file(let kind):
            return .file(kind, itemStart: itemStart(isList: kind == .bibliography))
        }
    }
}

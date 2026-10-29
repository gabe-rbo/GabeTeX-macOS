import Foundation

/// A forward walk over a masked source that tracks braces, environments and math mode. It backs both
/// `StructureLinter` (walk to the end, report problems) and `CompletionEngine` (walk to the cursor, report
/// the innermost open environment and whether the cursor is in math mode).
struct StructureWalk {
    struct OpenBrace {
        var offset: Int
        /// The group is the argument of a text-mode command (`\text{...}`) and thus not math.
        var isTextGroup: Bool
    }

    struct OpenEnvironment {
        var name: String
        /// Offset of the `\begin`.
        var offset: Int
        /// Offset just past the closing brace of `\begin{name}`.
        var end: Int
    }

    struct Mismatch {
        var open: OpenEnvironment
        var closeName: String
        var offset: Int
        var end: Int
    }

    struct StrayEnd {
        var name: String
        var offset: Int
        var end: Int
    }

    var strayClosingBraces: [Int] = []
    var openBraces: [OpenBrace] = []
    var openEnvironments: [OpenEnvironment] = []
    var mismatches: [Mismatch] = []
    var strayEnds: [StrayEnd] = []
    var unclosedDollars: [Int] = []
    var hasBeginDocument = false
    /// `\end{document}` closed the document: nothing after it is analysed.
    var documentEnded = false
    /// The walk covered the whole source (or stopped at `\end{document}`).
    var reachedEnd = false

    // State at the stop position.
    fileprivate(set) var inlineMath = false          // `$...$` or `\(...\)`
    fileprivate(set) var displayMath = false         // `$$...$$` or `\[...\]`
    fileprivate(set) var mathEnvironmentDepth = 0
    fileprivate(set) var textGroupDepth = 0

    /// Math mode at the stop position (text groups such as `\text{..}` count as text).
    var isInMath: Bool {
        (inlineMath || displayMath || mathEnvironmentDepth > 0) && textGroupDepth == 0
    }
}

enum StructureWalker {
    private enum DefinitionShape: Equatable {
        case command, environment, documentCommand, documentEnvironment, plainDef
        /// Hook-style commands whose braced arguments are code to run later (`\AtEndEnvironment{x}{\end{center}}`).
        case hook(groups: Int)
    }

    private static let definitions: [String: DefinitionShape] = {
        var table: [String: DefinitionShape] = [:]
        for name in ["newcommand", "renewcommand", "providecommand", "DeclareRobustCommand",
                     "newrobustcmd", "renewrobustcmd", "providerobustcmd"] { table[name] = .command }
        for name in ["newenvironment", "renewenvironment"] { table[name] = .environment }
        for name in ["NewDocumentCommand", "RenewDocumentCommand", "ProvideDocumentCommand",
                     "DeclareDocumentCommand", "NewExpandableDocumentCommand"] { table[name] = .documentCommand }
        for name in ["NewDocumentEnvironment", "RenewDocumentEnvironment", "ProvideDocumentEnvironment",
                     "DeclareDocumentEnvironment"] { table[name] = .documentEnvironment }
        for name in ["def", "gdef", "edef", "xdef"] { table[name] = .plainDef }
        for name in ["AtBeginDocument", "AtEndDocument", "AtEndPreamble"] { table[name] = .hook(groups: 1) }
        for name in ["AtBeginEnvironment", "AtEndEnvironment", "BeforeBeginEnvironment", "AfterBeginEnvironment",
                     "BeforeEndEnvironment", "AfterEndEnvironment", "AddToHook", "NewEnviron", "RenewEnviron",
                     "csdef", "csgdef", "csedef", "gappto", "eappto", "appto", "preto"] {
            table[name] = .hook(groups: 2)
        }
        for name in ["apptocmd", "pretocmd", "patchcmd"] { table[name] = .hook(groups: 4) }
        return table
    }()

    /// Walks `src` up to (not including) `limit`; `nil` walks the whole source.
    static func walk(_ src: MaskedSource, upTo limit: Int? = nil) -> StructureWalk {
        let u = src.masked
        let n = u.count
        let stop = min(limit ?? n, n)
        var walk = StructureWalk()

        // 0 none, 1 `$`, 2 `$$`, 3 `\(`, 4 `\[`
        var mathMode = 0
        var mathOpen = 0
        var lastTextCommandEnd = -1
        var i = 0

        func popEnvironment() {
            guard let top = walk.openEnvironments.popLast() else { return }
            if LaTeXSyntax.mathEnvironments.contains(top.name) { walk.mathEnvironmentDepth -= 1 }
        }

        walkLoop: while i < stop {
            switch u[i] {
            case 123: // {
                var isText = false
                if lastTextCommandEnd >= 0 && lastTextCommandEnd <= i {
                    isText = true
                    var k = lastTextCommandEnd
                    while k < i { if !isHSpace(u[k]) { isText = false; break }; k += 1 }
                }
                lastTextCommandEnd = -1
                walk.openBraces.append(StructureWalk.OpenBrace(offset: i, isTextGroup: isText))
                if isText { walk.textGroupDepth += 1 }
                i += 1

            case 125: // }
                if let brace = walk.openBraces.popLast() {
                    if brace.isTextGroup { walk.textGroupDepth -= 1 }
                } else {
                    walk.strayClosingBraces.append(i)
                }
                i += 1

            case 36: // $
                if walk.mathEnvironmentDepth > 0 || mathMode == 3 || mathMode == 4 {
                    i += 1
                } else if mathMode == 0 {
                    if i + 1 < n && u[i + 1] == 36 {
                        mathMode = 2
                        i += 2
                    } else {
                        mathMode = 1
                        i += 1
                    }
                    mathOpen = i - (mathMode == 2 ? 2 : 1)
                } else if mathMode == 1 {
                    mathMode = 0
                    i += 1
                } else { // `$$`
                    if i + 1 < n && u[i + 1] == 36 {
                        mathMode = 0
                        i += 2
                    } else {
                        i += 1
                    }
                }

            case 10, 13:
                if src.isParagraphBreak(afterLineBreakAt: i) {
                    if mathMode == 1 { walk.unclosedDollars.append(mathOpen) }
                    mathMode = 0
                }
                if u[i] == 13 && i + 1 < n && u[i + 1] == 10 { i += 1 }
                i += 1

            case 92: // backslash
                guard i + 1 < n else { i += 1; continue walkLoop }
                let d = u[i + 1]
                guard isCommandLetter(d) else {
                    if isLineBreak(d) { i += 1; continue walkLoop }
                    if d == 40 && mathMode == 0 && walk.mathEnvironmentDepth == 0 { mathMode = 3 }
                    else if d == 41 && mathMode == 3 { mathMode = 0 }
                    else if d == 91 && mathMode == 0 && walk.mathEnvironmentDepth == 0 { mathMode = 4 }
                    else if d == 93 && mathMode == 4 { mathMode = 0 }
                    i += (isHighSurrogate(d) && i + 2 < n && isLowSurrogate(u[i + 2])) ? 3 : 2
                    continue walkLoop
                }
                var j = i + 2
                while j < n && isCommandLetter(u[j]) { j += 1 }
                let name = String(decoding: u[(i + 1)..<j], as: UTF16.self)

                if name == "begin" || name == "end" {
                    var k = j
                    while k < n && isHSpace(u[k]) { k += 1 }
                    // A name cut off by the stop position is not a complete command.
                    guard let parsed = LaTeXSyntax.environmentName(u, open: k), parsed.end <= stop else {
                        i = j
                        continue walkLoop
                    }
                    let envName = utf16String(u, parsed.name)
                    if name == "begin" {
                        if envName == "document" && walk.openEnvironments.isEmpty { walk.hasBeginDocument = true }
                        walk.openEnvironments.append(StructureWalk.OpenEnvironment(name: envName, offset: i, end: parsed.end))
                        if LaTeXSyntax.mathEnvironments.contains(envName) { walk.mathEnvironmentDepth += 1 }
                    } else if let top = walk.openEnvironments.last {
                        if top.name == envName {
                            popEnvironment()
                        } else if top.name == "document" {
                            // `\end{x}` with nothing but the document open: a stray end. Closing the document
                            // here would turn the real `\end{document}` into a second, misleading error.
                            walk.strayEnds.append(StructureWalk.StrayEnd(name: envName, offset: i, end: parsed.end))
                        } else {
                            walk.mismatches.append(StructureWalk.Mismatch(open: top, closeName: envName, offset: i, end: parsed.end))
                            if let position = walk.openEnvironments.lastIndex(where: { $0.name == envName }) {
                                while walk.openEnvironments.count > position { popEnvironment() }
                            } else {
                                popEnvironment()
                            }
                        }
                        if envName == "document" && walk.hasBeginDocument && walk.openEnvironments.isEmpty {
                            walk.documentEnded = true
                            i = parsed.end
                            break walkLoop
                        }
                    } else {
                        walk.strayEnds.append(StructureWalk.StrayEnd(name: envName, offset: i, end: parsed.end))
                    }
                    i = parsed.end
                    continue walkLoop
                }

                if let shape = definitions[name], let end = definitionEnd(u, shape: shape, from: j), end <= stop {
                    i = end
                    continue walkLoop
                }
                if LaTeXSyntax.textModeCommands.contains(name) { lastTextCommandEnd = j }
                i = j

            default:
                i += 1
            }
        }

        walk.inlineMath = mathMode == 1 || mathMode == 3
        walk.displayMath = mathMode == 2 || mathMode == 4
        walk.reachedEnd = walk.documentEnded || stop >= n
        if walk.reachedEnd && mathMode == 1 { walk.unclosedDollars.append(mathOpen) }
        return walk
    }

    /// End offset of a complete definition (name, parameters and all bodies), or nil when it is malformed.
    private static func definitionEnd(_ u: [UInt16], shape: DefinitionShape, from j: Int) -> Int? {
        var p = TeXArguments.skipWhitespace(u, j)
        switch shape {
        case .hook(let groups):
            // Optional `[…]`, an optional bare control sequence (`\appto\cmd{…}`), then up to `groups` braced groups.
            var end = p
            var found = 0
            var guardCount = 0
            while found < groups, guardCount < 8 {
                guardCount += 1
                end = TeXArguments.skipWhitespace(u, end)
                if end < u.count, u[end] == 91, let group = TeXArguments.bracketed(u, open: end, limit: 400) {
                    end = group.end
                } else if end < u.count, u[end] == 92, found == 0, let cs = TeXArguments.controlSequence(u, at: end) {
                    end = cs.end
                } else if end < u.count, u[end] == 123, let group = TeXArguments.braced(u, open: end) {
                    end = group.end
                    found += 1
                } else {
                    break
                }
            }
            return found > 0 ? end : nil

        case .plainDef:
            guard p < u.count, u[p] == 92, let cs = TeXArguments.controlSequence(u, at: p) else { return nil }
            var k = cs.end
            let stop = min(u.count, k + 120)
            while k < stop && u[k] != 123 {
                if isLineBreak(u[k]) && k + 1 < u.count && isLineBreak(u[k + 1]) { return nil }
                k += 1
            }
            guard k < stop, let body = TeXArguments.braced(u, open: k) else { return nil }
            return body.end

        case .command, .environment, .documentCommand, .documentEnvironment:
            if p < u.count && u[p] == 42 { p = TeXArguments.skipWhitespace(u, p + 1) }
            // Name: {\foo}, \foo or {name}
            if p < u.count, u[p] == 123 {
                guard let name = TeXArguments.braced(u, open: p, limit: 300) else { return nil }
                p = name.end
            } else if shape == .command || shape == .documentCommand, p < u.count, u[p] == 92,
                      let cs = TeXArguments.controlSequence(u, at: p) {
                p = cs.end
            } else {
                return nil
            }
            p = TeXArguments.skipWhitespace(u, p)
            var bodies = (shape == .environment || shape == .documentEnvironment) ? 2 : 1
            if shape == .documentCommand || shape == .documentEnvironment {
                guard p < u.count, u[p] == 123, let spec = TeXArguments.braced(u, open: p, limit: 400) else { return nil }
                p = TeXArguments.skipWhitespace(u, spec.end)
            } else {
                var optionals = 0
                while optionals < 2, p < u.count, u[p] == 91, let group = TeXArguments.bracketed(u, open: p, limit: 400) {
                    p = TeXArguments.skipWhitespace(u, group.end)
                    optionals += 1
                }
            }
            var end = p
            while bodies > 0 {
                guard end < u.count, u[end] == 123, let body = TeXArguments.braced(u, open: end) else { return nil }
                end = TeXArguments.skipWhitespace(u, body.end)
                bodies -= 1
                if bodies > 0 { continue }
                return body.end
            }
            return nil
        }
    }
}

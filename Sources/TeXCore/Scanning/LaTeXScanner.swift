import Foundation

/// Lightweight structural scanning of a single LaTeX source (no file I/O).
/// All functions ignore commented-out text (`%` to end of line, but not `\%`)
/// and the bodies of verbatim-like environments.
public enum LaTeXScanner {
    /// Magic comments in the leading comment block / first 20 lines.
    ///
    /// Recognized (keys are case-insensitive, `!TEX`, `!TeX` and `!BIB` accepted):
    /// `% !TEX root = path`, `% !TEX program = x` (also `TS-program`), `% !TEX spellcheck = x`,
    /// `% !BIB program = x` and `% !TEX bib = x`. The first occurrence of a key wins.
    public static func magicComments(in text: String) -> MagicComments {
        var result = MagicComments()
        let lines = text.split(maxSplits: 20, omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for rawLine in lines.prefix(20) {
            var line = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            guard line.first == "%" else { continue }
            line = line.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            guard line.first == "!" else { continue }
            line = line.dropFirst()
            let domain = line.prefix(while: { $0.isLetter }).lowercased()
            guard domain == "tex" || domain == "bib" else { continue }
            let rest = line.dropFirst(domain.count)
            guard let equals = rest.firstIndex(of: "=") else { continue }
            let key = rest[rest.startIndex..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = rest[rest.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if domain == "bib" {
                if (key == "program" || key == "ts-program") && result.bibProgram == nil { result.bibProgram = value }
                continue
            }
            switch key {
            case "root", "ts-root": if result.root == nil { result.root = value }
            case "program", "ts-program": if result.program == nil { result.program = value }
            case "spellcheck", "ts-spellcheck": if result.spellcheck == nil { result.spellcheck = value }
            case "bib", "bibtex", "ts-bib": if result.bibProgram == nil { result.bibProgram = value }
            default: break
            }
        }
        return result
    }

    /// True when the text is a root document: an uncommented `\documentclass` (or `\begin{document}`).
    public static func isRootDocument(_ text: String) -> Bool {
        scan(MaskedSource(text), fileURL: placeholderURL, parts: .rootInfo).isRoot
    }

    /// Every file reference in source order.
    public static func includes(in text: String) -> [IncludeReference] {
        scan(MaskedSource(text), fileURL: placeholderURL, parts: .includes).includes
    }

    /// Sectioning commands (incl. starred), beamer frames and labels, in source order.
    public static func outlineEntries(in text: String, fileURL: URL) -> [OutlineEntry] {
        scan(MaskedSource(text), fileURL: fileURL, parts: .outline).outline
    }

    /// `\label{...}` definitions with a short context.
    ///
    /// The context is the innermost enclosing environment (`equation`, `figure`, `theorem` ...; layout
    /// wrappers such as `document`, `center` or `minipage` are skipped) or, outside environments, the
    /// title of the nearest preceding heading.
    public static func labels(in text: String, fileURL: URL) -> [LabelDefinition] {
        scan(MaskedSource(text), fileURL: fileURL, parts: .labels).labels
    }

    /// User-defined commands as completion items (insertText has one placeholder per argument).
    public static func customCommands(in text: String) -> [CompletionItem] {
        scan(MaskedSource(text), fileURL: placeholderURL, parts: .definitions).customCommands
    }

    /// User-defined environment names (\newenvironment, \newtheorem, \NewDocumentEnvironment, \newtcolorbox...).
    public static func customEnvironments(in text: String) -> [String] {
        scan(MaskedSource(text), fileURL: placeholderURL, parts: .definitions).customEnvironments
    }

    // MARK: - Internal single-pass scan

    static let placeholderURL = URL(fileURLWithPath: "/")

    struct ScanParts: OptionSet {
        let rawValue: Int
        static let rootInfo = ScanParts(rawValue: 1)
        static let includes = ScanParts(rawValue: 2)
        static let outline = ScanParts(rawValue: 4)
        static let labels = ScanParts(rawValue: 8)
        static let definitions = ScanParts(rawValue: 16)
        static let all: ScanParts = [.rootInfo, .includes, .outline, .labels, .definitions]
    }

    /// Everything one pass over a file yields.
    struct FileScan {
        var isRoot = false
        /// Name and `[options]` of `\documentclass`.
        var documentClass: String?
        var documentClassOptions: String?
        var includes: [IncludeReference] = []
        /// Headings, frames and labels in source order.
        var outline: [OutlineEntry] = []
        var labels: [LabelDefinition] = []
        var customCommands: [CompletionItem] = []
        var customEnvironments: [String] = []
    }

    private enum Action {
        case section(OutlineEntry.Kind)
        case label, frameTitle, begin, end, documentClass
        case inputLike(IncludeReference.Kind)
        case importLike(IncludeReference.Kind)
        case bibliography, addBibResource, includeGraphics, includePDF, listing, inputMinted, usePackage
        case newCommand, plainDef, mathOperator, documentCommand, pairedDelimiter, pairedDelimiterX
        case environment, theoremList
    }

    private static let actions: [String: Action] = {
        var table: [String: Action] = [:]
        for (name, kind) in LaTeXSyntax.sectioningKinds { table[name] = .section(kind) }
        table["label"] = .label
        table["frametitle"] = .frameTitle
        table["begin"] = .begin
        table["end"] = .end
        table["documentclass"] = .documentClass
        table["input"] = .inputLike(.input)
        table["include"] = .inputLike(.include)
        table["subfile"] = .inputLike(.subfile)
        table["import"] = .importLike(.importFile)
        table["subimport"] = .importLike(.subimport)
        table["bibliography"] = .bibliography
        table["addbibresource"] = .addBibResource
        table["includegraphics"] = .includeGraphics
        table["includepdf"] = .includePDF
        table["lstinputlisting"] = .listing
        table["inputminted"] = .inputMinted
        table["usepackage"] = .usePackage
        table["RequirePackage"] = .usePackage
        for name in ["newcommand", "renewcommand", "providecommand", "DeclareRobustCommand",
                     "newrobustcmd", "renewrobustcmd", "providerobustcmd"] { table[name] = .newCommand }
        for name in ["def", "gdef", "edef", "xdef"] { table[name] = .plainDef }
        table["DeclareMathOperator"] = .mathOperator
        for name in ["NewDocumentCommand", "RenewDocumentCommand", "ProvideDocumentCommand",
                     "DeclareDocumentCommand", "NewExpandableDocumentCommand",
                     "RenewExpandableDocumentCommand", "ProvideExpandableDocumentCommand",
                     "DeclareExpandableDocumentCommand"] { table[name] = .documentCommand }
        table["DeclarePairedDelimiter"] = .pairedDelimiter
        table["DeclarePairedDelimiterX"] = .pairedDelimiterX
        table["DeclarePairedDelimiterXPP"] = .pairedDelimiterX
        for name in ["newenvironment", "renewenvironment", "NewDocumentEnvironment", "RenewDocumentEnvironment",
                     "ProvideDocumentEnvironment", "DeclareDocumentEnvironment", "newtheorem", "newtcolorbox",
                     "renewtcolorbox", "newtcbtheorem", "newmdtheoremenv", "newmdenv", "NewEnviron",
                     "NewTColorBox", "DeclareTColorBox"] { table[name] = .environment }
        table["declaretheorem"] = .theoremList
        return table
    }()

    /// Environments that wrap content without being a useful label context.
    private static let layoutEnvironments: Set<String> = [
        "document", "center", "flushleft", "flushright", "minipage", "adjustbox", "spacing", "singlespace",
        "onehalfspace", "doublespace", "frame", "multicols", "multicols*", "group", "small", "footnotesize",
        "scriptsize", "tiny", "large", "Large", "LARGE", "huge", "Huge", "tcolorbox", "framed", "mdframed",
    ]

    /// One pass over an already masked source.
    static func scan(_ src: MaskedSource, fileURL: URL, parts: ScanParts) -> FileScan {
        var result = FileScan()
        let u = src.masked
        let n = u.count
        var envStack: [String] = []
        var openFrames: [Int] = []          // indices into result.outline of open beamer frames (-1: untracked)
        var droppedFrames = Set<Int>()
        var lastHeading: String?
        var seenCommands = Set<String>()
        var seenEnvironments = Set<String>()
        let wantsOutline = parts.contains(.outline)
        let wantsHeadings = wantsOutline || parts.contains(.labels)

        func addReference(_ kind: IncludeReference.Kind, _ range: Range<Int>, directory: String? = nil) {
            let r = TeXArguments.trimmed(u, range)
            guard !r.isEmpty else { return }
            let argument = utf16String(u, r)
            if argument.contains("#") || argument.contains("\\") { return }
            result.includes.append(IncludeReference(kind: kind, argument: argument, directory: directory,
                                                    line: src.line(at: r.lowerBound), range: nsRange(r)))
        }

        func addList(_ kind: IncludeReference.Kind, _ range: Range<Int>) {
            for item in TeXArguments.splitList(u, range) { addReference(kind, item) }
        }

        func skipOverlay(_ from: Int) -> Int {
            var p = from
            while p < n && isHSpace(u[p]) { p += 1 }
            if p < n, u[p] == 60 {
                var q = p + 1
                while q < n && u[q] != 62 && !isLineBreak(u[q]) { q += 1 }
                if q < n && u[q] == 62 { p = q + 1 }
            }
            return p
        }

        var i = 0
        while i < n {
            guard u[i] == 92 else { i += 1; continue }
            guard i + 1 < n else { break }
            let d = u[i + 1]
            guard isCommandLetter(d) else {
                if isLineBreak(d) { i += 1 }
                else if isHighSurrogate(d) && i + 2 < n && isLowSurrogate(u[i + 2]) { i += 3 }
                else { i += 2 }
                continue
            }
            var j = i + 2
            while j < n && isCommandLetter(u[j]) { j += 1 }
            let name = String(decoding: u[(i + 1)..<j], as: UTF16.self)
            guard let action = actions[name] else { i = j; continue }
            let commandStart = i
            i = j
            switch action {
            // MARK: Sectioning and labels
            case .section(let kind):
                guard wantsHeadings else { break }
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1),
                      let titleRange = call.mandatory.first else { break }
                let title = cleanTitle(src, titleRange)
                lastHeading = title
                if wantsOutline {
                    result.outline.append(OutlineEntry(kind: kind, title: title, isStarred: call.isStarred, fileURL: fileURL,
                                                       line: src.line(at: commandStart), offset: commandStart))
                }

            case .frameTitle:
                guard wantsHeadings else { break }
                var p = skipOverlay(j)
                if p < n, u[p] == 91, let g = TeXArguments.bracketed(u, open: p) { p = TeXArguments.skipWhitespace(u, g.end) }
                guard p < n, u[p] == 123, let g = TeXArguments.braced(u, open: p) else { break }
                let title = cleanTitle(src, g.content)
                lastHeading = title
                if let frameIndex = openFrames.last, frameIndex >= 0 {
                    if result.outline[frameIndex].title.isEmpty { result.outline[frameIndex].title = title }
                } else if openFrames.isEmpty && wantsOutline {
                    result.outline.append(OutlineEntry(kind: .frame, title: title, fileURL: fileURL,
                                                       line: src.line(at: commandStart), offset: commandStart))
                }

            case .label:
                guard wantsHeadings else { break }
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1, allowStar: false),
                      let keyRange = call.mandatory.first else { break }
                let r = TeXArguments.trimmed(u, keyRange)
                guard !r.isEmpty else { break }
                let key = utf16String(u, r)
                if key.contains("#") || key.contains("\\") || key.contains("{") { break }
                let line = src.line(at: commandStart)
                let context = envStack.last(where: { !layoutEnvironments.contains($0) }) ?? lastHeading
                if parts.contains(.labels) {
                    result.labels.append(LabelDefinition(key: key, fileURL: fileURL, line: line,
                                                         context: (context?.isEmpty ?? true) ? nil : context))
                }
                if wantsOutline {
                    result.outline.append(OutlineEntry(kind: .label, title: key, fileURL: fileURL, line: line, offset: commandStart))
                }

            // MARK: Environments
            case .begin:
                var k = j
                while k < n && isHSpace(u[k]) { k += 1 }
                guard let parsed = LaTeXSyntax.environmentName(u, open: k) else { break }
                let envName = utf16String(u, parsed.name)
                if envName == "document" { result.isRoot = true }
                envStack.append(envName)
                i = parsed.end
                if envName == "frame" {
                    if wantsOutline {
                        var p = skipOverlay(parsed.end)
                        if p < n, u[p] == 91, let g = TeXArguments.bracketed(u, open: p) { p = g.end }
                        while p < n && isHSpace(u[p]) { p += 1 }
                        var title = ""
                        if p < n, u[p] == 123, let g = TeXArguments.braced(u, open: p) { title = cleanTitle(src, g.content) }
                        if !title.isEmpty { lastHeading = title }
                        result.outline.append(OutlineEntry(kind: .frame, title: title, fileURL: fileURL,
                                                           line: src.line(at: commandStart), offset: commandStart))
                        openFrames.append(result.outline.count - 1)
                    } else {
                        openFrames.append(-1)
                    }
                }

            case .end:
                var k = j
                while k < n && isHSpace(u[k]) { k += 1 }
                guard let parsed = LaTeXSyntax.environmentName(u, open: k) else { break }
                let envName = utf16String(u, parsed.name)
                if let position = envStack.lastIndex(of: envName) { envStack.removeSubrange(position...) }
                i = parsed.end
                if envName == "frame", let frameIndex = openFrames.popLast(), frameIndex >= 0,
                   result.outline[frameIndex].title.isEmpty {
                    droppedFrames.insert(frameIndex)
                }

            case .documentClass:
                result.isRoot = true
                guard let call = TeXArguments.parse(u, from: j, mandatoryCount: 1, allowStar: false),
                      let cls = call.mandatory.first else { break }
                result.documentClass = utf16String(u, TeXArguments.trimmed(u, cls))
                if let options = call.optionals.first {
                    result.documentClassOptions = utf16String(u, TeXArguments.trimmed(u, options))
                }
                if parts.contains(.includes) { addReference(.documentclass, cls) }

            // MARK: Includes
            case .inputLike(let kind):
                guard parts.contains(.includes) else { break }
                var p = TeXArguments.skipWhitespace(u, j)
                if p < n, u[p] == 123 {
                    if let g = TeXArguments.braced(u, open: p) { addReference(kind, g.content) }
                } else if kind == .input && p > j && p < n && u[p] != 92 && u[p] != 37 && u[p] != 125 {
                    // TeX primitive form: \input file.tex
                    let start = p
                    while p < n && !isTeXWhitespace(u[p]) && u[p] != 92 && u[p] != 123 && u[p] != 125 && u[p] != 37 { p += 1 }
                    addReference(.input, start..<p)
                }

            case .importLike(let kind):
                guard parts.contains(.includes),
                      let call = TeXArguments.parse(u, from: j, mandatoryCount: 2), call.mandatory.count == 2 else { break }
                let directory = utf16String(u, TeXArguments.trimmed(u, call.mandatory[0]))
                addReference(kind, call.mandatory[1], directory: directory)

            case .bibliography:
                guard parts.contains(.includes), let call = TeXArguments.parse(u, from: j, mandatoryCount: 1, allowStar: false),
                      let list = call.mandatory.first else { break }
                addList(.bibliography, list)

            case .usePackage:
                guard parts.contains(.includes), let call = TeXArguments.parse(u, from: j, mandatoryCount: 1, allowStar: false),
                      let list = call.mandatory.first else { break }
                addList(.usepackage, list)

            case .addBibResource, .includeGraphics, .includePDF, .listing:
                guard parts.contains(.includes), let call = TeXArguments.parse(u, from: j, mandatoryCount: 1),
                      let file = call.mandatory.first else { break }
                let kind: IncludeReference.Kind
                switch action {
                case .addBibResource: kind = .addbibresource
                case .includeGraphics: kind = .includegraphics
                case .includePDF: kind = .includepdf
                default: kind = .lstinputlisting
                }
                addReference(kind, file)

            case .inputMinted:
                guard parts.contains(.includes), let call = TeXArguments.parse(u, from: j, mandatoryCount: 2),
                      call.mandatory.count == 2 else { break }
                addReference(.inputminted, call.mandatory[1])

            // MARK: Definitions
            case .newCommand, .plainDef, .mathOperator, .documentCommand, .pairedDelimiter, .pairedDelimiterX:
                guard parts.contains(.definitions) else { break }
                let item: CompletionItem?
                switch action {
                case .newCommand: item = ScannerDefinitions.newCommand(u, from: j)
                case .plainDef: item = ScannerDefinitions.plainDef(u, from: j)
                case .mathOperator: item = ScannerDefinitions.mathOperator(u, from: j)
                case .documentCommand: item = ScannerDefinitions.documentCommand(u, from: j)
                case .pairedDelimiter: item = ScannerDefinitions.pairedDelimiter(u, from: j, hasCount: false)
                default: item = ScannerDefinitions.pairedDelimiter(u, from: j, hasCount: true)
                }
                if let item, seenCommands.insert(item.label).inserted { result.customCommands.append(item) }

            case .environment, .theoremList:
                guard parts.contains(.definitions) else { break }
                var isList = false
                if case .theoremList = action { isList = true }
                for envName in ScannerDefinitions.environmentNames(u, from: j, isList: isList) {
                    if seenEnvironments.insert(envName).inserted { result.customEnvironments.append(envName) }
                }
            }
        }

        if !droppedFrames.isEmpty {
            result.outline = result.outline.enumerated().filter { !droppedFrames.contains($0.offset) }.map { $0.element }
        }
        return result
    }

    /// Heading title: comments removed, `\label{...}` removed, whitespace collapsed.
    static func cleanTitle(_ src: MaskedSource, _ range: Range<Int>) -> String {
        let raw = src.textWithoutComments(range)
        var out: [UInt16] = []
        out.reserveCapacity(raw.count)
        let label = Array("\\label".utf16)
        var i = 0
        var pendingSpace = false
        while i < raw.count {
            let c = raw[i]
            if c == 92, i + label.count <= raw.count, Array(raw[i..<(i + label.count)]) == label,
               i + label.count == raw.count || !isCommandLetter(raw[i + label.count]) {
                var p = i + label.count
                while p < raw.count && isTeXWhitespace(raw[p]) { p += 1 }
                if p < raw.count, raw[p] == 123, let g = TeXArguments.braced(raw, open: p) {
                    i = g.end
                    continue
                }
            }
            if isTeXWhitespace(c) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(32); pendingSpace = false }
                out.append(c)
            }
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }
}

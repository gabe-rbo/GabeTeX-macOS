import Foundation

/// The reading-order walk behind `DocumentStatistics`: files are visited depth-first from the root, at the
/// position of the `\input`-like command that includes them, exactly as `ProjectIndex.build` does for the
/// outline. Every heading the scanner reports opens a section; words and formulas are added to the section
/// that is open. The text rules live in `StatisticsEngine+Text.swift` and `+Environments.swift`.
final class StatisticsEngine {
    struct FileData {
        var source: MaskedSource
        /// Headings and frames (no labels), in file order — the entries of the outline.
        var entries: [OutlineEntry]
        /// Includes that the outline follows (`\input`, `\include`, `\subfile`, `\import`, `\subimport`).
        var includes: [IncludeReference]
        /// Resolved .tex file of each include (nil when it does not resolve to a .tex file).
        var targets: [URL?]
        var hasDocumentClass: Bool
        var hasBeginDocument: Bool
    }

    struct Accumulator {
        var entry: OutlineEntry?
        var counts = StatisticsCounts()
        var headingEndLine: Int
    }

    // MARK: Inputs

    let root: URL
    let read: (URL) -> String?
    let fileExists: (URL) -> Bool
    let isFragment: Bool

    // MARK: Files

    var cache: [URL: FileData] = [:]
    var visited = Set<URL>()
    var order: [URL] = []

    // MARK: The file being walked

    var fileURL: URL
    var source = MaskedSource("")
    var u: [UInt16] = []
    var entries: [OutlineEntry] = []
    var entryIndex = 0
    var includes: [IncludeReference] = []
    var includeTargets: [URL?] = []
    var includeIndex = 0
    /// Included files that carry their own `\documentclass` (subfiles, standalone figures) contribute only
    /// what lies between their `\begin{document}` and `\end{document}`.
    var isEnvelope = false
    /// Text of the current file is not part of the document right now (an envelope's own preamble).
    var fileSuppressed = false
    var depth = 0

    // MARK: Counting state

    var accumulators: [Accumulator] = []
    var current = 0
    /// Before `\begin{document}`: nothing counts.
    var inPreamble = false
    /// After `\end{document}`: nothing counts.
    var documentEnded = false
    /// > 0 while walking code that is not typeset (includes found inside a skipped definition or picture).
    var suppressed = 0
    /// > 0 inside a float (figure, table …): its contents are not prose. Only captions count there, and they
    /// lift this to 0 while they are read.
    var excluded = 0
    var inHeading = false
    var word = WordState()
    var titledEnvironments = StatisticsRules.defaultTitledEnvironments

    init(root: URL, read: @escaping (URL) -> String?, fileExists: @escaping (URL) -> Bool, isFragment: Bool = false) {
        self.root = root
        self.read = read
        self.fileExists = fileExists
        self.isFragment = isFragment
        self.fileURL = root
    }

    var isCounting: Bool { !inPreamble && !documentEnded && suppressed == 0 && excluded == 0 && !fileSuppressed }

    // MARK: Run

    func run() -> DocumentStatistics {
        accumulators = [Accumulator(entry: nil, headingEndLine: 1)]
        current = 0
        // A document counts from `\begin{document}` on. When no file reachable from the root has one (a
        // fragment, a document still being started), everything counts.
        inPreamble = isFragment ? false : anyFileHasBeginDocument()
        walkFile(root)
        return assemble()
    }

    /// Reads, masks and scans a file once.
    func load(_ url: URL) -> FileData? {
        if let cached = cache[url] { return cached }
        let text = read(url) ?? ""
        let masked = MaskedSource(text)
        let scan = LaTeXScanner.scan(masked, fileURL: url, parts: [.includes, .outline])
        var references: [IncludeReference] = []
        var targets: [URL?] = []
        for reference in scan.includes {
            switch reference.kind {
            case .input, .include, .subfile, .importFile, .subimport: break
            default: continue
            }
            references.append(reference)
            let target = ProjectIndex.resolve(reference, includingFile: url, rootFile: root, fileExists: fileExists)
            targets.append(target.flatMap { $0.pathExtension.lowercased() == "tex" ? $0 : nil })
        }
        let data = FileData(
            source: masked,
            entries: scan.outline.filter { $0.kind != .label },
            includes: references,
            targets: targets,
            hasDocumentClass: scan.documentClass != nil,
            hasBeginDocument: Self.containsBeginDocument(masked.masked)
        )
        cache[url] = data
        return data
    }

    private func anyFileHasBeginDocument() -> Bool {
        var seen: Set<URL> = [root]
        var stack: [URL] = [root]
        while let url = stack.popLast() {
            guard let data = load(url) else { continue }
            if data.hasBeginDocument { return true }
            for case let target? in data.targets where seen.insert(target).inserted { stack.append(target) }
        }
        return false
    }

    /// True when the masked source holds `\begin{document}`.
    static func containsBeginDocument(_ u: [UInt16]) -> Bool {
        let n = u.count
        var i = 0
        while i + 6 < n {
            guard u[i] == 92 else { i += 1; continue }
            // \begin
            guard u[i + 1] == 98, u[i + 2] == 101, u[i + 3] == 103, u[i + 4] == 105, u[i + 5] == 110 else { i += 1; continue }
            var k = i + 6
            if k < n, isCommandLetter(u[k]) { i = k; continue }
            while k < n && isHSpace(u[k]) { k += 1 }
            if let parsed = LaTeXSyntax.environmentName(u, open: k), utf16String(u, parsed.name) == "document" { return true }
            i = k
        }
        return false
    }

    // MARK: Walking a file

    func walkFile(_ url: URL) {
        guard let data = load(url) else { return }
        visited.insert(url)
        order.append(url)

        let saved = (fileURL, source, u, entries, entryIndex, includes, includeTargets, includeIndex, isEnvelope, fileSuppressed)
        fileURL = url
        source = data.source
        u = data.source.masked
        entries = data.entries
        entryIndex = 0
        includes = data.includes
        includeTargets = data.targets
        includeIndex = 0
        isEnvelope = depth > 0 && data.hasDocumentClass && data.hasBeginDocument && !inPreamble
        fileSuppressed = isEnvelope
        depth += 1

        walk(0, u.count)
        sweep(upTo: Int.max)

        depth -= 1
        (fileURL, source, u, entries, entryIndex, includes, includeTargets, includeIndex, isEnvelope, fileSuppressed) = saved
    }

    /// Opens the sections whose heading lies at or before `position` and walks (uncounted) the includes that
    /// lie before it and were skipped over — an `\input` inside a definition or a picture still belongs to the
    /// outline, so its headings must exist here too.
    func sweep(upTo position: Int) {
        while true {
            let hasEntry = entryIndex < entries.count
            let hasInclude = includeIndex < includes.count
            let nextEntry = hasEntry ? entries[entryIndex].offset : Int.max
            let nextInclude = hasInclude ? includes[includeIndex].range.location : Int.max
            if hasEntry, nextEntry <= position, nextEntry <= nextInclude {
                // A heading the walk reaches as a command opens its section. One it jumped over (inside a
                // definition, a picture …) is not typeset: it exists for the outline's sake but takes no text.
                openSection(entries[entryIndex], makeCurrent: nextEntry >= position)
                entryIndex += 1
            } else if hasInclude, nextInclude < position, nextInclude < nextEntry {
                let target = includeTargets[includeIndex]
                includeIndex += 1
                let section = current
                descend(into: target, counted: false)
                current = section
            } else {
                break
            }
        }
    }

    func descend(into target: URL?, counted: Bool) {
        guard let target, !visited.contains(target) else { return }
        if !counted { suppressed += 1 }
        walkFile(target)
        if !counted { suppressed -= 1 }
    }

    func openSection(_ entry: OutlineEntry, makeCurrent: Bool) {
        word.separator()
        accumulators.append(Accumulator(entry: entry, headingEndLine: entry.line))
        if makeCurrent { current = accumulators.count - 1 }
    }

    // MARK: Counting

    @inline(__always)
    func countWord() {
        guard isCounting else { return }
        if inHeading {
            accumulators[current].counts.headingWords += 1
        } else {
            accumulators[current].counts.textWords += 1
        }
    }

    func countMath(display: Bool) {
        guard isCounting else { return }
        if display {
            accumulators[current].counts.displayMath += 1
        } else {
            accumulators[current].counts.inlineMath += 1
        }
    }

    /// Records where the heading that opened the current section ends.
    func noteHeadingEnd(commandStart: Int, endOffset: Int) {
        guard let entry = accumulators[current].entry, entry.offset == commandStart, entry.fileURL == fileURL else { return }
        accumulators[current].headingEndLine = source.line(at: max(commandStart, endOffset - 1))
    }

    func beginDocument() {
        if fileSuppressed { fileSuppressed = false } else { inPreamble = false }
    }

    func endDocument() {
        if isEnvelope { fileSuppressed = true } else { documentEnded = true }
    }

    // MARK: Result

    private func assemble() -> DocumentStatistics {
        let front = SectionStatistics(frontMatterIn: root, own: accumulators[0].counts)
        var sections: [SectionStatistics] = []
        var occurrences: [String: Int] = [:]
        for accumulator in accumulators.dropFirst() {
            guard let entry = accumulator.entry else { continue }
            let key = "\(entry.fileURL.path)#\(entry.kind.rawValue)#\(entry.title)"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            sections.append(SectionStatistics(entry: entry, headingEndLine: accumulator.headingEndLine,
                                              own: accumulator.counts, occurrence: occurrence))
        }

        // A section's subtree runs up to the next heading of the same or a shallower level.
        var prefix = [StatisticsCounts](repeating: .zero, count: sections.count + 1)
        for (position, section) in sections.enumerated() { prefix[position + 1] = prefix[position] + section.own }
        var next = [Int](repeating: sections.count, count: sections.count)
        var stack: [Int] = []
        for position in stride(from: sections.count - 1, through: 0, by: -1) {
            while let top = stack.last, sections[top].level > sections[position].level { stack.removeLast() }
            next[position] = stack.last ?? sections.count
            stack.append(position)
        }
        for position in sections.indices {
            sections[position].subtree = prefix[next[position]] - prefix[position]
        }

        return DocumentStatistics(rootFile: root, frontMatter: front, sections: sections,
                                  totals: front.own + prefix[sections.count], files: order)
    }
}

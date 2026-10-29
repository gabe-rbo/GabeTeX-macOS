import Foundation

/// Cross-file view of a LaTeX project, built from a root document by following includes.
/// Pure: all file contents come from the `read` closure (the app passes unsaved buffer text when available).
public struct ProjectIndex: Hashable, Sendable {
    public var rootFile: URL
    /// .tex files reachable from the root, in document order (depth-first, root first). Cycles are ignored.
    public var files: [URL]
    /// Parent file → directly included .tex files.
    public var includeGraph: [URL: [URL]]
    /// Document outline across all files (headings nested by level; labels as leaves under the nearest heading).
    public var outline: [OutlineNode]
    public var labels: [LabelDefinition]
    public var bibFiles: [URL]
    public var bibEntries: [BibEntry]
    public var customCommands: [CompletionItem]
    public var customEnvironments: [String]
    /// Magic comments of the root file.
    public var magicComments: MagicComments

    public init(rootFile: URL) {
        self.rootFile = rootFile
        self.files = [rootFile]
        self.includeGraph = [:]
        self.outline = []
        self.labels = []
        self.bibFiles = []
        self.bibEntries = []
        self.customCommands = []
        self.customEnvironments = []
        self.magicComments = MagicComments()
    }

    /// Symbols for completion. `projectFiles` = all files under the project directory (relative to the root file's dir).
    public func symbols(projectFiles: [String]) -> ProjectSymbols {
        ProjectSymbols(
            labels: labels,
            bibEntries: bibEntries,
            customCommands: customCommands,
            customEnvironments: customEnvironments,
            projectFiles: projectFiles
        )
    }

    // MARK: - Resolution

    private static let imageExtensions = [".pdf", ".png", ".jpg", ".jpeg", ".eps"]

    /// Resolves a reference found in `includingFile` to an existing file URL, applying TeX's rules
    /// (see ARCHITECTURE.md §TeXCore). `fileExists` lets callers test against buffers + disk.
    ///
    /// `fileExists` should answer true for *regular files only*: `\input{chapter1}` tries `chapter1`
    /// before `chapter1.tex`, so a directory with the same name would otherwise win.
    public static func resolve(
        _ reference: IncludeReference,
        includingFile: URL,
        rootFile: URL,
        fileExists: (URL) -> Bool
    ) -> URL? {
        let rootDirectory = rootFile.deletingLastPathComponent()
        let includingDirectory = includingFile.deletingLastPathComponent()
        let argument = reference.argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return nil }

        func url(_ path: String, relativeTo base: URL) -> URL {
            if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
            return base.appendingPathComponent(path).standardizedFileURL
        }

        var base: URL
        var path = argument
        switch reference.kind {
        case .subfile:
            base = includingDirectory
        case .subimport:
            base = includingDirectory
            if let directory = reference.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
                base = url(directory, relativeTo: includingDirectory)
            }
        case .importFile:
            base = rootDirectory
            if let directory = reference.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
                base = url(directory, relativeTo: rootDirectory)
            }
        default:
            base = rootDirectory
        }
        if path.hasPrefix("./") && path.count > 2 { path = String(path.dropFirst(2)) }

        var candidates: [String]
        switch reference.kind {
        case .input, .subfile, .importFile, .subimport:
            candidates = [path, path + ".tex"]
        case .include:
            candidates = [path + ".tex"]
            if path.hasSuffix(".tex") { candidates.append(path) }
        case .bibliography:
            candidates = [path + ".bib"]
            if path.hasSuffix(".bib") { candidates.insert(path, at: 0) }
        case .addbibresource, .lstinputlisting, .inputminted:
            candidates = [path]
        case .includegraphics, .includepdf:
            candidates = [path] + imageExtensions.map { path + $0 }
        case .usepackage:
            candidates = [path + ".sty"]
        case .documentclass:
            candidates = [path + ".cls"]
        }

        for candidate in candidates {
            let candidateURL = url(candidate, relativeTo: base)
            if fileExists(candidateURL) { return candidateURL }
        }
        return nil
    }

    private static func isTeXSource(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "tex"
    }

    private static func followsInclude(_ kind: IncludeReference.Kind) -> Bool {
        switch kind {
        case .input, .include, .subfile, .importFile, .subimport: return true
        default: return false
        }
    }

    // MARK: - Build

    /// Builds the index starting at `rootFile`.
    public static func build(rootFile: URL, read: (URL) -> String?, fileExists: (URL) -> Bool) -> ProjectIndex {
        let root = rootFile.standardizedFileURL
        var index = ProjectIndex(rootFile: root)
        var visited = Set<URL>()
        var files: [URL] = []
        var graph: [URL: [URL]] = [:]
        var flatOutline: [OutlineEntry] = []
        var labels: [LabelDefinition] = []
        var commands: [CompletionItem] = []
        var seenCommands = Set<String>()
        var environments: [String] = []
        var seenEnvironments = Set<String>()
        var bibFiles: [URL] = []
        var seenBib = Set<URL>()
        var seenLocalPackages = Set<URL>()

        func absorbDefinitions(_ scan: LaTeXScanner.FileScan) {
            for item in scan.customCommands where seenCommands.insert(item.label).inserted { commands.append(item) }
            for name in scan.customEnvironments where seenEnvironments.insert(name).inserted { environments.append(name) }
        }

        func visit(_ file: URL) {
            visited.insert(file)
            files.append(file)
            let text = read(file) ?? ""
            let scan = LaTeXScanner.scan(MaskedSource(text), fileURL: file, parts: .all)
            if file == root { index.magicComments = LaTeXScanner.magicComments(in: text) }
            labels.append(contentsOf: scan.labels)
            absorbDefinitions(scan)

            // Interleave outline entries and includes by position.
            var entryIndex = 0
            var children: [URL] = []
            func flushEntries(before offset: Int) {
                while entryIndex < scan.outline.count && scan.outline[entryIndex].offset < offset {
                    flatOutline.append(scan.outline[entryIndex])
                    entryIndex += 1
                }
            }
            for reference in scan.includes {
                switch reference.kind {
                case .bibliography, .addbibresource:
                    if let bib = resolve(reference, includingFile: file, rootFile: root, fileExists: fileExists),
                       seenBib.insert(bib).inserted {
                        bibFiles.append(bib)
                    }
                case .usepackage, .documentclass:
                    if let local = resolve(reference, includingFile: file, rootFile: root, fileExists: fileExists),
                       seenLocalPackages.insert(local).inserted, let source = read(local) {
                        absorbDefinitions(LaTeXScanner.scan(MaskedSource(source), fileURL: local, parts: .definitions))
                    }
                case .input, .include, .subfile, .importFile, .subimport:
                    flushEntries(before: reference.range.location)
                    guard let target = resolve(reference, includingFile: file, rootFile: root, fileExists: fileExists),
                          isTeXSource(target) else { continue }
                    if !children.contains(target) { children.append(target) }
                    if !visited.contains(target) { visit(target) }
                default:
                    break
                }
            }
            flushEntries(before: Int.max)
            if !children.isEmpty { graph[file] = children }
        }
        visit(root)

        var entries: [BibEntry] = []
        for bib in bibFiles {
            if let text = read(bib) { entries.append(contentsOf: BibParser.entries(in: text, fileURL: bib)) }
        }

        index.files = files
        index.includeGraph = graph
        index.outline = buildTree(flatOutline)
        index.labels = labels
        index.bibFiles = bibFiles
        index.bibEntries = entries
        index.customCommands = commands
        index.customEnvironments = environments
        return index
    }

    /// Nests a flat, ordered list of entries: a deeper level becomes a child of the nearest shallower
    /// heading; labels are leaves under the nearest heading (top level when there is none).
    static func buildTree(_ entries: [OutlineEntry]) -> [OutlineNode] {
        final class Node {
            let entry: OutlineEntry
            var children: [Node] = []
            init(_ entry: OutlineEntry) { self.entry = entry }
            func freeze() -> OutlineNode {
                OutlineNode(entry: entry, children: children.isEmpty ? nil : children.map { $0.freeze() })
            }
        }
        var roots: [Node] = []
        var stack: [Node] = []
        for entry in entries {
            let node = Node(entry)
            if entry.kind == .label {
                if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
                continue
            }
            while let top = stack.last, top.entry.kind.level >= entry.kind.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        return roots.map { $0.freeze() }
    }

    // MARK: - Root detection

    /// Picks the root document for `file`:
    /// 1. `% !TEX root = …` magic comment in `file`; 2. `file` itself if it is a root document
    ///    (a `subfiles` document whose `\documentclass[main.tex]{subfiles}` names an existing file
    ///    resolves to that main file instead);
    /// 3. a root document among `candidates` whose include closure contains `file` (prefer "main.tex");
    /// 4. nil.
    public static func findRoot(for file: URL, candidates: [URL], read: (URL) -> String?, fileExists: (URL) -> Bool) -> URL? {
        let target = file.standardizedFileURL
        let text = read(file) ?? ""

        // 1. Magic comment.
        if let rootPath = LaTeXScanner.magicComments(in: text).root, !rootPath.isEmpty {
            let expanded = (rootPath as NSString).expandingTildeInPath
            let url: URL
            if expanded.hasPrefix("/") {
                url = URL(fileURLWithPath: expanded).standardizedFileURL
            } else {
                url = target.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL
            }
            if fileExists(url) { return url }
        }

        // 2. The file itself.
        let scan = LaTeXScanner.scan(MaskedSource(text), fileURL: target, parts: [.rootInfo, .includes])
        if scan.isRoot {
            if scan.documentClass == "subfiles", var main = scan.documentClassOptions, !main.isEmpty {
                if !main.hasSuffix(".tex") { main += ".tex" }
                let url = target.deletingLastPathComponent().appendingPathComponent(main).standardizedFileURL
                if url != target && fileExists(url) { return url }
            }
            return file
        }

        // 3. A candidate root whose closure contains the file.
        var closureCache: [URL: [IncludeReference]] = [:]
        func includes(of url: URL) -> [IncludeReference] {
            if let cached = closureCache[url] { return cached }
            let found = LaTeXScanner.scan(MaskedSource(read(url) ?? ""), fileURL: url, parts: .includes).includes
                .filter { followsInclude($0.kind) }
            closureCache[url] = found
            return found
        }
        func closureContains(root: URL, target: URL) -> Bool {
            var visited: Set<URL> = [root]
            var stack: [URL] = [root]
            while let current = stack.popLast() {
                if current == target { return true }
                for reference in includes(of: current) {
                    guard let resolved = resolve(reference, includingFile: current, rootFile: root, fileExists: fileExists),
                          isTeXSource(resolved), visited.insert(resolved).inserted else { continue }
                    stack.append(resolved)
                }
            }
            return false
        }

        let isMain: (URL) -> Bool = { $0.lastPathComponent.lowercased() == "main.tex" }
        let ordered = candidates.filter(isMain) + candidates.filter { !isMain($0) }
        for candidate in ordered {
            let standardized = candidate.standardizedFileURL
            guard standardized != target, let candidateText = read(candidate) else { continue }
            guard LaTeXScanner.scan(MaskedSource(candidateText), fileURL: standardized, parts: .rootInfo).isRoot else { continue }
            if closureContains(root: standardized, target: target) { return candidate }
        }
        return nil
    }
}

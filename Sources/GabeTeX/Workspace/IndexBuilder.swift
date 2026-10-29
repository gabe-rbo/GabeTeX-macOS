import Foundation
import TeXCore

/// Builds the `ProjectIndex` and picks the root document. Runs off the main actor on a snapshot
/// (unsaved buffer texts + the file list), so typing never waits for it.
nonisolated enum IndexBuilder {
    nonisolated struct Input: Sendable {
        var folder: URL
        /// Explicit “Set as Main Document” choice.
        var overrideRoot: URL?
        var currentFile: URL?
        /// The previously chosen root, kept when nothing better is found.
        var stickyRoot: URL?
        var files: [URL]
        /// Unsaved buffer texts (dirty buffers only; clean buffers equal the disk).
        var overlays: [URL: String]
        /// Which files are root documents (`\documentclass`), cached across runs.
        var rootStatus: [URL: Bool]
    }

    nonisolated struct Output: Sendable {
        var root: URL?
        var index: ProjectIndex?
        var rootCandidates: [URL]
        var projectFiles: [String]
        var rootStatus: [URL: Bool]
    }

    static let texExtensions: Set<String> = ["tex", "ltx"]

    static func compute(_ input: Input) -> Output {
        let overlays = input.overlays
        let read: (URL) -> String? = { url in
            if let text = overlays[url] { return text }
            return (try? TextFileIO.read(url))?.text
        }
        let exists: (URL) -> Bool = { url in
            overlays[url] != nil || FileManager.default.fileExists(atPath: url.path)
        }

        // Root-document candidates (cached; dirty buffers are always re-evaluated).
        let fileSet = Set(input.files)
        var status = input.rootStatus.filter { key, _ in fileSet.contains(key) }
        var candidates: [URL] = []
        for file in input.files where texExtensions.contains(file.pathExtension.lowercased()) {
            let isRoot: Bool
            if let text = overlays[file] {
                isRoot = LaTeXScanner.isRootDocument(text)
            } else if let cached = status[file] {
                isRoot = cached
            } else {
                isRoot = LaTeXScanner.isRootDocument(readHead(file))
                status[file] = isRoot
            }
            if isRoot { candidates.append(file) }
        }

        // Pick the root.
        var root: URL?
        if let forced = input.overrideRoot, exists(forced) {
            root = forced
        } else if let current = input.currentFile,
                  let found = ProjectIndex.findRoot(for: current, candidates: candidates, read: read, fileExists: exists) {
            root = found
        } else if let sticky = input.stickyRoot, exists(sticky), candidates.contains(sticky) {
            root = sticky
        } else {
            root = candidates.first { $0.lastPathComponent.lowercased() == "main.tex" }
                ?? candidates.min { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }

        guard let root else {
            return Output(root: nil, index: nil, rootCandidates: candidates, projectFiles: [], rootStatus: status)
        }
        let index = ProjectIndex.build(rootFile: root, read: read, fileExists: exists)
        let rootDirectory = root.deletingLastPathComponent()
        let projectFiles = input.files.compactMap { $0.relativePath(from: rootDirectory) }
        return Output(root: root, index: index, rootCandidates: candidates, projectFiles: projectFiles, rootStatus: status)
    }

    /// First 64 KB of a file as text (enough to find `\documentclass`).
    private static func readHead(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return TextFileIO.decode(data)?.text ?? ""
    }
}

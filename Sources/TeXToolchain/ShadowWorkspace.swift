import Foundation
import Darwin
import CryptoKit

/// The private mirror of a project in which `LaTeXCompiler` runs latexmk (ARCHITECTURE.md §Shadow workspace).
///
/// ```
/// <root>/tree/…               mirrors the project's ancestor folder A (`ancestorLevels` above the project):
///                             each entry of A and of every folder between A and the project is a symlink to
///                             the original, except the folders on the way down to the project (real folders)
/// <root>/tree/<a>/<b>/<proj>  the project mirror (`sourceDirectory`): every project file is a symlink to the
///                             original, except overlays (unsaved buffers), which are real files; directories
///                             are real directories
/// <root>/out/…                latexmk's -outdir, with the same directory tree as the project
/// ```
/// The ancestor layer makes `\input{../macros}`, `\bibliography{../refs}`, `\includegraphics{../figs/x}`
/// resolve exactly as they do next to the real project.
///
/// A symlinked directory of the project (`chapters -> ../shared/chapters`) is mirrored as one symlink — unless an
/// overlay or the root document lies below it: then it is *materialized* as a real directory of per-entry
/// symlinks (recursively, only along that path), so the overlay is written into the shadow and never through
/// the link into the user's files. As a second line of defence every directory, symlink and overlay is created
/// only after checking that the real path of its parent lies inside the shadow tree (`writeAtomically` throws
/// otherwise).
///
/// VCS metadata (`.git`, `.svn`, `.hg`), `.DS_Store` and editor swap/backup files are not mirrored; everything
/// else is, including `.latexmkrc`. `refresh` compares the desired listing with what is on disk and only
/// touches entries that changed (stale entries, hidden ones included, are removed).
struct ShadowWorkspace: Sendable {
    let projectDirectory: URL
    let root: URL

    /// Upper bound on mirrored project entries: opening a huge folder (e.g. the home directory) must not make
    /// every background compile walk it.
    static let maximumEntries = 20_000
    /// How many folders above the project the ancestor layer mirrors (`../../../x` still compiles).
    static let ancestorLevels = 3
    /// An ancestor folder with more entries than this contributes no sibling symlinks (its `..` path still works).
    static let maximumSiblingsPerLevel = 5_000

    init(projectDirectory: URL, root: URL) {
        self.projectDirectory = projectDirectory.standardizedFileURL
        self.root = root
    }

    /// Root of the ancestor layer (mirrors `ancestorDirectory`).
    var treeDirectory: URL { root.appendingPathComponent("tree", isDirectory: true) }
    var outputDirectory: URL { root.appendingPathComponent("out", isDirectory: true) }

    /// The real folder mirrored at `treeDirectory`, and the path components leading from it to the project.
    var layout: (ancestor: String, components: [String]) { Self.layout(forProjectPath: projectDirectory.path) }

    var ancestorDirectory: URL { URL(fileURLWithPath: layout.ancestor, isDirectory: true) }

    /// The project mirror: the shadow counterpart of `projectDirectory`.
    var sourceDirectory: URL {
        layout.components.reduce(treeDirectory) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    var pathMapper: ShadowPathMapper {
        ShadowPathMapper(projectDirectory: projectDirectory, shadowDirectory: sourceDirectory,
                         ancestorDirectory: ancestorDirectory, ancestorShadowDirectory: treeDirectory)
    }

    static func layout(forProjectPath path: String) -> (ancestor: String, components: [String]) {
        let all = path.split(separator: "/").map(String.init)
        let levels = min(ancestorLevels, all.count)
        return ("/" + all.dropLast(levels).joined(separator: "/"), Array(all.suffix(levels)))
    }

    enum Failure: Error, Sendable, Equatable {
        case tooManyFiles(Int)
        case io(String)

        var message: String {
            switch self {
            case .tooManyFiles(let limit):
                String(localized: "The project folder contains more than \(limit) files; open the folder that contains the document instead.")
            case .io(let detail):
                String(localized: "Could not prepare the build folder: \(detail)")
            }
        }
    }

    /// What `refresh` found: canonical project URLs keyed by the NFC-normalized project-relative path, used
    /// to report diagnostics with the on-disk spelling of file names.
    struct Snapshot: Sendable {
        var projectFiles: [String: URL]
        /// Project-relative directories (also created in `out/`).
        var directories: [String]
    }

    /// `<16 hex digits of SHA-256(standardized project path)>`.
    static func identifier(for projectDirectory: URL) -> String {
        let digest = SHA256.hash(data: Data(projectDirectory.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Names that are never mirrored: VCS metadata, Finder metadata and editor swap/backup files.
    static func isExcluded(_ name: String) -> Bool {
        switch name {
        case ".git", ".svn", ".hg", ".DS_Store": return true
        default: break
        }
        if name.hasPrefix(".#") || name.hasSuffix("~") { return true }                    // Emacs lock, backups
        if name.count > 2 && name.hasPrefix("#") && name.hasSuffix("#") { return true }   // Emacs auto-save
        if name.hasPrefix(".") {                                                           // Vim .x.swp/.swo/.swn…
            let ext = (name as NSString).pathExtension
            if ext.count == 3 && ext.hasPrefix("sw") { return true }
        }
        return false
    }

    // MARK: Refresh

    private enum Desired {
        case directory
        case link(target: String)
        case overlay(Data)
    }

    private enum Actual {
        case directory
        case link(target: String)
        case file
        case other
    }

    private typealias Entry = (spelling: String, kind: Desired)

    /// Brings the mirror (and the directory tree of `out/`) up to date with the project and the overlays.
    ///
    /// - Parameters:
    ///   - overlays: unsaved buffer contents keyed by project file URL (files outside the project are ignored).
    ///   - encodings: encoding to write each overlay with; missing entries and unrepresentable text use UTF-8.
    ///   - pinned: further project files (the root document) whose directory must be a real shadow directory,
    ///     i.e. symlinked directories on their path are materialized like an overlay's.
    func refresh(overlays: [URL: String], encodings: [URL: String.Encoding] = [:], pinned: [URL] = []) throws(Failure) -> Snapshot {
        let projectPath = projectDirectory.path
        let projectBase = projectPath == "/" ? "" : projectPath
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

        // 1. The project, keyed by NFC project-relative path; values keep the on-disk spelling.
        var project: [String: Entry] = [:]
        var projectFiles: [String: URL] = [:]
        var count = 0
        var walkError: Failure?
        Self.walk(directory: projectPath, relative: "", skipping: Self.isExcluded) { rel, type in
            count += 1
            if count > Self.maximumEntries {
                walkError = .tooManyFiles(Self.maximumEntries)
                return false
            }
            if type == .directory {
                project[key(rel)] = (rel, .directory)
                return true
            }
            project[key(rel)] = (rel, .link(target: projectBase + "/" + rel))
            projectFiles[key(rel)] = URL(fileURLWithPath: projectBase + "/" + rel, isDirectory: false)
            return true
        }
        if let walkError { throw walkError }

        /// Replaces the symlink `spelling` (a directory of the project reached through a link) by a real
        /// directory whose entries are symlinks; returns false if the link does not lead to a directory.
        func materialize(_ spelling: String) -> Bool {
            let real = projectBase + "/" + spelling
            var info = stat()
            if stat(real, &info) == 0 && (info.st_mode & S_IFMT) != S_IFDIR { return false }
            project[key(spelling)] = (spelling, .directory)
            // Reading through the user's link is fine; only writes must never go through it.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: real)) ?? []
            for name in names.sorted() where !Self.isExcluded(name) {
                let child = spelling + "/" + name
                guard project[key(child)] == nil else { continue }
                project[key(child)] = (child, .link(target: projectBase + "/" + child))
                var childInfo = stat()
                if stat(projectBase + "/" + child, &childInfo) == 0 && (childInfo.st_mode & S_IFMT) != S_IFDIR {
                    projectFiles[key(child)] = URL(fileURLWithPath: projectBase + "/" + child, isDirectory: false)
                }
            }
            return true
        }

        /// Makes every parent of `relative` a real directory of the mirror; returns the on-disk spelling of
        /// the parent, or nil when a parent is a file (nothing can live below it).
        func prepareParents(of relative: String) -> String? {
            var parent = ""
            for component in relative.split(separator: "/").dropLast() {
                let candidate = parent.isEmpty ? String(component) : parent + "/" + component
                switch project[key(candidate)]?.kind {
                case .directory?:
                    break
                case .link?:
                    guard let spelling = project[key(candidate)]?.spelling, materialize(spelling) else { return nil }
                case .overlay?:
                    return nil
                case nil:
                    project[key(candidate)] = (candidate, .directory)   // a folder that does not exist on disk yet
                }
                parent = project[key(candidate)]?.spelling ?? candidate
            }
            return parent
        }

        func projectRelative(_ url: URL) -> String? {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(projectBase + "/") else { return nil }
            let rel = String(path.dropFirst(projectBase.count + 1))
            return rel.isEmpty ? nil : rel
        }

        // (Materializing also registers the files of the materialized directory in `projectFiles`.)
        for url in pinned {
            if let rel = projectRelative(url) { _ = prepareParents(of: rel) }
        }

        let encodingByPath = Dictionary(encodings.map { ($0.key.standardizedFileURL.path, $0.value) },
                                        uniquingKeysWith: { first, _ in first })
        for (url, text) in overlays {
            guard let rel = projectRelative(url), let parent = prepareParents(of: rel) else { continue }
            let name = (rel as NSString).lastPathComponent
            let existing = project[key(rel)]
            if case .directory? = existing?.kind { continue }
            let spelling = existing?.spelling ?? (parent.isEmpty ? name : parent + "/" + name)
            let encoding = encodings[url] ?? encodingByPath[url.standardizedFileURL.path]
            project[key(rel)] = (spelling, .overlay(Self.encode(text, as: encoding)))
            if projectFiles[key(rel)] == nil {
                projectFiles[key(rel)] = URL(fileURLWithPath: projectBase + "/" + spelling, isDirectory: false)
            }
        }

        // 2. Desired state of tree/, keyed by NFC tree-relative path: ancestor layer + project mirror.
        var desired: [String: Entry] = [:]
        let (ancestor, components) = layout
        var level = ancestor
        var prefix = ""
        for component in components {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: level),
               names.count <= Self.maximumSiblingsPerLevel {
                let componentNFC = key(component)
                for name in names where !Self.isExcluded(name) {
                    // The shadow volume is usually case-insensitive: never put a link next to the real path.
                    if key(name).caseInsensitiveCompare(componentNFC) == .orderedSame { continue }
                    let rel = prefix.isEmpty ? name : prefix + "/" + name
                    desired[key(rel)] = (rel, .link(target: (level == "/" ? "" : level) + "/" + name))
                }
            }
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            desired[key(prefix)] = (prefix, .directory)
            level = (level == "/" ? "" : level) + "/" + component
        }
        var projectDirectories: [String] = []
        for (_, entry) in project {
            let rel = prefix.isEmpty ? entry.spelling : prefix + "/" + entry.spelling
            desired[key(rel)] = (rel, entry.kind)
            if case .directory = entry.kind { projectDirectories.append(entry.spelling) }
        }

        // 3. What is in tree/ now (no exclusions: stale hidden entries must be removed too).
        let tree = treeDirectory.path
        let out = outputDirectory.path
        do {
            try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        } catch {
            throw .io(error.localizedDescription)
        }
        // Workspaces of earlier versions mirrored the project at <root>/src.
        let legacy = root.appendingPathComponent("src").path
        if FileManager.default.fileExists(atPath: legacy) { try? FileManager.default.removeItem(atPath: legacy) }
        guard let realTree = Self.realPath(tree) else { throw .io(String(localized: "cannot resolve \(tree)")) }

        var actual: [String: (spelling: String, kind: Actual)] = [:]
        Self.walk(directory: tree, relative: "", skipping: { _ in false }) { rel, type in
            switch type {
            case .directory: actual[key(rel)] = (rel, .directory)
            case .symlink: actual[key(rel)] = (rel, .link(target: Self.readLink(tree + "/" + rel) ?? ""))
            case .regular: actual[key(rel)] = (rel, .file)
            case .other: actual[key(rel)] = (rel, .other)
            }
            return true
        }

        // 4. Remove stale or mismatching entries (a removed directory takes its subtree with it). The walk
        //    never descends into symlinks, so every path here is physically inside tree/.
        var removedPrefixes: [String] = []
        for k in actual.keys.sorted() {
            if removedPrefixes.contains(where: { k.hasPrefix($0) }) { continue }
            guard let (spelling, kind) = actual[k] else { continue }
            let keep: Bool
            switch (kind, desired[k]?.kind) {
            case (.directory, .directory?): keep = true
            case (.link(let a), .link(let b)?): keep = a == b
            case (.file, .overlay?): keep = true   // contents compared below
            default: keep = false
            }
            if keep { continue }
            let path = tree + "/" + spelling
            if case .directory = kind {
                removedPrefixes.append(k + "/")
                do { try FileManager.default.removeItem(atPath: path) } catch { throw .io(error.localizedDescription) }
            } else if unlink(path) != 0 && errno != ENOENT {
                throw .io(String(cString: strerror(errno)) + " (\(path))")
            }
            actual[k] = nil
        }
        for removed in removedPrefixes {
            for k in actual.keys where k.hasPrefix(removed) { actual[k] = nil }
        }

        // 5. Create what is missing: directories first (parents before children), then links and overlays.
        var verifiedParents: Set<String> = []
        func checkParent(of path: String) throws(Failure) {
            let parent = (path as NSString).deletingLastPathComponent
            if verifiedParents.contains(parent) { return }
            try Self.requireInside(parent, root: realTree)
            verifiedParents.insert(parent)
        }
        let ordered = desired.sorted { $0.key.count != $1.key.count ? $0.key.count < $1.key.count : $0.key < $1.key }
        for (k, entry) in ordered {
            guard case .directory = entry.kind, actual[k] == nil else { continue }
            let path = tree + "/" + entry.spelling
            try checkParent(of: path)
            if mkdir(path, 0o755) != 0, errno != EEXIST {
                throw .io(String(cString: strerror(errno)) + " (\(entry.spelling))")
            }
        }
        for directory in projectDirectories.sorted(by: { $0.count < $1.count }) {
            if mkdir(out + "/" + directory, 0o755) != 0, errno != EEXIST, errno != ENOENT {
                throw .io(String(cString: strerror(errno)) + " (out/\(directory))")
            }
        }
        let sourcePath = sourceDirectory.path
        for (k, entry) in ordered {
            let path = tree + "/" + entry.spelling
            switch entry.kind {
            case .directory:
                continue
            case .link(let target):
                guard actual[k] == nil else { continue }
                try checkParent(of: path)
                if symlink(target, path) != 0, errno != EEXIST {
                    throw .io(String(cString: strerror(errno)) + " (\(entry.spelling))")
                }
            case .overlay(let data):
                if actual[k] != nil, let existing = FileManager.default.contents(atPath: path), existing == data { continue }
                try Self.writeAtomically(data, to: path, within: sourcePath)
            }
        }
        return Snapshot(projectFiles: projectFiles, directories: projectDirectories.sorted())
    }

    /// Removes the whole workspace.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: File-system helpers

    enum EntryType { case directory, symlink, regular, other }

    /// Depth-first walk that does not follow symbolic links and skips names for which `skipping` returns
    /// true. `visit` returns false to stop the walk.
    @discardableResult
    static func walk(directory: String, relative: String, skipping: (String) -> Bool,
                     visit: (String, EntryType) -> Bool) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return true }
        for name in names.sorted() where !skipping(name) {
            let full = directory + "/" + name
            let rel = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(full, &info) == 0 else { continue }
            let type: EntryType
            switch info.st_mode & S_IFMT {
            case S_IFDIR: type = .directory
            case S_IFLNK: type = .symlink
            case S_IFREG: type = .regular
            default: type = .other
            }
            guard visit(rel, type) else { return false }
            if type == .directory {
                guard walk(directory: full, relative: rel, skipping: skipping, visit: visit) else { return false }
            }
        }
        return true
    }

    static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n >= 0 else { return nil }
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `realpath(3)`: the absolute path with every symlink, `.` and `..` resolved; nil if it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Throws unless the real path of `directory` is `root` (already a real path) or lies below it.
    static func requireInside(_ directory: String, root: String) throws(Failure) {
        guard let real = realPath(directory) else {
            throw .io(String(localized: "cannot resolve \(directory)"))
        }
        guard real == root || real.hasPrefix(root == "/" ? "/" : root + "/") else {
            throw .io(String(localized: "refusing to write outside the build folder: \(directory) leads to \(real)"))
        }
    }

    /// `text` in `encoding` (UTF-8 when nil or when the text is not representable in it).
    static func encode(_ text: String, as encoding: String.Encoding?) -> Data {
        if let encoding, encoding != .utf8, let data = text.data(using: encoding, allowLossyConversion: false) {
            return data
        }
        return Data(text.utf8)
    }

    /// Writes to a new temporary sibling and renames it over `path` (replacing a symlink, never following
    /// it). Hard guard: throws — without touching anything — unless the real path of `path`'s parent lies
    /// inside `root` (resolved with realpath too), so an intermediate symlink can never redirect the write
    /// into the user's files.
    static func writeAtomically(_ data: Data, to path: String, within root: String) throws(Failure) {
        guard let realRoot = realPath(root) else { throw .io(String(localized: "cannot resolve \(root)")) }
        try requireInside((path as NSString).deletingLastPathComponent, root: realRoot)
        let temporary = path + ".gabetex-\(UUID().uuidString.prefix(8)).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw .io(String(cString: strerror(errno)) + " (\((path as NSString).lastPathComponent))")
        }
        var failure: Int32 = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count, let base = buffer.baseAddress {
                let n = Darwin.write(fd, base + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += n
            }
        }
        if close(fd) != 0 && failure == 0 { failure = errno }
        if failure == 0 && rename(temporary, path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary)
            throw .io(String(cString: strerror(failure)) + " (\((path as NSString).lastPathComponent))")
        }
    }
}

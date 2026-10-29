import Foundation

/// One entry of the project file tree. `children` is nil for files and non-nil (possibly empty)
/// for folders, which is what `List(_:children:)` expects.
nonisolated struct FileNode: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var children: [FileNode]?

    var id: URL { url }

    var fileExtension: String { url.pathExtension.lowercased() }
}

/// Scans a project folder (called off the main actor).
nonisolated enum FileTreeScanner {
    nonisolated struct Result: Sendable, Equatable {
        var nodes: [FileNode]
        /// Every file (not folder) in the tree, depth first.
        var files: [URL]
        /// True when the scan stopped early (huge folder).
        var truncated: Bool
    }

    /// Auxiliary files produced by TeX runs outside GabeTeX; hidden to keep the tree calm.
    static let hiddenExtensions: Set<String> = [
        "aux", "log", "out", "toc", "lof", "lot", "fls", "fdb_latexmk", "bbl", "blg", "bcf", "nav", "snm",
        "vrb", "idx", "ilg", "ind", "run.xml", "synctex", "gz", "xdv", "dvi", "listing"
    ]
    static let skippedFolders: Set<String> = ["node_modules", "__pycache__", ".git", ".build", ".svn"]
    static let maxEntries = 6000
    static let maxDepth = 10

    static func scan(root: URL) -> Result {
        var count = 0
        var truncated = false
        var files: [URL] = []
        let rootURL = root.standardizedFileURL
        let rootPhysical = FileIdentity.physicalPath(rootURL.path) ?? rootURL.path
        var ancestors: Set<String> = [rootPhysical]
        let nodes = scanDirectory(rootURL, physical: rootPhysical, depth: 0, ancestors: &ancestors,
                                  count: &count, truncated: &truncated, files: &files)
        return Result(nodes: nodes, files: files, truncated: truncated)
    }

    /// `physical` is the directory’s real path; `ancestors` holds the real paths of every directory on the
    /// way down, so a symbolic link that points back up the tree is shown as an empty folder, not followed.
    private static func scanDirectory(_ directory: URL, physical: String, depth: Int, ancestors: inout Set<String>,
                                      count: inout Int, truncated: inout Bool, files: inout [URL]) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        // List through the real path (a symbolic link to a folder lists fine either way, but this never
        // depends on how Foundation treats a link URL); child URLs keep the project-space spelling.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: physical, isDirectory: true), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var folders: [FileNode] = []
        var plain: [FileNode] = []
        for entry in entries {
            if count >= maxEntries { truncated = true; break }
            let name = entry.lastPathComponent
            let values = try? entry.resourceValues(forKeys: Set(keys))
            var isDirectory = values?.isDirectory ?? false
            var isPackage = values?.isPackage ?? false
            let isLink = values?.isSymbolicLink ?? false
            var childPhysical = physical == "/" ? "/" + name : physical + "/" + name
            if isLink {
                // The resource values above describe the link itself; a link to a folder is a folder.
                var info = stat()
                if stat(entry.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                    isDirectory = true
                    childPhysical = FileIdentity.physicalPath(entry.path) ?? childPhysical
                    isPackage = (try? URL(fileURLWithPath: childPhysical).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
                }
            }
            let url = directory.appendingPathComponent(name, isDirectory: isDirectory).standardizedFileURL
            if isDirectory && !isPackage {
                if skippedFolders.contains(name) { continue }
                count += 1
                let children: [FileNode]
                if depth >= maxDepth || ancestors.contains(childPhysical) {
                    children = []
                } else {
                    ancestors.insert(childPhysical)
                    children = scanDirectory(url, physical: childPhysical, depth: depth + 1, ancestors: &ancestors,
                                             count: &count, truncated: &truncated, files: &files)
                    ancestors.remove(childPhysical)
                }
                folders.append(FileNode(url: url, name: name, isDirectory: true, children: children))
            } else {
                let ext = url.pathExtension.lowercased()
                if hiddenExtensions.contains(ext) || name.hasSuffix(".run.xml") || name.hasSuffix(".synctex.gz") { continue }
                count += 1
                files.append(url)
                plain.append(FileNode(url: url, name: name, isDirectory: false, children: nil))
            }
        }
        let order: (FileNode, FileNode) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: order) + plain.sorted(by: order)
    }
}

nonisolated extension URL {
    /// Path relative to `base` using "/", or nil when the URL is not inside `base`.
    func relativePath(from base: URL) -> String? {
        let selfPath = standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        guard selfPath.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/") else { return nil }
        return String(selfPath.dropFirst(basePath.hasSuffix("/") ? basePath.count : basePath.count + 1))
    }
}

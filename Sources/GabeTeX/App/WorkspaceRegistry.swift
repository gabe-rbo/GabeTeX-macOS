import AppKit

/// Weak registry of live project workspaces: used to route Finder/Dock opens to an existing window,
/// and to ask about unsaved changes when the app quits.
final class WorkspaceRegistry {
    static let shared = WorkspaceRegistry()

    private struct Entry { weak var workspace: ProjectWorkspace? }
    private var entries: [Entry] = []

    var all: [ProjectWorkspace] {
        entries = entries.filter { $0.workspace != nil }
        return entries.compactMap(\.workspace)
    }

    func register(_ workspace: ProjectWorkspace) {
        if !all.contains(where: { $0 === workspace }) {
            entries.append(Entry(workspace: workspace))
        }
    }

    func unregister(_ workspace: ProjectWorkspace) {
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
    }

    /// The workspace of `folder`, however the folder is spelled (a link, another letter case).
    func workspace(for folder: URL) -> ProjectWorkspace? {
        let std = folder.standardizedFileURL
        if let exact = all.first(where: { $0.folderURL == std }) { return exact }
        guard let physical = FileIdentity.physicalPath(std.path) else { return nil }
        return all.first { $0.folderPhysical == physical }
    }

    /// Workspaces with unsaved buffers.
    var dirty: [ProjectWorkspace] { all.filter { $0.hasUnsavedChanges } }
}

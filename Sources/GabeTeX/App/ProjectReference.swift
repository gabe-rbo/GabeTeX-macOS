import Foundation

/// Identifies one project window: the project folder plus an optional file to select on open.
/// This is the value type of `WindowGroup(id: "project", for: ProjectReference.self)`.
nonisolated struct ProjectReference: Codable, Hashable, Sendable {
    var folderURL: URL
    var initialFile: URL?

    init(folderURL: URL, initialFile: URL? = nil) {
        self.folderURL = folderURL.standardizedFileURL
        self.initialFile = initialFile?.standardizedFileURL
    }
}

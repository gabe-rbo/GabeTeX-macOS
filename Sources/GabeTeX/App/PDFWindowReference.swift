import Foundation

/// Identifies the detached PDF window of one project: the value type of
/// `WindowGroup(id: "pdf", for: PDFWindowReference.self)`. One window per project folder.
nonisolated struct PDFWindowReference: Codable, Hashable, Sendable {
    var folderURL: URL

    init(folderURL: URL) {
        self.folderURL = folderURL.standardizedFileURL
    }
}

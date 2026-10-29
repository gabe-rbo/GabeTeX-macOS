import AppKit
import Observation

/// Recently opened project folders (most recent first), persisted in `UserDefaults`.
///
/// The cap (`limit`) applies to unlabeled projects only: a project that carries a label never falls off the
/// list (see `ProjectLabelStore`).
@Observable
final class RecentProjects {
    static let shared = RecentProjects()
    static let limit = 15

    private(set) var urls: [URL] = []

    @ObservationIgnored private let defaultsKey = "recentProjects"
    @ObservationIgnored private let labels = ProjectLabelStore.shared

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    /// Recent folders that still exist on disk.
    var existing: [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        let std = url.standardizedFileURL
        // A renamed or moved project brings its labels along; its old path leaves the list.
        if let oldPath = labels.noteOpened(std) {
            urls.removeAll { $0.path == oldPath }
        }
        urls.removeAll { $0 == std }
        urls.insert(std, at: 0)
        urls = RecentsPolicy.trim(urls, limit: Self.limit) { labels.hasLabels($0) }
        persist()
        // Also feeds the Dock icon’s recent items.
        NSDocumentController.shared.noteNewRecentDocumentURL(std)
    }

    func remove(_ url: URL) {
        let std = url.standardizedFileURL
        urls.removeAll { $0 == std }
        persist()
    }

    /// Clears the list. Labeled projects stay: labeling is a deliberate act of organizing.
    func clear() {
        urls = urls.filter { labels.hasLabels($0) }
        persist()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func persist() {
        UserDefaults.standard.set(urls.map(\.path), forKey: defaultsKey)
    }
}

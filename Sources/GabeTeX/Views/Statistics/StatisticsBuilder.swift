import Foundation
import TeXCore
import TeXToolchain

/// Counts the project off the main actor from a snapshot (unsaved buffer texts + the files on disk).
nonisolated enum StatisticsBuilder {
    static func compute(root: URL, overlays: [URL: String]) -> DocumentStatistics {
        let read: (URL) -> String? = { url in
            if let text = overlays[url] { return text }
            return (try? TextFileIO.read(url))?.text
        }
        let exists: (URL) -> Bool = { url in
            overlays[url] != nil || FileManager.default.fileExists(atPath: url.path)
        }
        return DocumentStatistics.compute(rootFile: root, read: read, fileExists: exists)
    }
}

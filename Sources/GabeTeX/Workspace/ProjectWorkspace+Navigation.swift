import SwiftUI
import AppKit
import TeXCore
import TeXToolchain
import EditorKit
import PreviewKit

// MARK: - ⌘-click navigation, issue navigation (SyncTeX lives in ProjectWorkspace+Sync.swift)

extension ProjectWorkspace {
    // MARK: ⌘-click

    /// ⌘-click on `\input{…}`, `\include{…}`, `\includegraphics{…}` …
    func openReference(_ reference: IncludeReference) {
        guard let current = currentFile else { return }
        let root = mainFile ?? current
        let target = ProjectIndex.resolve(reference, includingFile: current, rootFile: root) { url in
            self.buffers[url] != nil || FileManager.default.fileExists(atPath: url.path)
        }
        guard let target else {
            NSSound.beep()
            switch reference.kind {
            case .usepackage, .documentclass:
                flash(String(localized: "“\(reference.argument)” is not a file in this project."))
            default:
                flash(String(localized: "Could not find “\(reference.argument)”."))
            }
            return
        }
        open(target, focusEditor: true)
    }

    /// ⌘-click on the key of `\ref{…}`, `\eqref{…}`, `\cref{…}` …
    func openLabel(_ key: String) {
        guard let definition = symbols.labels.first(where: { $0.key == key }) else {
            NSSound.beep()
            flash(String(localized: "No \\label{\(key)} was found."))
            return
        }
        open(definition.fileURL, line: definition.line)
    }

    // MARK: Issues

    /// Errors and warnings with a location, in panel order.
    var navigableIssues: [Diagnostic] {
        diagnostics.filter { $0.fileURL != nil && $0.line != nil && $0.severity >= .warning }
    }

    func goToIssue(_ diagnostic: Diagnostic) {
        selectedIssueID = diagnostic.id
        guard let url = diagnostic.fileURL, let line = diagnostic.line else { return }
        open(url, line: line, column: diagnostic.column)
    }

    /// ⌘' / ⇧⌘': next / previous error or warning.
    func goToNextIssue(forward: Bool) {
        let issues = navigableIssues
        guard !issues.isEmpty else {
            flash(String(localized: "No errors or warnings."))
            return
        }
        let position = issues.firstIndex { $0.id == selectedIssueID }
        let next: Int
        if let position {
            next = (position + (forward ? 1 : -1) + issues.count) % issues.count
        } else {
            next = forward ? 0 : issues.count - 1
        }
        goToIssue(issues[next])
    }

    // MARK: Quick Open

    struct QuickOpenItem: Identifiable, Hashable {
        var url: URL
        var relativePath: String
        var isOpen: Bool
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var directory: String {
            let dir = (relativePath as NSString).deletingLastPathComponent
            return dir
        }
    }

    /// Files matching `query`, best first (open files win ties; empty query lists open files first).
    func quickOpenResults(query: String, limit: Int = 60) -> [QuickOpenItem] {
        let candidates: [QuickOpenItem] = allFiles.compactMap { url in
            guard let relative = url.relativePath(from: folderURL) else { return nil }
            return QuickOpenItem(url: url, relativePath: relative, isOpen: tabs.contains(url))
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let recent = candidates.filter(\.isOpen).sorted { (tabs.firstIndex(of: $0.url) ?? 0) < (tabs.firstIndex(of: $1.url) ?? 0) }
            let rest = candidates.filter { !$0.isOpen }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            return Array((recent + rest).prefix(limit))
        }
        let scored: [(QuickOpenItem, Int)] = candidates.compactMap { item in
            FuzzyMatcher.score(query: trimmed, path: item.relativePath).map { (item, $0 + (item.isOpen ? 6 : 0)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.relativePath < $1.0.relativePath }
            .prefix(limit).map(\.0)
    }
}

import Foundation
import Observation

// Project labels: an app-level way to organize the Welcome window's recent projects. Labels are never written
// to the project folder (and are unrelated to Finder tags); they live in UserDefaults, keyed by folder path.
// This file is Foundation-only (no UI) so it can be tested headlessly; colors and menus are in
// `ProjectLabels+UI.swift`.

/// The Finder-like palette. The UI maps each case to the matching system color, so it is right in Light and Dark.
nonisolated enum LabelColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .gray: String(localized: "Gray")
        }
    }
}

nonisolated struct ProjectLabel: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var color: LabelColor

    init(id: UUID = UUID(), name: String, color: LabelColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// The labels of one project folder. `fileID` identifies the folder itself (device + inode), so the labels
/// follow it when it is renamed or moved on the same volume and then opened from its new path.
nonisolated struct LabelAssignment: Codable, Equatable, Sendable {
    var labelIDs: [UUID] = []
    var fileID: String?
}

/// Identity of a folder on disk that survives renames.
nonisolated enum FolderIdentity {
    static func id(ofPath path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}

/// The recent-projects cap, which only applies to unlabeled projects.
nonisolated enum RecentsPolicy {
    /// Keeps every labeled item and at most `limit` unlabeled ones (the first, i.e. most recent, ones);
    /// the order is preserved.
    static func trim<T>(_ items: [T], limit: Int, isLabeled: (T) -> Bool) -> [T] {
        var unlabeled = 0
        return items.filter { item in
            if isLabeled(item) { return true }
            unlabeled += 1
            return unlabeled <= limit
        }
    }
}

/// All labels and their assignments to projects.
@Observable
final class ProjectLabelStore {
    static let shared = ProjectLabelStore()
    /// Longest label name (longer input is cut).
    static let maxNameLength = 32

    private(set) var labels: [ProjectLabel]
    private var assignments: [String: LabelAssignment]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let labelsKey: String
    @ObservationIgnored private let assignmentsKey: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "projectLabels") {
        let labelsKey = keyPrefix + ".items"
        let assignmentsKey = keyPrefix + ".assignments"
        let decoder = JSONDecoder()
        let loadedLabels = defaults.data(forKey: labelsKey).flatMap { try? decoder.decode([ProjectLabel].self, from: $0) } ?? []
        var loadedAssignments = defaults.data(forKey: assignmentsKey)
            .flatMap { try? decoder.decode([String: LabelAssignment].self, from: $0) } ?? [:]
        // Drop references to labels that no longer exist.
        let known = Set(loadedLabels.map(\.id))
        for (key, var entry) in loadedAssignments {
            entry.labelIDs = entry.labelIDs.filter { known.contains($0) }
            loadedAssignments[key] = entry.labelIDs.isEmpty ? nil : entry
        }
        self.defaults = defaults
        self.labelsKey = labelsKey
        self.assignmentsKey = assignmentsKey
        labels = loadedLabels
        assignments = loadedAssignments
    }

    // MARK: Keys

    static func key(for url: URL) -> String { url.standardizedFileURL.path }

    // MARK: Labels

    func label(withID id: UUID) -> ProjectLabel? { labels.first { $0.id == id } }

    /// Collapses whitespace, trims and cuts to `maxNameLength`.
    static func normalizedName(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(maxNameLength))
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// True when `name` is not empty and no other label (than `id`) has it.
    func isNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let normalized = Self.normalizedName(name)
        guard !normalized.isEmpty else { return false }
        return !labels.contains { $0.id != id && Self.sameName($0.name, normalized) }
    }

    /// A color that no label uses yet (else the palette cycles).
    func suggestedColor() -> LabelColor {
        let used = Set(labels.map(\.color))
        return LabelColor.allCases.first { !used.contains($0) } ?? LabelColor.allCases[labels.count % LabelColor.allCases.count]
    }

    /// Adds a label; nil when the name is empty or already taken.
    @discardableResult
    func createLabel(name: String, color: LabelColor) -> ProjectLabel? {
        guard isNameAvailable(name) else { return nil }
        let label = ProjectLabel(name: Self.normalizedName(name), color: color)
        labels.append(label)
        persist()
        return label
    }

    @discardableResult
    func renameLabel(_ id: UUID, to name: String) -> Bool {
        guard let index = labels.firstIndex(where: { $0.id == id }), isNameAvailable(name, excluding: id) else { return false }
        labels[index].name = Self.normalizedName(name)
        persist()
        return true
    }

    func setColor(_ color: LabelColor, for id: UUID) {
        guard let index = labels.firstIndex(where: { $0.id == id }), labels[index].color != color else { return }
        labels[index].color = color
        persist()
    }

    /// Removes the label and all its assignments.
    func deleteLabel(_ id: UUID) {
        guard labels.contains(where: { $0.id == id }) else { return }
        labels.removeAll { $0.id == id }
        for (key, var entry) in assignments {
            entry.labelIDs.removeAll { $0 == id }
            assignments[key] = entry.labelIDs.isEmpty ? nil : entry
        }
        persist()
    }

    // MARK: Assignments

    /// The labels of a project, in the order of the label list.
    func labels(for url: URL) -> [ProjectLabel] {
        guard let entry = assignments[Self.key(for: url)] else { return [] }
        return labels.filter { entry.labelIDs.contains($0.id) }
    }

    func hasLabels(_ url: URL) -> Bool {
        assignments[Self.key(for: url)]?.labelIDs.isEmpty == false
    }

    func isAssigned(_ label: ProjectLabel, to url: URL) -> Bool {
        assignments[Self.key(for: url)]?.labelIDs.contains(label.id) == true
    }

    func setAssigned(_ assigned: Bool, _ label: ProjectLabel, for url: URL) {
        let key = Self.key(for: url)
        var entry = assignments[key] ?? LabelAssignment()
        let has = entry.labelIDs.contains(label.id)
        guard has != assigned, labels.contains(where: { $0.id == label.id }) else { return }
        if assigned {
            entry.labelIDs.append(label.id)
            if entry.fileID == nil { entry.fileID = FolderIdentity.id(ofPath: key) }
        } else {
            entry.labelIDs.removeAll { $0 == label.id }
        }
        assignments[key] = entry.labelIDs.isEmpty ? nil : entry
        persist()
    }

    func toggle(_ label: ProjectLabel, for url: URL) {
        setAssigned(!isAssigned(label, to: url), label, for: url)
    }

    /// Number of projects that carry the label.
    func projectCount(for id: UUID) -> Int {
        assignments.values.filter { $0.labelIDs.contains(id) }.count
    }

    /// Call when a project folder is opened. Remembers the folder's identity; and when the folder has no labels
    /// under this path but another path with the same identity does and no longer exists (the folder was
    /// renamed or moved), the labels move here. Returns the old path in that case.
    @discardableResult
    func noteOpened(_ url: URL) -> String? {
        let key = Self.key(for: url)
        guard let id = FolderIdentity.id(ofPath: key) else { return nil }
        if var entry = assignments[key] {
            if entry.fileID != id {
                entry.fileID = id
                assignments[key] = entry
                persist()
            }
            return nil
        }
        for (oldKey, entry) in assignments where oldKey != key && entry.fileID == id {
            if FolderIdentity.id(ofPath: oldKey) == id { continue }     // the old path still leads to this folder
            assignments[key] = entry
            assignments[oldKey] = nil
            persist()
            return oldKey
        }
        return nil
    }

    // MARK: Persistence

    private func persist() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(labels) { defaults.set(data, forKey: labelsKey) }
        if let data = try? encoder.encode(assignments) { defaults.set(data, forKey: assignmentsKey) }
    }
}

import SwiftUI
import AppKit

/// The right column of the Welcome window: recent projects with their labels, filter chips and (for long
/// lists) a search field.
struct RecentProjectsColumn: View {
    private let recents = RecentProjects.shared
    private let store = ProjectLabelStore.shared

    /// The search field appears above this many recent projects.
    private static let searchThreshold = 8

    @LocalState private var filter: UUID? = nil
    @LocalState private var query = ""
    @LocalState private var editor: LabelEditorRequest? = nil
    @LocalState private var labelPendingDeletion: ProjectLabel? = nil

    var body: some View {
        let all = recents.existing
        let labels = store.labels
        let activeFilter = filter.flatMap { id in labels.first { $0.id == id } }
        let showsSearch = all.count > Self.searchThreshold
        let needle = showsSearch ? query.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let items = all.filter { url in
            if let activeFilter, !store.isAssigned(activeFilter, to: url) { return false }
            if !needle.isEmpty {
                return url.lastPathComponent.localizedStandardContains(needle) || url.path.localizedStandardContains(needle)
            }
            return true
        }

        return VStack(alignment: .leading, spacing: 0) {
            header(hasItems: !all.isEmpty)

            if !labels.isEmpty {
                LabelFilterBar(
                    labels: labels,
                    selection: $filter,
                    onRename: { editor = LabelEditorRequest(mode: .edit($0.id)) },
                    onDelete: { labelPendingDeletion = $0 }
                )
                .padding(.horizontal, 20)       // the header's and the search field's inset
                .padding(.bottom, 6)
            }

            if showsSearch {
                searchField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if all.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Projects", systemImage: "clock")
                } description: {
                    Text("Projects you open appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Projects", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    if activeFilter != nil {
                        Text("No recent project has this label.")
                    } else {
                        Text("No recent project matches your search.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items, id: \.self) { url in
                            RecentRow(url: url) { editor = LabelEditorRequest(mode: .create(assignTo: $0)) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: labels.isEmpty)
        .sheet(item: $editor) { request in
            LabelEditorSheet(request: request)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { labelPendingDeletion != nil }, set: { if !$0 { labelPendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: labelPendingDeletion
        ) { label in
            Button("Delete Label", role: .destructive) {
                if filter == label.id { filter = nil }
                store.deleteLabel(label.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The label is removed from all projects. Your project folders are not changed.")
        }
    }

    private var deletionTitle: String {
        guard let label = labelPendingDeletion else { return "" }
        return String(localized: "Delete the label “\(label.name)”?")
    }

    private func header(hasItems: Bool) -> some View {
        HStack(spacing: 12) {
            Text("Recent Projects")
                .font(.headline)
            Spacer()
            Menu {
                Button("New Label…") { editor = LabelEditorRequest(mode: .create(assignTo: nil)) }
            } label: {
                Image(systemName: "tag")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Create a label to organize your projects")
            .accessibilityLabel("Labels")
            if hasItems {
                Button("Clear") { recents.clear() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear the list of recent projects (labeled projects stay)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Projects", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }
}

/// One recent project: icon, name with its labels, location. Click to open; right-click for labels and more.
private struct RecentRow: View {
    let url: URL
    let onNewLabel: (URL) -> Void

    private let store = ProjectLabelStore.shared
    @LocalState private var isHovering = false

    var body: some View {
        let labels = store.labels(for: url)
        Button {
            AppRouter.shared.open(folder: url)
        } label: {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        LabelBadges(labels: labels)
                            .layoutPriority(1)
                    }
                    Text(abbreviatedParent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isHovering ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .draggable(ProjectDragItem(path: url.path))
        .help(url.path)
        .accessibilityLabel(Text("Open \(url.lastPathComponent)"))
        .accessibilityValue(Text(verbatim: labels.map(\.name).joined(separator: ", ")))
        .contextMenu {
            Button("Open") { AppRouter.shared.open(folder: url) }
            Menu("Labels") {
                LabelsMenuContent(project: url) { onNewLabel(url) }
            }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from Recents") { RecentProjects.shared.remove(url) }
        }
    }

    private var abbreviatedParent: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

/// A project's labels as small colored capsules, or as dots when there are many or long names.
struct LabelBadges: View {
    let labels: [ProjectLabel]

    private var isCompact: Bool {
        labels.count > 2 || labels.reduce(0) { $0 + $1.name.count } > 22
    }

    var body: some View {
        if labels.isEmpty {
            EmptyView()
        } else if isCompact {
            HStack(spacing: 3) {
                ForEach(labels.prefix(4)) { label in
                    Circle()
                        .fill(label.color.color)
                        .frame(width: 8, height: 8)
                }
                if labels.count > 4 {
                    Text("+\(labels.count - 4)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .help(labels.map(\.name).joined(separator: ", "))
            .accessibilityElement(children: .ignore)
        } else {
            HStack(spacing: 4) {
                ForEach(labels) { label in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(label.color.color)
                            .frame(width: 6, height: 6)
                        Text(verbatim: label.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.75))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1.5)
                    .background(label.color.color.opacity(0.16), in: .capsule)
                }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
        }
    }
}

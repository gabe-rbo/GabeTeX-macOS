import SwiftUI
import TeXCore

/// The document outline across all included files: sections, frames and (optionally) labels.
struct OutlineSidebarView: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @AppStorage("outline.showLabels") private var showLabels = false
    @LocalState private var collapsed: Set<String> = []

    var body: some View {
        let nodes = Self.filtered(workspace.index?.outline ?? [], showLabels: showLabels)
        List {
            OutlineBranch(nodes: nodes, collapsed: $collapsed)
        }
        .listStyle(.sidebar)
        .overlay {
            if nodes.isEmpty {
                ContentUnavailableView {
                    Label("No Outline", systemImage: "list.bullet.indent")
                } description: {
                    Text("Sections, frames and labels of your document appear here.")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Toggle(isOn: $showLabels) {
                    Label("Labels", systemImage: "tag")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show \\label entries in the outline")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Drops label leaves unless requested.
    nonisolated static func filtered(_ nodes: [OutlineNode], showLabels: Bool) -> [OutlineNode] {
        if showLabels { return nodes }
        return nodes.compactMap { node in
            if node.entry.kind == .label { return nil }
            var copy = node
            if let children = node.children {
                let kept = filtered(children, showLabels: false)
                copy.children = kept.isEmpty ? nil : kept
            }
            return copy
        }
    }
}

private struct OutlineBranch: View {
    let nodes: [OutlineNode]
    @Binding var collapsed: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children, !children.isEmpty {
                DisclosureGroup(isExpanded: expansion(for: node)) {
                    OutlineBranch(nodes: children, collapsed: $collapsed)
                } label: {
                    OutlineRow(entry: node.entry, id: node.id)
                }
            } else {
                OutlineRow(entry: node.entry, id: node.id)
            }
        }
    }

    private func expansion(for node: OutlineNode) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(node.id) },
            set: { expanded in
                if expanded { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
            }
        )
    }
}

private struct OutlineRow: View {
    @Environment(ProjectWorkspace.self) private var workspace
    let entry: OutlineEntry
    /// `OutlineNode.id`: how the word count of this heading is looked up.
    let id: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label {
                Text(entry.title.isEmpty ? String(localized: "Untitled") : entry.title)
                    .font(font)
                    .lineLimit(2)
            } icon: {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            if let words = workspace.statistics.wordsByID[id], words > 0 {
                Spacer(minLength: 4)
                Text(verbatim: StatisticsText.number(words))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(Text(verbatim: StatisticsText.words(words)))
                    .accessibilityLabel(Text(verbatim: StatisticsText.words(words)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.open(entry.fileURL, line: entry.line)
        }
        .help(Text("\(entry.fileURL.lastPathComponent), line \(entry.line)"))
        .accessibilityAddTraits(.isButton)
    }

    private var symbol: String {
        switch entry.kind {
        case .part: "books.vertical"
        case .chapter: "book"
        case .section: "text.alignleft"
        case .subsection: "text.alignleft"
        case .subsubsection, .paragraph, .subparagraph: "text.append"
        case .frame: "rectangle.on.rectangle"
        case .label: "tag"
        }
    }

    private var font: Font {
        switch entry.kind {
        case .part, .chapter: .headline
        case .section: .body.weight(.medium)
        case .label: .system(.callout, design: .monospaced)
        default: .body
        }
    }
}

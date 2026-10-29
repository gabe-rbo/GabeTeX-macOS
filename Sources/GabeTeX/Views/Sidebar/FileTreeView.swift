import SwiftUI
import AppKit

/// The project’s file tree (folders first, ★ main document, dirty dots, context menu).
struct FileTreeView: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        List(workspace.fileTree, children: \.children, selection: selection) { node in
            FileRow(node: node)
        }
        .listStyle(.sidebar)
        .overlay {
            if workspace.fileTree.isEmpty {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "folder")
                } description: {
                    Text("Create a file to get started.")
                } actions: {
                    Button("New File…") { workspace.promptNewFile() }
                        .buttonStyle(.glass)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if workspace.treeTruncated {
                Label("This folder is large; only part of it is shown.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .contextMenu {
            Button("New File…") { workspace.promptNewFile(in: workspace.folderURL) }
            Button("New Folder…") { workspace.promptNewFolder(in: workspace.folderURL) }
            Divider()
            Button("Reveal in Finder") { workspace.revealInFinder(workspace.folderURL) }
        }
    }

    private var selection: Binding<URL?> {
        Binding(
            get: { workspace.sidebarSelection },
            set: { newValue in
                workspace.sidebarSelection = newValue
                if let newValue { workspace.open(newValue) }
            }
        )
    }
}

private struct FileRow: View {
    @Environment(ProjectWorkspace.self) private var workspace
    let node: FileNode

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(node.name).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: symbol).foregroundStyle(symbolStyle)
            }
            Spacer(minLength: 4)
            if workspace.isMainFile(node.url) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Main document")
                    .accessibilityLabel("Main document")
            }
            if workspace.isDirty(node.url) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
        }
        .contextMenu { menu }
    }

    private var symbol: String {
        if node.isDirectory { return "folder" }
        switch node.fileExtension {
        case "tex", "ltx": return "doc.text"
        case "bib": return "books.vertical"
        case "sty", "cls", "bst", "def", "cfg": return "puzzlepiece.extension"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "tiff", "svg", "eps", "heic", "webp": return "photo"
        case "md", "txt": return "doc.plaintext"
        case "py", "jl", "swift", "lean", "pl", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private var symbolStyle: HierarchicalShapeStyle {
        node.isDirectory ? .secondary : .primary
    }

    @ViewBuilder
    private var menu: some View {
        let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        Button("New File…") { workspace.promptNewFile(in: directory) }
        Button("New Folder…") { workspace.promptNewFolder(in: directory) }
        Divider()
        if !node.isDirectory {
            Button("Open") { workspace.open(node.url, focusEditor: true) }
        }
        Button("Rename…") { workspace.promptRename(node.url) }
        Button("Duplicate") { workspace.duplicate(node.url) }
        Divider()
        if !node.isDirectory, ["tex", "ltx"].contains(node.fileExtension) {
            if workspace.mainFileOverride == node.url {
                Button("Use Automatic Main Document") { workspace.setMainFile(nil) }
            } else {
                Button("Set as Main Document") { workspace.setMainFile(node.url) }
            }
        }
        Button("Reveal in Finder") { workspace.revealInFinder(node.url) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        Divider()
        Button("Move to Trash", role: .destructive) { workspace.moveToTrash(node.url) }
    }
}

import SwiftUI
import AppKit

/// Editor tabs as Liquid Glass pills. Click to switch, drag to reorder.
struct TabStrip: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabs, id: \.self) { url in
                        TabPill(url: url)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .scrollClipDisabled()
        .frame(height: 44)
        .animation(.smooth(duration: 0.2), value: workspace.tabs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open files")
    }
}

private struct TabPill: View {
    @Environment(ProjectWorkspace.self) private var workspace
    let url: URL
    @LocalState private var isHovering = false

    private var isSelected: Bool { workspace.currentFile == url }
    private var isDirty: Bool { workspace.buffer(for: url)?.isDirty == true }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
            if workspace.isMainFile(url) {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Main document")
            }
            closeControl
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: 28)
        .glassEffect(
            isSelected ? .regular.tint(Color.accentColor.opacity(0.22)).interactive() : .regular.interactive(),
            in: .capsule
        )
        .contentShape(.capsule)
        .onTapGesture { workspace.selectFile(url) }
        .onHover { isHovering = $0 }
        .help(url.relativePath(from: workspace.folderURL) ?? url.path)
        .draggable("gabetex-tab:" + url.path)
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first, payload.hasPrefix("gabetex-tab:") else { return false }
            let source = URL(fileURLWithPath: String(payload.dropFirst("gabetex-tab:".count))).standardizedFileURL
            workspace.moveTab(source, before: url)
            return true
        }
        .contextMenu {
            Button("Close Tab") { workspace.closeTab(url) }
            Button("Close Other Tabs") { workspace.closeOtherTabs(keeping: url) }
            .disabled(workspace.tabs.count < 2)
            Divider()
            Button("Reveal in Finder") { workspace.revealInFinder(url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isDirty ? Text("\(url.lastPathComponent), unsaved changes") : Text(verbatim: url.lastPathComponent))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var closeControl: some View {
        ZStack {
            if isDirty && !isHovering {
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .transition(.opacity)
            } else if isHovering || isSelected {
                Button {
                    workspace.closeTab(url)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Close tab (⌘W)")
                .accessibilityLabel("Close tab")
                .transition(.opacity)
            }
        }
        .frame(width: 16, height: 16)
        .animation(.smooth(duration: 0.12), value: isHovering)
    }

    private var symbol: String {
        switch url.pathExtension.lowercased() {
        case "bib": "books.vertical"
        case "sty", "cls": "puzzlepiece.extension"
        case "tex", "ltx": "doc.text"
        default: "doc"
        }
    }
}

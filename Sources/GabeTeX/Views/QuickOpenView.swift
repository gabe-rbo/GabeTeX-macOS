import SwiftUI

/// Scrim + palette (⌘P).
struct QuickOpenOverlay: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        ZStack(alignment: .top) {
            if workspace.isQuickOpenPresented {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.isQuickOpenPresented = false }
                    .accessibilityHidden(true)
                QuickOpenView()
                    .padding(.top, 56)
                    .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.18), value: workspace.isQuickOpenPresented)
    }
}

/// Glass palette with fuzzy file search. ↑↓ moves, Return opens, Esc closes.
struct QuickOpenView: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @LocalState private var query = ""
    @LocalState private var selection = 0
    @LocalState private var results: [ProjectWorkspace.QuickOpenItem] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Open file by name", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit { openSelected() }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .accessibilityLabel("Quick Open")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            if results.isEmpty {
                Text("No matching files")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                QuickOpenRow(item: item, isSelected: index == selection)
                                    .id(item.id)
                                    .onTapGesture { open(item) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, newValue in
                        if results.indices.contains(newValue) { proxy.scrollTo(results[newValue].id) }
                    }
                }
            }
        }
        .frame(width: 580)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear {
            refresh()
            isFocused = true
        }
        .onChange(of: query) { _, _ in
            selection = 0
            refresh()
        }
        .onExitCommand { close() }
    }

    private func refresh() {
        results = workspace.quickOpenResults(query: query)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func openSelected() {
        guard results.indices.contains(selection) else { return }
        open(results[selection])
    }

    private func open(_ item: ProjectWorkspace.QuickOpenItem) {
        close()
        workspace.open(item.url, focusEditor: true)
    }

    private func close() {
        workspace.isQuickOpenPresented = false
        query = ""
    }
}

private struct QuickOpenRow: View {
    let item: ProjectWorkspace.QuickOpenItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(item.name)
                .fontWeight(.medium)
                .lineLimit(1)
            if !item.directory.isEmpty {
                Text(item.directory)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if item.isOpen {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.secondary)
                    .help("Open in a tab")
                    .accessibilityLabel("Open in a tab")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        switch item.url.pathExtension.lowercased() {
        case "tex", "ltx": "doc.text"
        case "bib": "books.vertical"
        case "sty", "cls": "puzzlepiece.extension"
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg", "eps": "photo"
        default: "doc"
        }
    }
}

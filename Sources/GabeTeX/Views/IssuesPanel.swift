import SwiftUI
import AppKit
import TeXCore

/// Bottom panel: compile problems (filterable, click to jump) and the raw TeX log.
struct IssuesPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case issues, log
        var id: String { rawValue }
    }

    @Environment(ProjectWorkspace.self) private var workspace
    @LocalState private var tab: Tab = .issues
    @LocalState private var showErrors = true
    @LocalState private var showWarnings = true
    @LocalState private var showOthers = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .issues: issuesList
            case .log: LogTextView(text: workspace.log.isEmpty ? workspace.toolOutput : workspace.log)
            }
        }
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Panel", selection: $tab) {
                Text("Issues").tag(Tab.issues)
                Text("Log").tag(Tab.log)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            if tab == .issues {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        filterToggle(isOn: $showErrors, symbol: "xmark.octagon.fill", tint: .red, count: workspace.errorCount, help: "Show errors")
                        filterToggle(isOn: $showWarnings, symbol: "exclamationmark.triangle.fill", tint: .orange, count: workspace.warningCount, help: "Show warnings")
                        filterToggle(isOn: $showOthers, symbol: "text.badge.minus", tint: .secondary, count: workspace.otherIssueCount, help: "Show bad boxes and notes")
                    }
                }
            }
            Spacer()
            Button {
                withAnimation(.smooth) { workspace.showIssues = false }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide the Issues panel (⇧⌘M)")
            .accessibilityLabel("Hide Issues panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func filterToggle(isOn: Binding<Bool>, symbol: String, tint: Color, count: Int, help: LocalizedStringKey) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text("\(count)").monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .opacity(isOn.wrappedValue ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn.wrappedValue ? .regular.interactive() : .clear.interactive(), in: .capsule)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityValue(Text("\(count)"))
    }

    // MARK: Issues

    private var filtered: [Diagnostic] {
        workspace.diagnostics.filter { diagnostic in
            switch diagnostic.severity {
            case .error: showErrors
            case .warning: showWarnings
            case .badbox, .info: showOthers
            }
        }
    }

    @ViewBuilder
    private var issuesList: some View {
        let items = filtered
        if items.isEmpty {
            Group {
                if workspace.diagnostics.isEmpty {
                    ContentUnavailableView {
                        Label("No Issues", systemImage: "checkmark.circle")
                    } description: {
                        Text("Errors and warnings from TeX appear here.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Matching Issues", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Adjust the filters above to see other messages.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(items, selection: Binding(
                    get: { workspace.selectedIssueID },
                    set: { id in
                        workspace.selectedIssueID = id
                        if let id, let diagnostic = items.first(where: { $0.id == id }) { workspace.goToIssue(diagnostic) }
                    }
                )) { diagnostic in
                    IssueRow(diagnostic: diagnostic, folder: workspace.folderURL, isSelected: workspace.selectedIssueID == diagnostic.id)
                        .tag(diagnostic.id)
                }
                .listStyle(.plain)
                .onChange(of: workspace.selectedIssueID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
    }
}

private struct IssueRow: View {
    let diagnostic: Diagnostic
    let folder: URL
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(diagnostic.message)
                    .font(.system(size: 12))
                    .lineLimit(isSelected ? nil : 2)
                    .textSelection(.enabled)
                if isSelected, let detail = diagnostic.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let location {
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var location: String? {
        guard let url = diagnostic.fileURL else { return nil }
        let path = url.relativePath(from: folder) ?? url.lastPathComponent
        if let line = diagnostic.line { return "\(path):\(line)" }
        return path
    }

    private var symbol: String {
        switch diagnostic.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .badbox: "text.badge.minus"
        case .info: "info.circle"
        }
    }

    private var tint: Color {
        switch diagnostic.severity {
        case .error: .red
        case .warning: .orange
        case .badbox, .info: .secondary
        }
    }
}

/// Read-only monospaced text for the TeX log (an `NSTextView`, so very long logs stay fast).
struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isRichText = false
            textView.usesFindBar = true
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}

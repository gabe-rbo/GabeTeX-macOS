import AppKit
import SwiftUI
import TeXCore

/// Compact list of diagnostics shown in the gutter-click popover and the hover popover.
struct DiagnosticListView: View {
    let diagnostics: [Diagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(diagnostics.prefix(12).enumerated()), id: \.offset) { _, diagnostic in
                DiagnosticRow(diagnostic: diagnostic)
            }
            if diagnostics.count > 12 {
                Text("\(diagnostics.count - 12) more…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 220, maxWidth: 480, alignment: .leading)
    }
}

private struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: EditorTheme.symbolName(for: diagnostic.severity))
                .foregroundStyle(Color(nsColor: EditorTheme.color(for: diagnostic.severity)))
                .font(.system(size: 12, weight: .semibold))
                .accessibilityLabel(severityLabel)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: diagnostic.message)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let detail = diagnostic.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text(verbatim: sourceLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var severityLabel: String {
        switch diagnostic.severity {
        case .error: String(localized: "Error")
        case .warning: String(localized: "Warning")
        case .badbox: String(localized: "Bad box")
        case .info: String(localized: "Information")
        }
    }

    private var sourceLabel: String {
        let tool: String = switch diagnostic.source {
        case .tex: "TeX"
        case .latexmk: "latexmk"
        case .bibtex: "BibTeX"
        case .biber: "Biber"
        case .makeindex: "makeindex"
        case .chktex: "ChkTeX"
        case .structure: String(localized: "Structure")
        }
        if let line = diagnostic.line {
            return String(localized: "\(severityLabel) · \(tool) · line \(line)")
        }
        return String(localized: "\(severityLabel) · \(tool)")
    }
}

/// Shows `DiagnosticListView` in an `NSPopover`.
final class DiagnosticPopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    /// The rect (in the anchor view) the current popover points at.
    private(set) var anchorRect: NSRect = .zero

    var isShown: Bool { popover?.isShown ?? false }

    func show(_ diagnostics: [Diagnostic], relativeTo rect: NSRect, of view: NSView,
              transient: Bool, edge: NSRectEdge = .maxY) {
        guard !diagnostics.isEmpty, view.window != nil else { return }
        close(animated: false)
        let hosting = NSHostingController(rootView: DiagnosticListView(diagnostics: diagnostics))
        hosting.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = transient ? .transient : .applicationDefined
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        anchorRect = rect
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    func close(animated: Bool = true) {
        guard let popover else { return }
        popover.animates = animated
        popover.performClose(nil)
        if !animated { popover.close() }
        self.popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === popover { popover = nil }
    }
}

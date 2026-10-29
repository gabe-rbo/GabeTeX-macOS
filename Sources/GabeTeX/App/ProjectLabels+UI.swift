import SwiftUI
import AppKit

// UI side of the project labels: colors, menu images, the “New Label / Rename” request and the drag payload.

extension LabelColor {
    /// The Finder-like system color (adapts to Light and Dark).
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// A colored dot for menu items. Palette-colored symbols are not templates, so the color survives in menus.
    var menuImage: NSImage {
        let size = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let palette = NSImage.SymbolConfiguration(paletteColors: [nsColor])
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: displayName)?
            .withSymbolConfiguration(size.applying(palette))
        return image ?? NSImage()
    }
}

/// Asks a window to present the label editor (New Label… / Rename…).
struct LabelEditorRequest: Identifiable {
    enum Mode {
        /// Create a label; when `assignTo` is set the new label is also given to that project.
        case create(assignTo: URL?)
        /// Rename and recolor an existing label.
        case edit(UUID)
    }

    let id = UUID()
    var mode: Mode
}

/// What a dragged recent-project row carries, so it can be dropped on a label chip.
nonisolated struct ProjectDragItem: Codable, Transferable, Sendable {
    var path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// A toggle for one label, with its colored dot, for use inside menus.
struct LabelToggle: View {
    let label: ProjectLabel
    let project: URL
    private let store = ProjectLabelStore.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { store.isAssigned(label, to: project) },
            set: { store.setAssigned($0, label, for: project) }
        )) {
            Label {
                Text(verbatim: label.name)
            } icon: {
                Image(nsImage: label.color.menuImage)
            }
        }
    }
}

/// “Labels ▸” — one toggle per label, then “New Label…”. Shared by the Welcome row menu and File ▸ Project Labels.
struct LabelsMenuContent: View {
    let project: URL
    let onNewLabel: () -> Void
    private let store = ProjectLabelStore.shared

    var body: some View {
        ForEach(store.labels) { label in
            LabelToggle(label: label, project: project)
        }
        if !store.labels.isEmpty { Divider() }
        Button("New Label…", action: onNewLabel)
    }
}

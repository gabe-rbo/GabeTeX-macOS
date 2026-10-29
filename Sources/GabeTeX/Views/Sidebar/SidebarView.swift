import SwiftUI

/// Sidebar: [Files | Outline] segmented control above the selected list.
struct SidebarView: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        Group {
            switch workspace.sidebarMode {
            case .files: FileTreeView()
            case .outline: OutlineSidebarView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Sidebar", selection: $workspace.sidebarMode) {
                Text("Files").tag(ProjectWorkspace.SidebarMode.files)
                Text("Outline").tag(ProjectWorkspace.SidebarMode.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

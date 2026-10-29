import SwiftUI
import TeXToolchain

/// Compile · Stop │ Engine · Live │ Preview · Issues
///
/// Every item is a small view of its own that reads the workspace from the environment, so each button
/// follows exactly the state it shows (compiling spinner, enabled state, toggles).
struct ProjectToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { CompileButton() }
        ToolbarItem(placement: .primaryAction) { StopButton() }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) { EngineMenu() }
        ToolbarItem(placement: .primaryAction) { LiveCompileToggle() }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) { PreviewToggle() }
        ToolbarItem(placement: .primaryAction) { DetachPreviewToggle() }
        ToolbarItem(placement: .primaryAction) { IssuesToggle() }
    }
}

private struct CompileButton: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        Button {
            workspace.compile()
        } label: {
            if workspace.isCompiling {
                ProgressView().controlSize(.small)
            } else {
                Label("Compile", systemImage: "play.fill")
            }
        }
        .buttonStyle(.glassProminent)
        .disabled(workspace.mainFile == nil)
        .help("Compile the document (⌘B)")
        .accessibilityLabel("Compile")
    }
}

private struct StopButton: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        Button {
            workspace.stopCompile()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .disabled(!workspace.isCompiling)
        .help("Stop compiling (⌘.)")
        .accessibilityLabel("Stop")
    }
}

private struct EngineMenu: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Menu {
            Picker("Engine", selection: Binding<TeXEngine?>(
                get: { workspace.engineOverride },
                set: { workspace.setEngineOverride($0) }
            )) {
                Text("Automatic (\(settings.defaultEngine.displayName))").tag(TeXEngine?.none)
                ForEach(TeXEngine.allCases) { engine in
                    Text(engine.displayName).tag(TeXEngine?.some(engine))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(workspace.effectiveEngine.displayName, systemImage: "gearshape.2")
        }
        .help("TeX engine used to compile")
        .accessibilityLabel("TeX engine")
    }
}

private struct LiveCompileToggle: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Toggle(isOn: Binding(get: { settings.liveCompile }, set: { settings.liveCompile = $0 })) {
            Label("Live Compile", systemImage: "bolt.fill")
        }
        .help(settings.liveCompile ? Text("Live compile is on: the document is compiled while you type") : Text("Live compile is off"))
        .accessibilityLabel("Live compile")
    }
}

private struct PreviewToggle: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        // While the preview is in its own window this toggle is on and inert; the neighbouring button moves it back.
        Toggle(isOn: Binding(
            get: { workspace.showPreview || workspace.isPreviewDetached },
            set: { value in withAnimation(.smooth) { workspace.showPreview = value } }
        )) {
            Label("PDF Preview", systemImage: "doc.richtext")
        }
        .disabled(workspace.isPreviewDetached)
        .help(workspace.isPreviewDetached ? Text("The PDF preview is in a separate window") : Text("Show or hide the PDF preview (⌥⌘P)"))
        .accessibilityLabel("PDF preview")
    }
}

/// Moves the preview into its own window and back.
private struct DetachPreviewToggle: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        Toggle(isOn: Binding(
            get: { workspace.isPreviewDetached },
            set: { _ in withAnimation(.smooth) { workspace.togglePreviewDetached() } }
        )) {
            if workspace.isPreviewDetached {
                Label("Attach PDF to Project Window", systemImage: "arrow.down.right.and.arrow.up.left")
            } else {
                Label("Open PDF in Separate Window", systemImage: "arrow.up.forward.app")
            }
        }
        .help(workspace.isPreviewDetached ? Text("Attach PDF to Project Window") : Text("Open PDF in Separate Window"))
        .accessibilityLabel(workspace.isPreviewDetached ? Text("Attach PDF to Project Window") : Text("Open PDF in Separate Window"))
    }
}

private struct IssuesToggle: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        Toggle(isOn: Binding(get: { workspace.showIssues }, set: { value in withAnimation(.smooth) { workspace.showIssues = value } })) {
            Label("Issues", systemImage: workspace.errorCount > 0 ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
        }
        .help("Show or hide the Issues panel (⇧⌘M)")
        .accessibilityLabel("Issues panel")
    }
}

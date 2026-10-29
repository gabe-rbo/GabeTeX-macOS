import SwiftUI
import EditorKit

/// The text editor for the current tab, or an empty state.
struct EditorArea: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let buffer = workspace.currentBuffer {
            LaTeXEditorView(
                buffer: buffer,
                controller: workspace.editor,
                configuration: settings.editorConfiguration,
                diagnostics: workspace.diagnostics,
                symbols: workspace.symbols,
                onTextChange: { workspace.bufferDidChange($0) }
            )
            // No SwiftUI accessibility modifier here: it would replace the AppKit text view's own
            // accessibility element (AXTextArea "LaTeX source") and hide the text from VoiceOver.
        } else {
            ContentUnavailableView {
                Label("No File Open", systemImage: "doc.text")
            } description: {
                Text("Choose a file in the sidebar, or press ⌘P to open one quickly.")
            } actions: {
                Button("Quick Open…") { workspace.isQuickOpenPresented = true }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
    }
}

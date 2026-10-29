import SwiftUI
import PreviewKit

/// The PDF preview with floating glass controls, a compiling state and PreviewKit’s empty state.
/// Docked beside the editor or, with `.detached`, filling the PDF window.
struct PreviewPane: View {
    enum Placement {
        case docked, detached
    }

    var placement: Placement = .docked
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        ZStack(alignment: .bottom) {
            // Always present, so the controller keeps a view to load into; the overlays cover it.
            PDFPreviewView(controller: workspace.preview)
                .accessibilityLabel("PDF preview")
            if workspace.preview.hasDocument {
                PDFPreviewControls(controller: workspace.preview)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            } else if workspace.isCompiling {
                compiling
                    .transition(.opacity)
            } else {
                PDFPreviewPlaceholder(message: failureMessage)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if placement == .docked {
                detachButton
            }
        }
        .animation(.smooth(duration: 0.25), value: workspace.preview.hasDocument)
        .animation(.smooth(duration: 0.25), value: workspace.isCompiling)
    }

    /// A small glass button in the corner: moves the preview into its own window.
    private var detachButton: some View {
        Button {
            workspace.detachPreview()
        } label: {
            Image(systemName: "arrow.up.forward.app")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .padding(.top, 10)
        .padding(.trailing, 18)      // clear of the scroll bar
        .help("Open PDF in Separate Window")
        .accessibilityLabel("Open PDF in Separate Window")
    }

    private var compiling: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Compiling…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// An explanation for the placeholder after a compile that produced no PDF; nil before the first one.
    private var failureMessage: String? {
        switch workspace.compileState {
        case .toolError(let message): message
        case .failed: String(localized: "The last build failed. See the Issues panel for details.")
        default: nil
        }
    }
}

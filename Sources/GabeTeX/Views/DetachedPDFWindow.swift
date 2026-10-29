import SwiftUI
import AppKit

/// The root of the detached PDF window: finds the project's workspace and shows its preview.
///
/// The window shows the same `PDFPreviewController` as the docked pane, so live reloads, forward-sync
/// highlights and PDF → source clicks keep working; the menus work too because the window publishes the same
/// focused scene values as a project window.
struct DetachedPDFWindow: View {
    let reference: PDFWindowReference
    @Environment(\.dismiss) private var dismiss
    @LocalState private var workspace: ProjectWorkspace? = nil
    private let settings = AppSettings.shared

    var body: some View {
        Group {
            if let workspace {
                DetachedPDFContent()
                    .publishesMenuState(inPDFWindow: true)      // before `.environment`, which it reads
                    .environment(workspace)
                    .environment(settings)
                    .background(PDFWindowAccessor(workspace: workspace))
            } else {
                Color.clear
            }
        }
        .task {
            // The workspace registers itself at the start of `start()`, which opens this window.
            for _ in 0..<40 {
                if let found = WorkspaceRegistry.shared.workspace(for: reference.folderURL) {
                    workspace = found
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            dismiss()
        }
    }
}

/// The window’s content: the preview and one toolbar button to attach it again.
private struct DetachedPDFContent: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        PreviewPane(placement: .detached)
            .frame(minWidth: 320, minHeight: 360)
            .navigationTitle(String(localized: "\(workspace.displayName) — PDF"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        workspace.attachPreview()
                    } label: {
                        Label("Attach PDF to Project Window", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Attach PDF to Project Window")
                    .accessibilityLabel("Attach PDF to Project Window")
                }
            }
    }
}

/// Connects the PDF window to its workspace: remembers the frame per project (also across displays), tells the
/// workspace when the window closes, and keeps the window out of system restoration.
struct PDFWindowAccessor: NSViewRepresentable {
    let workspace: ProjectWorkspace

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.workspace = workspace
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {
        view.workspace = workspace
    }

    final class AccessorView: NSView {
        weak var workspace: ProjectWorkspace?
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let workspace else { return }
            window.isRestorable = false
            window.tabbingMode = .disallowed
            restoreFrame(of: window, for: workspace)
            workspace.pdfWindowDidOpen(window)
            if closeObserver == nil {
                closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak workspace] _ in
                    MainActor.assumeIsolated { workspace?.pdfWindowWillClose() }
                }
            }
        }

        isolated deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }

        /// A stable autosave name per project keeps position and size across launches and displays.
        /// SwiftUI sizes a new window after it appears, so the saved frame is applied once more shortly after.
        private func restoreFrame(of window: NSWindow, for workspace: ProjectWorkspace) {
            let name = "GabeTeX.PDFWindow." + workspace.folderURL.path
            window.setFrameAutosaveName(name)
            Task { [weak window] in
                for delay in [0, 250] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) } else { await Task.yield() }
                    guard let window else { return }
                    if window.setFrameUsingName(name) { Self.keepOnScreen(window) }
                }
            }
        }

        /// A frame saved on a display that is gone must not leave the window out of reach.
        private static func keepOnScreen(_ window: NSWindow) {
            let frame = window.frame
            let reachable = NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) }
            if !reachable {
                window.setFrame(window.constrainFrameRect(frame, to: NSScreen.main), display: true)
            }
        }
    }
}

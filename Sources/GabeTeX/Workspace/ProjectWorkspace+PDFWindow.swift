import SwiftUI
import AppKit

// MARK: - Detachable PDF preview

/// The preview can leave the project window and live in a window of its own (second display, free placement).
/// Both places show the *same* `PDFPreviewController`, so reloads, highlights and PDF → source sync behave
/// identically; only the view that displays it moves.
///
/// The detached state is remembered per project: it is restored when the project opens again.
extension ProjectWorkspace {
    private var detachedKey: String { sessionKey("pdfDetached") }

    /// Whether the preview is on screen right now (docked and shown, or in its own window).
    var isPreviewOnScreen: Bool {
        isPreviewDetached ? pdfWindow?.isVisible == true : showPreview
    }

    // MARK: Detach / attach

    func togglePreviewDetached() {
        if isPreviewDetached { attachPreview() } else { detachPreview() }
    }

    /// Moves the preview into its own window ("Open PDF in Separate Window").
    /// - Parameter restoring: the project is opening and remembers the detached state: the PDF window appears
    ///   without taking the focus from the project window.
    func detachPreview(restoring: Bool = false) {
        if isPreviewDetached {
            focusPDFWindow()
            return
        }
        isPreviewDetached = true
        keepsFocusWhenPDFWindowOpens = restoring
        UserDefaults.standard.set(true, forKey: detachedKey)
        AppRouter.shared.openPDFWindow(for: folderURL)
    }

    /// Docks the preview in the project window again ("Attach PDF to Project Window").
    func attachPreview() {
        guard isPreviewDetached else { return }
        isPreviewDetached = false
        showPreview = true
        UserDefaults.standard.set(false, forKey: detachedKey)
        let closing = pdfWindow
        pdfWindow = nil
        closing?.close()
        bringWindowToFront()
    }

    /// ⌥⌘P: docked → show/hide; detached → bring the PDF window forward.
    func togglePreviewVisibility() {
        if isPreviewDetached {
            focusPDFWindow()
        } else {
            withAnimation(.smooth) { showPreview.toggle() }
        }
    }

    /// Brings the PDF window to the front and makes it key (opens it again if it got lost).
    func focusPDFWindow() {
        guard let pdfWindow else {
            AppRouter.shared.openPDFWindow(for: folderURL)
            return
        }
        if pdfWindow.isMiniaturized { pdfWindow.deminiaturize(nil) }
        pdfWindow.makeKeyAndOrderFront(nil)
    }

    /// Shows the preview wherever it is, for an explicit forward search: a hidden docked preview opens, a
    /// detached window comes forward *without* taking the key focus from the editor.
    func revealPreviewForSync() {
        if isPreviewDetached {
            guard let pdfWindow else {
                AppRouter.shared.openPDFWindow(for: folderURL)
                return
            }
            if pdfWindow.isMiniaturized { pdfWindow.deminiaturize(nil) }
            pdfWindow.orderFront(nil)
        } else if !showPreview {
            showPreview = true
        }
    }

    // MARK: Window events (called by `PDFWindowAccessor`)

    func pdfWindowDidOpen(_ window: NSWindow) {
        pdfWindow = window
        guard keepsFocusWhenPDFWindowOpens else { return }
        keepsFocusWhenPDFWindowOpens = false
        // The restored PDF window must not take the focus from the editor of the window being restored.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !self.stopped, let projectWindow = self.window else { return }
            projectWindow.makeKeyAndOrderFront(nil)
        }
    }

    /// The PDF window is closing. When the user closed it, the preview docks again; when the whole project is
    /// closing (or the app quits) the detached state stays, so the project reopens the same way.
    func pdfWindowWillClose() {
        pdfWindow = nil
        guard isPreviewDetached, !isClosingProject, !AppRouter.shared.isTerminating else { return }
        isPreviewDetached = false
        showPreview = true
        UserDefaults.standard.set(false, forKey: detachedKey)
    }

    /// The project window is closing: its PDF window goes with it.
    func projectWindowWillClose() {
        isClosingProject = true
        let closing = pdfWindow
        pdfWindow = nil
        closing?.close()
    }
}

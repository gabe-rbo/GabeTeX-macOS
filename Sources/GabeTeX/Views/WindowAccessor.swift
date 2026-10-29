import SwiftUI
import AppKit

/// Connects a project window to its workspace: proxy icon, edited dot, closing with unsaved changes,
/// and stopping the workspace when the window goes away.
struct WindowAccessor: NSViewRepresentable {
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
        private var closeGuard: WindowCloseGuard?
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let workspace else { return }
            workspace.window = window
            window.representedURL = workspace.folderURL
            window.isDocumentEdited = workspace.hasUnsavedChanges
            if closeGuard == nil {
                let guardian = WindowCloseGuard(workspace: workspace, window: window)
                guardian.original = window.delegate
                window.delegate = guardian
                closeGuard = guardian
            }
            if closeObserver == nil {
                closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak workspace] _ in
                    // The detached PDF window goes with its project window, in the same step.
                    MainActor.assumeIsolated { workspace?.projectWindowWillClose() }
                    Task { @MainActor in workspace?.stop() }
                }
            }
        }

        isolated deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }
}

/// Window delegate proxy: asks about unsaved changes before closing and forwards everything else
/// to the delegate SwiftUI installed.
///
/// `nonisolated` so the Objective-C forwarding overrides keep the isolation of `NSObject`; AppKit only
/// calls them on the main thread, and the delegate callback itself is `@MainActor`.
nonisolated final class WindowCloseGuard: NSObject, NSWindowDelegate {
    /// SwiftUI’s own delegate. Held strongly: `NSWindow.delegate` is weak, so once this guard replaces it
    /// nothing else may be keeping it alive. (No cycle: SwiftUI’s delegate does not retain the guard.)
    var original: NSWindowDelegate?
    private weak var workspace: ProjectWorkspace?
    private weak var window: NSWindow?
    private var allowClose = false

    init(workspace: ProjectWorkspace, window: NSWindow) {
        self.workspace = workspace
        self.window = window
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return original?.windowShouldClose?(sender) ?? true }
        guard let workspace, workspace.hasUnsavedChanges else {
            return original?.windowShouldClose?(sender) ?? true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Do you want to save the changes you made to “\(workspace.displayName)”?")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        alert.beginSheetModal(for: sender) { [weak self, weak workspace] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if workspace?.saveAll() ?? true {
                    self.allowClose = true
                    sender.close()
                }
            case .alertThirdButtonReturn:
                self.allowClose = true
                sender.close()
            default:
                break
            }
        }
        return false
    }
}

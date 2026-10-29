import AppKit
import SwiftUI
import TeXToolchain

/// Bridges AppKit-only events: Finder/Dock opens, Dock-icon reopen, quit with unsaved changes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run GabeTeX` (unbundled) behave like a regular app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.activate()
        SystemCloseItemRemover.shared.start()
        // View ▸ Customize Touch Bar… (AppKit shows it only on Macs with a Touch Bar).
        NSApplication.shared.isAutomaticCustomizeTouchBarMenuItemEnabled = true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppRouter.shared.handleOpen(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppRouter.shared.showWelcome() }
        return flag
    }

    /// Stops running compiles so latexmk (which runs in its own process group) does not outlive the app.
    /// Cancelling a task is asynchronous, so whatever is still running is killed synchronously afterwards.
    func applicationWillTerminate(_ notification: Notification) {
        AppRouter.shared.isTerminating = true
        for workspace in WorkspaceRegistry.shared.all { workspace.stop() }
        LaTeXCompiler.terminateAllRunningProcesses()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = WorkspaceRegistry.shared.dirty
        guard !dirty.isEmpty else {
            AppRouter.shared.isTerminating = true
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        let names = ListFormatter.localizedString(byJoining: dirty.map(\.displayName))
        alert.messageText = String(localized: "Do you want to save the changes you made?")
        alert.informativeText = String(localized: "Unsaved changes in \(names) will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard dirty.allSatisfy({ $0.saveAll() }) else { return .terminateCancel }
            AppRouter.shared.isTerminating = true
            return .terminateNow
        case .alertThirdButtonReturn:
            AppRouter.shared.isTerminating = true
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

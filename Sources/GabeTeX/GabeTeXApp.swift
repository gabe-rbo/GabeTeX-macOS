import SwiftUI
import AppKit

/// GabeTeX — a native LaTeX editor.
///
/// Scenes: the Welcome window, one window per project, the New Project window and Settings.
@main
struct GabeTeXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Lets `swift run GabeTeX` (unbundled) show a regular app with a Dock icon and menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Welcome to GabeTeX", id: "welcome") {
            WelcomeView()
                .capturesWindowActions()
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)

        WindowGroup(id: "project", for: ProjectReference.self) { $reference in
            if let reference {
                ProjectWindow(reference: reference)
            }
        }
        .defaultSize(width: 1320, height: 840)
        .commands { AppCommands() }

        // The PDF preview in a window of its own (View ▸ Open PDF in Separate Window). The project
        // brings it back by itself, so the system must not restore it.
        WindowGroup(id: "pdf", for: PDFWindowReference.self) { $reference in
            if let reference {
                DetachedPDFWindow(reference: reference)
            }
        }
        .defaultSize(width: 760, height: 940)
        .restorationBehavior(.disabled)

        Window("New Project", id: "new-project") {
            NewProjectView()
                .capturesWindowActions()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
        }
    }
}

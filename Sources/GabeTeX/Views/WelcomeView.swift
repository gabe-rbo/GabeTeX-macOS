import SwiftUI
import AppKit

/// The Welcome window: app identity, the three ways to start, and recent projects (see `RecentProjectsColumn`).
struct WelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    private let router = AppRouter.shared

    /// Only the very first appearance (app launch) may close itself when project windows were restored
    /// or a Finder open is pending; reopening Welcome from the menu must always stay open.
    private static var didHandleLaunch = false

    /// At launch the window stays invisible until it is clear that nothing else is being opened, so a
    /// restored project or a Finder/Dock open never flashes the Welcome window first.
    @LocalState private var veiled = !WelcomeView.didHandleLaunch

    var body: some View {
        HStack(spacing: 0) {
            hero
                .frame(width: 300)
            Divider()
            RecentProjectsColumn()
                .frame(width: 380)
        }
        .frame(height: 440)
        .containerBackground(.regularMaterial, for: .window)
        .dropDestination(for: URL.self) { urls, _ in
            router.handleOpen(urls: urls)
            return !urls.isEmpty
        }
        .background(WindowVeil(hidden: veiled))
        .task {
            guard !Self.didHandleLaunch else { return }
            Self.didHandleLaunch = true
            // Restored project windows and Finder/Dock opens arrive within a few hundred milliseconds.
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(50))
                if router.hasProjectWindows || router.launchOpenReceived {
                    dismissWindow(id: "welcome")
                    return
                }
            }
            veiled = false
        }
    }

    // MARK: Left column

    private var hero: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                .accessibilityHidden(true)
            Text("GabeTeX")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .padding(.top, 14)
            Text("A LaTeX editor for projects, not just files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.horizontal, 28)
            Spacer(minLength: 20)
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    Button {
                        openWindow(id: "new-project")
                    } label: {
                        Label("New Project…", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .help("Create a project from a template (⇧⌘N)")

                    Button {
                        router.chooseFolderAndOpen()
                    } label: {
                        Label("Open Folder…", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .help("Open a folder as a project (⌘O)")

                    Button {
                        router.chooseFileAndOpen()
                    } label: {
                        Label("Open File…", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .help("Open a .tex file; its folder becomes the project (⌥⌘O)")
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 36)
            Spacer(minLength: 32)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Keeps the hosting window fully transparent (and click-through) while `hidden`, then fades it in.
private struct WindowVeil: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> VeilView {
        let view = VeilView()
        view.veiled = hidden
        return view
    }

    func updateNSView(_ view: VeilView, context: Context) {
        view.setVeiled(hidden)
    }

    final class VeilView: NSView {
        var veiled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply(animated: false)
        }

        func setVeiled(_ value: Bool) {
            guard value != veiled else { return }
            veiled = value
            apply(animated: true)
        }

        private func apply(animated: Bool) {
            guard let window else { return }
            if veiled {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            } else {
                window.ignoresMouseEvents = false
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18
                        window.animator().alphaValue = 1
                    }
                } else {
                    window.alphaValue = 1
                }
            }
        }
    }
}

import SwiftUI
import AppKit
import EditorKit

/// Shows the command palette (⇧⌘P) as a borderless glass panel at the top of the key window — the project window
/// or the detached PDF window — like Spotlight. The panel is a child window of that window (it moves with it) and
/// becomes key while open, so typing goes to its search field; it closes on Esc, ⇧⌘P, a click elsewhere, or
/// when a command runs. Running a command first gives the focus back to the window it was opened over, then
/// performs the command there (commands that need the editor bring the project window forward themselves).
final class CommandPaletteController {
    static let shared = CommandPaletteController()

    static let width: CGFloat = 640
    /// Distance between the top of the window's content area (below the toolbar) and the palette.
    static let topInset: CGFloat = 36

    private var panel: CommandPalettePanel?
    private var model: CommandPaletteModel?
    private weak var host: NSWindow?
    private weak var workspace: ProjectWorkspace?
    private var observers: [NSObjectProtocol] = []

    var isShown: Bool { panel != nil }

    /// Opens the palette for `workspace` over its project window (or its PDF window), or closes it when it is
    /// already open for that workspace.
    func toggle(for workspace: ProjectWorkspace, inPDFWindow: Bool) {
        if isShown, self.workspace === workspace {
            close()
        } else {
            show(for: workspace, inPDFWindow: inPDFWindow)
        }
    }

    func show(for workspace: ProjectWorkspace, inPDFWindow: Bool) {
        close(restoringFocus: false)
        let preferredHost = inPDFWindow ? workspace.pdfWindow : workspace.window
        guard let host = preferredHost ?? NSApp.keyWindow, host.isVisible else { return }
        if host.isMiniaturized { host.deminiaturize(nil) }

        let model = CommandPaletteModel(workspace: workspace, inPDFWindow: inPDFWindow)
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: model.preferredHeight),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: CommandPaletteView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting

        model.onRun = { [weak self] id in self?.run(id) }
        model.onClose = { [weak self] in self?.close() }
        model.onHeightChange = { [weak self] height in self?.resize(height: height) }

        self.panel = panel
        self.model = model
        self.host = host
        self.workspace = workspace
        panel.setFrame(frame(height: model.preferredHeight, over: host), display: false)
        host.addChildWindow(panel, ordered: .above)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        panel.invalidateShadow()
        workspace.isCommandPalettePresented = true
        observe(panel: panel, host: host)
    }

    /// Closes the palette. With `restoringFocus` the window it was opened over becomes key again.
    func close(restoringFocus: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        model = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        workspace?.isCommandPalettePresented = false
        if restoringFocus, let host, host.isVisible { host.makeKeyAndOrderFront(nil) }
    }

    // MARK: Running

    private func run(_ id: CommandID) {
        guard let command = CommandRegistry.shared[id], let model else { return }
        let workspace = self.workspace
        let inPDFWindow = model.inPDFWindow
        guard command.isEnabled(CommandContext.live(workspace: workspace, inPDFWindow: inPDFWindow)) else {
            NSSound.beep()
            return
        }
        CommandRecents.shared.note(id)
        close(restoringFocus: true)
        // On the next turn, once the window is key again (and its menu state is current).
        Task { @MainActor in
            command.perform(CommandContext.live(workspace: workspace, inPDFWindow: inPDFWindow))
        }
    }

    // MARK: Geometry

    private func frame(height: CGFloat, over host: NSWindow) -> NSRect {
        let content = host.convertToScreen(host.contentLayoutRect)
        let width = min(Self.width, max(320, content.width - 40))
        let top = content.maxY - Self.topInset
        return NSRect(x: (content.midX - width / 2).rounded(), y: (top - height).rounded(), width: width, height: height)
    }

    /// Keeps the top edge where it is (the list grows and shrinks downwards).
    private func resize(height: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: Observation

    private func observe(panel: NSWindow, host: NSWindow) {
        let center = NotificationCenter.default
        // A click elsewhere (or another app) takes the key status: close without stealing the focus back.
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoringFocus: false) }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: host, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoringFocus: false) }
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
    }

    private func reposition() {
        guard let panel, let host else { return }
        panel.setFrame(frame(height: panel.frame.height, over: host), display: true)
    }
}

/// The palette's window: borderless, may become key (for the search field), never main. Esc and the palette's own
/// shortcut close it.
final class CommandPalettePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let combo = ShortcutStore.shared.combo(for: .commandPalette), combo.matches(event) {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

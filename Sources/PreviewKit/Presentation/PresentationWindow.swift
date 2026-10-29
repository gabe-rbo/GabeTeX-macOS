import AppKit
import SwiftUI

/// A borderless full-screen window of a presentation: the slides (audience) or the presenter view, depending on
/// its stage's mode.
///
/// Every key press goes to the presentation first (`PresentationController.handleKeyDown`), whatever view has the
/// focus, so Space or Return never "press" a focused button of the presenter view; ⌘ shortcuts still reach the
/// menus. Closing the window (or ⌘W) ends the presentation.
public final class PresentationWindow: NSWindow {
    /// The window's content.
    public let stage: PresentationStageView
    /// The presentation; nil once it ended.
    public private(set) weak var controller: PresentationController?

    /// Builds a window for `controller` without showing it (the controller orders it on screen; checks keep it
    /// offscreen).
    public init(controller: PresentationController, mode: PresentationStageView.Mode,
                contentRect: CGRect = CGRect(x: 0, y: 0, width: 1280, height: 800)) {
        self.controller = controller
        self.stage = PresentationStageView(controller: controller, mode: mode)
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = .disallowed
        animationBehavior = .none
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isExcludedFromWindowsMenu = true
        title = String(localized: "\(controller.title) — Presentation")
        stage.frame = CGRect(origin: .zero, size: contentRect.size)
        stage.autoresizingMask = [.width, .height]
        contentView = stage
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    /// Borderless windows may cover the menu bar: no constraining to the visible frame.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Fills `screen` (menu bar and Dock included).
    func place(on screen: NSScreen) {
        if frame != screen.frame { setFrame(screen.frame, display: true) }
    }

    /// Gives the keyboard focus to the visible stage content.
    func focusStage() {
        makeFirstResponder(stage.focusTarget)
    }

    /// Closes the window for good without ending the presentation again (the controller is ending it, or moving to
    /// a single display).
    func dismiss() {
        controller = nil
        orderOut(nil)
        close()
    }

    private var didClose = false

    // MARK: Events

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let controller, controller.handleKeyDown(event) { return }
        super.sendEvent(event)
    }

    public override func performClose(_ sender: Any?) {
        if let controller { controller.end() } else { close() }
    }

    /// Closing ends the presentation (unless the controller is the one closing it).
    public override func close() {
        guard !didClose else { return }
        didClose = true
        let ending = controller
        controller = nil
        stage.detach()
        super.close()
        ending?.end()
    }

    public override func cancelOperation(_ sender: Any?) {
        controller?.perform(.escape)
    }

    // MARK: Touch Bar

    public override func makeTouchBar() -> NSTouchBar? {
        guard let controller else { return nil }
        return PresentationTouchBarProvider(controller: controller).makeTouchBar()
    }
}

/// The content of a presentation window: the slides on black, or the presenter view.
public final class PresentationStageView: NSView {
    public enum Mode: Hashable, Sendable {
        case audience
        case presenter
    }

    public private(set) var mode: Mode
    /// The slides (always present; hidden while the presenter view shows).
    public let audienceView: AudienceSlidesView
    /// The presenter view, created the first time it is needed.
    public private(set) var presenterHost: NSView?
    private weak var controller: PresentationController?

    init(controller: PresentationController, mode: Mode) {
        self.controller = controller
        self.mode = mode
        self.audienceView = AudienceSlidesView(controller: controller)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        audienceView.frame = bounds
        audienceView.autoresizingMask = [.width, .height]
        addSubview(audienceView)
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var isOpaque: Bool { true }

    /// Shows the slides or the presenter view.
    public func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        applyMode()
    }

    /// The view that should have the keyboard focus.
    var focusTarget: NSView { mode == .presenter ? (presenterHost ?? self) : audienceView }

    private func applyMode() {
        let presenting = mode == .presenter
        if presenting, presenterHost == nil, let controller {
            let host = NSHostingView(rootView: PresenterView(controller: controller))
            host.appearance = NSAppearance(named: .darkAqua)
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            presenterHost = host
        }
        presenterHost?.isHidden = !presenting
        audienceView.isHidden = presenting
        audienceView.isAudienceVisible = !presenting
    }

    /// Lets go of the controller's views (the window is closing).
    func detach() {
        presenterHost?.removeFromSuperview()
        presenterHost = nil
        audienceView.isAudienceVisible = false
    }
}

/// The audience view: the current slide on black, the black / white screen, a click advances, the pointer hides
/// after a moment. With a single display it also shows the slide number being typed (bottom right).
public final class AudienceSlidesView: NSView, PresentationRefreshing {
    public let slideView = SlideLayerView(frame: .zero)
    private let blankView = NSView(frame: .zero)
    private var digitsHost: NSHostingView<TypedSlideBadge>?
    private weak var controller: PresentationController?
    private var trackingArea: NSTrackingArea?
    /// False while hidden behind the presenter view (no transitions, no pointer hiding).
    var isAudienceVisible = true

    init(controller: PresentationController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        slideView.renderer = controller.renderer
        slideView.playsTransitions = true
        slideView.prefetchOffsets = [1, 2, -1]
        slideView.frame = bounds
        slideView.autoresizingMask = [.width, .height]
        addSubview(slideView)

        blankView.wantsLayer = true
        blankView.layer?.backgroundColor = NSColor.black.cgColor
        blankView.alphaValue = 0
        blankView.isHidden = true
        blankView.frame = bounds
        blankView.autoresizingMask = [.width, .height]
        addSubview(blankView)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        controller.addListener(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The blank screen currently shown (for checks).
    public private(set) var shownBlank = PresentationBlank.none

    func presentationDidChange(transition: SlideTransition?) {
        guard let controller else { return }
        let navigator = controller.navigator
        let deck = controller.deck
        slideView.show(deck: deck, page: deck.pageCount > 0 ? navigator.currentIndex : nil, part: .slide,
                       transition: isAudienceVisible ? transition : nil)
        setBlank(navigator.blank)
        setAccessibilityLabel(deck.pageCount > 0
            ? String(localized: "Slide \(navigator.currentIndex + 1) of \(deck.pageCount)")
            : String(localized: "No slides"))
        updateDigitsBadge(controller)
    }

    private func setBlank(_ blank: PresentationBlank) {
        guard blank != shownBlank else { return }
        let previous = shownBlank
        shownBlank = blank
        let animated = isAudienceVisible && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if blank != .none {
            blankView.layer?.backgroundColor = (blank == .white ? NSColor.white : NSColor.black).cgColor
            blankView.isHidden = false
            let fromBlank = previous != .none
            if animated && !fromBlank {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    blankView.animator().alphaValue = 1
                }
            } else {
                blankView.alphaValue = 1
            }
        } else if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                blankView.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.shownBlank == .none else { return }
                    self.blankView.isHidden = true
                }
            })
        } else {
            blankView.alphaValue = 0
            blankView.isHidden = true
        }
    }

    /// The typed slide number, shown on the slides only when there is no presenter display to show it.
    private func updateDigitsBadge(_ controller: PresentationController) {
        let digits = controller.navigator.typedDigits
        let showsBadge = !digits.isEmpty && controller.layout == .single(showsPresenter: false)
        guard showsBadge else {
            digitsHost?.isHidden = true
            return
        }
        let badge = TypedSlideBadge(digits: digits, pageCount: controller.pageCount)
        if let digitsHost {
            digitsHost.rootView = badge
            digitsHost.isHidden = false
        } else {
            let host = NSHostingView(rootView: badge)
            host.appearance = NSAppearance(named: .darkAqua)
            addSubview(host)
            digitsHost = host
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        if let digitsHost {
            let size = digitsHost.fittingSize
            digitsHost.frame = CGRect(x: bounds.maxX - size.width - 32, y: bounds.minY + 32,
                                      width: size.width, height: size.height)
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        controller?.perform(.next)
    }

    public override func rightMouseDown(with event: NSEvent) {
        controller?.perform(.previous)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        if isAudienceVisible { controller?.pointerMoved() }
    }
}

/// "Go to slide 12" on the slides (one display, presenter view hidden).
struct TypedSlideBadge: View {
    var digits: String
    var pageCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: digits)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
            Text(verbatim: "/ \(pageCount)")
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Go to slide \(digits)"))
    }
}

import AppKit
import PDFKit

/// Where the reader is in the document: enough to put the same piece of paper back under the same pixel
/// after the PDF has been regenerated.
struct PDFViewState {
    /// 0-based page under the top-left corner of the visible area.
    var pageIndex: Int
    /// The visible area's top-left corner, in PDF page space (origin bottom-left; may lie slightly
    /// outside the page when the corner is in the gap above it).
    var pointInPage: CGPoint
    var scale: CGFloat
    /// `true` when the zoom was following the width of the view ("fit width").
    var autoScales: Bool
}

/// `PDFView` tuned for a live LaTeX preview.
///
/// - `replaceDocument(_:)` swaps in a regenerated document keeping the scroll position (page + point inside
///   the page) and the zoom. Swap, zoom restore and scroll restore happen synchronously in one Core Animation
///   transaction with implicit animations off, so the compositor never sees an intermediate state.
/// - "Fit width" is computed here against the width that is really visible (see `fitsWidth`) and followed on resize.
/// - Sync gestures (double-click or ⌘-click, see `PDFSyncTrigger`) are reported as `onSyncClick`; ordinary clicks
///   (selection, links) are left to PDFKit. The gesture code lives in `GabePDFView+Sync.swift`.
/// - `presentHighlights(_:)` paints forward-search rectangles in an overlay view (never as annotations).
/// - A view can be re-hosted: the controller hands its document and reading position to a newer view (another
///   window, say) and retires the old one for good (`isRetired`).
public final class GabePDFView: PDFView {
    // MARK: Wiring (set by `PDFPreviewController`)

    /// The sync gesture was performed on text (or on a page): where, which word, what context.
    var onSyncClick: ((PDFSyncClick) -> Void)?
    /// Called whenever the scroll position, zoom, page count or size changed.
    var onViewportChange: (() -> Void)?
    weak var controller: PDFPreviewController?
    /// Set once a newer view took over the controller (or this view was dismantled). A retired view never attaches
    /// again, so a late SwiftUI update of the old view cannot steal the callbacks back.
    var isRetired = false

    // MARK: State

    let highlightOverlay = PDFHighlightOverlayView(frame: .zero)
    private var retiredDocuments: [PDFDocument] = []
    private weak var observedClipView: NSClipView?
    var activeHighlights: [PDFHighlight] = []
    var deferredHighlights: (items: [PDFHighlight], scroll: PDFHighlightScroll)?
    private var highlightTask: Task<Void, Never>?
    private var pendingScrollRestore: PDFViewState?
    /// The primary mouse button went down on a ⌘-click that was reported (and kept from PDFKit): its drag and
    /// release are swallowed too.
    var swallowsMouseSequence = false
    /// The backing scale or the screen changed: refit and re-place the highlights at the next layout.
    private var needsBackingRefit = false
    private weak var observedWindow: NSWindow?
    /// Where the pointer is now, in window coordinates. Replaceable so checks can drive the view without a mouse.
    var pointerLocation: (NSWindow) -> NSPoint = { $0.mouseLocationOutsideOfEventStream }
    /// Until this time a zoom that differs from the one this view applied is attributed to the display change, not
    /// to the user.
    private var scaleDriftIgnoredUntil: CFTimeInterval = 0

    /// `true` while the zoom follows the width of the view ("fit width").
    ///
    /// PDFKit's own `autoScales` is never switched on: it fits the page to the full width of the *view* and
    /// ignores the thickness of a legacy scroller (mouse attached / "always show scroll bars"), which pushes the
    /// right margin and the edge of every page 17 pt out of sight. This view does the fitting itself against the
    /// width that is really visible (`refitIfNeeded()`), and stops following when the zoom is changed by anyone else
    /// (pinch, menu command).
    private(set) var fitsWidth = true
    /// The last zoom this view set itself; a different `scaleFactor` means the user zoomed.
    private var appliedScale: CGFloat = 1
    /// > 0 while this view changes document / zoom itself, so notifications are not mistaken for user zooming.
    private var programmaticDepth = 0
    private var isRefitting = false

    private static let highlightHold: Duration = .milliseconds(1500)
    private static let highlightFade: CFTimeInterval = 0.5

    // MARK: Lifecycle

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        // PDFKit measures these in page space, so they grow with the zoom: at "fit width" (~125 %) that is
        // ≈ 12 pt beside each page and ≈ 20 pt between pages.
        pageBreakMargins = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        minScaleFactor = PDFPreviewController.minimumScale
        maxScaleFactor = PDFPreviewController.maximumScale
        autoScales = false // see `fitsWidth`
        interpolationQuality = .high
        applyBackground()
        addSubview(highlightOverlay)
        setAccessibilityLabel(String(localized: "PDF preview"))

        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDocumentChanged,
                     .PDFViewDisplayModeChanged, .PDFViewVisiblePagesChanged] {
            center.addObserver(self, selector: #selector(viewportDidChange(_:)), name: name, object: self)
        }
        // The scroller style decides how much width is really visible.
        center.addObserver(self, selector: #selector(scrollerStyleDidChange(_:)),
                           name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    @objc private func scrollerStyleDidChange(_ notification: Notification) {
        needsLayout = true
    }

    // MARK: Appearance

    /// A calm backdrop that blends with the window: the window background, a touch darker, so the white pages
    /// (and their shadows) stand out in Light and Dark mode alike.
    private func applyBackground() {
        var resolved = NSColor.windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.windowBackgroundColor
            resolved = base.blended(withFraction: 0.07, of: .black) ?? base
        }
        backgroundColor = resolved
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
        highlightOverlay.refreshColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackground()
        observeScrolling()
        observeWindow()
        // A different window may sit on a display with another backing scale.
        backingPropertiesDidChange()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backingPropertiesDidChange()
    }

    // MARK: Backing scale

    /// Pixels per point of the display the view is on (2 on Retina, 1 on a plain display, 3 on some).
    var backingScale: CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return scale >= 1 ? scale : 2
    }

    /// The window moved to a display with another scale (or another screen): keep the highlights on the pixel grid
    /// and, while following the width, fit again – PDFKit may report a different zoom while it re-renders, which
    /// must not be mistaken for the user zooming.
    private func backingPropertiesDidChange() {
        scaleDriftIgnoredUntil = CACurrentMediaTime() + 0.75
        needsBackingRefit = true
        needsLayout = true
        highlightOverlay.updateBackingScale(backingScale)
        layoutHighlights()
    }

    /// Follows the window's screen / backing-scale notifications (also fired when the scale stays the same).
    private func observeWindow() {
        guard window !== observedWindow else { return }
        let center = NotificationCenter.default
        if let old = observedWindow {
            center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: old)
            center.removeObserver(self, name: NSWindow.didChangeBackingPropertiesNotification, object: old)
        }
        observedWindow = window
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowDisplayDidChange(_:)),
                           name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(self, selector: #selector(windowDisplayDidChange(_:)),
                           name: NSWindow.didChangeBackingPropertiesNotification, object: window)
    }

    @objc private func windowDisplayDidChange(_ notification: Notification) {
        backingPropertiesDidChange()
    }

    public override func layout() {
        super.layout()
        observeScrolling()
        if needsBackingRefit, !bounds.isEmpty, document != nil {
            needsBackingRefit = false
            if fitsWidth { refit(force: true) }
        }
        if !bounds.isEmpty, document != nil {
            refitIfNeeded()
            if let state = pendingScrollRestore {
                pendingScrollRestore = nil
                restoreScroll(state)
            }
            if let deferred = deferredHighlights, window != nil {
                deferredHighlights = nil
                presentHighlights(deferred.items, scroll: deferred.scroll)
            }
        }
        layoutHighlights()
    }

    // MARK: Geometry helpers

    /// The area of the view that actually shows pages (the scroll view's clip area minus content insets), in
    /// view coordinates.
    var visibleContentRect: CGRect {
        guard let scrollView = documentView?.enclosingScrollView, let parent = scrollView.contentView.superview else {
            return bounds
        }
        var rect = convert(scrollView.contentView.frame, from: parent)
        let insets = scrollView.contentInsets
        rect.origin.x += insets.left
        rect.size.width -= insets.left + insets.right
        rect.origin.y += isFlipped ? insets.top : insets.bottom
        rect.size.height -= insets.top + insets.bottom
        return rect.width > 0 && rect.height > 0 ? rect : bounds
    }

    /// Top-left corner of the visible content area, in view coordinates.
    var visibleTopLeft: CGPoint {
        let rect = visibleContentRect
        return CGPoint(x: rect.minX, y: isFlipped ? rect.minY : rect.maxY)
    }

    var visibleCenter: CGPoint {
        let rect = visibleContentRect
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// 0-based index of the page at the centre of the view, if any.
    var centerPageIndex: Int? {
        guard let document, document.pageCount > 0,
              let page = page(for: visibleCenter, nearest: true) else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    /// Scrolls so that `pagePoint` (PDF page space) lands on `target` (view coordinates).
    /// Works on the scroll view directly: `go(to:)` clamps destinations that lie outside the page.
    func scroll(pagePoint: CGPoint, on page: PDFPage, toViewPoint target: CGPoint) {
        guard let scrollView = documentView?.enclosingScrollView else {
            go(to: PDFDestination(page: page, at: pagePoint))
            return
        }
        let clip = scrollView.contentView
        let current = clip.convert(convert(pagePoint, from: page), from: self)
        let wanted = clip.convert(target, from: self)
        var origin = clip.bounds.origin
        origin.x += current.x - wanted.x
        origin.y += current.y - wanted.y
        origin = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(origin.x - clip.bounds.origin.x) > 0.01 || abs(origin.y - clip.bounds.origin.y) > 0.01 else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Reading position

    /// The current reading position, or `nil` without a laid-out document.
    func captureViewState() -> PDFViewState? {
        guard let document, document.pageCount > 0 else { return nil }
        let anchor = visibleTopLeft
        guard let page = page(for: anchor, nearest: true) else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        return PDFViewState(pageIndex: index, pointInPage: convert(anchor, to: page),
                            scale: scaleFactor, autoScales: fitsWidth)
    }

    /// Re-applies zoom (immediately) and scroll position (immediately, or at the first layout with a size).
    func restore(_ state: PDFViewState) {
        programmatically {
            fitsWidth = state.autoScales
            if state.autoScales {
                if let fit = fitWidthScale { setScale(fit) }
            } else {
                setScale(state.scale)
            }
            layoutDocumentView()
        }
        if bounds.isEmpty || window == nil {
            pendingScrollRestore = state
        } else {
            restoreScroll(state)
        }
    }

    private func restoreScroll(_ state: PDFViewState) {
        guard let document, document.pageCount > 0 else { return }
        let index = min(max(state.pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        var point = state.pointInPage
        if index != state.pageIndex {
            // The document got shorter than the reader's position: stay at the top of the last page.
            let box = page.bounds(for: displayBox)
            point = CGPoint(x: box.minX, y: box.maxY)
        }
        scroll(pagePoint: point, on: page, toViewPoint: visibleTopLeft)
    }

    // MARK: Document swap

    /// Shows `newDocument` in place of the current one without flash or jump: position and zoom are
    /// preserved (`fallbackState` is used when no document is currently shown, e.g. when SwiftUI re-created the
    /// view). The very first document is fitted to the width.
    ///
    /// Everything happens synchronously inside one transaction with actions disabled: PDFKit's page layers are
    /// plain `CALayer`s, which would otherwise animate their frames and contents implicitly (a visible slide /
    /// cross-fade of pages after every build).
    func replaceDocument(_ newDocument: PDFDocument, fallbackState: PDFViewState? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let current = document != nil ? captureViewState() : nil
        let state = current ?? fallbackState
        if let old = document { retire(old) }

        programmatically {
            document = newDocument
            layoutDocumentView()
        }
        observeScrolling()
        if let state {
            restore(state)
        } else {
            // First document: fitted to the width, shown from the top.
            programmatically {
                fitsWidth = true
                if let fit = fitWidthScale { setScale(fit) }
                layoutDocumentView()
            }
        }
        layoutHighlights()
        onViewportChange?()
    }

    /// Removes the document (the view shows only its background).
    func clearDocument() {
        highlightTask?.cancel()
        activeHighlights = []
        deferredHighlights = nil
        pendingScrollRestore = nil
        highlightOverlay.reset()
        if let old = document { retire(old) }
        document = nil
        onViewportChange?()
    }

    /// PDFKit keeps analysing / drawing the old document's pages in the background for a while ("Drawing a PDFPage
    /// when its PDFDocument is nil is unsupported"), so the old document outlives the swap by a few seconds.
    private func retire(_ old: PDFDocument) {
        retiredDocuments.append(old)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.retiredDocuments.removeAll { $0 === old }
        }
    }

    // MARK: Zoom

    /// Zooms to `scale` (clamped) keeping the point at the centre of the view in place.
    func zoom(to scale: CGFloat) {
        let target = min(max(scale, PDFPreviewController.minimumScale), PDFPreviewController.maximumScale)
        let anchorPoint = visibleCenter
        let anchor = page(for: anchorPoint, nearest: true).map { ($0, convert(anchorPoint, to: $0)) }
        programmatically {
            fitsWidth = false
            setScale(target)
            layoutDocumentView()
        }
        if let (page, point) = anchor { scroll(pagePoint: point, on: page, toViewPoint: visibleCenter) }
        onViewportChange?()
    }

    /// Stops following the width of the view; the zoom stays where it is.
    func stopFittingWidth() {
        fitsWidth = false
    }

    /// Fits the page width and keeps the reader on the same part of the document.
    func fitWidth() {
        fitsWidth = true
        refit(force: true)
        onViewportChange?()
    }

    /// The scale at which the page width exactly fills the part of the view that is really visible.
    private var fitWidthScale: CGFloat? {
        guard document != nil, bounds.width > 1 else { return nil }
        // PDFKit's value fits the full width of the view (page + page-break margins); shrink it by what a legacy
        // scroller takes away.
        let natural = scaleFactorForSizeToFit
        let visibleWidth = visibleContentRect.width
        guard natural.isFinite, natural > 0, visibleWidth > 1 else { return nil }
        let scale = natural * min(1, visibleWidth / bounds.width)
        return min(max(scale, PDFPreviewController.minimumScale), PDFPreviewController.maximumScale)
    }

    /// Re-fits after the view was resized (or the scroller style changed) while following the width.
    private func refitIfNeeded() {
        guard fitsWidth else { return }
        refit(force: false)
    }

    private func refit(force: Bool) {
        guard !isRefitting, let target = fitWidthScale, force || abs(target - scaleFactor) > 0.0005 else { return }
        isRefitting = true
        defer { isRefitting = false }
        let anchorPoint = visibleTopLeft
        let anchor = page(for: anchorPoint, nearest: true).map { ($0, convert(anchorPoint, to: $0)) }
        programmatically {
            setScale(target)
            layoutDocumentView()
        }
        if let (page, point) = anchor { scroll(pagePoint: point, on: page, toViewPoint: visibleTopLeft) }
    }

    private func setScale(_ scale: CGFloat) {
        appliedScale = scale
        if abs(scaleFactor - scale) > 0.00001 { scaleFactor = scale }
    }

    private func programmatically(_ body: () -> Void) {
        programmaticDepth += 1
        defer { programmaticDepth -= 1 }
        body()
    }

    /// Scrolls to the top of the document.
    func scrollToTop() {
        guard let first = document?.page(at: 0) else { return }
        go(to: first)
    }

    // MARK: Observing scrolling

    @objc private func viewportDidChange(_ notification: Notification) {
        if fitsWidth, programmaticDepth == 0, abs(scaleFactor - appliedScale) > 0.001 {
            if CACurrentMediaTime() < scaleDriftIgnoredUntil {
                needsBackingRefit = true // PDFKit re-rendered for another display: fit again instead of giving up
                needsLayout = true
            } else {
                fitsWidth = false // zoomed by the user (pinch, menu, keyboard)
            }
        }
        observeScrolling()
        layoutHighlights()
        onViewportChange?()
    }

    /// Subscribes to the inner scroll view's clip bounds (it is replaced when PDFKit rebuilds its views).
    private func observeScrolling() {
        guard let clip = documentView?.enclosingScrollView?.contentView, clip !== observedClipView else { return }
        let center = NotificationCenter.default
        if let old = observedClipView {
            center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
        }
        observedClipView = clip
        clip.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(viewportDidChange(_:)),
                           name: NSView.boundsDidChangeNotification, object: clip)
    }

    // MARK: Highlights

    /// Scrolls the first highlight to the middle of the view and flashes all of them for ~1.5 s.
    func presentHighlights(_ highlights: [PDFHighlight], scroll policy: PDFHighlightScroll = .center) {
        guard let document else { return }
        if bounds.isEmpty || window == nil {
            deferredHighlights = (highlights, policy)
            return
        }
        highlightTask?.cancel()
        deferredHighlights = nil
        activeHighlights = highlights.filter { highlight in
            let rect = highlight.rect
            return highlight.pageIndex >= 0 && highlight.pageIndex < document.pageCount
                && !rect.isNull && !rect.isInfinite
                && rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.size.width.isFinite && rect.size.height.isFinite
        }
        guard let first = activeHighlights.first, let page = document.page(at: first.pageIndex) else {
            highlightOverlay.reset()
            return
        }

        let box = first.rect.standardized
        if policy == .center || !isVisibleComfortably(box, on: page) {
            scroll(pagePoint: CGPoint(x: box.midX, y: box.midY), on: page, toViewPoint: visibleCenter)
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        layoutHighlights()
        highlightOverlay.present(animated: !reduceMotion)
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: Self.highlightHold)
            guard !Task.isCancelled, let self else { return }
            if reduceMotion {
                self.finishHighlights()
            } else {
                self.highlightOverlay.fadeOut(duration: Self.highlightFade)
                try? await Task.sleep(for: .seconds(Self.highlightFade + 0.05))
                guard !Task.isCancelled else { return }
                self.finishHighlights()
            }
        }
    }

    /// `true` when `rect` (page space) is fully inside the visible area with a little margin to spare.
    private func isVisibleComfortably(_ rect: CGRect, on page: PDFPage) -> Bool {
        let inView = convert(rect, from: page)
        let area = visibleContentRect.insetBy(dx: 12, dy: 24)
        return !area.isEmpty && area.contains(inView)
    }

    private func finishHighlights() {
        activeHighlights = []
        highlightOverlay.reset()
    }

    /// Pixels per point the highlight layers were last told about (for checks).
    var highlightOverlayBackingScale: CGFloat { highlightOverlay.backingScale }

    /// Frames of the highlight rectangles currently on screen, in view coordinates (for checks).
    var highlightRectsInView: [CGRect] {
        let origin = highlightOverlay.frame.origin
        return highlightOverlay.visibleRects.map { rect in
            let y = isFlipped ? (highlightOverlay.frame.maxY - rect.maxY) : (rect.minY + origin.y)
            return CGRect(x: rect.minX + origin.x, y: y, width: rect.width, height: rect.height)
        }
    }

    /// Converts the active highlights from page space to overlay space. Called on every scroll / zoom / resize and
    /// when the display (backing scale) changes. Everything is snapped outward to the pixel grid of the current
    /// display so the edges stay crisp on 1x, 2x and 3x screens alike.
    private func layoutHighlights() {
        guard !activeHighlights.isEmpty, let document else { return }
        let scale = backingScale
        highlightOverlay.updateBackingScale(scale)
        let frame = visibleContentRect.pixelAligned(scale: scale)
        highlightOverlay.frame = frame
        var rects: [CGRect] = []
        for highlight in activeHighlights {
            guard let page = document.page(at: highlight.pageIndex) else { continue }
            var rect = convert(highlight.rect.standardized, from: page)
            // A little air around the glyphs, and never thinner than a visible chip.
            rect = rect.insetBy(dx: -2.5, dy: -1.5)
            if rect.width < 8 { rect = rect.insetBy(dx: (rect.width - 8) / 2, dy: 0) }
            if rect.height < 8 { rect = rect.insetBy(dx: 0, dy: (rect.height - 8) / 2) }
            rect = rect.pixelAligned(scale: scale)
            guard rect.intersects(frame) else { continue }
            let x = rect.minX - frame.minX
            let y = isFlipped ? (frame.maxY - rect.maxY) : (rect.minY - frame.minY)
            rects.append(CGRect(x: x, y: y, width: rect.width, height: rect.height))
        }
        highlightOverlay.setRects(rects)
    }

    /// Highlights still waiting for a window / a size. Handed back to the controller when a newer view takes over,
    /// so the request is not lost.
    func takeDeferredHighlights() -> (items: [PDFHighlight], scroll: PDFHighlightScroll)? {
        defer { deferredHighlights = nil }
        return deferredHighlights
    }

    // MARK: Mouse (sync gestures, see `GabePDFView+Sync.swift`)

    /// A ⌘-click that is a sync gesture goes to this view instead of PDFKit's page views, so it cannot start a
    /// selection or follow a link. Everything else is delivered the usual way.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let event = NSApp?.currentEvent, syncGesture(for: event) == .commandClick,
           let hit, let documentView, hit === documentView || hit.isDescendant(of: documentView) {
            return self
        }
        return hit
    }

    public override func mouseDown(with event: NSEvent) {
        swallowsMouseSequence = false
        switch syncGesture(for: event) {
        case .commandClick:
            swallowsMouseSequence = true
            reportSyncClick(for: event)
        case .doubleClick:
            super.mouseDown(with: event) // PDFKit selects the word, as for any double-click
            // PDFKit may follow the pointer until the button is released: a drag (extending the selection by words,
            // dragging the selected text) is not a click.
            if pointerStayedNear(event) { reportSyncClick(for: event) }
        case nil:
            super.mouseDown(with: event)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if swallowsMouseSequence { return }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if swallowsMouseSequence {
            swallowsMouseSequence = false
            return
        }
        super.mouseUp(with: event)
    }
}

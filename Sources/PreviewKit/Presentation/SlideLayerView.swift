import AppKit
import SwiftUI

/// Shows one slide (or the notes half of a page) aspect-fitted on a solid backdrop, from a bitmap rendered at
/// exactly the pixel size it occupies on its display.
///
/// Changing the page keeps the previous image until the new one is ready (usually it is: neighbours are rendered
/// ahead, see `prefetchOffsets`), then swaps it — with the page's transition when `playsTransitions` is on and
/// Reduce Motion is off. A reload (new deck generation) swaps without a transition, so live reloads never flash.
public final class SlideLayerView: NSView {
    /// Where images come from. Setting another renderer redraws.
    public var renderer: SlideRenderer? {
        didSet {
            guard renderer !== oldValue else { return }
            shownKey = nil
            needsLayout = true
        }
    }

    /// Plays page transitions when the page changes (the audience view).
    public var playsTransitions = false
    /// Pages to render ahead, relative to the page shown (e.g. `[1, 2, -1]`).
    public var prefetchOffsets: [Int] = []
    /// Called on a click; nil leaves clicks to the views behind (the audience view advances on a click).
    public var onClick: (() -> Void)?

    /// Letterbox color around the slide.
    public var backdropColor: NSColor = .black {
        didSet { applyBackdrop() }
    }

    /// Rounded corners of the whole view (the presenter's slide thumbnails).
    public var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = cornerRadius > 0
        }
    }

    public private(set) var deck = SlideDeck.empty
    public private(set) var pageIndex: Int?
    public private(set) var part = SlidePart.slide

    /// The image on screen (for checks and diagnostics).
    public private(set) var shownKey: SlideImageKey?
    /// Frame of the slide image inside the view.
    public var imageFrame: CGRect { imageLayer.frame }
    /// `true` once an image is on screen.
    public var hasImage: Bool { imageLayer.contents != nil }

    private let imageLayer = CALayer()
    private var wantedKey: SlideImageKey?
    private var pendingTransition: SlideTransition?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(imageLayer)
        applyBackdrop()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    private func applyBackdrop() {
        layer?.backgroundColor = backdropColor.cgColor
    }

    public override var isOpaque: Bool { cornerRadius == 0 && backdropColor.alphaComponent >= 1 }
    public override var acceptsFirstResponder: Bool { false }

    // MARK: Content

    /// Shows `part` of page `page` of `deck` (nil: nothing). `transition` plays only when the page changes within
    /// the same deck generation, `playsTransitions` is on and Reduce Motion is off.
    public func show(deck newDeck: SlideDeck, page newPage: Int?, part newPart: SlidePart,
                     transition: SlideTransition? = nil) {
        let changesPage = newPage != pageIndex || newPart != part
        let sameGeneration = newDeck.generation == deck.generation
        deck = newDeck
        pageIndex = newPage
        part = newPart
        if changesPage {
            pendingTransition = sameGeneration && playsTransitions ? transition : nil
        }
        updateImage()
    }

    public override func layout() {
        super.layout()
        updateImage()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = backingScale
        needsLayout = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageLayer.contentsScale = backingScale
        needsLayout = true
    }

    private var backingScale: CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return scale >= 1 ? scale : 2
    }

    /// Fits the image frame to the bounds and asks for the image of the current size.
    private func updateImage() {
        guard let page = pageIndex, let region = deck.region(part, ofPage: page),
              let size = deck.size(of: part, ofPage: page), let renderer, !bounds.isEmpty else {
            wantedKey = nil
            shownKey = nil
            pendingTransition = nil
            imageLayer.contents = nil
            return
        }
        let scale = backingScale
        let fit = SlideGeometry.aspectFit(size, in: bounds, scale: scale)
        if imageLayer.frame != fit {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = fit
            CATransaction.commit()
        }
        let pixels = SlideGeometry.pixelSize(for: fit.size, scale: scale)
        guard pixels.width > 0, pixels.height > 0 else { return }
        let key = SlideImageKey(generation: deck.generation, pageIndex: page, region: region,
                                pixelWidth: pixels.width, pixelHeight: pixels.height)
        wantedKey = key
        if key == shownKey {
            prefetchNeighbours()
            return
        }
        if let image = renderer.cachedImage(for: key) {
            apply(image, for: key)
        } else {
            renderer.image(for: key) { [weak self] image in
                guard let self, self.wantedKey == key, let image else { return }
                self.apply(image, for: key)
            }
        }
    }

    private func apply(_ image: CGImage, for key: SlideImageKey) {
        guard key != shownKey else { return }
        let hadImage = imageLayer.contents != nil
        let transition = pendingTransition
        pendingTransition = nil
        shownKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hadImage, let transition, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let animation = transition.caTransition() {
            imageLayer.add(animation, forKey: "slideTransition")
        } else {
            imageLayer.removeAnimation(forKey: "slideTransition")
        }
        imageLayer.contents = image
        CATransaction.commit()
        prefetchNeighbours()
    }

    /// Renders the neighbouring pages at the size they will have here.
    private func prefetchNeighbours() {
        guard let renderer, let page = pageIndex, !prefetchOffsets.isEmpty, !bounds.isEmpty else { return }
        let scale = backingScale
        for offset in prefetchOffsets where offset != 0 {
            let index = page + offset
            guard deck.pages.indices.contains(index), let region = deck.region(part, ofPage: index),
                  let size = deck.size(of: part, ofPage: index) else { continue }
            let fit = SlideGeometry.aspectFit(size, in: bounds, scale: scale)
            let pixels = SlideGeometry.pixelSize(for: fit.size, scale: scale)
            guard pixels.width > 0, pixels.height > 0 else { continue }
            renderer.prefetch(SlideImageKey(generation: deck.generation, pageIndex: index, region: region,
                                            pixelWidth: pixels.width, pixelHeight: pixels.height))
        }
    }

    // MARK: Mouse

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        if let onClick {
            onClick()
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// SwiftUI host of a `SlideLayerView` (the presenter view's slides).
struct SlideImage: NSViewRepresentable {
    var deck: SlideDeck
    var renderer: SlideRenderer
    var page: Int?
    var part: SlidePart = .slide
    var prefetch: [Int] = []
    var cornerRadius: CGFloat = 10
    var accessibilityLabel: String = ""
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> SlideLayerView {
        let view = SlideLayerView(frame: .zero)
        view.backdropColor = .black
        update(view)
        return view
    }

    func updateNSView(_ view: SlideLayerView, context: Context) {
        update(view)
    }

    private func update(_ view: SlideLayerView) {
        view.renderer = renderer
        view.prefetchOffsets = prefetch
        view.cornerRadius = cornerRadius
        view.onClick = onClick
        view.setAccessibilityLabel(accessibilityLabel)
        view.show(deck: deck, page: page, part: part)
    }
}

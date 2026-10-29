import AppKit

/// Transparent, click-through layer that paints the forward-search highlights above the PDF.
///
/// Highlights are *not* PDF annotations: they live in this view as plain layers, positioned by
/// `GabePDFView` in view space (so they follow scrolling and zooming) and removed after a moment.
/// The view is not flipped; callers hand it rectangles with a bottom-left origin.
final class PDFHighlightOverlayView: NSView {
    private let container = CALayer()
    private var rectLayers: [CALayer] = []
    /// Pixels per point of the display the overlay is shown on.
    private(set) var backingScale: CGFloat = 2
    private var fillColor = NSColor.controlAccentColor.withAlphaComponent(0.26).cgColor
    private var strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = true
        container.contentsScale = backingScale
        layer?.addSublayer(container)
        isHidden = true
        setAccessibilityElement(false)
        refreshColors()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// Re-resolves the dynamic accent colour for the current appearance and applies it to all layers.
    func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fillColor = NSColor.controlAccentColor.withAlphaComponent(0.26).cgColor
            strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        }
        for layer in rectLayers { style(layer) }
    }

    private func style(_ layer: CALayer) {
        layer.backgroundColor = fillColor
        layer.borderColor = strokeColor
        layer.borderWidth = 1
        layer.cornerCurve = .continuous
    }

    /// Positions one rounded rectangle per entry (view coordinates, bottom-left origin).
    func setRects(_ rects: [CGRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        while rectLayers.count < rects.count {
            let layer = CALayer()
            layer.contentsScale = backingScale
            style(layer)
            container.addSublayer(layer)
            rectLayers.append(layer)
        }
        for (index, layer) in rectLayers.enumerated() {
            if index < rects.count {
                let rect = rects[index]
                layer.isHidden = false
                layer.frame = rect
                layer.cornerRadius = min(5, min(rect.width, rect.height) / 2)
            } else {
                layer.isHidden = true
            }
        }
        CATransaction.commit()
    }

    /// Makes the overlay visible at full opacity (with a short fade-in when `animated`).
    func present(animated: Bool) {
        isHidden = false
        container.removeAnimation(forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = 1
        CATransaction.commit()
        guard animated else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        container.add(fade, forKey: "fade")
    }

    /// Fades the content to transparent over `duration`; the caller hides the view afterwards via `reset()`.
    func fadeOut(duration: CFTimeInterval) {
        let current = container.presentation()?.opacity ?? container.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        container.add(fade, forKey: "fade")
    }

    /// Hides the overlay immediately and drops its rectangles.
    func reset() {
        container.removeAllAnimations()
        setRects([])
        isHidden = true
    }

    /// Tells the layers how many pixels a point has on the current display (the window moved to another screen).
    func updateBackingScale(_ scale: CGFloat) {
        guard scale > 0, abs(backingScale - scale) > 0.001 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.contentsScale = scale
        for layer in rectLayers { layer.contentsScale = scale }
        CATransaction.commit()
        backingScale = scale
    }

    /// Number of rectangles currently shown (for diagnostics and checks).
    var visibleRectCount: Int { rectLayers.filter { !$0.isHidden }.count }

    /// Frames of the visible rectangles (for checks).
    var visibleRects: [CGRect] { rectLayers.filter { !$0.isHidden }.map(\.frame) }
}

extension CGRect {
    /// The smallest rectangle on the pixel grid of a display with `scale` pixels per point that contains `self`.
    func pixelAligned(scale: CGFloat) -> CGRect {
        guard scale > 0, !isNull, !isInfinite else { return self }
        let minX = (self.minX * scale).rounded(.down) / scale
        let minY = (self.minY * scale).rounded(.down) / scale
        let maxX = (self.maxX * scale).rounded(.up) / scale
        let maxY = (self.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

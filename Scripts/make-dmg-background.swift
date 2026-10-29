#!/usr/bin/env swift
//
// make-dmg-background.swift: renders the GabeTeX installer window background (the picture behind the two
// icons when GabeTeX.dmg is opened in Finder) and the layout numbers the DMG settings need.
//
//   swift Scripts/make-dmg-background.swift [<output-dir>]     render, write and check (default: Support/DMG)
//   swift Scripts/make-dmg-background.swift --check [<dir>]    only re-measure <dir>/background.tiff
//
// Writes into <output-dir>:
//   background.png       660 x 452 px   @ 72 dpi   (1x)
//   background@2x.png   1320 x 904 px   @ 144 dpi  (2x)
//   background.tiff     both, combined with `tiffutil -cathidpicheck` (what Finder loads)
//   layout.json         window frame, icon centres and label zones (read by dmgbuild-settings.py)
//
// Design: a calm indigo "twilight" gradient (the app icon's palette) with soft blue and violet light, two
// frosted-glass cards that hold the app and the Applications shortcut, a refined arrow between them, and a
// small bilingual caption. Style follows Scripts/make-icon.swift. Apple frameworks only.
//
// LEGIBILITY. Finder draws the icon labels itself: black in Light mode, white in Dark mode, directly on this
// picture. To read at 4.5:1 or better in both modes, the background under a label needs a relative luminance L
// with (L + 0.05) / 0.05 >= 4.5 (black text) and 1.05 / (L + 0.05) >= 4.5 (white text), i.e. L in
// [0.1750, 0.1833]: a very narrow band around sRGB #767676. So the lower part of each card is one flat tone
// whose 8-bit colour is searched to maximise the worse of the two ratios; the label zones sit entirely inside
// that flat area, and the script measures the real pixels of the final TIFF (both scales) and fails below 4.5.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - Layout (points; origin at the top-left of the Finder window's content area)

enum Layout {
    /// Window content area. The picture is anchored at its top-left corner.
    static let width = 660.0
    static let contentHeight = 420.0
    /// Extra picture below the content area, as tall as the title bar. Finder anchors the picture at the
    /// content area's top-left and clips it, so this costs nothing if WindowBounds is the whole frame (the
    /// expected case) and still leaves no empty strip if a Finder version reads it as the content size.
    static let bleed = 32.0
    static var canvasHeight: Double { contentHeight + bleed }
    /// Title bar of a titled window without toolbar on macOS 26/27 (measured with
    /// NSWindow.frameRect(forContentRect:styleMask:)). Finder's WindowBounds is the whole frame.
    static let titleBar = 32.0
    static let windowOrigin = (x: 200.0, y: 120.0)

    static let iconSize = 128.0
    static let textSize = 13.0
    static let iconCenterY = 170.0
    static let appCenterX = 170.0
    static let applicationsCenterX = 490.0

    static let cardHalfWidth = 96.0
    static let cardTop = 70.0
    static let cardBottom = 306.0
    static let cardCorner = 44.0

    /// Where Finder puts the label: just below the icon. Two lines of 13 pt plus the selection pill.
    static let labelTop = iconCenterY + iconSize / 2 + 2
    static let labelHeight = 46.0
    /// "Applications" at 13 pt is about 80 pt wide; leave room for longer localized names.
    static let labelHalfWidth = 76.0

    static let wcagTarget = 4.5

    static var windowFrameHeight: Double { contentHeight + titleBar }
}

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-dmg-background: \(message)\n".utf8))
    exit(1)
}

let sRGB: CGColorSpace = {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("sRGB colour space unavailable") }
    return space
}()

/// A colour in sRGB with 0...255 channels and 0...1 alpha.
struct Color {
    var r: Double, g: Double, b: Double, a: Double = 1
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    var cg: CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
    func alpha(_ value: Double) -> Color { Color(r, g, b, value) }
    func mixed(with other: Color, _ t: Double) -> Color {
        Color(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }
}

func smoothstep(_ t: Double) -> Double {
    let c = min(max(t, 0), 1)
    return c * c * (3 - 2 * c)
}

/// Gradient between two colours with an easing curve baked into many stops (avoids visible linear "ramps").
func easedGradient(_ from: Color, _ to: Color, steps: Int = 40, ease: (Double) -> Double = smoothstep) -> CGGradient {
    var colors: [CGColor] = []
    var locations: [CGFloat] = []
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        colors.append(from.mixed(with: to, ease(t)).cg)
        locations.append(CGFloat(t))
    }
    guard let g = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations) else {
        fail("could not create gradient")
    }
    return g
}

func stopsGradient(_ stops: [(Double, Color)]) -> CGGradient {
    guard let g = CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1.cg } as CFArray,
                             locations: stops.map { CGFloat($0.0) }) else {
        fail("could not create gradient")
    }
    return g
}

// MARK: - WCAG

func linearize(_ channel: Double) -> Double {
    let c = channel / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
    0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
}

func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
    (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

/// The flat tone under the labels: a periwinkle whose 8-bit colour maximises min(contrast vs black, vs white).
struct Tone {
    let r: Int, g: Int, b: Int
    var luminance: Double { relativeLuminance(Double(r), Double(g), Double(b)) }
    var vsBlack: Double { contrastRatio(luminance, 0) }
    var vsWhite: Double { contrastRatio(luminance, 1) }
    var worst: Double { min(vsBlack, vsWhite) }
    var color: Color { Color(Double(r), Double(g), Double(b)) }
}

func chooseLabelTone() -> Tone {
    // Direction of the hue (indigo-leaning periwinkle, matching the app icon); scaled until L is ideal.
    let direction = (r: 0.610, g: 0.663, b: 1.0)
    var best = Tone(r: 118, g: 118, b: 118)
    var scale = 120.0
    while scale <= 255 {
        let candidate = Tone(r: Int((scale * direction.r).rounded()),
                             g: Int((scale * direction.g).rounded()),
                             b: Int((scale * direction.b).rounded()))
        if candidate.worst > best.worst { best = candidate }
        scale += 0.05
    }
    return best
}

// MARK: - Geometry

/// Rounded rectangle with continuous corners (superellipse corners, exponent 5), like the app icon body.
func squirclePath(_ rect: CGRect, corner k: CGFloat) -> CGPath {
    let e = 2.0 / 5.0
    let steps = 48
    func p(_ v: Double) -> CGFloat { CGFloat(pow(max(v, 0), e)) }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + k, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - k, y: rect.minY))
    // The view is y-down here (flipped context): "top" is minY.
    var c = CGPoint(x: rect.maxX - k, y: rect.minY + k)          // top-right
    for i in 0...steps {
        let t = Double(i) / Double(steps) * Double.pi / 2
        path.addLine(to: CGPoint(x: c.x + k * p(sin(t)), y: c.y - k * p(cos(t))))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - k))
    c = CGPoint(x: rect.maxX - k, y: rect.maxY - k)             // bottom-right
    for i in 0...steps {
        let t = Double(i) / Double(steps) * Double.pi / 2
        path.addLine(to: CGPoint(x: c.x + k * p(cos(t)), y: c.y + k * p(sin(t))))
    }
    path.addLine(to: CGPoint(x: rect.minX + k, y: rect.maxY))
    c = CGPoint(x: rect.minX + k, y: rect.maxY - k)             // bottom-left
    for i in 0...steps {
        let t = Double(i) / Double(steps) * Double.pi / 2
        path.addLine(to: CGPoint(x: c.x - k * p(sin(t)), y: c.y + k * p(cos(t))))
    }
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + k))
    c = CGPoint(x: rect.minX + k, y: rect.minY + k)             // top-left
    for i in 0...steps {
        let t = Double(i) / Double(steps) * Double.pi / 2
        path.addLine(to: CGPoint(x: c.x - k * p(cos(t)), y: c.y - k * p(sin(t))))
    }
    path.closeSubpath()
    return path
}

// MARK: - Scene

struct Palette {
    let tone: Tone
    let cardTop = Color(160, 173, 238)
    let skyTopLeft = Color(40, 44, 128)
    let skyMid = Color(23, 27, 84)
    let skyBottomRight = Color(10, 13, 42)
    let blue = Color(58, 123, 255)
    let violet = Color(128, 96, 255)
}

/// Geometry of one card, in points.
func cardRect(centerX: Double) -> CGRect {
    CGRect(x: centerX - Layout.cardHalfWidth, y: Layout.cardTop,
           width: Layout.cardHalfWidth * 2, height: Layout.cardBottom - Layout.cardTop)
}

func drawBase(_ ctx: CGContext, _ palette: Palette, scale s: CGFloat) {
    let w = CGFloat(Layout.width), h = CGFloat(Layout.canvasHeight)

    ctx.drawLinearGradient(
        stopsGradient([(0, palette.skyTopLeft), (0.55, palette.skyMid), (1, palette.skyBottomRight)]),
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: h),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    func glow(_ center: CGPoint, _ radius: CGFloat, _ color: Color, _ strength: Double) {
        ctx.drawRadialGradient(easedGradient(color.alpha(strength), color.alpha(0)),
                               startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    glow(CGPoint(x: w * 0.86, y: -30), 430, palette.blue, 0.40)       // cool light from the upper right
    glow(CGPoint(x: w * 0.08, y: h * 0.98), 380, palette.violet, 0.26) // violet bloom, lower left
    glow(CGPoint(x: w * 0.50, y: 196), 360, Color(96, 118, 240), 0.16) // ambient halo behind the cards

    // Vignette (drawn before the cards, so the label tone is never touched).
    let centre = CGPoint(x: w / 2, y: 196)
    ctx.drawRadialGradient(easedGradient(Color(4, 5, 24, 0), Color(4, 5, 24, 0.50)),
                           startCenter: centre, startRadius: 210, endCenter: centre, endRadius: 470,
                           options: [.drawsAfterEndLocation])
}

func drawCard(_ ctx: CGContext, _ palette: Palette, centerX: Double, scale s: CGFloat) {
    let rect = cardRect(centerX: centerX)
    let path = squirclePath(rect, corner: CGFloat(Layout.cardCorner))
    let tone = palette.tone.color

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16 * s), blur: 34 * s, color: Color(2, 3, 24, 0.55).cg)
    ctx.addPath(path)
    ctx.setFillColor(tone.cg)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Frosted body: lighter periwinkle at the top easing into the flat label tone just under the icon.
    // Below `labelTop` the colour is exactly `tone` (drawsAfterEndLocation), so the label zone is flat.
    ctx.drawLinearGradient(easedGradient(palette.cardTop, tone),
                           start: CGPoint(x: centerX, y: Layout.cardTop),
                           end: CGPoint(x: centerX, y: Layout.labelTop - 4),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Glass sheen across the top; fully faded out (radius 170 from y = 40 reaches y = 210) above the labels.
    let sheen = CGPoint(x: centerX, y: 40)
    ctx.drawRadialGradient(easedGradient(Color(255, 255, 255, 0.30), Color(255, 255, 255, 0)),
                           startCenter: sheen, startRadius: 0, endCenter: sheen, endRadius: 170, options: [])

    // Hairline rim, brighter at the top (a 2 pt stroke of which the clip keeps the inner 1 pt).
    ctx.addPath(path)
    ctx.setLineWidth(2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        stopsGradient([(0, Color(255, 255, 255, 0.62)), (0.38, Color(255, 255, 255, 0.18)), (1, Color(255, 255, 255, 0.10))]),
        start: CGPoint(x: centerX, y: Layout.cardTop), end: CGPoint(x: centerX, y: Layout.cardBottom), options: [])
    ctx.restoreGState()
}

func drawArrow(_ ctx: CGContext, scale s: CGFloat) {
    let y = CGFloat(Layout.iconCenterY)
    let midX = CGFloat((Layout.appCenterX + Layout.applicationsCenterX) / 2)
    let x0 = midX - 46, x1 = midX + 48          // shaft start, tip
    let arm: CGFloat = 14
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x0, y: y))
    path.addLine(to: CGPoint(x: x1, y: y))
    path.move(to: CGPoint(x: x1 - arm, y: y - arm))
    path.addLine(to: CGPoint(x: x1, y: y))
    path.addLine(to: CGPoint(x: x1 - arm, y: y + arm))

    // Glow: a few wide, faint strokes underneath.
    for (width, alpha) in [(15.0, 0.035), (10.0, 0.06), (6.0, 0.10)] {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(CGFloat(width))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(Color(190, 205, 255, alpha).cg)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Crisp arrow: the shaft fades in from the app side, the head is fully opaque.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(3.4)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        stopsGradient([(0, Color(255, 255, 255, 0.0)), (0.55, Color(255, 255, 255, 0.92)), (1, Color(255, 255, 255, 0.98))]),
        start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y), options: [])
    ctx.restoreGState()
}

struct Caption {
    let text: String
    let font: CTFont
    let color: Color
    let kern: Double
    let baseline: Double
}

func captions() -> [Caption] {
    [Caption(text: "Drag GabeTeX to Applications",
             font: NSFont.systemFont(ofSize: 14, weight: .semibold) as CTFont,
             color: Color(255, 255, 255, 0.94), kern: 0.2, baseline: 356),
     Caption(text: "Arraste o GabeTeX para Aplicativos",
             font: NSFont.systemFont(ofSize: 12, weight: .regular) as CTFont,
             color: Color(255, 255, 255, 0.64), kern: 0.15, baseline: 377)]
}

func lineWidth(_ caption: Caption) -> Double {
    let attrs: [CFString: Any] = [kCTFontAttributeName: caption.font, kCTKernAttributeName: caption.kern]
    guard let string = CFAttributedStringCreate(nil, caption.text as CFString, attrs as CFDictionary) else { return 0 }
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), &ascent, &descent, &leading)
}

func drawCaption(_ ctx: CGContext, _ caption: Caption, scale s: CGFloat) {
    let attrs: [CFString: Any] = [kCTFontAttributeName: caption.font,
                                  kCTForegroundColorAttributeName: caption.color.cg,
                                  kCTKernAttributeName: caption.kern]
    guard let string = CFAttributedStringCreate(nil, caption.text as CFString, attrs as CFDictionary) else {
        fail("could not build caption text")
    }
    let line = CTLineCreateWithAttributedString(string)
    let width = lineWidth(caption)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1 * s), blur: 4 * s, color: Color(0, 0, 20, 0.45).cg)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)     // the context is y-down
    ctx.textPosition = CGPoint(x: Layout.width / 2 - width / 2, y: caption.baseline)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func renderScene(scale: Int, palette: Palette, withText: Bool) -> CGImage {
    let pixelWidth = Int(Layout.width) * scale, pixelHeight = Int(Layout.canvasHeight) * scale
    guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                              space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fail("could not create a \(pixelWidth) x \(pixelHeight) bitmap context")
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(false)        // grayscale text AA: no LCD fringes baked into a picture
    let s = CGFloat(scale)
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: CGFloat(Layout.canvasHeight))
    ctx.scaleBy(x: 1, y: -1)                  // from here on: points, origin top-left, y down

    drawBase(ctx, palette, scale: s)
    drawCard(ctx, palette, centerX: Layout.appCenterX, scale: s)
    drawCard(ctx, palette, centerX: Layout.applicationsCenterX, scale: s)
    drawArrow(ctx, scale: s)
    if withText {
        for caption in captions() { drawCaption(ctx, caption, scale: s) }
    }
    guard let image = ctx.makeImage() else { fail("could not render the background") }
    return image
}

// MARK: - Measuring

struct Pixels {
    let width: Int, height: Int
    let rgba: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !drawn { fail("could not read back pixels") }
        width = w
        height = h
        rgba = buffer
    }

    /// Range of relative luminance (and the extreme sRGB triples) over a rectangle given in points.
    func luminanceRange(x: Double, y: Double, width w: Double, height h: Double, scale: Int)
        -> (lo: Double, hi: Double, darkest: [UInt8], lightest: [UInt8]) {
        var lo = Double.infinity, hi = -Double.infinity
        var darkest: [UInt8] = [0, 0, 0], lightest: [UInt8] = [0, 0, 0]
        let x0 = Int((x * Double(scale)).rounded()), x1 = Int(((x + w) * Double(scale)).rounded())
        let y0 = Int((y * Double(scale)).rounded()), y1 = Int(((y + h) * Double(scale)).rounded())
        for py in max(y0, 0)..<min(y1, height) {
            for px in max(x0, 0)..<min(x1, width) {
                let i = (py * width + px) * 4
                let l = relativeLuminance(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2]))
                if l < lo { lo = l; darkest = [rgba[i], rgba[i + 1], rgba[i + 2]] }
                if l > hi { hi = l; lightest = [rgba[i], rgba[i + 1], rgba[i + 2]] }
            }
        }
        return (lo, hi, darkest, lightest)
    }
}

struct LabelZone {
    let name: String
    let x: Double, y: Double, width: Double, height: Double
}

func labelZones() -> [LabelZone] {
    [LabelZone(name: "GabeTeX.app", x: Layout.appCenterX - Layout.labelHalfWidth, y: Layout.labelTop,
               width: Layout.labelHalfWidth * 2, height: Layout.labelHeight),
     LabelZone(name: "Applications", x: Layout.applicationsCenterX - Layout.labelHalfWidth, y: Layout.labelTop,
               width: Layout.labelHalfWidth * 2, height: Layout.labelHeight)]
}

func f2(_ v: Double) -> String { String(format: "%.2f", v) }
func f4(_ v: Double) -> String { String(format: "%.4f", v) }

/// Prints the WCAG numbers for the label zones in `image`; returns the worst ratio found.
func reportLabelContrast(_ image: CGImage, scale: Int, title: String) -> Double {
    let pixels = Pixels(image)
    var worst = Double.infinity
    for zone in labelZones() {
        let r = pixels.luminanceRange(x: zone.x, y: zone.y, width: zone.width, height: zone.height, scale: scale)
        let black = contrastRatio(r.lo, 0)       // black text on the darkest pixel
        let white = contrastRatio(r.hi, 1)       // white text on the lightest pixel
        worst = min(worst, black, white)
        print("  \(title)  \(zone.name.padding(toLength: 12, withPad: " ", startingAt: 0)) L \(f4(r.lo))...\(f4(r.hi))"
              + "  rgb \(r.darkest.map { String($0) }.joined(separator: ","))...\(r.lightest.map { String($0) }.joined(separator: ","))"
              + "  black text >= \(f2(black)):1  white text >= \(f2(white)):1")
    }
    return worst
}

/// Informational: contrast of the bilingual caption against the lightest background pixel behind it.
func reportCaptionContrast(palette: Palette) {
    let bare = Pixels(renderScene(scale: 1, palette: palette, withText: false))
    for caption in captions() {
        let half = lineWidth(caption) / 2 + 6
        let r = bare.luminanceRange(x: Layout.width / 2 - half, y: caption.baseline - 14, width: half * 2, height: 20, scale: 1)
        let a = caption.color.a
        let g = r.lightest.map { Double($0) * (1 - a) + 255 * a }
        let textL = relativeLuminance(g[0], g[1], g[2])
        print("  caption \"\(caption.text)\"  background L <= \(f4(r.hi))  text on it \(f2(contrastRatio(textL, r.hi))):1")
    }
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL, dpi: Double) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("cannot create \(url.path)")
    }
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    do { try process.run() } catch { fail("cannot run \(tool): \(error.localizedDescription)") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(tool) exited with status \(process.terminationStatus)") }
}

func writeLayout(to url: URL, tone: Tone) {
    func point(_ x: Double, _ y: Double) -> [String: Double] { ["x": x, "y": y] }
    func zoneJSON(_ z: LabelZone) -> [String: Any] {
        ["x": z.x, "y": z.y, "width": z.width, "height": z.height]
    }
    let zones = labelZones()
    let layout: [String: Any] = [
        "comment": "Generated by Scripts/make-dmg-background.swift. Points; origin = top-left of the window content area.",
        "contentSize": ["width": Layout.width, "height": Layout.contentHeight],
        "backgroundSize": ["width": Layout.width, "height": Layout.canvasHeight],
        "titleBarHeight": Layout.titleBar,
        "windowFrame": ["x": Layout.windowOrigin.x, "y": Layout.windowOrigin.y,
                        "width": Layout.width, "height": Layout.windowFrameHeight],
        "iconSize": Layout.iconSize,
        "textSize": Layout.textSize,
        "icons": ["GabeTeX.app": point(Layout.appCenterX, Layout.iconCenterY),
                  "Applications": point(Layout.applicationsCenterX, Layout.iconCenterY)],
        "labelZones": ["GabeTeX.app": zoneJSON(zones[0]), "Applications": zoneJSON(zones[1])],
        "labelTone": ["rgb": [tone.r, tone.g, tone.b], "luminance": f4(tone.luminance),
                      "contrastBlack": f2(tone.vsBlack), "contrastWhite": f2(tone.vsWhite)],
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url)
    } catch {
        fail("cannot write \(url.path): \(error.localizedDescription)")
    }
}

/// Measures every image inside the TIFF; exits non-zero if the label contrast is below the target.
func checkTIFF(_ url: URL) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { fail("cannot open \(url.path)") }
    let count = CGImageSourceGetCount(source)
    print("check \(url.lastPathComponent): \(count) image(s)")
    guard count == 2 else { fail("expected a 1x + 2x TIFF, found \(count) image(s)") }
    var worst = Double.infinity
    for index in 0..<count {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { fail("cannot decode image \(index)") }
        let scale = image.width / Int(Layout.width)
        guard image.width == Int(Layout.width) * scale, image.height == Int(Layout.canvasHeight) * scale, scale == 1 || scale == 2 else {
            fail("image \(index) is \(image.width) x \(image.height) px: not \(Int(Layout.width)) x \(Int(Layout.canvasHeight)) at 1x or 2x")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 0
        guard Int(dpi.rounded()) == 72 * scale else { fail("image \(index) (\(scale)x) has \(dpi) dpi, expected \(72 * scale)") }
        print("  image \(index): \(image.width) x \(image.height) px, \(Int(dpi)) dpi (\(scale)x)")
        worst = min(worst, reportLabelContrast(image, scale: scale, title: "\(scale)x"))
    }
    print("worst label contrast in the TIFF: \(f2(worst)):1 (target >= \(Layout.wcagTarget):1)")
    if worst < Layout.wcagTarget { fail("label contrast below \(Layout.wcagTarget):1") }
}

// MARK: - Entry point

func main() {
    var args = Array(CommandLine.arguments.dropFirst())
    let checkOnly = args.first == "--check"
    if checkOnly { args.removeFirst() }
    let outDir: URL
    if let first = args.first {
        outDir = URL(fileURLWithPath: first, isDirectory: true)
    } else {
        outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/DMG", isDirectory: true)
    }
    if checkOnly {
        checkTIFF(outDir.appendingPathComponent("background.tiff"))
        return
    }

    let tone = chooseLabelTone()
    print("label tone rgb(\(tone.r), \(tone.g), \(tone.b))  L = \(f4(tone.luminance))"
          + "  black \(f2(tone.vsBlack)):1  white \(f2(tone.vsWhite)):1")
    let palette = Palette(tone: tone)

    do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) } catch {
        fail("cannot create \(outDir.path): \(error.localizedDescription)")
    }
    let png1x = outDir.appendingPathComponent("background.png")
    let png2x = outDir.appendingPathComponent("background@2x.png")
    let tiff = outDir.appendingPathComponent("background.tiff")
    writePNG(renderScene(scale: 1, palette: palette, withText: true), to: png1x, dpi: 72)
    writePNG(renderScene(scale: 2, palette: palette, withText: true), to: png2x, dpi: 144)
    try? FileManager.default.removeItem(at: tiff)
    run("/usr/bin/tiffutil", ["-cathidpicheck", png1x.path, png2x.path, "-out", tiff.path])
    writeLayout(to: outDir.appendingPathComponent("layout.json"), tone: tone)
    print("wrote background.png, background@2x.png, background.tiff, layout.json in \(outDir.path)")

    reportCaptionContrast(palette: palette)
    checkTIFF(tiff)
}

main()

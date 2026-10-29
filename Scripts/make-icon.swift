#!/usr/bin/env swift
//
// make-icon.swift: renders the GabeTeX app icon (macOS 26 Liquid Glass style) and packs it into an .icns.
//
//   swift Scripts/make-icon.swift <output.icns> [<master-1024.png>]
//
// Design: a superellipse ("squircle") body on the macOS icon grid (824 px inside a 1024 px canvas, leaving a
// 100 px transparent margin for the shadow), an indigo-to-blue gradient with a glossy top sheen, a bright
// inner rim and a faint bottom shade. The glyph is an italic serif partial-derivative sign (U+2202, the
// boundary operator), filled with frosted, slightly translucent white and lifted by a soft shadow.
//
// The 1024 px master is rendered once and every iconset size is a high-quality downsample of it. With a
// second argument, the master and a 64 px preview are also written there. Apple frameworks only.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - Layout

let masterSize = 1024
let bodyInset: CGFloat = 100      // transparent margin on each side (shadow room)
let bodySide: CGFloat = 824       // macOS icon grid body
let glyphHeight: CGFloat = 520    // ink height of the partial-derivative sign

let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors as CFArray, locations: locations) else {
        fail("could not create gradient")
    }
    return g
}

func makeContext(_ pixels: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not create a \(pixels) px bitmap context")
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

// MARK: - Geometry

/// Continuous-corner square: a superellipse with exponent 5 inscribed in the 824 px body.
func bodyPath() -> CGPath {
    let cx = Double(bodyInset + bodySide / 2)
    let cy = Double(bodyInset + bodySide / 2)
    let a = Double(bodySide / 2)
    let exponent = 2.0 / 5.0
    func signedPow(_ v: Double) -> Double { v < 0 ? -pow(-v, exponent) : pow(v, exponent) }
    let path = CGMutablePath()
    let steps = 800
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let point = CGPoint(x: cx + a * signedPow(cos(t)), y: cy + a * signedPow(sin(t)))
        if i == 0 {
            path.move(to: point)
        } else {
            path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

/// Outline of U+2202 in an italic New York serif, scaled to `glyphHeight` and centred on the canvas by its
/// ink bounds (not the font box).
func glyphPath() -> CGPath {
    let character = "\u{2202}"
    var descriptor = NSFont.systemFont(ofSize: 1000).fontDescriptor
    if let serif = descriptor.withDesign(.serif) {
        descriptor = serif
    }
    descriptor = descriptor.withSymbolicTraits(.italic)
    let font = NSFont(descriptor: descriptor, size: 1000)
        ?? NSFont(name: "Times New Roman Italic", size: 1000)
        ?? NSFont.systemFont(ofSize: 1000)
    // CoreText picks a font that actually contains the glyph, following the system fallback cascade.
    let units = Array(character.utf16)
    let fitted = CTFontCreateForString(font as CTFont, character as CFString,
                                       CFRange(location: 0, length: units.count))
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    guard CTFontGetGlyphsForCharacters(fitted, units, &glyphs, units.count),
          let glyph = glyphs.first, glyph != 0,
          let outline = CTFontCreatePathForGlyph(fitted, glyph, nil) else {
        fail("no outline for U+2202 in the serif font")
    }
    let ink = outline.boundingBoxOfPath
    let scale = glyphHeight / ink.height
    let centre = CGPoint(x: CGFloat(masterSize) / 2, y: CGFloat(masterSize) / 2)
    let toOrigin = CGAffineTransform(translationX: -ink.midX, y: -ink.midY)
    let scaling = CGAffineTransform(scaleX: scale, y: scale)
    let toCentre = CGAffineTransform(translationX: centre.x, y: centre.y)
    var transform = toOrigin.concatenating(scaling).concatenating(toCentre)
    guard let placed = outline.copy(using: &transform) else {
        fail("could not place the glyph outline")
    }
    return placed
}

// MARK: - Drawing

func drawGlyph(_ ctx: CGContext, _ path: CGPath) {
    let ink = path.boundingBoxOfPath

    // Soft shadow lifts the glyph off the background.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(5, 5, 50, 0.40))
    ctx.addPath(path)
    ctx.setFillColor(rgb(255, 255, 255, 0.92))
    ctx.fillPath()
    ctx.restoreGState()

    // Frosted fill: slightly translucent white, easing toward a cool tint at the base.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(255, 255, 255, 0.98), rgb(214, 226, 255, 0.86)], [0, 1]),
        start: CGPoint(x: ink.midX, y: ink.maxY),
        end: CGPoint(x: ink.midX, y: ink.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Hairline edge so the outline stays crisp where the glyph meets the sheen.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.45))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()
}

func renderMaster() -> CGImage {
    let ctx = makeContext(masterSize)
    let body = bodyPath()
    let minX = bodyInset, minY = bodyInset
    let maxX = bodyInset + bodySide, maxY = bodyInset + bodySide
    let midX = bodyInset + bodySide / 2
    let slant = bodySide * 0.2

    // Drop shadow cast by the body onto the transparent margin.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: rgb(12, 10, 50, 0.30))
    ctx.addPath(body)
    ctx.setFillColor(rgb(43, 45, 140))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()

    // Background: indigo at the lower left to blue at the upper right, a slightly diagonal sweep.
    ctx.drawLinearGradient(
        gradient([rgb(43, 45, 140), rgb(58, 123, 255)], [0, 1]),
        start: CGPoint(x: minX + slant, y: minY),
        end: CGPoint(x: maxX - slant, y: maxY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Glossy sheen: a broad radial highlight across the top third.
    let sheenCentre = CGPoint(x: midX, y: maxY + 120)
    ctx.drawRadialGradient(
        gradient([rgb(255, 255, 255, 0.34), rgb(255, 255, 255, 0.10), rgb(255, 255, 255, 0)], [0, 0.55, 1]),
        startCenter: sheenCentre, startRadius: 0,
        endCenter: sheenCentre, endRadius: 470,
        options: [])

    // Gentle inner shadow along the bottom edge.
    ctx.drawLinearGradient(
        gradient([rgb(0, 0, 40, 0.28), rgb(0, 0, 40, 0)], [0, 1]),
        start: CGPoint(x: midX, y: minY),
        end: CGPoint(x: midX, y: minY + 170),
        options: [.drawsAfterEndLocation])

    // Bright inner rim: a 4 px stroke centred on the edge, of which the clip keeps only the inner 2 px.
    ctx.addPath(body)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.25))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    drawGlyph(ctx, glyphPath())

    guard let image = ctx.makeImage() else { fail("could not render the master image") }
    return image
}

// MARK: - Output

func downsample(_ master: CGImage, to pixels: Int) -> CGImage {
    let ctx = makeContext(pixels)
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = ctx.makeImage() else { fail("could not downsample to \(pixels) px") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

func buildICNS(master: CGImage, output: URL) {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("gabetex-icon-\(UUID().uuidString)", isDirectory: true)
    let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    do {
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    } catch {
        fail("cannot create \(iconset.path): \(error.localizedDescription)")
    }
    for entry in iconsetEntries {
        writePNG(downsample(master, to: entry.pixels), to: iconset.appendingPathComponent(entry.name))
    }

    try? fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: output)
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", "-o", output.path, iconset.path]
    do {
        try iconutil.run()
    } catch {
        try? fm.removeItem(at: work)
        fail("cannot run iconutil: \(error.localizedDescription)")
    }
    iconutil.waitUntilExit()
    try? fm.removeItem(at: work)
    guard iconutil.terminationStatus == 0 else {
        fail("iconutil exited with status \(iconutil.terminationStatus)")
    }
    print("wrote \(output.path)")
}

// MARK: - Entry point

func main() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        fail("usage: swift Scripts/make-icon.swift <output.icns> [<master-1024.png>]")
    }
    let master = renderMaster()
    if args.count >= 3 {
        let masterURL = URL(fileURLWithPath: args[2])
        let folder = masterURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writePNG(master, to: masterURL)
        let preview = folder.appendingPathComponent(masterURL.deletingPathExtension().lastPathComponent + "-64.png")
        writePNG(downsample(master, to: 64), to: preview)
        print("wrote \(masterURL.path) and \(preview.path)")
    }
    buildICNS(master: master, output: URL(fileURLWithPath: args[1]))
}

main()

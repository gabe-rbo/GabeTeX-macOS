import AppKit
import CheckKit
import PDFKit
import PreviewKit

// Headless checks of presentation mode, part 2 (owned by the present agent): PDF transitions, rendering of slide
// and notes halves, the controller (commands, reloads, following the preview), and the windows, presenter view and
// Touch Bar built in offscreen windows that are never ordered on screen. Set PRESENTATION_SNAPSHOTS=<folder> to also
// write PNG snapshots of the presenter and audience views (for design review).

// MARK: - Helpers

/// One page of a generated deck: the left part's colour and, for a split (notes) page, the right part's.
private struct DeckPage {
    var left: CGColor
    var right: CGColor?
}

private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
private let green = CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1)
private let yellow = CGColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1)

/// Writes a PDF whose pages are `size` points, each filled with its colour(s) (left / right halves when split).
private func makeDeck(_ pages: [DeckPage], size: CGSize) -> URL? {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    for page in pages {
        context.beginPDFPage(nil)
        if let right = page.right {
            context.setFillColor(page.left)
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            context.setFillColor(right)
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        } else {
            context.setFillColor(page.left)
            context.fill(box)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return writeTemporary(data as Data, name: "deck")
}

private func writeTemporary(_ data: Data, name: String) -> URL? {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("presentation-\(name)-\(UUID().uuidString).pdf")
    do { try data.write(to: url) } catch { return nil }
    return url
}

/// A hand-written PDF with page transitions (`/Trans`) and a rotated page.
private func makeTransitionsPDF() -> URL? {
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Trans << /S /Dissolve /D 0.4 >> >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Rotate 90 /Trans << /S /Push /Di 180 /D 0.8 >> >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Trans << /S /R >> >>",
    ]
    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, body) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
    }
    let xref = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return writeTemporary(Data(pdf.utf8), name: "transitions")
}

/// The colour of one pixel of `image` (origin bottom-left), 0–255 per channel.
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
    guard let data = context.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
}

private func isColor(_ sample: (r: Int, g: Int, b: Int)?, _ r: Int, _ g: Int, _ b: Int) -> Bool {
    guard let sample else { return false }
    return abs(sample.r - r) < 40 && abs(sample.g - g) < 40 && abs(sample.b - b) < 40
}

/// Lets queued main-actor work (renders, observation hops, SwiftUI layout) run.
private func presentationSettle(_ milliseconds: Int = 60) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

/// Waits (up to `timeout` ms) until `condition` holds, laying out `views` first on every try (offscreen windows
/// get no display cycle of their own).
private func waitFor(_ timeout: Int = 3000, layingOut views: [NSView] = [], _ condition: () -> Bool) async -> Bool {
    var waited = 0
    while true {
        for view in views { view.layoutSubtreeIfNeeded() }
        if condition() { return true }
        if waited >= timeout { return false }
        try? await Task.sleep(for: .milliseconds(20))
        waited += 20
    }
}

private func keyEvent(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent? {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: false, keyCode: code)
}

private func mouseEvent(_ type: NSEvent.EventType) -> NSEvent? {
    NSEvent.mouseEvent(with: type, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
}

private func slideViews(in view: NSView) -> [SlideLayerView] {
    var found: [SlideLayerView] = []
    if let slide = view as? SlideLayerView { found.append(slide) }
    for subview in view.subviews { found += slideViews(in: subview) }
    return found
}

private func offscreenWindow(_ controller: PresentationController, _ mode: PresentationStageView.Mode,
                             width: CGFloat, height: CGFloat) -> PresentationWindow {
    let window = PresentationWindow(controller: controller, mode: mode,
                                    contentRect: CGRect(x: 0, y: 0, width: width, height: height))
    window.stage.layoutSubtreeIfNeeded()
    return window
}

// MARK: - Snapshots (opt-in)

/// A Beamer-like deck with text: slides on the left half, speaker notes on the right half of every page.
private func makeTextDeck(pages: Int) -> URL? {
    let slide = CGSize(width: 455, height: 256)          // 16:9 (160 mm × 90 mm)
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: slide.width * 2, height: slide.height)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    let titles = ["Homologia simplicial", "Complexos de cadeias", "Números de Betti", "Forma normal de Smith",
                  "Exemplo: o toro", "Conclusão"]
    for page in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.2, blue: 0.36, alpha: 1))
        context.fill(CGRect(x: 0, y: slide.height - 46, width: slide.width, height: 46))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let title = titles[page % titles.count]
        (title as NSString).draw(at: CGPoint(x: 18, y: slide.height - 33),
                                 withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white])
        for (line, text) in ["• Um complexo simplicial K e suas cadeias C_n(K)",
                             "• Operador de bordo ∂_n ∘ ∂_{n+1} = 0",
                             "• H_n(K) = ker ∂_n / im ∂_{n+1}"].enumerated() {
            (text as NSString).draw(at: CGPoint(x: 26, y: slide.height - 90 - CGFloat(line) * 30),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
        }
        ("\(page + 1)" as NSString).draw(at: CGPoint(x: slide.width - 24, y: 10),
                                         withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray])
        for (line, text) in ["Lembrar: definir orientação dos simplexos.", "Mostrar o exemplo do toro no quadro.",
                             "Tempo previsto: 2 minutos."].enumerated() {
            (text as NSString).draw(at: CGPoint(x: slide.width + 20, y: slide.height - 40 - CGFloat(line) * 22),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.current = previous
        context.endPDFPage()
    }
    context.closePDF()
    return writeTemporary(data as Data, name: "text-deck")
}

/// Writes PNGs of `view` (cacheDisplay and layer rendering) into $PRESENTATION_SNAPSHOTS, when set.
private func snapshot(_ view: NSView, _ name: String) {
    guard let directory = ProcessInfo.processInfo.environment["PRESENTATION_SNAPSHOTS"], !directory.isEmpty else { return }
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-cache.png"))
    }
    let scale: CGFloat = 1
    let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
    if let layer = view.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
       let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        if let image = context.makeImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-layer.png"))
        }
    }
}

private func snapshotChecks() async {
    guard ProcessInfo.processInfo.environment["PRESENTATION_SNAPSHOTS"] != nil else { return }
    await Check.suite("Presentation: snapshots") {
        guard let url = makeTextDeck(pages: 12) else { return Check.fail("no deck") }
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PresentationController(title: "Topologia", notesMode: .automatic)
        Check.expect(await controller.load(url))
        controller.toggleTimer()
        _ = controller.perform(.goTo(4))
        let presenter = offscreenWindow(controller, .presenter, width: 1440, height: 900)
        let audience = offscreenWindow(controller, .audience, width: 1280, height: 800)
        defer {
            presenter.close()
            audience.close()
        }
        let stages: [NSView] = [presenter.stage, audience.stage]
        _ = await waitFor(layingOut: stages) {
            (presenter.stage.presenterHost.map(slideViews(in:)) ?? []).filter(\.hasImage).count >= 3
                && audience.stage.audienceView.slideView.hasImage
        }
        await presentationSettle(400)
        snapshot(presenter.stage, "presenter")
        snapshot(audience.stage, "audience")
        _ = controller.perform(.toggleBlack)
        _ = controller.perform(.digit(1))
        _ = controller.perform(.digit(1))
        await presentationSettle(300)
        snapshot(presenter.stage, "presenter-goto")
        _ = controller.perform(.clearDigits)
        await presentationSettle(300)
        snapshot(presenter.stage, "presenter-black")
        _ = controller.perform(.toggleBlack)
        controller.notesMode = .off
        _ = controller.perform(.last)
        await presentationSettle(500)
        snapshot(presenter.stage, "presenter-nonotes-last")
        controller.notesMode = .automatic
    }
}

func presentationRenderingChecks() async {
    await transitionChecks()
    await renderingAndControllerChecks()
    await windowChecks()
    await snapshotChecks()
}

private func transitionChecks() async {
    await Check.suite("Presentation: PDF transitions") {
        Check.equal(SlideTransition.fromPDF(style: "R", duration: nil, direction: nil)?.style, .cut)
        Check.equal(SlideTransition.fromPDF(style: "Dissolve", duration: 0.5, direction: nil),
                    SlideTransition(style: .fade, duration: 0.5))
        Check.equal(SlideTransition.fromPDF(style: "Push", duration: 2, direction: 180),
                    SlideTransition(style: .push, duration: 1.5, direction: .fromRight), "duration capped")
        Check.equal(SlideTransition.fromPDF(style: "Cover", duration: nil, direction: 270),
                    SlideTransition(style: .moveIn, duration: 1, direction: .fromTop))
        Check.equal(SlideTransition.fromPDF(style: "Uncover", duration: 0.01, direction: 90),
                    SlideTransition(style: .reveal, duration: 0.05, direction: .fromBottom))
        Check.equal(SlideTransition.fromPDF(style: "Push", duration: 1, direction: -90)?.direction, .fromTop)
        Check.equal(SlideTransition.fromPDF(style: "Wipe", duration: 0.3, direction: 0)?.style, .fade)
        Check.equal(SlideTransition.fromPDF(style: "Bogus", duration: 1, direction: 0), nil)
        Check.equal(SlideTransition.standard.style, .fade)
        Check.expect(SlideTransition.standard.duration < 0.3, "the default dissolve is short")

        guard let url = makeTransitionsPDF() else { return Check.fail("could not write the PDF") }
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PresentationController(title: "Transitions", notesMode: .automatic)
        Check.expect(await controller.load(url), "hand-written PDF loads")
        let pages = controller.deck.pages
        Check.equal(pages.count, 3)
        guard pages.count == 3 else { return }
        Check.equal(pages[0].transition, SlideTransition(style: .fade, duration: 0.4))
        Check.equal(pages[1].transition?.style, .push)
        Check.equal(pages[1].transition?.direction, .fromRight)
        Check.equal(pages[2].transition?.style, .cut)
        Check.equal(pages[0].size, CGSize(width: 400, height: 300))
        Check.equal(pages[1].size, CGSize(width: 300, height: 400), "/Rotate 90 swaps the display size")
    }
}

private func renderingAndControllerChecks() async {
    let savedNotesMode = PresentationPreferences.notesMode
    defer { PresentationPreferences.notesMode = savedNotesMode }

    await Check.suite("Presentation: rendering the halves of notes pages") {
        guard let url = makeDeck([DeckPage(left: red, right: blue), DeckPage(left: green, right: yellow)],
                                 size: CGSize(width: 800, height: 300)) else { return Check.fail("no deck") }
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PresentationController(title: "Notes", notesMode: .automatic)
        Check.expect(await controller.load(url))
        let deck = controller.deck
        Check.equal(deck.notesSide, .right, "double-width pages: notes on the right")
        Check.expect(controller.hasNotes)

        func render(_ page: Int, _ region: PageRegion) async -> CGImage? {
            await controller.renderer.image(for: SlideImageKey(generation: controller.deck.generation, pageIndex: page,
                                                               region: region, pixelWidth: 80, pixelHeight: 60))
        }
        guard let slide = await render(0, .leftHalf), let notes = await render(0, .rightHalf),
              let whole = await render(1, .whole) else { return Check.fail("render failed") }
        Check.equal(slide.width, 80)
        Check.equal(slide.height, 60)
        Check.expect(isColor(pixel(slide, x: 40, y: 30), 255, 0, 0), "slide half is red: \(String(describing: pixel(slide, x: 40, y: 30)))")
        Check.expect(isColor(pixel(slide, x: 2, y: 2), 255, 0, 0) && isColor(pixel(slide, x: 77, y: 57), 255, 0, 0),
                     "no blue bleeds into the slide half")
        Check.expect(isColor(pixel(notes, x: 40, y: 30), 0, 0, 255), "notes half is blue")
        Check.expect(isColor(pixel(whole, x: 10, y: 30), 0, 204, 0) && isColor(pixel(whole, x: 70, y: 30), 255, 230, 0),
                     "the whole page has both halves")
        Check.expect(controller.renderer.cachedImageCount >= 3, "renders are cached")
        let again = controller.renderer.cachedImage(for: SlideImageKey(generation: controller.deck.generation, pageIndex: 0,
                                                                       region: .leftHalf, pixelWidth: 80, pixelHeight: 60))
        Check.expect(again === slide, "cache hit returns the same image")
        Check.equal(await controller.renderer.image(for: SlideImageKey(generation: controller.deck.generation, pageIndex: 9,
                                                                       region: .whole, pixelWidth: 10, pixelHeight: 10)) == nil,
                    true, "a page that does not exist renders nothing")

        controller.notesMode = .left
        Check.equal(controller.deck.notesSide, .left)
        Check.equal(controller.deck.region(.slide, ofPage: 0), .rightHalf)
        Check.equal(PresentationPreferences.notesMode, .left, "the setting is remembered")
        controller.notesMode = .off
        Check.equal(controller.deck.notesSide, nil)
        Check.expect(!controller.hasNotes)
        controller.notesHint = .right
        controller.notesMode = .automatic
        Check.equal(controller.deck.notesSide, .right)
    }

    await Check.suite("Presentation: controller without windows") {
        guard let four = makeDeck(Array(repeating: DeckPage(left: red), count: 4), size: CGSize(width: 400, height: 300)),
              let six = makeDeck(Array(repeating: DeckPage(left: blue), count: 6), size: CGSize(width: 400, height: 300)),
              let two = makeDeck(Array(repeating: DeckPage(left: green), count: 2), size: CGSize(width: 400, height: 300))
        else { return Check.fail("no deck") }
        defer { for url in [four, six, two] { try? FileManager.default.removeItem(at: url) } }

        let controller = PresentationController(title: "Talk", notesMode: .automatic)
        var endCount = 0
        controller.onEnd = { endCount += 1 }
        Check.expect(await controller.load(four))
        Check.equal(controller.pageCount, 4)
        Check.equal(controller.deck.notesSide, nil, "plain slides: no notes")
        Check.expect(!controller.isRunning)
        Check.equal(controller.layout, .single(showsPresenter: false))
        Check.equal(controller.perform(.next), .moved(from: 0, to: 1))
        _ = controller.perform(.digit(4))
        Check.equal(controller.perform(.confirm), .moved(from: 1, to: 3))
        Check.equal(controller.perform(.togglePresenterView), .togglePresenterView)
        Check.equal(controller.layout, .single(showsPresenter: true), "P shows the presenter view on one display")
        _ = controller.perform(.togglePresenterView)
        Check.equal(controller.layout, .single(showsPresenter: false))

        if let right = keyEvent(PresentationKeyMap.KeyCode.leftArrow) {
            Check.expect(controller.handleKeyDown(right), "← handled")
            Check.equal(controller.currentIndex, 2)
        }
        if let commandB = keyEvent(11, "b", flags: .command) {
            Check.expect(!controller.handleKeyDown(commandB), "⌘B is not a presentation key")
        }

        let generation = controller.deck.generation
        _ = controller.perform(.goTo(3))
        controller.reload(from: six)
        Check.expect(await waitFor { controller.pageCount == 6 }, "reloaded with 6 pages")
        Check.equal(controller.currentIndex, 3, "the slide is kept")
        Check.expect(controller.deck.generation > generation, "new deck generation")
        controller.reload(from: two)
        Check.expect(await waitFor { controller.pageCount == 2 }, "reloaded with 2 pages")
        Check.equal(controller.currentIndex, 1, "clamped to the last slide")
        let twoGeneration = controller.deck.generation
        controller.reload(from: two)
        await presentationSettle(150)
        Check.equal(controller.deck.generation, twoGeneration, "identical bytes: nothing reloaded")

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-missing-\(UUID().uuidString).pdf")
        Check.expect(!(await controller.load(missing)), "a missing PDF does not load")
        Check.equal(controller.loadFailure, .missing)
        Check.equal(controller.pageCount, 2, "the previous PDF stays")

        controller.toggleTimer()
        Check.expect(controller.timer.isRunning)
        controller.resetTimer()
        Check.expect(controller.timer.elapsed(at: Date()) < 1)
        controller.toggleTimer()
        Check.expect(!controller.timer.isRunning)

        Check.equal(controller.perform(.escape), .end)
        Check.expect(controller.hasEnded)
        Check.equal(endCount, 1, "onEnd called once")
        controller.end()
        Check.equal(endCount, 1, "ending twice is harmless")
        Check.equal(controller.perform(.next), .none, "an ended presentation ignores commands")
        let restart = await controller.start(url: four)
        Check.expect(!restart, "an ended controller does not start again")
    }

    await Check.suite("Presentation: follows the preview's reloads") {
        guard let three = makeDeck(Array(repeating: DeckPage(left: red), count: 3), size: CGSize(width: 400, height: 300)),
              let five = makeDeck(Array(repeating: DeckPage(left: blue), count: 5), size: CGSize(width: 400, height: 300))
        else { return Check.fail("no deck") }
        defer { for url in [three, five] { try? FileManager.default.removeItem(at: url) } }
        let preview = PDFPreviewController()
        Check.expect(await preview.loadAndWait(three))
        let controller = PresentationController(title: "Live", notesMode: .automatic)
        Check.expect(await controller.load(three))
        controller.follow(preview)
        _ = controller.perform(.last)
        Check.expect(await preview.loadAndWait(five), "the preview loads a new build")
        Check.expect(await waitFor { controller.pageCount == 5 }, "the presentation follows (\(controller.pageCount) pages)")
        Check.equal(controller.currentIndex, 2, "same slide after the live reload")
        controller.end()
        Check.expect(await preview.loadAndWait(three))
        await presentationSettle(200)
        Check.equal(controller.pageCount, 5, "an ended presentation stops following")
    }
}

private func windowChecks() async {
    await Check.suite("Presentation: windows and presenter view offscreen") {
        guard let url = makeDeck([DeckPage(left: red, right: blue), DeckPage(left: green, right: yellow),
                                  DeckPage(left: blue, right: red)],
                                 size: CGSize(width: 800, height: 300)) else { return Check.fail("no deck") }
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PresentationController(title: "Offscreen", notesMode: .automatic)
        Check.expect(await controller.load(url))

        let audience = offscreenWindow(controller, .audience, width: 960, height: 540)
        let presenter = offscreenWindow(controller, .presenter, width: 1440, height: 900)
        defer {
            audience.close()
            presenter.close()
        }
        Check.expect(!audience.isVisible && !presenter.isVisible, "nothing on screen")
        Check.expect(audience.canBecomeKey, "borderless windows can take the keyboard")
        Check.equal(audience.styleMask, [.borderless])
        Check.equal(audience.stage.mode, .audience)
        Check.equal(presenter.stage.mode, .presenter)
        Check.expect(presenter.stage.presenterHost != nil && presenter.stage.presenterHost?.isHidden == false,
                     "presenter view built")
        Check.expect(presenter.stage.audienceView.isHidden, "slides hidden behind the presenter view")

        let slide = audience.stage.audienceView.slideView
        let stages: [NSView] = [audience.stage, presenter.stage]
        Check.expect(await waitFor(layingOut: stages) { slide.hasImage }, "the audience shows the first slide")
        Check.equal(slide.shownKey?.pageIndex, 0)
        Check.equal(slide.shownKey?.region, .leftHalf, "the audience sees the slide half only")
        let scale = audience.backingScaleFactor
        Check.equal(slide.imageFrame, CGRect(x: 120, y: 0, width: 720, height: 540), "4:3 slide pillarboxed on 16:9")
        Check.equal(slide.shownKey?.pixelWidth, Int((720 * scale).rounded()), "rendered at the display's pixel size")

        var presenterSlides: [SlideLayerView] { presenter.stage.presenterHost.map(slideViews(in:)) ?? [] }
        Check.expect(await waitFor(layingOut: stages) { presenterSlides.filter(\.hasImage).count >= 3 },
                     "current, next and notes rendered (\(presenterSlides.filter(\.hasImage).count) of \(presenterSlides.count))")
        let parts = Set(presenterSlides.compactMap { view in view.shownKey.map { "\($0.pageIndex)-\($0.region.rawValue)" } })
        Check.expect(parts.contains("0-leftHalf"), "current slide: \(parts)")
        Check.expect(parts.contains("1-leftHalf"), "next slide: \(parts)")
        Check.expect(parts.contains("0-rightHalf"), "notes of the current slide: \(parts)")

        // Keys through the window (whatever has the focus).
        if let right = keyEvent(PresentationKeyMap.KeyCode.rightArrow) { audience.sendEvent(right) }
        Check.equal(controller.currentIndex, 1, "→ in the audience window")
        Check.expect(await waitFor(layingOut: stages) { slide.shownKey?.pageIndex == 1 }, "audience follows")
        if let b = keyEvent(11, "b") { presenter.sendEvent(b) }
        Check.equal(controller.navigator.blank, .black, "B in the presenter window")
        Check.equal(audience.stage.audienceView.shownBlank, .black)
        if let right = keyEvent(PresentationKeyMap.KeyCode.rightArrow) { presenter.sendEvent(right) }
        Check.equal(controller.navigator.blank, .none, "→ brings the slides back")
        Check.equal(controller.currentIndex, 1)
        Check.equal(audience.stage.audienceView.shownBlank, .none)

        // Clicks on the slides.
        if let click = mouseEvent(.leftMouseDown) { audience.stage.audienceView.mouseDown(with: click) }
        Check.equal(controller.currentIndex, 2, "click = next")
        if let click = mouseEvent(.rightMouseDown) { audience.stage.audienceView.rightMouseDown(with: click) }
        Check.equal(controller.currentIndex, 1, "right click = previous")

        // Typed slide number and Return.
        if let three = keyEvent(20, "3") { presenter.sendEvent(three) }
        Check.equal(controller.navigator.typedDigits, "3")
        await presentationSettle()
        if let returnKey = keyEvent(PresentationKeyMap.KeyCode.returnKey, "\r") { presenter.sendEvent(returnKey) }
        Check.equal(controller.currentIndex, 2, "3 + Return")
        Check.equal(controller.navigator.typedDigits, "")

        // Live reload keeps the slide; the views follow the new generation.
        guard let fewer = makeDeck([DeckPage(left: yellow, right: green), DeckPage(left: red, right: blue)],
                                   size: CGSize(width: 800, height: 300)) else { return Check.fail("no deck") }
        defer { try? FileManager.default.removeItem(at: fewer) }
        controller.reload(from: fewer)
        Check.expect(await waitFor { controller.pageCount == 2 }, "reloaded")
        Check.equal(controller.currentIndex, 1, "clamped")
        Check.expect(await waitFor(layingOut: stages) {
            slide.shownKey?.generation == controller.deck.generation && slide.shownKey?.pageIndex == 1
        },
                     "audience shows the reloaded slide")

        // Switching the stage (P on one display) builds the presenter view on demand.
        audience.stage.setMode(.presenter)
        Check.expect(audience.stage.presenterHost != nil && audience.stage.audienceView.isHidden)
        audience.stage.setMode(.audience)
        Check.expect(audience.stage.presenterHost?.isHidden == true && !audience.stage.audienceView.isHidden)

        // Esc ends.
        if let escape = keyEvent(PresentationKeyMap.KeyCode.escape) { presenter.sendEvent(escape) }
        Check.expect(controller.hasEnded, "Esc ends the presentation")
    }

    await Check.suite("Presentation: closing a window ends it") {
        guard let url = makeDeck([DeckPage(left: red), DeckPage(left: blue)], size: CGSize(width: 400, height: 300))
        else { return Check.fail("no deck") }
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PresentationController(title: "Close", notesMode: .automatic)
        var ended = 0
        controller.onEnd = { ended += 1 }
        Check.expect(await controller.load(url))
        let window = offscreenWindow(controller, .presenter, width: 1280, height: 800)
        window.performClose(nil)
        Check.expect(controller.hasEnded, "closing the window ended the presentation")
        Check.equal(ended, 1)
        window.close()
        Check.equal(ended, 1, "closing again is harmless")
    }

    await Check.suite("Presentation: Touch Bar") {
        guard let url = makeDeck([DeckPage(left: red), DeckPage(left: blue), DeckPage(left: green)],
                                 size: CGSize(width: 400, height: 300)) else { return Check.fail("no deck") }
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PresentationController(title: "Bar", notesMode: .automatic)
        Check.expect(await controller.load(url))
        let window = offscreenWindow(controller, .audience, width: 800, height: 600)
        defer { window.close() }
        guard let bar = window.makeTouchBar(), let delegate = bar.delegate else { return Check.fail("no Touch Bar") }
        Check.equal(bar.defaultItemIdentifiers, PresentationTouchBar.defaultItemIdentifiers)
        let navigation = delegate.touchBar?(bar, makeItemForIdentifier: PresentationTouchBar.Item.navigation) as? NSCustomTouchBarItem
        let views = (navigation?.view as? NSStackView)?.arrangedSubviews ?? []
        guard views.count == 3, let previous = views[0] as? NSButton, let counter = views[1] as? NSTextField,
              let next = views[2] as? NSButton else { return Check.fail("navigation item: \(views)") }
        Check.equal(counter.stringValue, "1 / 3")
        Check.expect(!previous.isEnabled, "no previous slide on the first")
        _ = next.sendAction(next.action, to: next.target)
        Check.equal(controller.currentIndex, 1, "Touch Bar › = next slide")
        Check.equal(counter.stringValue, "2 / 3")
        Check.expect(previous.isEnabled)

        let timerItem = delegate.touchBar?(bar, makeItemForIdentifier: PresentationTouchBar.Item.timer) as? NSCustomTouchBarItem
        let timerViews = (timerItem?.view as? NSStackView)?.arrangedSubviews ?? []
        if let label = timerViews.first as? NSTextField, let toggle = timerViews.last as? NSButton {
            Check.equal(label.stringValue, "00:00")
            let wasRunning = controller.timer.isRunning
            _ = toggle.sendAction(toggle.action, to: toggle.target)
            Check.equal(controller.timer.isRunning, !wasRunning, "Touch Bar timer button toggles")
        } else {
            Check.fail("timer item: \(timerViews)")
        }
        let blankItem = delegate.touchBar?(bar, makeItemForIdentifier: PresentationTouchBar.Item.blank) as? NSCustomTouchBarItem
        if let button = blankItem?.view as? NSButton {
            _ = button.sendAction(button.action, to: button.target)
            Check.equal(controller.navigator.blank, .black, "Touch Bar black screen")
        } else {
            Check.fail("no black-screen button")
        }
        let endItem = delegate.touchBar?(bar, makeItemForIdentifier: PresentationTouchBar.Item.end) as? NSCustomTouchBarItem
        if let button = endItem?.view as? NSButton {
            _ = button.sendAction(button.action, to: button.target)
            Check.expect(controller.hasEnded, "Touch Bar End")
        } else {
            Check.fail("no End button")
        }
    }
}

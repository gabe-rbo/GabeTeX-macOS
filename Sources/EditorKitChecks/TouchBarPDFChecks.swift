import AppKit
import CheckKit
import PDFKit
import PreviewKit
import SwiftUI

// Headless checks of the PDF preview's Touch Bar (owned by the touchbar agent). The preview is hosted in an
// offscreen window that is never ordered on screen (SwiftUI needs a window to create the representable's view).

/// A small PDF with real text: page n reads "Page n alpha beta gamma".
private func makeSamplePDF(pages: Int) -> URL? {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    for page in 1...pages {
        context.beginPDFPage(nil)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for line in 0..<12 {
            ("Page \(page) alpha beta gamma \(line)" as NSString)
                .draw(at: CGPoint(x: 30, y: 360 - CGFloat(line) * 28), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        }
        NSGraphicsContext.current = previous
        context.endPDFPage()
    }
    context.closePDF()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("touchbar-pdf-\(UUID().uuidString).pdf")
    do { try (data as Data).write(to: url) } catch { return nil }
    return url
}

private func findPDFView(in view: NSView) -> GabePDFView? {
    if let pdf = view as? GabePDFView { return pdf }
    for subview in view.subviews {
        if let found = findPDFView(in: subview) { return found }
    }
    return nil
}

/// Lets queued main-actor work (observation refreshes, PDFKit layout) run.
private func settle(_ milliseconds: Int = 60) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

private func pdfButton(_ item: NSTouchBarItem?) -> NSButton? {
    (item as? NSCustomTouchBarItem)?.view as? NSButton
}

private func pdfTap(_ button: NSButton?) {
    guard let button else { return Check.fail("missing button") }
    Check.expect(button.isEnabled, "button \(button.accessibilityLabel() ?? "?") enabled")
    _ = button.sendAction(button.action, to: button.target)
}

private func tapSegment(_ control: NSSegmentedControl, _ index: Int) {
    control.trackingMode = .selectOne
    control.selectedSegment = index
    _ = control.sendAction(control.action, to: control.target)
    control.trackingMode = .momentary
}

func touchBarPDFChecks() async {
    typealias Item = PDFTouchBar.Item

    await Check.suite("PDF Touch Bar: bar, page navigation, zoom, Show in Source, app commands") {
        guard let url = makeSamplePDF(pages: 3) else { return Check.fail("could not write a sample PDF") }
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFPreviewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PDFPreviewView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await settle()
        guard let view = findPDFView(in: host) else { return Check.fail("no GabePDFView in the hosted preview") }
        Check.expect(await controller.loadAndWait(url), "sample PDF loaded")
        await settle()

        Check.expect(window.makeFirstResponder(view), "the PDF view accepts first responder")
        var responder: NSResponder? = window.firstResponder
        var resolved: NSTouchBar?
        while let current = responder, resolved == nil {
            resolved = current.touchBar
            responder = current.nextResponder
        }
        Check.equal(resolved?.customizationIdentifier, PDFTouchBar.customizationIdentifier,
                    "the first bar up the responder chain is the PDF bar (docked or separate window alike)")

        guard let bar = view.makeTouchBar() else { return Check.fail("makeTouchBar() returned nil") }
        Check.equal(bar.customizationIdentifier, PDFTouchBar.customizationIdentifier)
        Check.equal(bar.defaultItemIdentifiers, PDFTouchBar.defaultItemIdentifiers)
        for identifier in PDFTouchBar.defaultItemIdentifiers {
            let item = bar.item(forIdentifier: identifier)
            Check.expect(item != nil, "\(identifier.rawValue) produces an item")
            Check.expect(item?.customizationLabel.isEmpty == false, "\(identifier.rawValue) has a customization label")
        }
        for name in PDFTouchBar.symbolNames {
            Check.expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "SF Symbol \(name) exists")
        }

        guard let navigation = (bar.item(forIdentifier: Item.pageNavigation) as? NSCustomTouchBarItem)?.view as? NSStackView,
              navigation.arrangedSubviews.count == 3,
              let previous = navigation.arrangedSubviews[0] as? NSButton,
              let label = navigation.arrangedSubviews[1] as? NSTextField,
              let next = navigation.arrangedSubviews[2] as? NSButton else { return Check.fail("page navigation views") }
        await settle()
        Check.equal(label.stringValue, "1 / 3", "page label")
        Check.expect(!previous.isEnabled && next.isEnabled, "only Next on the first page")
        pdfTap(next)
        await settle(120)
        Check.equal(controller.currentPageIndex, 1, "Next page")
        Check.equal(label.stringValue, "2 / 3", "label follows the controller")
        Check.expect(previous.isEnabled, "Previous enabled on page 2")
        pdfTap(previous)
        await settle(120)
        Check.equal(controller.currentPageIndex, 0, "Previous page")

        guard let zoom = (bar.item(forIdentifier: Item.zoom) as? NSCustomTouchBarItem)?.view as? NSSegmentedControl else {
            return Check.fail("zoom control")
        }
        let scale = controller.scaleFactor
        tapSegment(zoom, 2)
        await settle()
        Check.expect(controller.scaleFactor > scale + 0.001, "zoom in (\(scale) → \(controller.scaleFactor))")
        Check.expect(!controller.autoScales, "no longer fitting the width")
        tapSegment(zoom, 1)
        await settle()
        Check.expect(controller.autoScales, "fit width")
        tapSegment(zoom, 0)
        await settle()
        Check.expect(!controller.autoScales, "zoom out")

        let source = pdfButton(bar.item(forIdentifier: Item.showInSource))
        Check.expect(source?.isEnabled == false, "Show in Source disabled while nobody listens")
        var clicks: [PDFSyncClick] = []
        controller.onSyncClick = { clicks.append($0) }
        controller.touchBarStatus = PDFTouchBarStatus(compile: .ready)   // host change refreshes the bar
        pdfTap(source)
        Check.equal(clicks.count, 1, "Show in Source → onSyncClick")
        Check.equal(clicks.first?.pageIndex, 0, "page of the visible centre")
        Check.expect(["Page", "alpha", "beta", "gamma"].contains(clicks.first?.word ?? "") || Int(clicks.first?.word ?? "") != nil,
                     "a word of the page near the centre (got \(clicks.first?.word ?? "nil"))")
        if let page = controller.pdfView?.document?.page(at: 0), let selection = page.selectionForLine(at: CGPoint(x: 60, y: 365)) {
            controller.pdfView?.setCurrentSelection(selection, animate: false)
            pdfTap(source)
            Check.equal(clicks.last?.word, "Page", "the selection's first word")
            Check.expect(clicks.last?.contextAfter.hasPrefix(" 1 alpha") == true, "context after the word")
            controller.pdfView?.clearSelection()
        } else {
            Check.fail("no line selection on the sample page")
        }

        let compile = pdfButton(bar.item(forIdentifier: Item.compile))
        Check.expect(compile?.isEnabled == false, "Compile disabled without a host")
        var commands: [PDFTouchBarCommand] = []
        controller.onTouchBarCommand = { commands.append($0) }
        controller.touchBarStatus = PDFTouchBarStatus(compile: .ready, isPreviewDetached: false)
        pdfTap(compile)
        Check.equal(commands, [.compile])
        controller.touchBarStatus.compile = .running
        Check.equal(compile?.accessibilityLabel(), String(localized: "Stop"))
        pdfTap(compile)
        Check.equal(commands.last, .stopCompile)
        let windowButton = pdfButton(bar.item(forIdentifier: Item.previewWindow))
        Check.equal(windowButton?.accessibilityLabel(), String(localized: "Open PDF in Separate Window"))
        pdfTap(windowButton)
        Check.equal(commands.last, .togglePreviewWindow)
        controller.touchBarStatus.isPreviewDetached = true
        Check.equal(windowButton?.accessibilityLabel(), String(localized: "Attach PDF to Project Window"))
        controller.touchBarStatus.isPreviewDetached = nil
        Check.expect(windowButton?.isEnabled == false, "no detachable preview → disabled")
        window.contentView = nil
        window.close()
    }
}

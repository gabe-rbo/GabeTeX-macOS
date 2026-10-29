import AppKit
import PDFKit

/// What the PDF preview's Touch Bar shows about the project (set by the host app, see
/// `PDFPreviewController.touchBarStatus`).
public nonisolated struct PDFTouchBarStatus: Equatable, Sendable {
    /// The Compile item: `.running` turns it into Stop.
    public nonisolated enum CompileState: Equatable, Sendable {
        /// Nothing can be compiled: the item is disabled.
        case unavailable
        case ready
        case running
    }

    public var compile: CompileState
    /// Whether the preview is in its own window; nil when the host cannot detach it (item disabled).
    public var isPreviewDetached: Bool?

    public init(compile: CompileState = .unavailable, isPreviewDetached: Bool? = nil) {
        self.compile = compile
        self.isPreviewDetached = isPreviewDetached
    }
}

/// App-level commands sent by the PDF preview's Touch Bar (see `PDFPreviewController.onTouchBarCommand`).
public nonisolated enum PDFTouchBarCommand: Hashable, Sendable {
    case compile
    case stopCompile
    /// Open the preview in its own window, or attach it to the project window again.
    case togglePreviewWindow
}

/// The PDF preview's Touch Bar (shown while a `GabePDFView` — docked or in its own window — is first
/// responder): Compile, page navigation, zoom, Show in Source, attach/detach. Customizable.
public enum PDFTouchBar {
    public static let customizationIdentifier = NSTouchBar.CustomizationIdentifier("io.github.gabe-rbo.GabeTeX.pdf")

    public enum Item {
        public static let compile = make("compile")
        /// Previous page, "3 / 12", next page.
        public static let pageNavigation = make("pageNavigation")
        /// Zoom out, fit width, zoom in.
        public static let zoom = make("zoom")
        public static let showInSource = make("showInSource")
        public static let previewWindow = make("previewWindow")

        private static func make(_ name: String) -> NSTouchBarItem.Identifier {
            NSTouchBarItem.Identifier("io.github.gabe-rbo.GabeTeX.pdf.\(name)")
        }
    }

    public static let defaultItemIdentifiers: [NSTouchBarItem.Identifier] = [
        Item.compile, Item.pageNavigation, Item.zoom, Item.showInSource, Item.previewWindow,
    ]

    public static let customizationAllowedItemIdentifiers: [NSTouchBarItem.Identifier] =
        defaultItemIdentifiers + [.flexibleSpace, .fixedSpaceSmall, .fixedSpaceLarge]

    /// SF Symbols used by the bar (each has a text fallback).
    public static let symbolNames: [String] = [
        "play.fill", "stop.fill", "chevron.left", "chevron.right", "minus.magnifyingglass",
        "arrow.left.and.right", "plus.magnifyingglass", "chevron.left.forwardslash.chevron.right",
        "arrow.up.forward.app", "arrow.down.right.and.arrow.up.left",
    ]
}

extension PDFPreviewController {
    /// Project state shown by the PDF Touch Bar. Setting it updates a live Touch Bar immediately; nothing
    /// visible happens on Macs without a Touch Bar.
    public var touchBarStatus: PDFTouchBarStatus {
        get { PDFTouchBarSlot.existing(for: self)?.status ?? PDFTouchBarStatus() }
        set {
            let slot = PDFTouchBarSlot.slot(for: self)
            guard slot.status != newValue else { return }
            slot.status = newValue
            PDFTouchBarProvider.hostStateDidChange(for: self)
        }
    }

    /// Receives the Touch Bar's app-level commands. While nil, Compile and attach/detach are disabled.
    public var onTouchBarCommand: ((PDFTouchBarCommand) -> Void)? {
        get { PDFTouchBarSlot.existing(for: self)?.onCommand }
        set {
            PDFTouchBarSlot.slot(for: self).onCommand = newValue
            PDFTouchBarProvider.hostStateDidChange(for: self)
        }
    }

    /// "Show in Source" without a click: reports the first word of the PDF selection, or else the text nearest
    /// to the centre of the visible area, through `onSyncClick` (or `onInverseSearch` when that is not set).
    /// Returns false when there is no PDF on screen or nobody listens.
    @discardableResult
    public func showSourceOfVisibleArea() -> Bool {
        guard let view = previewView, let click = view.sourceSyncClick() else { return false }
        if let onSyncClick {
            onSyncClick(click)
            return true
        }
        if let onInverseSearch {
            onInverseSearch(click.pageIndex, click.point)
            return true
        }
        return false
    }

    /// Whether `showSourceOfVisibleArea()` can do something.
    var canShowSource: Bool {
        hasDocument && (onSyncClick != nil || onInverseSearch != nil)
    }
}

/// Touch Bar state kept beside a `PDFPreviewController` (whose stored properties live in PreviewKit.swift).
final class PDFTouchBarSlot {
    weak var owner: PDFPreviewController?
    var status = PDFTouchBarStatus()
    var onCommand: ((PDFTouchBarCommand) -> Void)?

    private static var slots: [ObjectIdentifier: PDFTouchBarSlot] = [:]

    private init(owner: PDFPreviewController) {
        self.owner = owner
    }

    static func existing(for controller: PDFPreviewController) -> PDFTouchBarSlot? {
        guard let slot = slots[ObjectIdentifier(controller)] else { return nil }
        return slot.owner === controller ? slot : nil
    }

    static func slot(for controller: PDFPreviewController) -> PDFTouchBarSlot {
        if let slot = existing(for: controller) { return slot }
        slots = slots.filter { $0.value.owner != nil }
        let slot = PDFTouchBarSlot(owner: controller)
        slots[ObjectIdentifier(controller)] = slot
        return slot
    }
}

extension GabePDFView {
    /// The text a "Show in Source" request refers to: the selection's first word (with page context), else
    /// the character nearest to the centre of the visible area. Nil without a document.
    func sourceSyncClick() -> PDFSyncClick? {
        guard let document, document.pageCount > 0 else { return nil }

        if let selection = currentSelection, let page = selection.pages.first,
           let string = selection.string, string.contains(where: { $0.isLetter || $0.isNumber }) {
            let index = document.index(for: page)
            if index != NSNotFound {
                let box = selection.bounds(for: page)
                var click = PDFSyncClick(pageIndex: index, point: CGPoint(x: box.midX, y: box.midY))
                let pageText = (page.string ?? "") as NSString
                var start = selection.numberOfTextRanges(on: page) > 0 ? selection.range(at: 0, on: page).location : NSNotFound
                if start != NSNotFound, start < pageText.length {
                    // Skip leading spaces/punctuation of the selection.
                    while start < pageText.length, !PDFWordScan.isWordCharacter(at: start, in: pageText) { start += 1 }
                    PDFWordScan.fill(&click, from: pageText, at: start)
                } else {
                    click.word = PDFWordScan.firstWord(in: string)
                }
                return click
            }
        }

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        guard let page = page(for: center, nearest: true) else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        let pagePoint = convert(center, to: page)
        let pageText = (page.string ?? "") as NSString
        guard let nearest = PDFWordScan.nearestCharacter(on: page, to: pagePoint, length: pageText.length) else {
            return PDFSyncClick(pageIndex: index, point: pagePoint)
        }
        var click = PDFSyncClick(pageIndex: index, point: nearest.point)
        PDFWordScan.fill(&click, from: pageText, at: nearest.index)
        return click
    }
}

/// Word and context extraction from a PDF page's text (UTF-16, composed characters kept whole).
enum PDFWordScan {
    static let contextLength = 40

    static func isWordCharacter(at index: Int, in text: NSString) -> Bool {
        guard index >= 0, index < text.length else { return false }
        let range = text.rangeOfComposedCharacterSequence(at: index)
        guard let scalar = text.substring(with: range).unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Sets `word`, `contextBefore` and `contextAfter` of `click` from the word containing `index`.
    static func fill(_ click: inout PDFSyncClick, from text: NSString, at index: Int) {
        guard isWordCharacter(at: index, in: text) else { return }
        var start = text.rangeOfComposedCharacterSequence(at: index).location
        while start > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: start - 1)
            guard isWordCharacter(at: previous.location, in: text) else { break }
            start = previous.location
        }
        var end = start
        while end < text.length, isWordCharacter(at: end, in: text) {
            let r = text.rangeOfComposedCharacterSequence(at: end)
            end = r.location + r.length
        }
        click.word = text.substring(with: NSRange(location: start, length: end - start))
        var beforeStart = max(0, start - contextLength)
        if beforeStart > 0 { beforeStart = text.rangeOfComposedCharacterSequence(at: beforeStart).location }
        click.contextBefore = text.substring(with: NSRange(location: beforeStart, length: start - beforeStart))
        var afterEnd = min(text.length, end + contextLength)
        if afterEnd < text.length {
            let r = text.rangeOfComposedCharacterSequence(at: afterEnd)
            if r.location < afterEnd { afterEnd = r.location }
        }
        click.contextAfter = text.substring(with: NSRange(location: end, length: max(0, afterEnd - end)))
    }

    static func firstWord(in string: String) -> String? {
        let text = string as NSString
        var i = 0
        while i < text.length, !isWordCharacter(at: i, in: text) { i += 1 }
        guard i < text.length else { return nil }
        var click = PDFSyncClick(pageIndex: 0, point: .zero)
        fill(&click, from: text, at: i)
        return click.word
    }

    /// The character nearest to `point` (page space), searching outwards (lines first, then along the line).
    static func nearestCharacter(on page: PDFPage, to point: CGPoint, length: Int) -> (point: CGPoint, index: Int)? {
        guard length > 0 else { return nil }
        let text = (page.string ?? "") as NSString
        let verticalSteps: [CGFloat] = [0] + (1...12).flatMap { [CGFloat($0) * -7, CGFloat($0) * 7] }
        let horizontalSteps: [CGFloat] = [0, -30, 30, -80, 80, -160, 160]
        for dx in horizontalSteps {
            for dy in verticalSteps {
                let candidate = CGPoint(x: point.x + dx, y: point.y + dy)
                let index = page.characterIndex(at: candidate)
                // Only a word character counts: the point may sit on the space between two words.
                if index >= 0, index < length, PDFWordScan.isWordCharacter(at: index, in: text) {
                    return (candidate, index)
                }
            }
        }
        // Nothing close to the point (e.g. the visible centre lies in a margin of a zoomed-out page): take the
        // word character whose bounds are nearest on the whole page. This runs only on an explicit tap, so a
        // linear scan (bounded for very long pages) is fine.
        var best: (distance: CGFloat, point: CGPoint, index: Int)?
        for index in 0..<min(length, text.length, 50_000) where PDFWordScan.isWordCharacter(at: index, in: text) {
            let bounds = page.characterBounds(at: index)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let dx = max(bounds.minX - point.x, 0, point.x - bounds.maxX)
            let dy = max(bounds.minY - point.y, 0, point.y - bounds.maxY)
            let distance = dx * dx + dy * dy
            if distance < (best?.distance ?? .infinity) {
                best = (distance, CGPoint(x: bounds.midX, y: bounds.midY), index)
            }
        }
        return best.map { ($0.point, $0.index) }
    }
}

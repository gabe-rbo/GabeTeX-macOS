import AppKit
import PDFKit
import SwiftUI
import Observation

/// A rectangle to highlight after a forward search.
public struct PDFHighlight: Sendable, Hashable {
    /// 0-based page index.
    public var pageIndex: Int
    /// Rectangle in PDF page space (points, origin bottom-left).
    public var rect: CGRect

    public init(pageIndex: Int, rect: CGRect) {
        self.pageIndex = pageIndex
        self.rect = rect
    }
}

/// Which gesture in the PDF asks to jump to the source (inverse SyncTeX).
public enum PDFSyncTrigger: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Double-click on text (also selects the word, like Overleaf).
    case doubleClick
    /// ⌘-click (TeXShop / Skim convention).
    case commandClick

    public var id: String { rawValue }
}

/// A sync request from the PDF: where the user clicked and which word of the PDF text is there, so the
/// app can place the caret on that exact word in the source (SyncTeX alone only knows the line).
public struct PDFSyncClick: Sendable, Hashable {
    /// 0-based page index.
    public var pageIndex: Int
    /// Clicked point in PDF page space (points, origin bottom-left).
    public var point: CGPoint
    /// The word of the PDF text under the click (letters/digits; ligatures and hyphenation resolved by
    /// PDFKit), or nil when the click is not on text.
    public var word: String?
    /// Up to ~40 characters of page text right before / after `word` (for disambiguation), may be empty.
    public var contextBefore: String
    public var contextAfter: String

    public init(pageIndex: Int, point: CGPoint, word: String? = nil, contextBefore: String = "", contextAfter: String = "") {
        self.pageIndex = pageIndex
        self.point = point
        self.word = word
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

/// How `showHighlights` moves the document.
public enum PDFHighlightScroll: Sendable, Hashable {
    /// Scroll so that the (first) highlight is centered in the view. The default.
    case center
    /// Scroll (centering) only when the highlight is not fully visible already; otherwise leave the document where it
    /// is. For silent syncs such as "follow the cursor".
    case ifNeeded
}

/// Drives the PDF preview. Reloading keeps the visible position and zoom.
///
/// The controller owns the loaded `PDFDocument`, so it works whether or not a `PDFPreviewView` is currently on
/// screen: a view that appears later receives the document and the reading position the last view had.
///
/// **Moving the preview to another window.** Host the same controller in a `PDFPreviewView` of the other window
/// (and remove the old one whenever convenient). The newest view wins: it receives the document, the page, the zoom
/// (or "fit width") and the highlights still waiting to be shown, and from then on drives the observable state and
/// the callbacks. The previous view is retired for good, so it can neither steal the controller back on a late
/// SwiftUI update nor disturb it when it is dismantled. Both views may coexist for a moment.
@Observable
public final class PDFPreviewController {
    /// Smallest and largest zoom (1 = 100 %).
    public static let minimumScale: CGFloat = 0.25
    public static let maximumScale: CGFloat = 8

    /// Preset zoom levels used by `zoomIn()` / `zoomOut()`.
    private static let zoomStops: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75,
                                               2, 2.5, 3, 4, 6, 8]

    // MARK: Observable state

    /// The file last passed to `load(_:)`.
    public private(set) var pdfURL: URL?
    public internal(set) var pageCount = 0
    /// 0-based index of the page at the center of the view.
    public internal(set) var currentPageIndex = 0
    public internal(set) var scaleFactor: CGFloat = 1

    /// `true` while the PDF follows the width of the view ("fit width"). Set it to `true` to re-fit; the view
    /// turns it off by itself when the user zooms.
    public var autoScales: Bool {
        get {
            access(keyPath: \.autoScales)
            return autoScalesStorage
        }
        set {
            updateAutoScales(newValue)
            guard let view = previewView, view.fitsWidth != newValue else { return }
            if newValue { view.fitWidth() } else { view.stopFittingWidth() }
        }
    }

    /// `true` once a PDF has been loaded successfully (and until `unload()`).
    public private(set) var hasDocument = false
    /// `true` while a `load(_:)` is waiting for the file to settle on disk.
    public private(set) var isLoading = false
    /// Why the latest load failed; `nil` after a successful load. The last good PDF stays visible.
    public private(set) var loadFailure: PDFLoadFailure?

    /// `true` unless the zoom is already at its largest / smallest value.
    public var canZoomIn: Bool { hasDocument && scaleFactor < Self.maximumScale - 0.001 }
    public var canZoomOut: Bool { hasDocument && scaleFactor > Self.minimumScale + 0.001 }

    // MARK: Callbacks

    /// Legacy sync callback: 0-based page index and point in PDF page space. Fires together with `onSyncClick`
    /// (same gesture, same values); a client that sets only this one keeps getting ⌘-clicks, whatever `syncTrigger`
    /// says. Clear it when `onSyncClick` is used, or the jump happens twice.
    @ObservationIgnored public var onInverseSearch: ((Int, CGPoint) -> Void)?

    /// The gesture that triggers `onSyncClick` (default: double-click). Takes effect with the next click.
    @ObservationIgnored public var syncTrigger: PDFSyncTrigger = .doubleClick
    /// Sync request from the PDF, fired for `syncTrigger` on a page: a double-click selects the word as usual and is
    /// reported right after; a ⌘-click is reported and kept from PDFKit. `word` is the PDF word under the pointer
    /// (nil when the pointer is not on text), `contextBefore` / `contextAfter` about 40 characters of page text
    /// around it (whitespace collapsed, line-end hyphenation joined, ligatures expanded).
    @ObservationIgnored public var onSyncClick: ((PDFSyncClick) -> Void)?

    @ObservationIgnored public internal(set) weak var pdfView: PDFView?

    // MARK: Private state

    @ObservationIgnored private var autoScalesStorage = true
    @ObservationIgnored private var document: PDFDocument?
    @ObservationIgnored private var documentData: Data?
    @ObservationIgnored private var loadTask: Task<Bool, Never>?
    @ObservationIgnored private var loadGeneration = 0
    /// Reading position of a view that went away, handed to the next view.
    @ObservationIgnored private var savedState: PDFViewState?
    /// Highlights requested while the PDF is still loading / no view is attached yet.
    @ObservationIgnored private var pendingHighlights: PendingHighlights?
    @ObservationIgnored private var suppressRefresh = false
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var wantsHighlightFlush = false

    /// A highlight request that could not be shown yet. Text matching happens when it is finally shown, against the
    /// PDF that is on screen by then.
    private struct PendingHighlights {
        var items: [PDFHighlight]
        var text: String?
        var contextBefore: String
        var contextAfter: String
        var scroll: PDFHighlightScroll
        var date: Date
    }

    public init() {}

    var previewView: GabePDFView? { pdfView as? GabePDFView }

    // MARK: Loading

    /// Loads or reloads the PDF at `url` (re-reads it from disk even if the URL is unchanged),
    /// preserving the current page, scroll offset and scale.
    ///
    /// Returns immediately. The file is read into memory off the main thread (never memory-mapped); if it does
    /// not end with `%%EOF` yet – `latexmk` is still writing – the read is retried for about a second. When the
    /// file is missing or broken the previous PDF stays on screen and `loadFailure` is set. Calling `load` again
    /// supersedes a load still in progress, and `showHighlights(_:)` calls made meanwhile wait for the swap.
    public func load(_ url: URL) {
        startLoading(url)
    }

    /// Like `load(_:)`, but waits until the new PDF is on screen. Returns `false` when it could not be
    /// shown (see `loadFailure`) or the request was superseded by a newer one.
    @discardableResult
    public func loadAndWait(_ url: URL) async -> Bool {
        await startLoading(url).value
    }

    @discardableResult
    private func startLoading(_ url: URL) -> Task<Bool, Never> {
        pdfURL = url
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        let task = Task { [weak self] () -> Bool in
            let result = await PDFFileReader.read(url)
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return false }
            return self.finishLoading(result)
        }
        loadTask = task
        return task
    }

    private func finishLoading(_ result: Result<Data, PDFLoadFailure>) -> Bool {
        isLoading = false
        loadTask = nil
        switch result {
        case .failure(let failure):
            loadFailure = failure
            pendingHighlights = nil
            return false
        case .success(let data):
            if document != nil, data == documentData {
                // Byte-identical to what is on screen: nothing to swap, nothing to flash.
                loadFailure = nil
                flushPendingHighlights()
                return true
            }
            guard let newDocument = PDFDocument(data: data), newDocument.pageCount > 0, !newDocument.isLocked else {
                loadFailure = .invalid
                pendingHighlights = nil
                return false
            }
            document = newDocument
            documentData = data
            loadFailure = nil
            hasDocument = true
            pageCount = newDocument.pageCount
            if let view = previewView {
                view.replaceDocument(newDocument)
                savedState = nil
            }
            refreshFromView()
            flushPendingHighlights()
            return true
        }
    }

    /// Removes the PDF (e.g. when another project is opened). The view shows only its background.
    public func unload() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        isLoading = false
        document = nil
        documentData = nil
        savedState = nil
        pendingHighlights = nil
        pdfURL = nil
        loadFailure = nil
        hasDocument = false
        pageCount = 0
        currentPageIndex = 0
        previewView?.clearDocument()
    }

    // MARK: Highlights

    /// Scrolls to the first highlight (centered) and shows all of them briefly (fade out after ~1.5 s).
    /// Honors Reduce Motion. Call it right after `load(_:)` if you like: the highlights are held back until the
    /// new PDF is on screen (and dropped if it fails to load or if more than 5 s pass).
    public func showHighlights(_ highlights: [PDFHighlight], scroll: PDFHighlightScroll = .center) {
        request(PendingHighlights(items: highlights, text: nil, contextBefore: "", contextAfter: "",
                                  scroll: scroll, date: Date()))
    }

    /// Like `showHighlights(_:)`, but when `text` (e.g. the word at the editor's caret) occurs in the page
    /// text inside or near a highlight box (within about a line), highlights exactly that occurrence instead of the
    /// whole box: tight around the word, centered in the view, same style and fade as the boxes.
    ///
    /// Matching ignores case, accents and ligatures (the PDF's "ﬁ" matches "fi"), understands LaTeX accent
    /// forms in `text` (`\'e`, `{\c c}`), sees through line-end hyphenation (a ≥ 4-letter beginning of the word
    /// before a hyphen counts), and prefers whole words. Among several occurrences the one whose surrounding text
    /// agrees best with `contextBefore` / `contextAfter` (source text around the word; markup is ignored) wins,
    /// then the one closest to a box. Without any usable occurrence the boxes are highlighted.
    public func showHighlights(_ highlights: [PDFHighlight], matching text: String?, contextBefore: String = "",
                               contextAfter: String = "", scroll: PDFHighlightScroll = .center) {
        request(PendingHighlights(items: highlights, text: text, contextBefore: contextBefore,
                                  contextAfter: contextAfter, scroll: scroll, date: Date()))
    }

    private func request(_ request: PendingHighlights) {
        guard !isLoading, let view = previewView else {
            pendingHighlights = request
            return
        }
        present(request, in: view)
    }

    private func present(_ request: PendingHighlights, in view: GabePDFView) {
        var items = request.items
        if let text = request.text, let document {
            items = PDFTextLocator.resolve(items, matching: text, contextBefore: request.contextBefore,
                                           contextAfter: request.contextAfter, in: document)
        }
        view.presentHighlights(items, scroll: request.scroll)
    }

    private func flushPendingHighlights() {
        guard let pending = pendingHighlights, let view = previewView else { return }
        pendingHighlights = nil
        guard Date().timeIntervalSince(pending.date) < 5 else { return }
        present(pending, in: view)
    }

    // MARK: Zoom and navigation

    public func zoomIn() { stepZoom(by: 1) }
    public func zoomOut() { stepZoom(by: -1) }

    /// Fit page width (and keep following the width of the view as it is resized).
    public func zoomToFitWidth() {
        previewView?.fitWidth()
        refreshFromView()
    }

    /// 100 %.
    public func zoomToActualSize() { setScale(1) }

    /// Zooms to `scale` (1 = 100 %), clamped to the supported range, around the center of the view.
    public func setScale(_ scale: CGFloat) {
        previewView?.zoom(to: scale)
        refreshFromView()
    }

    private func stepZoom(by direction: Int) {
        guard let view = previewView, view.document != nil else { return }
        let current = view.scaleFactor
        let target: CGFloat
        if direction > 0 {
            target = Self.zoomStops.first { $0 > current * 1.004 } ?? Self.maximumScale
        } else {
            target = Self.zoomStops.last { $0 < current * 0.996 } ?? Self.minimumScale
        }
        setScale(target)
    }

    public func goToPage(_ index: Int) {
        guard let view = previewView, let document = view.document, document.pageCount > 0 else { return }
        let clamped = min(max(index, 0), document.pageCount - 1)
        guard let page = document.page(at: clamped) else { return }
        view.go(to: page)
        refreshFromView()
    }

    public func goToNextPage() { goToPage(currentPageIndex + 1) }
    public func goToPreviousPage() { goToPage(currentPageIndex - 1) }

    /// Scrolls to the top of the first page.
    public func scrollToTop() {
        previewView?.scrollToTop()
        refreshFromView()
    }

    // MARK: View attachment (used by `PDFPreviewView`)

    /// Makes `view` the controller's view: the newest view wins. A view that was retired never attaches again.
    func attach(_ view: GabePDFView) {
        guard !view.isRetired, pdfView !== view else { return }
        // The same view moved to another controller: let go of the old one first.
        if let other = view.controller, other !== self { other.detach(view) }
        // Two views at once (the preview is moving between windows): the old one is out for good.
        if let old = previewView {
            old.isRetired = true
            detach(old)
        }
        pdfView = view
        view.controller = self
        view.onSyncClick = { [weak self] click in self?.deliver(click) }
        view.onViewportChange = { [weak self] in self?.viewportChanged() }
        if let document {
            suppressRefresh = true
            view.replaceDocument(document, fallbackState: savedState)
            suppressRefresh = false
            savedState = nil
        }
        // `attach` runs inside a SwiftUI update pass, where observable state must not change: refresh next turn.
        scheduleRefresh(flushingHighlights: true)
    }

    /// Lets go of `view`. When it is the current view its reading position and any highlight still waiting for a
    /// window are kept for the next one.
    func detach(_ view: GabePDFView) {
        guard pdfView === view else {
            if view.controller === self {
                view.onSyncClick = nil
                view.onViewportChange = nil
                view.controller = nil
            }
            return
        }
        savedState = view.captureViewState() ?? savedState
        if let deferred = view.takeDeferredHighlights() {
            pendingHighlights = PendingHighlights(items: deferred.items, text: nil, contextBefore: "", contextAfter: "",
                                                  scroll: deferred.scroll, date: Date())
        }
        view.onSyncClick = nil
        view.onViewportChange = nil
        view.controller = nil
        pdfView = nil
    }

    /// A sync gesture in the view: the new callback first, then the legacy one.
    private func deliver(_ click: PDFSyncClick) {
        onSyncClick?(click)
        onInverseSearch?(click.pageIndex, click.point)
    }

    /// Scroll / zoom / layout notifications. They can arrive in the middle of a SwiftUI layout pass, where
    /// observable state must not change, so the refresh hops to the next main-actor turn (and coalesces).
    private func viewportChanged() {
        guard !suppressRefresh else { return }
        scheduleRefresh()
    }

    private func scheduleRefresh(flushingHighlights: Bool = false) {
        wantsHighlightFlush = wantsHighlightFlush || flushingHighlights
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshFromView()
            if self.wantsHighlightFlush, !self.isLoading {
                self.wantsHighlightFlush = false
                self.flushPendingHighlights()
            }
        }
    }

    /// Copies page count, page, zoom and zoom mode from the view into the observable properties.
    func refreshFromView() {
        guard let view = previewView else { return }
        let count = view.document?.pageCount ?? 0
        if pageCount != count { pageCount = count }
        let scale = view.scaleFactor
        if scaleFactor != scale { scaleFactor = scale }
        updateAutoScales(view.fitsWidth)
        if let index = view.centerPageIndex, currentPageIndex != index { currentPageIndex = index }
    }

    private func updateAutoScales(_ value: Bool) {
        guard autoScalesStorage != value else { return }
        withMutation(keyPath: \.autoScales) { autoScalesStorage = value }
    }
}

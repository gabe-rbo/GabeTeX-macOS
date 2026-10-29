import Foundation
import CoreGraphics
import QuartzCore

// Rendering of slides into bitmaps, off the main thread.
//
// Slides are drawn with Core Graphics (`CGPDFDocument` is immutable and `Sendable`) into images of exactly the
// pixel size they are shown at, then handed to plain `CALayer`s: page changes are instant (images of the
// neighbouring slides are rendered ahead), sharp on every display, and transitions are a layer animation.

// MARK: - Deck

/// One page of the presented PDF.
public nonisolated struct SlidePageInfo: Hashable, Sendable {
    /// Display size in points: the crop box, with the page rotation applied.
    public var size: CGSize
    /// The page's own transition (`/Trans`), if it asks for one.
    public var transition: SlideTransition?

    public init(size: CGSize, transition: SlideTransition? = nil) {
        self.size = size
        self.transition = transition
    }
}

/// A snapshot of the presented document: pages and where their notes are. A new generation replaces it on every
/// reload, so images of an older PDF are never mistaken for current ones.
public nonisolated struct SlideDeck: Hashable, Sendable {
    public var generation: Int
    public var pages: [SlidePageInfo]
    /// Where the notes are on split pages, nil when pages are shown whole.
    public var notesSide: NotesSide?

    public init(generation: Int = 0, pages: [SlidePageInfo] = [], notesSide: NotesSide? = nil) {
        self.generation = generation
        self.pages = pages
        self.notesSide = notesSide
    }

    public static let empty = SlideDeck()

    public var pageCount: Int { pages.count }

    /// `true` when at least the first page has a notes half.
    public var hasNotes: Bool {
        guard let first = pages.first else { return false }
        return SlideGeometry.regions(pageSize: first.size, side: notesSide).notes != nil
    }

    public func regions(ofPage index: Int) -> SlideRegions? {
        guard pages.indices.contains(index) else { return nil }
        return SlideGeometry.regions(pageSize: pages[index].size, side: notesSide)
    }

    /// The region of `part` on page `index`, nil when the page does not exist or has no notes.
    public func region(_ part: SlidePart, ofPage index: Int) -> PageRegion? {
        guard let regions = regions(ofPage: index) else { return nil }
        switch part {
        case .slide: return regions.slide
        case .notes: return regions.notes
        }
    }

    /// Size in points of `part` of page `index`.
    public func size(of part: SlidePart, ofPage index: Int) -> CGSize? {
        guard let region = region(part, ofPage: index) else { return nil }
        return region.size(onPage: pages[index].size)
    }
}

/// The slide itself or the speaker's notes half of a page.
public nonisolated enum SlidePart: String, Hashable, Sendable {
    case slide, notes
}

// MARK: - Transitions

/// A page transition (from the PDF's `/Trans` dictionary, or the default dissolve).
public nonisolated struct SlideTransition: Hashable, Sendable {
    public enum Style: String, Hashable, Sendable {
        /// An instant change (the PDF asks for `/R`, "replace").
        case cut
        case fade, push, moveIn, reveal
    }

    /// Where the new slide comes from (`push`, `moveIn`, `reveal`).
    public enum Direction: String, Hashable, Sendable {
        case fromLeft, fromRight, fromTop, fromBottom
    }

    public var style: Style
    public var duration: TimeInterval
    public var direction: Direction

    public init(style: Style, duration: TimeInterval, direction: Direction = .fromRight) {
        self.style = style
        self.duration = duration
        self.direction = direction
    }

    /// The short dissolve used between slides that do not specify a transition.
    public static let standard = SlideTransition(style: .fade, duration: 0.14)

    /// Maps a PDF transition (`/S` style name, `/D` duration, `/Di` direction in degrees) to one the layers can
    /// play. `R` (replace) is an instant cut; styles without an equivalent become a dissolve; unknown names give
    /// nil (the default transition). Durations are kept between 0.05 s and 1.5 s.
    public static func fromPDF(style name: String, duration: Double?, direction degrees: Int?) -> SlideTransition? {
        let seconds = min(max(duration ?? 1, 0.05), 1.5)
        let direction: Direction
        switch ((degrees ?? 0) % 360 + 360) % 360 {
        case 90: direction = .fromBottom
        case 180: direction = .fromRight
        case 270: direction = .fromTop
        default: direction = .fromLeft
        }
        switch name {
        case "R": return SlideTransition(style: .cut, duration: 0)
        case "Push": return SlideTransition(style: .push, duration: seconds, direction: direction)
        case "Cover": return SlideTransition(style: .moveIn, duration: seconds, direction: direction)
        case "Uncover": return SlideTransition(style: .reveal, duration: seconds, direction: direction)
        case "Dissolve", "Fade", "Wipe", "Split", "Blinds", "Box", "Glitter", "Fly":
            return SlideTransition(style: .fade, duration: seconds)
        default: return nil
        }
    }

    /// A Core Animation transition playing this one; nil for a cut.
    @MainActor func caTransition() -> CATransition? {
        guard style != .cut, duration > 0 else { return nil }
        let transition = CATransition()
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        switch style {
        case .cut, .fade: transition.type = .fade
        case .push: transition.type = .push
        case .moveIn: transition.type = .moveIn
        case .reveal: transition.type = .reveal
        }
        if style != .fade && style != .cut {
            switch direction {
            case .fromLeft: transition.subtype = .fromLeft
            case .fromRight: transition.subtype = .fromRight
            case .fromTop: transition.subtype = .fromTop
            case .fromBottom: transition.subtype = .fromBottom
            }
        }
        return transition
    }
}

// MARK: - Reading the PDF

nonisolated enum SlidePDF {
    /// Opens PDF bytes for presenting; nil when they are not a PDF with pages that can be drawn.
    static func document(from data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.isUnlocked, document.numberOfPages > 0 else { return nil }
        return document
    }

    /// Size and transition of every page.
    static func pageInfos(of document: CGPDFDocument) -> [SlidePageInfo] {
        guard document.numberOfPages > 0 else { return [] }
        return (1...document.numberOfPages).map { number in
            guard let page = document.page(at: number) else { return SlidePageInfo(size: .zero) }
            return SlidePageInfo(size: displaySize(of: page), transition: transition(of: page))
        }
    }

    /// The crop box size with the page rotation applied.
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    /// The page's `/Trans` dictionary as a `SlideTransition`.
    static func transition(of page: CGPDFPage) -> SlideTransition? {
        guard let dictionary = page.dictionary else { return nil }
        var trans: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Trans", &trans), let trans else { return nil }
        var name: UnsafePointer<CChar>?
        let style = CGPDFDictionaryGetName(trans, "S", &name) ? name.map { String(cString: $0) } ?? "R" : "R"
        var duration: CGPDFReal = 1
        let hasDuration = CGPDFDictionaryGetNumber(trans, "D", &duration)
        var degrees: CGPDFInteger = 0
        let hasDirection = CGPDFDictionaryGetInteger(trans, "Di", &degrees)
        return SlideTransition.fromPDF(style: style, duration: hasDuration ? Double(duration) : nil,
                                       direction: hasDirection ? Int(degrees) : nil)
    }
}

// MARK: - Rasterizing

/// What to render: a region of a page of one deck generation, at an exact pixel size.
public nonisolated struct SlideImageKey: Hashable, Sendable {
    public var generation: Int
    public var pageIndex: Int
    public var region: PageRegion
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(generation: Int, pageIndex: Int, region: PageRegion, pixelWidth: Int, pixelHeight: Int) {
        self.generation = generation
        self.pageIndex = pageIndex
        self.region = region
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var byteCount: Int { pixelWidth * pixelHeight * 4 }
}

/// Draws pages of one document into bitmaps, one at a time, off the main actor. Each rasterizer opens its own
/// `CGPDFDocument` from the (immutable) bytes, so no document is ever drawn from two threads at once.
actor SlideRasterizer {
    private let document: CGPDFDocument?

    init(data: Data) {
        self.document = SlidePDF.document(from: data)
    }

    func render(_ key: SlideImageKey) -> CGImage? {
        guard let document else { return nil }
        return Self.draw(document, key)
    }

    /// Renders `key.region` of the page, filling the bitmap (the region's aspect ratio is the caller's business):
    /// white paper, the page content clipped to its crop box, high-quality interpolation.
    nonisolated static func draw(_ document: CGPDFDocument, _ key: SlideImageKey) -> CGImage? {
        guard key.pixelWidth > 0, key.pixelHeight > 0, key.pixelWidth <= 16384, key.pixelHeight <= 16384,
              let page = document.page(at: key.pageIndex + 1),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: key.pixelWidth, height: key.pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let display = SlidePDF.displaySize(of: page)
        guard display.width > 0, display.height > 0 else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: key.pixelWidth, height: key.pixelHeight))
        context.interpolationQuality = .high
        context.setShouldAntialias(true)

        let unit = key.region.unitRect
        let region = CGRect(x: unit.minX * display.width, y: unit.minY * display.height,
                            width: unit.width * display.width, height: unit.height * display.height)
        context.scaleBy(x: CGFloat(key.pixelWidth) / region.width, y: CGFloat(key.pixelHeight) / region.height)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.clip(to: CGRect(origin: .zero, size: display))
        // Maps the crop box (with its origin and the page rotation) onto (0, 0, display size) at scale 1 —
        // `getDrawingTransform` never scales up, so the scaling is done above.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: display),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

// MARK: - Cache

/// Renders slide images on demand and keeps the recent ones (bounded by memory). Main actor; the drawing itself
/// happens on two background rasterizers.
public final class SlideRenderer {
    /// Upper bound of the cached bitmaps.
    static let byteBudget = 256 * 1024 * 1024

    public private(set) var generation = 0
    private var rasterizers: [SlideRasterizer] = []
    private var nextRasterizer = 0
    private var cache: [SlideImageKey: CGImage] = [:]
    /// Least recently used first.
    private var recency: [SlideImageKey] = []
    private var cachedBytes = 0
    private var waiting: [SlideImageKey: [(CGImage?) -> Void]] = [:]

    public init() {}

    /// Starts a new generation for the PDF bytes `data` (nil: nothing to draw). Images of older generations are
    /// dropped; renders still running for them are discarded when they finish.
    @discardableResult
    func setDocument(_ data: Data?) -> Int {
        generation += 1
        rasterizers = data.map { bytes in [SlideRasterizer(data: bytes), SlideRasterizer(data: bytes)] } ?? []
        nextRasterizer = 0
        cache.removeAll()
        recency.removeAll()
        cachedBytes = 0
        return generation
    }

    /// A finished image for `key`, if one is cached.
    public func cachedImage(for key: SlideImageKey) -> CGImage? {
        guard let image = cache[key] else { return nil }
        touch(key)
        return image
    }

    /// Delivers the image for `key` (from the cache right away, else once rendered; nil when it cannot be drawn).
    /// Requests for the same key share one render.
    public func image(for key: SlideImageKey, priority: TaskPriority = .userInitiated,
                      completion: @escaping (CGImage?) -> Void) {
        if let image = cachedImage(for: key) {
            completion(image)
            return
        }
        guard key.generation == generation, !rasterizers.isEmpty else {
            completion(nil)
            return
        }
        if waiting[key] != nil {
            waiting[key, default: []].append(completion)
            return
        }
        waiting[key] = [completion]
        let rasterizer = rasterizers[nextRasterizer % rasterizers.count]
        nextRasterizer &+= 1
        Task(priority: priority) { [weak self] in
            let image = await rasterizer.render(key)
            self?.finish(key, image: image)
        }
    }

    /// Renders `key` ahead of time (low priority) unless it is cached or already being rendered.
    public func prefetch(_ key: SlideImageKey) {
        guard cache[key] == nil, waiting[key] == nil, key.generation == generation else { return }
        image(for: key, priority: .utility) { _ in }
    }

    /// The image for `key`, awaiting a render when needed.
    public func image(for key: SlideImageKey) async -> CGImage? {
        await withCheckedContinuation { continuation in
            image(for: key) { continuation.resume(returning: $0) }
        }
    }

    /// Number of cached images (for checks).
    public var cachedImageCount: Int { cache.count }

    private func finish(_ key: SlideImageKey, image: CGImage?) {
        let completions = waiting.removeValue(forKey: key) ?? []
        if let image, key.generation == generation, key.byteCount <= Self.byteBudget {
            store(image, for: key)
        }
        for completion in completions { completion(image) }
    }

    private func store(_ image: CGImage, for key: SlideImageKey) {
        if cache[key] == nil { cachedBytes += key.byteCount }
        cache[key] = image
        touch(key)
        while cachedBytes > Self.byteBudget, let oldest = recency.first {
            recency.removeFirst()
            if cache.removeValue(forKey: oldest) != nil { cachedBytes -= oldest.byteCount }
        }
    }

    private func touch(_ key: SlideImageKey) {
        if let index = recency.lastIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }
}

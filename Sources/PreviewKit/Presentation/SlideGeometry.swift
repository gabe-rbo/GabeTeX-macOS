import Foundation
import CoreGraphics

// Pure geometry of a presentation: Beamer notes split, aspect fitting, which display gets which window, and
// what the root document's preamble says about presenting. Covered by the headless checks.

// MARK: - Beamer notes

/// The side of each PDF page that holds the speaker notes
/// (`\setbeameroption{show notes on second screen=<side>}`; Beamer's default is `right`).
public nonisolated enum NotesSide: String, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// The "Notes on" setting of the presenter view.
public nonisolated enum PresentationNotesMode: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Pages about twice as wide as a slide are split; the side comes from the preamble (default: right).
    case automatic
    /// Notes in the right half of double-width pages.
    case right
    /// Notes in the left half of double-width pages.
    case left
    /// Never split: every page is a slide.
    case off

    public var id: String { rawValue }

    /// User-facing name (localized).
    public var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .right: String(localized: "Right Half")
        case .left: String(localized: "Left Half")
        case .off: String(localized: "No Notes")
        }
    }
}

/// The part of a PDF page that is drawn (in page display space: crop box, rotation applied).
public nonisolated enum PageRegion: String, Hashable, Sendable, CaseIterable {
    case whole, leftHalf, rightHalf, bottomHalf, topHalf

    /// The region in unit coordinates of the page (origin bottom-left, like PDF page space).
    public var unitRect: CGRect {
        switch self {
        case .whole: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .bottomHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .topHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        }
    }

    /// Size of the region on a page of `pageSize` points.
    public func size(onPage pageSize: CGSize) -> CGSize {
        let unit = unitRect
        return CGSize(width: pageSize.width * unit.width, height: pageSize.height * unit.height)
    }
}

/// Which part of a page the audience sees and which part is the speaker's notes.
public nonisolated struct SlideRegions: Hashable, Sendable {
    public var slide: PageRegion
    /// nil when the page has no notes half.
    public var notes: PageRegion?

    public init(slide: PageRegion, notes: PageRegion?) {
        self.slide = slide
        self.notes = notes
    }
}

public nonisolated enum SlideGeometry {
    /// A page at least this many times wider than tall is a slide with its notes beside it. Beamer slides are at
    /// most 16:9 (≈ 1.78); with notes on the second screen they become ≥ 2.5 (5:4 doubled), 2.67 (4:3) or 3.56
    /// (16:9).
    public static let doubleWidthRatio: CGFloat = 2.2

    /// `true` for a page about twice as wide as a slide.
    public static func isDoubleWidth(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return size.width / size.height >= doubleWidthRatio
    }

    /// `true` for a portrait page: a landscape slide with its notes above or below it. Only used together with an
    /// explicit `top` / `bottom` from the preamble (an article page is portrait too).
    public static func isDoubleHeight(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > size.width
    }

    /// Where the notes are for a document whose (first) page has `pageSize`, or nil when pages are not split.
    ///
    /// - `.off` never splits. `.right` / `.left` split double-width pages on that side.
    /// - `.automatic` follows the preamble's `hint` when the page shape agrees with it (`left` / `right` need a
    ///   double-width page, `top` / `bottom` a portrait one) and otherwise splits double-width pages on the right,
    ///   Beamer's default.
    public static func notesSide(mode: PresentationNotesMode, pageSize: CGSize, hint: NotesSide?) -> NotesSide? {
        let wide = isDoubleWidth(pageSize)
        switch mode {
        case .off: return nil
        case .right: return wide ? .right : nil
        case .left: return wide ? .left : nil
        case .automatic:
            switch hint {
            case .left?, .right?: return wide ? hint : nil
            case .top?, .bottom?: return isDoubleHeight(pageSize) ? hint : (wide ? .right : nil)
            case nil: return wide ? .right : nil
            }
        }
    }

    /// The slide and notes regions of a page of `pageSize` in a document whose notes are on `side`. A page that
    /// does not have the split shape (an appended full-size page, say) is shown whole, without notes.
    public static func regions(pageSize: CGSize, side: NotesSide?) -> SlideRegions {
        switch side {
        case .right? where isDoubleWidth(pageSize): SlideRegions(slide: .leftHalf, notes: .rightHalf)
        case .left? where isDoubleWidth(pageSize): SlideRegions(slide: .rightHalf, notes: .leftHalf)
        case .bottom? where isDoubleHeight(pageSize): SlideRegions(slide: .topHalf, notes: .bottomHalf)
        case .top? where isDoubleHeight(pageSize): SlideRegions(slide: .bottomHalf, notes: .topHalf)
        default: SlideRegions(slide: .whole, notes: nil)
        }
    }

    /// The largest rectangle of `size`'s aspect ratio that fits in `rect`, centered. Pass `scale` (pixels per
    /// point) to snap it to the pixel grid. An empty size or rect gives `.zero`.
    public static func aspectFit(_ size: CGSize, in rect: CGRect, scale: CGFloat = 0) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return .zero }
        let factor = min(rect.width / size.width, rect.height / size.height)
        var width = size.width * factor
        var height = size.height * factor
        var x = rect.minX + (rect.width - width) / 2
        var y = rect.minY + (rect.height - height) / 2
        if scale > 0 {
            width = (width * scale).rounded() / scale
            height = (height * scale).rounded() / scale
            x = (x * scale).rounded() / scale
            y = (y * scale).rounded() / scale
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Pixel size of a rendering of a `pointSize` area at `scale`, at least 1 × 1 and at most `maximum` on the
    /// longer side (aspect ratio kept).
    public static func pixelSize(for pointSize: CGSize, scale: CGFloat, maximum: Int = 8192) -> (width: Int, height: Int) {
        guard pointSize.width > 0, pointSize.height > 0, scale > 0 else { return (0, 0) }
        var width = pointSize.width * scale
        var height = pointSize.height * scale
        let longest = max(width, height)
        if longest > CGFloat(maximum) {
            let shrink = CGFloat(maximum) / longest
            width *= shrink
            height *= shrink
        }
        return (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
    }
}

// MARK: - Displays

/// What the presentation needs to know about a display.
public nonisolated struct PresentationScreen: Hashable, Sendable {
    /// `CGDirectDisplayID` (`NSScreenNumber`).
    public var id: UInt32
    /// Frame in global screen coordinates (points).
    public var frame: CGRect
    /// The laptop's own panel.
    public var isBuiltIn: Bool
    public var name: String

    public init(id: UInt32, frame: CGRect, isBuiltIn: Bool, name: String = "") {
        self.id = id
        self.frame = frame
        self.isBuiltIn = isBuiltIn
        self.name = name
    }
}

/// Which display shows the slides and which one the presenter view.
public nonisolated struct PresentationScreenPlan: Hashable, Sendable {
    /// The display that shows the slides full screen.
    public var audience: UInt32
    /// The display of the presenter view; nil with a single display (the presenter view is toggled with P).
    public var presenter: UInt32?

    public init(audience: UInt32, presenter: UInt32?) {
        self.audience = audience
        self.presenter = presenter
    }
}

public nonisolated enum PresentationScreenPlanner {
    /// - One display: the slides on it, no separate presenter display.
    /// - Several: the presenter view goes to the built-in display (the speaker sits at the laptop); without one,
    ///   to `preferredPresenter` (the display of the project window) when it is connected, else to the first
    ///   display. The slides go to the first other display. `swapped` exchanges the two.
    /// - Mirrored displays count as one (`NSScreen.screens` lists a mirror set once).
    public static func plan(screens: [PresentationScreen], preferredPresenter: UInt32?, swapped: Bool) -> PresentationScreenPlan? {
        guard let first = screens.first else { return nil }
        guard screens.count > 1 else { return PresentationScreenPlan(audience: first.id, presenter: nil) }
        let presenter: PresentationScreen
        if let builtIn = screens.first(where: \.isBuiltIn) {
            presenter = builtIn
        } else if let preferredPresenter, let preferred = screens.first(where: { $0.id == preferredPresenter }) {
            presenter = preferred
        } else {
            presenter = first
        }
        guard let audience = screens.first(where: { $0.id != presenter.id }) else {
            return PresentationScreenPlan(audience: presenter.id, presenter: nil)
        }
        return swapped
            ? PresentationScreenPlan(audience: presenter.id, presenter: audience.id)
            : PresentationScreenPlan(audience: audience.id, presenter: presenter.id)
    }
}

// MARK: - Source hints

/// What the root document's preamble says about presenting: the document class (the toolbar shows "Present" for
/// Beamer) and where `\setbeameroption{show notes on second screen=…}` puts the notes.
public nonisolated struct PresentationSourceInfo: Hashable, Sendable {
    /// Classes made for slides.
    public static let presentationClasses: Set<String> = ["beamer", "ltx-talk"]

    /// The class name of `\documentclass[…]{name}`, nil when there is none.
    public var documentClass: String?
    /// The notes side requested in the preamble, nil when the preamble does not ask for notes on a second screen.
    public var notesSide: NotesSide?

    public init(documentClass: String? = nil, notesSide: NotesSide? = nil) {
        self.documentClass = documentClass
        self.notesSide = notesSide
    }

    /// `true` for a Beamer (or other slide-class) document.
    public var isPresentation: Bool {
        documentClass.map { Self.presentationClasses.contains($0) } ?? false
    }

    /// Scans the preamble of a root document (everything before `\begin{document}`, at most the first 4 000
    /// lines), ignoring comments (`%` to the end of the line, but not `\%`).
    public static func scan(_ source: String) -> PresentationSourceInfo {
        var preamble = ""
        preamble.reserveCapacity(min(source.utf8.count, 64 * 1024))
        var lineCount = 0
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineCount += 1
            if lineCount > 4000 { break }
            let line = withoutComment(rawLine)
            if let range = line.range(of: "\\begin{document}") {
                preamble += line[line.startIndex..<range.lowerBound]
                break
            }
            preamble += line
            preamble += "\n"
        }

        var info = PresentationSourceInfo()
        let text = preamble as NSString
        let whole = NSRange(location: 0, length: text.length)
        let classPattern = try? NSRegularExpression(pattern: classPatternSource)
        let notesPattern = try? NSRegularExpression(pattern: notesPatternSource, options: [.caseInsensitive])
        if let match = classPattern?.firstMatch(in: preamble, range: whole), match.range(at: 1).location != NSNotFound {
            let name = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { info.documentClass = name }
        }
        if let matches = notesPattern?.matches(in: preamble, range: whole), let last = matches.last {
            let sideRange = last.range(at: 1)
            if sideRange.location != NSNotFound {
                info.notesSide = NotesSide(rawValue: text.substring(with: sideRange).lowercased())
            } else {
                info.notesSide = .right
            }
        }
        return info
    }

    private static let classPatternSource = #"\\documentclass\s*(?:\[[^\]]*\]\s*)?\{\s*([^}\s]+)\s*\}"#
    private static let notesPatternSource =
        #"\\setbeameroption\s*\{\s*show\s+notes\s+on\s+second\s+screen\s*(?:=\s*(left|right|top|bottom)\s*)?\}"#

    /// The line up to its first unescaped `%`.
    private static func withoutComment(_ line: Substring) -> Substring {
        var backslashes = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "%" && backslashes % 2 == 0 { return line[line.startIndex..<index] }
            backslashes = character == "\\" ? backslashes + 1 : 0
            index = line.index(after: index)
        }
        return line
    }
}

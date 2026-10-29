import AppKit

/// Timing and accessibility knobs of the "reveal" flash (`LaTeXTextView.reveal`, `EditorController.goTo`).
/// The defaults are the product behaviour; only tests and unusual hosts need to change them.
public struct RevealFlashOptions: Equatable, Sendable {
    /// Full-strength phase before the fade starts.
    public var hold: Duration = .milliseconds(250)
    /// Fade-out time after `hold` (hold + fade ≈ 1.2 s in total).
    public var fade: Duration = .milliseconds(950)
    /// With Reduce Motion: how long the highlight stays (at full strength, no animation) before it is removed.
    public var reducedMotionDuration: Duration = .milliseconds(800)
    /// `nil` follows the system "Reduce Motion" setting; `true`/`false` force it.
    public var reduceMotion: Bool?

    public init(hold: Duration = .milliseconds(250), fade: Duration = .milliseconds(950),
                reducedMotionDuration: Duration = .milliseconds(800), reduceMotion: Bool? = nil) {
        self.hold = hold
        self.fade = fade
        self.reducedMotionDuration = reducedMotionDuration
        self.reduceMotion = reduceMotion
    }
}

/// Draws and animates the soft accent-colored rounded highlight behind a range of the text.
///
/// - It is **drawing only**: nothing is written to the text storage, the undo manager or the buffer's
///   dirty state, and no layout-manager attribute is touched. The rects are recomputed from the layout
///   manager on every draw/tick, so the highlight follows scrolling, wrapping and re-layout while it fades.
/// - One flash at a time: `start` cancels the previous one; `cancel` is also called on buffer swaps,
///   character edits and when the view leaves its window.
/// - The fade is driven by a main-actor task that invalidates the flash rects every ~16 ms; every task
///   carries a generation number, so a cancelled flash can never remove its successor.
final class RevealFlashController {
    private weak var textView: LaTeXTextView?
    /// The text range being flashed (nil when idle).
    private(set) var range: NSRange?
    private var startedAt: ContinuousClock.Instant?
    private var options = RevealFlashOptions()
    private var reduceMotion = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private let clock = ContinuousClock()

    /// Vertical room taken from each line fragment so wrapped lines keep a thin gap between them.
    private let verticalInset: CGFloat = 1
    /// Horizontal padding around the text.
    private let horizontalPadding: CGFloat = 3

    init(textView: LaTeXTextView) {
        self.textView = textView
    }

    var isActive: Bool { range != nil }

    /// 1 while held, fading to 0; 0 when idle. With Reduce Motion it is 1 until the flash is removed.
    var intensity: Double {
        guard range != nil, let startedAt else { return 0 }
        let elapsed = seconds(clock.now - startedAt)
        if reduceMotion { return elapsed < seconds(options.reducedMotionDuration) ? 1 : 0 }
        let hold = seconds(options.hold)
        let fade = max(0.001, seconds(options.fade))
        if elapsed <= hold { return 1 }
        if elapsed >= hold + fade { return 0 }
        let x = (elapsed - hold) / fade
        return 1 - x * x * (3 - 2 * x)   // smoothstep: a soft start and a long, gentle tail
    }

    /// Starts flashing `newRange` (already clamped to the text), replacing any running flash.
    func start(range newRange: NSRange) {
        cancel()
        guard newRange.length > 0, let textView else { return }
        options = textView.revealFlashOptions
        reduceMotion = options.reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        range = newRange
        startedAt = clock.now
        generation += 1
        let mine = generation
        invalidate()
        task = Task { [weak self] in
            await self?.run(generation: mine)
        }
    }

    /// Stops the flash at once and repaints the area it covered. Safe to call when idle, and from a text
    /// storage delegate callback (it only uses the rects remembered from the last draw/tick, never layout).
    func cancel() {
        guard range != nil || task != nil else { return }
        task?.cancel()
        task = nil
        generation += 1
        range = nil
        startedAt = nil
        repaintAndForgetCoveredArea()
    }

    private func run(generation mine: Int) async {
        if reduceMotion {
            try? await Task.sleep(for: options.reducedMotionDuration)
            guard !Task.isCancelled, generation == mine else { return }
            finish()
            return
        }
        let total = options.hold + options.fade
        while !Task.isCancelled, generation == mine {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, generation == mine, textView != nil else { return }
            guard let startedAt, clock.now - startedAt < total else {
                finish()
                return
            }
            invalidate()
        }
    }

    private func finish() {
        task = nil
        range = nil
        startedAt = nil
        repaintAndForgetCoveredArea()
    }

    private func repaintAndForgetCoveredArea() {
        let covered = lastDrawnBounds
        lastDrawnBounds = []
        invalidate(rects: covered)
    }

    // MARK: - Geometry

    /// Union of what was last invalidated/drawn, so the final repaint also clears stale pixels.
    private var lastDrawnBounds: [NSRect] = []

    /// The highlight rects in view coordinates: one per line fragment the range touches (wrapped lines
    /// get one each), hugging the text horizontally and filling the line vertically (minus a thin gap).
    func rects() -> [NSRect] {
        guard let range, let textView, let lm = textView.layoutManager, let storage = textView.textStorage else { return [] }
        let text = storage.mutableString
        let clamped = range.clamped(to: text.length)
        guard clamped.length > 0 else { return [] }
        let origin = textView.textContainerOrigin
        let glyphs = lm.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return [] }
        var result: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, fragmentGlyphs, _ in
            var chars = NSIntersectionRange(clamped, lm.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil))
            // Never paint the line terminator (it would stretch to the end of the line).
            while chars.length > 0, TextScan.isLineBreak(text.character(at: chars.end - 1)) { chars.length -= 1 }
            guard chars.length > 0 else { return }
            let sub = lm.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            let bounds = lm.boundingRect(forGlyphRange: sub, in: container)
            let width = max(bounds.width, 2)
            result.append(NSRect(x: bounds.minX + origin.x - self.horizontalPadding,
                                 y: fragment.minY + origin.y + self.verticalInset,
                                 width: width + self.horizontalPadding * 2,
                                 height: max(2, fragment.height - self.verticalInset * 2)))
        }
        return result
    }

    private func invalidate(rects explicit: [NSRect]? = nil) {
        guard let textView else { return }
        let current = explicit ?? rects()
        if explicit == nil { lastDrawnBounds = current }
        for rect in current {
            textView.setNeedsDisplay(rect.insetBy(dx: -2, dy: -2), avoidAdditionalLayout: true)
        }
    }

    // MARK: - Drawing

    /// Called from `drawBackground(in:)`: paints the highlight behind the text.
    func draw(in dirtyRect: NSRect) {
        guard range != nil else { return }
        let level = intensity
        guard level > 0 else { return }
        // The rects remembered from the last tick tell whether any of the flash can be in this dirty rect;
        // if not, don't touch layout from inside a draw (the range may be far off-screen).
        guard lastDrawnBounds.contains(where: { $0.insetBy(dx: -8, dy: -8).intersects(dirtyRect) }) else { return }
        let all = rects()
        lastDrawnBounds = all
        let visible = all.filter { $0.intersects(dirtyRect) }
        guard !visible.isEmpty else { return }
        EditorTheme.revealFlash(intensity: level).setFill()
        for rect in visible {
            NSBezierPath(roundedRect: rect, xRadius: min(5, rect.height / 3), yRadius: min(5, rect.height / 3)).fill()
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

import AppKit
import TeXCore

/// Tokenizer injection point: a pure function from text to sorted, non-overlapping tokens.
/// It may run off the main actor (large documents), so it must be `@Sendable`.
public typealias LaTeXTokenizing = @Sendable (NSString) -> [LaTeXToken]

/// Syntax highlighting with layout-manager **temporary attributes** (never touches the text storage:
/// no undo registration, no dirtiness, no relayout, so no scroll jumps).
///
/// Pipeline per edit:
/// 1. `noteEdit` (from the text storage notification) shifts the cached tokens and marks the edited
///    lines dirty — O(tokens after the edit), no layout access.
/// 2. `flush` (after the edit completed) re-tokenizes — synchronously for normal files, on a background
///    task for large ones (results are transformed through edits made meanwhile) — and diffs old vs new
///    tokens so only the region whose tokens changed is re-colored.
/// 3. Dirty regions intersecting the visible area (+ one screen of margin) are colored immediately;
///    the rest is colored in small idle slices, and on scroll.
final class SyntaxHighlighter {
    unowned let textView: LaTeXTextView
    var tokenize: LaTeXTokenizing

    /// Current tokens (in current text coordinates; approximate while a re-tokenization is pending).
    private(set) var tokens: [LaTeXToken] = []
    private var dirty = IndexSet()
    /// Lines touched by edits whose fresh tokens are not known yet. They keep the (inherited) colors
    /// they have until the tokenizer result is installed, so typing never flashes uncolored text.
    private var editDirty = IndexSet()
    private var version = 0
    private var needsTokenize = false
    private var asyncTask: Task<Void, Never>?
    private var editLog: [(version: Int, range: NSRange, delta: Int)] = []
    private var generation = 0
    private var idleScheduled = false

    /// Documents up to this size are re-tokenized synchronously on each edit (if fast enough).
    var syncLengthLimit = 200_000
    /// Documents up to this size are tokenized synchronously when first shown (no uncolored flash).
    var attachSyncLengthLimit = 2_000_000
    /// Above this measured tokenization time, switch to background tokenization.
    var syncDurationLimit: Double = 0.008
    /// Seconds spent in the last tokenization.
    private(set) var lastTokenizeDuration: Double = 0
    /// Set when the highlighter is waiting for a background tokenization.
    var isTokenizingInBackground: Bool { asyncTask != nil }

    init(textView: LaTeXTextView, tokenize: @escaping LaTeXTokenizing) {
        self.textView = textView
        self.tokenize = tokenize
    }

    private var storage: NSTextStorage? { textView.textStorage }
    private var layoutManager: NSLayoutManager? { textView.layoutManager }

    // MARK: - Lifecycle

    /// Starts over for a newly attached text storage. `cachedTokens` (still valid for this text) avoid
    /// re-tokenizing when switching back to a buffer.
    func reset(cachedTokens: [LaTeXToken]?) {
        generation += 1
        asyncTask?.cancel()
        asyncTask = nil
        editLog = []
        version += 1
        idleScheduled = false
        let length = storage?.length ?? 0
        dirty = length > 0 ? IndexSet(integersIn: 0..<length) : IndexSet()
        editDirty = IndexSet()
        if let cachedTokens {
            tokens = cachedTokens
            needsTokenize = false
        } else {
            tokens = []
            needsTokenize = true
            if length <= attachSyncLengthLimit { tokenizeSynchronously() } else { startBackgroundTokenization() }
        }
        applyVisible()
        scheduleIdle()
    }

    /// Re-colors everything (theme change, re-attach).
    func invalidateAll() {
        let length = storage?.length ?? 0
        dirty = length > 0 ? IndexSet(integersIn: 0..<length) : IndexSet()
        applyVisible()
        scheduleIdle()
    }

    // MARK: - Edits

    /// Records an edit. Called from the text storage's didProcessEditing notification (layout is not
    /// valid yet, so this only updates data). `dirtyLines` is the edited range extended to whole lines.
    func noteEdit(editedRange: NSRange, delta: Int, dirtyLines: NSRange) {
        version += 1
        Self.shift(&tokens, editedRange: editedRange, delta: delta)
        let oldEnd = editedRange.location + editedRange.length - delta
        Self.shift(&dirty, editedRange: editedRange, oldEnd: oldEnd, delta: delta)
        Self.shift(&editDirty, editedRange: editedRange, oldEnd: oldEnd, delta: delta)
        if dirtyLines.length > 0 {
            editDirty.insert(integersIn: dirtyLines.location..<dirtyLines.end)
        }
        if let length = storage?.length {
            if let last = dirty.last, last >= length { dirty.remove(integersIn: length..<(last + 1)) }
            if let last = editDirty.last, last >= length { editDirty.remove(integersIn: length..<(last + 1)) }
        }
        needsTokenize = true
        if asyncTask != nil { editLog.append((version, editedRange, delta)) }
    }

    /// Brings highlighting up to date after edits: re-tokenize and color the visible dirty region now.
    func flush() {
        if needsTokenize {
            let length = storage?.length ?? 0
            if asyncTask == nil, length <= syncLengthLimit, lastTokenizeDuration < syncDurationLimit {
                tokenizeSynchronously()
            } else {
                startBackgroundTokenization()
            }
        }
        applyVisible()
        scheduleIdle()
    }

    /// Colors everything that is still dirty, synchronously (tests, printing, export).
    func flushCompletely() {
        if needsTokenize || asyncTask != nil { tokenizeSynchronously() }
        let pending = Array(dirty.rangeView)
        for r in pending { applyColors(NSRange(location: r.lowerBound, length: r.count)) }
        dirty.removeAll()
    }

    /// Colors dirty text in `range` now (scrolling, before drawing).
    func ensureColored(_ range: NSRange) {
        guard !dirty.isEmpty, range.length > 0 else { return }
        let pieces = dirty.rangeView(of: range.location..<range.end).map { $0 }
        for piece in pieces {
            let lo = max(piece.lowerBound, range.location)
            let hi = min(piece.upperBound, range.end)
            guard hi > lo else { continue }
            applyColors(NSRange(location: lo, length: hi - lo))
            dirty.remove(integersIn: lo..<hi)
        }
    }

    var hasPendingWork: Bool { needsTokenize || !dirty.isEmpty || !editDirty.isEmpty || asyncTask != nil }

    /// True when some text still needs coloring with the current tokens.
    var hasDirtyRegions: Bool { !dirty.isEmpty }

    // MARK: - Queries

    /// The token containing `offset`, if any.
    func token(containing offset: Int) -> LaTeXToken? {
        let i = Self.firstIndex(endingAfter: offset, in: tokens)
        guard i < tokens.count, tokens[i].range.location <= offset else { return nil }
        return tokens[i]
    }

    /// True when `offset` (a caret position) is inside math mode according to the current tokens.
    func isMath(at offset: Int) -> Bool {
        let before = offset > 0 ? token(containing: offset - 1)?.kind : nil
        let after = token(containing: offset)?.kind
        let mathKinds: Set<LaTeXTokenKind> = [.math, .mathCommand]
        if let b = before, mathKinds.contains(b) { return true }
        if let a = after, mathKinds.contains(a) { return true }
        return before == .mathDelimiter && after == .mathDelimiter
    }

    /// Tokens intersecting `range`.
    func tokens(intersecting range: NSRange) -> ArraySlice<LaTeXToken> {
        let lo = Self.firstIndex(endingAfter: range.location, in: tokens)
        var hi = lo
        while hi < tokens.count, tokens[hi].range.location < max(range.end, range.location + 1) { hi += 1 }
        return tokens[lo..<hi]
    }

    // MARK: - Tokenization

    private func tokenizeSynchronously() {
        guard let storage else { return }
        generation += 1          // drop any in-flight background result
        asyncTask?.cancel()
        asyncTask = nil
        editLog = []
        let clock = ContinuousClock()
        let start = clock.now
        let fresh = tokenize(storage.mutableString)
        lastTokenizeDuration = Self.seconds(clock.now - start)
        install(fresh)
        needsTokenize = false
    }

    private func startBackgroundTokenization() {
        guard asyncTask == nil, let storage else { return }   // an in-flight run restarts itself when done
        let snapshot = storage.string
        let baseVersion = version
        let gen = generation
        let tokenize = self.tokenize
        editLog = []
        needsTokenize = false
        asyncTask = Task.detached(priority: .userInitiated) { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            let result = tokenize(snapshot as NSString)
            let elapsed = SyntaxHighlighter.seconds(clock.now - start)
            await self?.backgroundTokenizationFinished(result, baseVersion: baseVersion, generation: gen, duration: elapsed)
        }
    }

    private func backgroundTokenizationFinished(_ result: [LaTeXToken], baseVersion: Int, generation gen: Int, duration: Double) {
        guard gen == generation else { return }
        asyncTask = nil
        lastTokenizeDuration = duration
        var transformed = result
        for entry in editLog where entry.version > baseVersion {
            Self.shift(&transformed, editedRange: entry.range, delta: entry.delta)
        }
        editLog = []
        if let length = storage?.length {
            transformed.removeAll { $0.range.end > length }
        }
        install(transformed)
        applyVisible()
        scheduleIdle()
        if needsTokenize { flush() }
    }

    private func install(_ fresh: [LaTeXToken]) {
        if let changed = Self.changedRange(old: tokens, new: fresh), let length = storage?.length {
            let r = changed.clamped(to: length)
            if r.length > 0 { dirty.insert(integersIn: r.location..<r.end) }
        }
        dirty.formUnion(editDirty)
        editDirty = IndexSet()
        tokens = fresh
    }

    // MARK: - Coloring

    private func applyVisible() {
        guard !dirty.isEmpty, let visible = textView.visibleCharacterRange(marginScreens: 1) else { return }
        ensureColored(visible)
    }

    private func applyColors(_ range: NSRange) {
        guard let layoutManager, let storage else { return }
        let r = range.clamped(to: storage.length)
        guard r.length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
        var i = Self.firstIndex(endingAfter: r.location, in: tokens)
        while i < tokens.count {
            let token = tokens[i]
            if token.range.location >= r.end { break }
            let piece = NSIntersectionRange(token.range, r)
            if piece.length > 0 {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind),
                                                    forCharacterRange: piece)
            }
            i += 1
        }
    }

    private func scheduleIdle() {
        guard !dirty.isEmpty, !idleScheduled else { return }
        idleScheduled = true
        let gen = generation
        Task { [weak self] in
            guard let self, gen == self.generation else { return }
            self.idleScheduled = false
            self.idleStep()
        }
    }

    private func idleStep() {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(4)
        // Prefer what is near the viewport, then the rest in document order.
        if let visible = textView.visibleCharacterRange(marginScreens: 3) {
            ensureColored(visible)
        }
        while clock.now < deadline, let first = dirty.rangeView.first {
            let end = min(first.upperBound, first.lowerBound + 8_192)
            applyColors(NSRange(location: first.lowerBound, length: end - first.lowerBound))
            dirty.remove(integersIn: first.lowerBound..<end)
        }
        scheduleIdle()
    }

    // MARK: - Pure helpers

    nonisolated static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }

    /// Index of the first token whose end is > `offset`.
    nonisolated static func firstIndex(endingAfter offset: Int, in tokens: [LaTeXToken]) -> Int {
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid].range.location + tokens[mid].range.length <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Moves an index set through an edit: indexes after the replaced range shift by `delta`, indexes
    /// inside it are dropped (the caller marks the edited lines dirty itself).
    nonisolated static func shift(_ set: inout IndexSet, editedRange: NSRange, oldEnd: Int, delta: Int) {
        guard !set.isEmpty else { return }
        let start = editedRange.location
        if oldEnd > start { set.remove(integersIn: start..<oldEnd) }
        if delta != 0 { set.shift(startingAt: oldEnd, by: delta) }
    }

    /// Moves tokens through an edit: tokens before it stay, tokens after it shift by `delta`,
    /// tokens overlapping the replaced range are dropped (their lines are re-colored anyway).
    nonisolated static func shift(_ tokens: inout [LaTeXToken], editedRange: NSRange, delta: Int) {
        guard !tokens.isEmpty else { return }
        let start = editedRange.location
        let oldEnd = editedRange.location + editedRange.length - delta
        let first = firstIndex(endingAfter: start, in: tokens)
        guard first < tokens.count else { return }
        var write = first
        var read = first
        while read < tokens.count {
            var t = tokens[read]
            if t.range.location >= oldEnd {
                t.range.location += delta
                tokens[write] = t
                write += 1
            } else if t.range.location + t.range.length <= start {
                tokens[write] = t
                write += 1
            }
            // else: overlaps the replaced text → dropped
            read += 1
        }
        if write < tokens.count { tokens.removeSubrange(write..<tokens.count) }
    }

    /// The character range covering every difference between two token lists (nil when identical).
    nonisolated static func changedRange(old: [LaTeXToken], new: [LaTeXToken]) -> NSRange? {
        let common = min(old.count, new.count)
        var i = 0
        while i < common, old[i] == new[i] { i += 1 }
        if i == old.count && i == new.count { return nil }
        var j = 0
        while j < common - i, old[old.count - 1 - j] == new[new.count - 1 - j] { j += 1 }
        var lo = Int.max
        var hi = Int.min
        if i < old.count - j {
            lo = min(lo, old[i].range.location)
            hi = max(hi, old[old.count - 1 - j].range.end)
        }
        if i < new.count - j {
            lo = min(lo, new[i].range.location)
            hi = max(hi, new[new.count - 1 - j].range.end)
        }
        guard lo <= hi else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }
}

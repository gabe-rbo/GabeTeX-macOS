import Foundation

// VimKit is main-actor isolated by default (see Package.swift).

/// The text the Vim engine edits. EditorKit adapts NSTextView to this protocol.
/// All offsets/ranges are UTF-16 (NSString) based.
public protocol VimTextBuffer: AnyObject {
    /// Current full text.
    var vimText: NSString { get }
    /// Selection. In normal mode the engine keeps `length == 0` and the block cursor covers the
    /// character at `location`; in visual modes it is the visual selection (inclusive of the cursor char).
    var vimSelection: NSRange { get set }
    /// Replace text (must be undoable). The engine wraps multi-step changes in begin/end undo groups.
    func vimReplace(_ range: NSRange, with string: String)
    func vimBeginUndoGroup()
    func vimEndUndoGroup()
    func vimUndo()
    func vimRedo()
    /// 1-based first/last fully visible lines, for H/M/L and Ctrl-D/Ctrl-U/Ctrl-F/Ctrl-B; nil if unknown.
    var vimVisibleLines: ClosedRange<Int>? { get }
}

public enum VimMode: String, Sendable, Hashable, CaseIterable {
    case normal, insert, visual, visualLine, replace, commandLine

    /// Short status label, e.g. "NORMAL" (not localized — Vim convention).
    public var label: String {
        switch self {
        case .normal: "NORMAL"
        case .insert: "INSERT"
        case .visual: "VISUAL"
        case .visualLine: "V-LINE"
        case .replace: "REPLACE"
        case .commandLine: "COMMAND"
        }
    }
}

/// A key press as seen by Vim.
public struct VimKey: Hashable, Sendable {
    public enum Special: String, Hashable, Sendable {
        case escape, enter, backspace, tab, delete, left, right, up, down, home, end, pageUp, pageDown
    }
    /// The produced character(s) for printable keys (already shifted, e.g. "D", "$", "{"); nil for specials.
    public var character: String?
    public var special: Special?
    public var control: Bool

    public init(_ character: String, control: Bool = false) {
        self.character = character
        self.special = nil
        self.control = control
    }

    public init(special: Special, control: Bool = false) {
        self.character = nil
        self.special = special
        self.control = control
    }

    public static let escape = VimKey(special: .escape)
    public static let enter = VimKey(special: .enter)
    public static let backspace = VimKey(special: .backspace)

    /// Ctrl+`character` (e.g. `VimKey.ctrl("r")` for redo).
    public static func ctrl(_ character: String) -> VimKey { VimKey(character, control: true) }
}

/// Ex commands the host must handle (the engine handles motions/edits itself).
public enum VimExCommand: Hashable, Sendable {
    case write              // :w
    case quit               // :q
    case writeQuit          // :wq / :x
    case writeAll           // :wa
    case compile            // :make / :TeX
    case goToLine(Int)      // :42 (the engine also moves the cursor itself)
    case unknown(String)
}

/// A buffer that does nothing; used while no `handle` call is in progress.
final class DetachedBuffer: VimTextBuffer {
    static let shared = DetachedBuffer()
    var vimText: NSString { "" }
    var vimSelection = NSRange(location: 0, length: 0)
    func vimReplace(_ range: NSRange, with string: String) {}
    func vimBeginUndoGroup() {}
    func vimEndUndoGroup() {}
    func vimUndo() {}
    func vimRedo() {}
    var vimVisibleLines: ClosedRange<Int>? { nil }
}

/// Vim emulation state machine. See ARCHITECTURE.md §VimKit for the required command set.
///
/// The engine is fed one key at a time through ``handle(_:in:)``. It keeps the cursor in sync with
/// `VimTextBuffer.vimSelection` (so mouse clicks and native edits are picked up on the next key) and
/// performs all edits through `vimReplace`. In insert mode the host inserts printable keys itself.
public final class VimEngine {
    public internal(set) var mode: VimMode = .normal
    /// Keys typed for an incomplete command (e.g. "2d"), for the status bar.
    public internal(set) var pendingKeys: String = ""
    /// Text of the ":" / "/" / "?" command line while in `.commandLine` mode (including the leading character).
    public internal(set) var commandLine: String? = nil

    public var onModeChange: ((VimMode) -> Void)?
    public var onExCommand: ((VimExCommand) -> Void)?
    /// Optional bridge to the system clipboard for the unnamed register (and "+ / "*).
    public var readClipboard: (() -> String?)?
    public var writeClipboard: ((String) -> Void)?

    // MARK: Configuration (additive API)

    /// Text inserted by `>` and removed by `<` for one level of indentation.
    public var indentUnit: String = "  "
    /// Copy the indentation of the current line for `o`, `O`, `cc`, `S`.
    public var autoIndent: Bool = true
    /// Case-insensitive search / substitute unless `smartCase` applies.
    public var ignoreCase: Bool = true
    /// With `ignoreCase`: a pattern containing an uppercase letter is matched case-sensitively.
    public var smartCase: Bool = true
    /// Searches wrap around the end of the text.
    public var wrapScan: Bool = true
    /// Yanks go to the system clipboard (through `writeClipboard`) and `p` pastes text copied elsewhere.
    public var clipboardUnnamed: Bool = true
    /// Also mirror deletes (`d`, `x`, `c` …) of the unnamed register to the clipboard.
    public var mirrorDeletesToClipboard: Bool = false
    /// Called for `zz`, `zt`, `zb`: the host should scroll the cursor line.
    public var onViewport: ((VimViewportCommand) -> Void)?
    /// Called with informational / error messages ("E486: Pattern not found: x", "3 substitutions on 2 lines").
    public var onMessage: ((String) -> Void)?
    /// The last message (cleared by the next command).
    public internal(set) var message: String?
    /// The pattern of the last search (for highlighting).
    public var lastSearchPattern: String? { searchHighlightHidden ? nil : lastSearch?.pattern }

    // MARK: Internal state

    var buf: VimTextBuffer = DetachedBuffer.shared
    var cursor = 0
    var visualAnchor = 0
    /// Sticky column for j/k: nil = recompute from the cursor, `Int.max` = end of line (after `$`).
    var desiredCol: Int?
    var lastWrittenSelection = NSRange(location: 0, length: 0)
    var pending: [VimKey] = []
    var regs = RegisterFile()
    var clipboardSnapshot: String?
    var marks: [Character: Int] = [:]
    var lastFind: LastFind?
    var lastSearch: LastSearch?
    var lastSubstitute: SubstituteSpec?
    var lastChange: RepeatRecord?
    /// A change waiting for the end of its insert / replace session.
    var building: RepeatRecord?
    var insertSession: InsertSession?
    var replaceSession: ReplaceSession?
    var undoGroupOpen = false
    var groupBuffer: VimTextBuffer?
    /// Cursor before the change of the open undo group, and bookkeeping to detect whether it changed anything.
    var groupStartCursor = UndoCursor(line: 0, column: 0)
    var groupStartLength = 0
    var groupChanged = false
    /// Cursor positions recorded per closed undo group (parallel to the host's undo / redo stacks).
    var undoCursors: [UndoCursor] = []
    var redoCursors: [UndoCursor] = []
    var lastVisual: (anchor: Int, cursor: Int, mode: VimMode)?
    var replaying = false
    var replayInsertText: String?
    var insertOneShot = false
    var ctrlRPending = false
    // Command line
    var cmdPrefix: Character = ":"
    var cmdReturnMode: VimMode = .normal
    var cmdPendingOperator: VimCommand?
    var history: [Character: [String]] = [:]
    var historyIndex: Int?
    /// Operator-pending information kept while the search command line is open.
    var searchOrigin = 0
    /// `:noh` hides the highlight of the last search until the next search.
    var searchHighlightHidden = false
    var regexCache: [String: NSRegularExpression] = [:]

    public init() {}

    /// A snapshot of the buffer text. The copy keeps every `Doc` valid even when the host returns a live,
    /// mutating string (e.g. an `NSTextStorage`'s backing store) and the engine edits it afterwards.
    var doc: Doc {
        let t = buf.vimText
        return Doc((t.copy() as? NSString) ?? t)
    }

    // MARK: Public API

    /// Processes one key. Returns true if the key was consumed; false means the host should handle it
    /// normally (e.g. ordinary typing in insert mode).
    @discardableResult
    public func handle(_ key: VimKey, in buffer: VimTextBuffer) -> Bool {
        buf = buffer
        message = nil
        syncFromBuffer()
        let consumed: Bool
        switch mode {
        case .normal, .visual, .visualLine: consumed = handlePendingKey(key)
        case .insert: consumed = handleInsertKey(key)
        case .replace: consumed = handleReplaceKey(key)
        case .commandLine: consumed = handleCommandLineKey(key)
        }
        finishKey(consumed: consumed)
        buf = DetachedBuffer.shared
        return consumed
    }

    /// Force a mode (e.g. the host switches to insert after a mouse click in some configurations).
    ///
    /// Leaving insert / replace mode this way does not move the cursor (unlike Esc). Pending keys are discarded.
    public func setMode(_ newMode: VimMode, in buffer: VimTextBuffer) {
        buf = buffer
        pending.removeAll()
        pendingKeys = ""
        let sel = clampRange(buffer.vimSelection, length: buffer.vimText.length)
        if mode == .insert || mode == .replace {
            cursor = sel.location
            finishInsertSession(stepLeft: false)
        } else if mode == .commandLine {
            commandLine = nil
            cmdPendingOperator = nil
        }
        insertOneShot = false
        cursor = sel.location
        let d = doc
        switch newMode {
        case .normal:
            cursor = d.clampNormal(sel.location)
            switchMode(.normal)
        case .insert:
            switchMode(.insert)
            beginInsertSession(kind: .before, count: 1, records: false)
        case .replace:
            switchMode(.replace)
            beginReplaceSession(count: 1, records: false)
        case .visual, .visualLine:
            visualAnchor = sel.location
            cursor = sel.length > 0 ? d.prevCharStart(sel.end) : sel.location
            if sel.length == 0 { cursor = d.clampNormal(cursor); visualAnchor = cursor }
            switchMode(newMode)
        case .commandLine:
            cmdReturnMode = .normal
            openCommandLine(":")
        }
        if newMode == .normal || newMode == .visual || newMode == .visualLine { desiredCol = nil }
        finishKey(consumed: true)
        buf = DetachedBuffer.shared
    }

    // MARK: Mode switching

    func switchMode(_ newMode: VimMode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode != .commandLine { commandLine = nil }
        onModeChange?(newMode)
    }

    // MARK: Buffer <-> engine synchronisation

    func syncFromBuffer() {
        let d = doc
        let sel = clampRange(buf.vimSelection, length: d.length)
        switch mode {
        case .insert, .replace:
            cursor = sel.location
        case .normal:
            if sel != lastWrittenSelection {
                cursor = d.clampNormal(sel.location)
                desiredCol = nil
            } else {
                cursor = d.clampNormal(cursor)
            }
        case .commandLine:
            break
        case .visual, .visualLine:
            if sel != lastWrittenSelection {
                visualAnchor = sel.location
                cursor = sel.length > 0 ? d.prevCharStart(sel.end) : sel.location
                desiredCol = nil
            }
            cursor = max(0, min(cursor, d.length))
            visualAnchor = max(0, min(visualAnchor, d.length))
        }
    }

    /// Computes the selection the buffer should show for the current mode.
    func currentSelection() -> NSRange {
        let d = doc
        switch mode {
        case .normal:
            return NSRange(location: d.clampNormal(cursor), length: 0)
        case .insert, .replace:
            return NSRange(location: max(0, min(cursor, d.length)), length: 0)
        case .commandLine:
            return buf.vimSelection
        case .visual:
            let lo = min(visualAnchor, cursor), hi = max(visualAnchor, cursor)
            let end = min(d.length, hi + d.cursorCharLength(at: hi))
            return NSRange(location: lo, length: max(0, end - lo))
        case .visualLine:
            let lo = d.lineStart(min(visualAnchor, cursor))
            let hi = d.lineEnd(max(visualAnchor, cursor))
            return NSRange(location: lo, length: max(0, hi - lo))
        }
    }

    func publishSelection() {
        let sel = currentSelection()
        if mode == .normal { cursor = sel.location }
        if buf.vimSelection != sel { buf.vimSelection = sel }
        lastWrittenSelection = buf.vimSelection
    }

    func finishKey(consumed: Bool) {
        if mode != .commandLine {
            if mode == .insert || mode == .replace {
                if consumed { publishSelection() }
            } else {
                publishSelection()
            }
        } else {
            lastWrittenSelection = buf.vimSelection
        }
        if mode != .insert && mode != .replace { closeUndoGroup() }
        pendingKeys = pending.map { $0.display }.joined()
    }

    // MARK: Undo groups

    func openUndoGroup() {
        guard !undoGroupOpen else { return }
        let d = doc
        groupStartCursor = UndoCursor(line: d.lineIndex(of: cursor), column: d.column(of: cursor))
        groupStartLength = d.length
        groupChanged = false
        buf.vimBeginUndoGroup()
        groupBuffer = buf
        undoGroupOpen = true
    }

    func closeUndoGroup() {
        guard undoGroupOpen else { return }
        let b = groupBuffer ?? buf
        b.vimEndUndoGroup()
        if groupChanged || b.vimText.length != groupStartLength {
            undoCursors.append(groupStartCursor)
            if undoCursors.count > 1000 { undoCursors.removeFirst(undoCursors.count - 1000) }
            redoCursors.removeAll()
        }
        groupBuffer = nil
        undoGroupOpen = false
    }

    // MARK: Editing primitive

    /// Replaces text through the buffer (inside the current undo group) and keeps the marks in sync.
    func replace(_ range: NSRange, with s: String) {
        let len = buf.vimText.length
        let r = clampRange(range, length: len)
        let newLen = s.u16
        if r.length == 0 && newLen == 0 { return }
        openUndoGroup()
        groupChanged = true
        buf.vimReplace(r, with: s)
        for (k, v) in marks {
            if v >= r.end { marks[k] = v - r.length + newLen }
            else if v > r.location { marks[k] = r.location }
        }
        marks["."] = r.location
    }

    func notify(_ text: String) {
        message = text
        onMessage?(text)
    }
}

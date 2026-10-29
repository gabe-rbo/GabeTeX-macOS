import Foundation
import CheckKit
import VimKit

// Test harness: an in-memory `VimTextBuffer` with real undo / redo groups, a key-notation parser and a
// session that plays the role of the host (it inserts printable keys itself when the engine returns false).

/// An in-memory buffer that behaves like the NSTextView adapter: edits are undoable, groups nest, and
/// `vimText` is a *live* view of the storage (the engine must not rely on it staying unchanged).
final class MockBuffer: VimTextBuffer {
    struct Edit {
        var location: Int
        var old: String
        var new: String
    }

    let storage = NSMutableString()
    private var selection = NSRange(location: 0, length: 0)
    private var undoStack: [[Edit]] = []
    private var redoStack: [[Edit]] = []
    private var open: [Edit] = []
    private var depth = 0
    var visibleLines: ClosedRange<Int>?

    init(_ text: String = "") { storage.setString(text) }

    /// Number of undo groups currently on the undo stack.
    var undoGroups: Int { undoStack.count }
    var groupDepth: Int { depth }

    var vimText: NSString { storage }
    var vimSelection: NSRange {
        get { selection }
        set { selection = clamp(newValue) }
    }
    var vimVisibleLines: ClosedRange<Int>? { visibleLines }

    private func clamp(_ r: NSRange) -> NSRange {
        let len = storage.length
        let s = max(0, min(r.location, len))
        let e = max(s, min(r.location + r.length, len))
        return NSRange(location: s, length: e - s)
    }

    func vimReplace(_ range: NSRange, with string: String) {
        let r = clamp(range)
        let old = storage.substring(with: r)
        storage.replaceCharacters(in: r, with: string)
        let e = Edit(location: r.location, old: old, new: string)
        if depth > 0 {
            open.append(e)
        } else {
            undoStack.append([e])
            redoStack.removeAll()
        }
        selection = NSRange(location: r.location + (string as NSString).length, length: 0)
    }

    func vimBeginUndoGroup() {
        depth += 1
        if depth == 1 { open = [] }
    }

    func vimEndUndoGroup() {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 {
            if !open.isEmpty {
                undoStack.append(open)
                redoStack.removeAll()
            }
            open = []
        }
    }

    func vimUndo() {
        guard let group = undoStack.popLast() else { return }
        var at = 0
        for e in group.reversed() {
            storage.replaceCharacters(in: NSRange(location: e.location, length: (e.new as NSString).length), with: e.old)
            at = e.location + (e.old as NSString).length
        }
        redoStack.append(group)
        // Like NSTextView: the caret ends up after the restored text (the engine must override this).
        selection = clamp(NSRange(location: at, length: 0))
    }

    func vimRedo() {
        guard let group = redoStack.popLast() else { return }
        var at = 0
        for e in group {
            storage.replaceCharacters(in: NSRange(location: e.location, length: (e.old as NSString).length), with: e.new)
            at = e.location + (e.new as NSString).length
        }
        undoStack.append(group)
        selection = clamp(NSRange(location: at, length: 0))
    }
}

// MARK: - Key notation

/// Parses `"d2w"`, `"ci{"`, `"<Esc>"`, `"<C-r>"`, `":s/a/b/g<CR>"` into keys. A `<` that does not start a known
/// `<Name>` is an ordinary character (so `"<<"` and `"d<"` work).
func parseKeys(_ s: String) -> [VimKey] {
    var keys: [VimKey] = []
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "<", let close = chars[i...].prefix(10).firstIndex(of: ">") {
            let name = String(chars[(i + 1)..<close])
            if let k = namedKey(name) {
                keys.append(k)
                i = close + 1
                continue
            }
        }
        keys.append(VimKey(String(c)))
        i += 1
    }
    return keys
}

private func namedKey(_ name: String) -> VimKey? {
    switch name.lowercased() {
    case "esc": return .escape
    case "cr", "enter", "return": return .enter
    case "bs": return .backspace
    case "tab": return VimKey(special: .tab)
    case "del": return VimKey(special: .delete)
    case "left": return VimKey(special: .left)
    case "right": return VimKey(special: .right)
    case "up": return VimKey(special: .up)
    case "down": return VimKey(special: .down)
    case "home": return VimKey(special: .home)
    case "end": return VimKey(special: .end)
    case "pageup": return VimKey(special: .pageUp)
    case "pagedown": return VimKey(special: .pageDown)
    case "space": return VimKey(" ")
    case "lt": return VimKey("<")
    case "bar": return VimKey("|")
    default: break
    }
    if name.count == 3, name.lowercased().hasPrefix("c-"), let ch = name.last {
        return VimKey(String(ch).lowercased(), control: true)
    }
    return nil
}

// MARK: - Session

/// An engine attached to a `MockBuffer`. The text notation marks the cursor with `|` (it sits *before* the
/// character the block cursor covers; at the very end it marks the end of the text).
final class VimSession {
    let engine = VimEngine()
    let buffer: MockBuffer
    var exCommands: [VimExCommand] = []
    var messages: [String] = []
    var modeChanges: [VimMode] = []
    var consumedLog: [Bool] = []
    var clipboard: String?
    var clipboardWrites: [String] = []

    init(_ marked: String) {
        let ns = marked as NSString
        let bar = ns.range(of: "|")
        var text = marked
        var cursor = 0
        if bar.location != NSNotFound {
            cursor = bar.location
            text = ns.replacingCharacters(in: bar, with: "")
        }
        buffer = MockBuffer(text)
        buffer.vimSelection = NSRange(location: cursor, length: 0)
        engine.onExCommand = { [unowned self] in self.exCommands.append($0) }
        engine.onMessage = { [unowned self] in self.messages.append($0) }
        engine.onModeChange = { [unowned self] in self.modeChanges.append($0) }
        // The clipboard closures are always installed; `clipboard == nil` behaves like an empty pasteboard.
        engine.readClipboard = { [unowned self] in self.clipboard }
        engine.writeClipboard = { [unowned self] in
            self.clipboard = $0
            self.clipboardWrites.append($0)
        }
    }

    // MARK: Driving

    @discardableResult
    func feed(_ keys: String) -> VimSession {
        for k in parseKeys(keys) { press(k) }
        return self
    }

    func press(_ key: VimKey) {
        let consumed = engine.handle(key, in: buffer)
        consumedLog.append(consumed)
        if !consumed { host(key) }
    }

    /// What NSTextView does natively with a key the engine declined (insert mode only).
    private func host(_ key: VimKey) {
        guard engine.mode == .insert else { return }
        if let s = key.special {
            switch s {
            case .enter: type("\n")
            case .tab: type("\t")
            case .backspace: deleteBackward()
            case .delete: deleteForward()
            case .left: moveCaret(by: -1)
            case .right: moveCaret(by: 1)
            default: break
            }
            return
        }
        if key.control { return }
        if let c = key.character { type(c) }
    }

    private func type(_ s: String) {
        buffer.vimReplace(buffer.vimSelection, with: s)
    }

    private func deleteBackward() {
        let sel = buffer.vimSelection
        if sel.length > 0 { buffer.vimReplace(sel, with: ""); return }
        guard sel.location > 0 else { return }
        let r = (buffer.vimText).rangeOfComposedCharacterSequence(at: sel.location - 1)
        buffer.vimReplace(r, with: "")
    }

    private func deleteForward() {
        let sel = buffer.vimSelection
        guard sel.location < buffer.vimText.length else { return }
        let r = buffer.vimText.rangeOfComposedCharacterSequence(at: sel.location)
        buffer.vimReplace(r, with: "")
    }

    private func moveCaret(by delta: Int) {
        let sel = buffer.vimSelection
        let p = max(0, min(buffer.vimText.length, sel.location + delta))
        buffer.vimSelection = NSRange(location: p, length: 0)
    }

    // MARK: Observing

    var text: String { buffer.storage as String }
    var cursor: Int { buffer.vimSelection.location }
    var mode: VimMode { engine.mode }

    /// The text with `|` inserted at the cursor (the selection start).
    var marked: String {
        let ns = buffer.storage
        let c = max(0, min(buffer.vimSelection.location, ns.length))
        return ns.substring(to: c) + "|" + ns.substring(from: c)
    }

    /// The selected text (visual modes).
    var selectedText: String {
        let sel = buffer.vimSelection
        return buffer.storage.substring(with: sel)
    }

    /// The selection with `[` `]` around it (visual modes).
    var markedSelection: String {
        let ns = buffer.storage
        let sel = buffer.vimSelection
        return ns.substring(to: sel.location) + "[" + ns.substring(with: sel) + "]" + ns.substring(from: sel.location + sel.length)
    }
}

// MARK: - Assertions

/// Runs `keys` on `text` (cursor marked with `|`) and returns the session for further inspection.
func run(_ keys: String, on text: String) -> VimSession {
    let s = VimSession(text)
    s.feed(keys)
    return s
}

/// Asserts that `keys` turn `before` into `after` (both with the cursor marked by `|`).
func vim(
    _ keys: String, _ before: String, _ after: String,
    mode: VimMode = .normal,
    file: StaticString = #fileID, line: UInt = #line
) {
    let s = run(keys, on: before)
    Check.equal(s.marked, after, "keys \(describe(keys)) on \(describe(before))", file: file, line: line)
    Check.equal(s.mode, mode, "mode after \(describe(keys))", file: file, line: line)
}

/// Asserts the result of `keys` on `before`, compared to `after` where `after` has no cursor marker.
func vimText(
    _ keys: String, _ before: String, _ after: String,
    file: StaticString = #fileID, line: UInt = #line
) {
    let s = run(keys, on: before)
    Check.equal(s.text, after, "keys \(describe(keys)) on \(describe(before))", file: file, line: line)
}

func describe(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
}

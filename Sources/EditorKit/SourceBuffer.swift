import AppKit
import Observation

/// The in-memory model of one open text file. Owns the NSTextStorage (so switching files in the
/// editor keeps text, undo history and selection) and tracks dirtiness.
/// One SourceBuffer per open file, owned by the app's workspace.
@Observable
public final class SourceBuffer: Identifiable {
    public let id = UUID()
    public private(set) var url: URL

    @ObservationIgnored public let textStorage: NSTextStorage
    @ObservationIgnored public let undoManager = UndoManager()

    /// Selection to restore when the buffer is shown again.
    @ObservationIgnored public var savedSelection = NSRange(location: 0, length: 0)
    /// Vertical scroll position to restore when the buffer is shown again.
    @ObservationIgnored public var savedScrollY: CGFloat = 0

    /// Increments on every edit (the editor calls `noteEdit()`).
    public private(set) var changeCount = 0
    public private(set) var savedChangeCount = 0
    public var isDirty: Bool { changeCount != savedChangeCount }

    public var text: String { textStorage.string }

    public init(url: URL, text: String) {
        self.url = url.standardizedFileURL
        self.textStorage = NSTextStorage(string: text)
    }

    /// Called by the editor after each user edit (typing, paste, undo, completion, Vim command).
    public func noteEdit() {
        changeCount += 1
    }

    public func markSaved() {
        savedChangeCount = changeCount
    }

    /// Replaces the whole text (e.g. file changed on disk). Clears undo history and marks clean.
    public func reload(text: String) {
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        textStorage.endEditing()
        undoManager.removeAllActions()
        changeCount += 1
        savedChangeCount = changeCount
        let len = (text as NSString).length
        savedSelection = NSRange(location: min(savedSelection.location, len), length: 0)
    }

    /// The file was renamed/moved.
    public func didMove(to newURL: URL) {
        url = newURL.standardizedFileURL
    }
}

import Foundation

// Internal value types shared by the parser, the motions, the operators and the engine.

/// Operators that take a motion / text object (or are doubled for whole lines).
enum VimOperator: Hashable {
    case delete, change, yank
    case shiftRight, shiftLeft
    case lowercase, uppercase, toggleCase

    /// Characters that are doubled to act on lines (`dd`, `>>`, `gUU` …).
    var isGPrefixed: Bool {
        switch self {
        case .lowercase, .uppercase, .toggleCase: return true
        default: return false
        }
    }

    /// True for operators that modify text (and are therefore repeatable with `.`).
    var modifiesText: Bool { self != .yank }
}

enum FindKind: Hashable {
    case forward, backward, tillForward, tillBackward

    var reversed: FindKind {
        switch self {
        case .forward: return .backward
        case .backward: return .forward
        case .tillForward: return .tillBackward
        case .tillBackward: return .tillForward
        }
    }
    var isForward: Bool { self == .forward || self == .tillForward }
    var isTill: Bool { self == .tillForward || self == .tillBackward }
}

enum VimMotion: Hashable {
    case left, right, up, down
    case wrapLeft, wrapRight                       // <BS> / <Space>
    case lineStart, firstNonBlank, lineEnd, lastNonBlank, column
    case nextLineFirstNonBlank, prevLineFirstNonBlank, currentLineFirstNonBlank   // + - _
    case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool), wordEndBackward(big: Bool)
    case fileTop, fileBottom                        // gg G
    case paragraphForward, paragraphBackward        // } {
    case matchPair                                  // %
    case find(FindKind, String)                     // f F t T
    case repeatFind(reverse: Bool)                  // ; ,
    case screenTop, screenMiddle, screenBottom      // H M L
    case halfPageDown, halfPageUp, pageDown, pageUp
    case searchWord(forward: Bool)                  // * #
    case searchNext(reverse: Bool)                  // n N
    case searchCommand(forward: Bool)               // / ? (opens the command line)
    case searchPattern(String, forward: Bool)       // a resolved / ? search (for `.` repeat)
    case mark(Character, linewise: Bool)            // ' `
}

enum VimTextObject: Hashable {
    case word(big: Bool, around: Bool)
    case paragraph(around: Bool)
    case pair(open: Character, close: Character, around: Bool)
    case quote(Character, around: Bool)
    case math(around: Bool)
    case environment(around: Bool)
}

enum InsertKind: Hashable {
    case before, after, lineStart, lineEnd, openBelow, openAbove, firstColumn, lastInsert
}

public enum VimViewportCommand: Hashable, Sendable {
    case cursorToCenter, cursorToTop, cursorToBottom
}

enum VimSimple: Hashable {
    case deleteChar, deleteCharBefore, deleteToEnd, changeToEnd, substituteChar, substituteLine, yankLine
    case put(after: Bool, cursorAfter: Bool)
    case join(spaces: Bool)
    case undo, redo, repeatChange
    case insert(InsertKind)
    case replaceChar(String)
    case replaceMode
    case toggleCaseChar
    case startVisual(VimMode)
    case visualSwapEnds
    case visualReselect
    case visualExit
    case visualLinewise(VimOperator)
    case setMark(Character)
    case increment(Int)
    case commandLine(Character)
    case writeQuit, quitNoSave
    case repeatSubstitute
    case viewport(VimViewportCommand)
    case noop
}

enum VimAction: Hashable {
    case motion(VimMotion)
    case operatorMotion(VimOperator, VimMotion)
    case operatorObject(VimOperator, VimTextObject)
    case operatorLines(VimOperator)
    case visualOperator(VimOperator)
    case visualObject(VimTextObject)
    case simple(VimSimple)
}

struct VimCommand: Hashable {
    var action: VimAction
    var register: Character?
    /// The product of all counts typed (`2d3w` → 6), nil when none was typed.
    var count: Int?
}

/// A text region an operator works on. `end` is exclusive.
struct Region {
    var start: Int
    var end: Int
    var linewise: Bool
    /// Where the cursor goes after a yank (nil → `start`).
    var yankCursor: Int?
}

/// The outcome of evaluating a motion.
struct MotionResult {
    var offset: Int
    var inclusive = false
    var linewise = false
    /// New sticky column for j/k: nil = reset (recompute from the cursor), `Int.max` = end of line (`$`).
    var column: Int?
    /// Motions that count as jumps (`G`, `gg`, `/`, `%` …) record the old position in the `'` mark.
    var isJump = false
}

/// What `.` replays.
struct RepeatRecord {
    var command: VimCommand
    /// Text typed during the insert / replace session started by the command.
    var insertText: String?
    /// Shape of the visual selection the command was applied to (for visual operators).
    var visual: VisualShape?
}

struct VisualShape {
    var mode: VimMode
    var lines: Int
    /// Characters in the last line (charwise) — for a single line the total characters.
    var columns: Int
}

struct LastFind {
    var kind: FindKind
    var text: String
}

struct LastSearch {
    var pattern: String
    var forward: Bool
    /// Search offset typed after the closing delimiter (`/foo/e+1` → `e+1`).
    var offset: String = ""
}

/// An ongoing insert session (the host inserts the typed text natively).
struct InsertSession {
    var start: Int
    var startLength: Int
    var count: Int
    var kind: InsertKind
    /// True when the session was started by a command that `.` should repeat.
    var records: Bool
}

struct ReplaceSession {
    var start: Int
    var originals: [String]       // replaced characters (empty string = appended past the line end)
    var typed: [String]
    var count: Int
    var records: Bool
}

import Foundation

// Pure presentation logic: the navigation state machine, slide-number entry, the timer and the keyboard model.
// No AppKit, no windows: everything here is a `Sendable` value type and is covered by the headless checks
// (`Sources/EditorKitChecks/PresentationChecks.swift`).

// MARK: - Commands

/// What a key, a click or a control of the presenter view asks the presentation to do.
public nonisolated enum PresentationCommand: Hashable, Sendable {
    /// → ↓ Space PageDown, a click on the slides.
    case next
    /// ← ↑ PageUp ⇧Space.
    case previous
    /// Home.
    case first
    /// End.
    case last
    /// A digit typed to jump to a slide: digits, then Return.
    case digit(Int)
    /// Delete: removes the last typed digit; without typed digits it goes to the previous slide.
    case deleteBackward
    /// Return: goes to the typed slide number; without typed digits it goes to the next slide.
    case confirm
    /// B or `.`: black screen on / off.
    case toggleBlack
    /// W or `,`: white screen on / off.
    case toggleWhite
    /// Esc: cancels a typed slide number; otherwise ends the presentation.
    case escape
    /// Ends the presentation right away (⌥⌘Return, the End button).
    case end
    /// P: shows or hides the presenter view when there is only one display.
    case togglePresenterView
    /// Goes to a slide (0-based index, clamped), e.g. from a control of the presenter view.
    case goTo(Int)
    /// Drops a typed slide number that was never confirmed (time-out).
    case clearDigits
}

/// What the audience sees instead of the slide.
public nonisolated enum PresentationBlank: String, Hashable, Sendable {
    case none
    case black
    case white
}

/// The visible effect of a command, for the views (transition direction) and the controller (end, P).
/// When a command has several effects the most important one is reported (end, presenter view, move, blank,
/// digits).
public nonisolated enum PresentationOutcome: Equatable, Sendable {
    case none
    case moved(from: Int, to: Int)
    case blankChanged(PresentationBlank)
    case digitsChanged
    case end
    case togglePresenterView
}

// MARK: - Navigation

/// The presentation's navigation state machine: current slide, blank screen and the slide number being typed.
///
/// Rules:
/// - Moving is clamped to the document; the last slide stays on screen when advancing past it (the presentation
///   never ends by itself).
/// - While the screen is black or white, a navigation key only brings the slides back (no move), like Keynote
///   and PowerPoint; a jump to a typed number or `goTo` shows the slides and moves.
/// - Digits are collected (at most `maximumDigits`); Return jumps to that slide number (1-based, clamped),
///   Delete removes the last digit, Esc cancels the entry. Any navigation drops a pending entry.
/// - A reload changes the page count: the current index is kept and clamped.
public nonisolated struct PresentationNavigator: Equatable, Sendable {
    /// Longest slide number that can be typed.
    public static let maximumDigits = 5

    public private(set) var pageCount: Int
    /// 0-based index of the slide on screen (0 when there are no pages).
    public private(set) var currentIndex: Int
    public private(set) var blank: PresentationBlank = .none
    /// The slide number being typed ("" when none).
    public private(set) var typedDigits: String = ""

    public init(pageCount: Int, startIndex: Int = 0) {
        let count = max(0, pageCount)
        self.pageCount = count
        self.currentIndex = Self.clamp(startIndex, count: count)
    }

    /// The following slide, nil on the last one.
    public var nextIndex: Int? { currentIndex + 1 < pageCount ? currentIndex + 1 : nil }
    /// The preceding slide, nil on the first one.
    public var previousIndex: Int? { currentIndex > 0 && pageCount > 0 ? currentIndex - 1 : nil }
    public var isOnLastSlide: Bool { pageCount == 0 || currentIndex == pageCount - 1 }
    /// The typed slide number, nil when nothing is typed.
    public var typedSlideNumber: Int? { typedDigits.isEmpty ? nil : Int(typedDigits) }
    /// Where Return would go with the typed number (0-based, clamped), nil when nothing is typed.
    public var typedTargetIndex: Int? {
        guard let number = typedSlideNumber, pageCount > 0 else { return nil }
        return Self.clamp(number - 1, count: pageCount)
    }

    @discardableResult
    public mutating func perform(_ command: PresentationCommand) -> PresentationOutcome {
        switch command {
        case .next: return navigate(to: currentIndex + 1)
        case .previous: return navigate(to: currentIndex - 1)
        case .first: return navigate(to: 0)
        case .last: return navigate(to: pageCount - 1)
        case .digit(let value):
            guard (0...9).contains(value), typedDigits.count < Self.maximumDigits, pageCount > 0 else { return .none }
            typedDigits.append(String(value))
            return .digitsChanged
        case .deleteBackward:
            if typedDigits.isEmpty { return navigate(to: currentIndex - 1) }
            typedDigits.removeLast()
            return .digitsChanged
        case .confirm:
            guard let target = typedTargetIndex else {
                if !typedDigits.isEmpty {        // digits but no pages
                    typedDigits = ""
                    return .digitsChanged
                }
                return navigate(to: currentIndex + 1)
            }
            typedDigits = ""
            return jump(to: target, reportsDigits: true)
        case .toggleBlack: return setBlank(blank == .black ? .none : .black)
        case .toggleWhite: return setBlank(blank == .white ? .none : .white)
        case .escape:
            if typedDigits.isEmpty { return .end }
            typedDigits = ""
            return .digitsChanged
        case .end:
            typedDigits = ""
            return .end
        case .togglePresenterView:
            return .togglePresenterView
        case .goTo(let index):
            typedDigits = ""
            return jump(to: index, reportsDigits: false)
        case .clearDigits:
            guard !typedDigits.isEmpty else { return .none }
            typedDigits = ""
            return .digitsChanged
        }
    }

    /// The document was reloaded (or replaced) with `count` pages: keeps the slide index, clamped.
    public mutating func updatePageCount(_ count: Int) {
        pageCount = max(0, count)
        currentIndex = Self.clamp(currentIndex, count: pageCount)
        if pageCount == 0 { typedDigits = "" }
    }

    // MARK: Private

    /// A navigation key: brings the slides back when blanked, else moves (clamped).
    private mutating func navigate(to index: Int) -> PresentationOutcome {
        let hadDigits = !typedDigits.isEmpty
        typedDigits = ""
        if blank != .none {
            blank = .none
            return .blankChanged(.none)
        }
        guard pageCount > 0 else { return hadDigits ? .digitsChanged : .none }
        let target = Self.clamp(index, count: pageCount)
        guard target != currentIndex else { return hadDigits ? .digitsChanged : .none }
        let from = currentIndex
        currentIndex = target
        return .moved(from: from, to: target)
    }

    /// A jump (typed number, `goTo`): shows the slides and moves.
    private mutating func jump(to index: Int, reportsDigits: Bool) -> PresentationOutcome {
        let wasBlank = blank != .none
        blank = .none
        guard pageCount > 0 else { return wasBlank ? .blankChanged(.none) : (reportsDigits ? .digitsChanged : .none) }
        let target = Self.clamp(index, count: pageCount)
        if target != currentIndex {
            let from = currentIndex
            currentIndex = target
            return .moved(from: from, to: target)
        }
        if wasBlank { return .blankChanged(.none) }
        return reportsDigits ? .digitsChanged : .none
    }

    private mutating func setBlank(_ value: PresentationBlank) -> PresentationOutcome {
        typedDigits = ""
        guard value != blank else { return .none }
        blank = value
        return .blankChanged(value)
    }

    static func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }
}

// MARK: - Timer

/// The presenter's elapsed-time stopwatch (pause / resume / reset). Dates are passed in, so it is deterministic.
public nonisolated struct PresentationTimer: Equatable, Sendable {
    /// Time counted before the current run (sum of the previous runs).
    public private(set) var accumulated: TimeInterval = 0
    /// Start of the current run; nil while paused.
    public private(set) var runningSince: Date?

    public init() {}

    public var isRunning: Bool { runningSince != nil }

    /// Starts or resumes counting at `date` (no effect while running).
    public mutating func start(at date: Date) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    /// Stops counting at `date`, keeping the time so far (no effect while paused).
    public mutating func pause(at date: Date) {
        guard let since = runningSince else { return }
        accumulated += max(0, date.timeIntervalSince(since))
        runningSince = nil
    }

    /// Pause ↔ resume.
    public mutating func toggle(at date: Date) {
        if isRunning { pause(at: date) } else { start(at: date) }
    }

    /// Back to 0:00. A running timer keeps running from `date`; a paused one stays paused.
    public mutating func reset(at date: Date) {
        accumulated = 0
        if runningSince != nil { runningSince = date }
    }

    /// Time counted up to `date` (never negative).
    public func elapsed(at date: Date) -> TimeInterval {
        var total = accumulated
        if let since = runningSince { total += max(0, date.timeIntervalSince(since)) }
        return max(0, total)
    }

    /// "04:07" below an hour, "1:02:03" from an hour on (whole seconds, rounded down).
    public static func format(_ interval: TimeInterval) -> String {
        let seconds = interval.isFinite ? max(0, Int(interval.rounded(.down))) : 0
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%02d:%02d", minutes, rest)
    }
}

// MARK: - Keyboard

/// A key press, reduced to what the presentation needs (built from an `NSEvent` by the windows).
public nonisolated struct PresentationKeyPress: Hashable, Sendable {
    /// The hardware key code (`NSEvent.keyCode`).
    public var keyCode: UInt16
    /// The characters ignoring modifiers (`NSEvent.charactersIgnoringModifiers`), layout-aware.
    public var characters: String
    public var shift: Bool
    public var option: Bool
    public var command: Bool
    public var control: Bool

    public init(keyCode: UInt16, characters: String, shift: Bool = false, option: Bool = false,
                command: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.shift = shift
        self.option = option
        self.command = command
        self.control = control
    }
}

/// The presentation keyboard model (the same in the audience and the presenter windows).
///
/// | Keys | Command |
/// |---|---|
/// | → ↓ Space PageDown | next (⇧Space: previous) |
/// | Return / Enter | go to the typed slide, else next |
/// | ← ↑ PageUp | previous |
/// | Delete ⌦ | remove a typed digit, else previous |
/// | Home / End | first / last slide |
/// | 0–9 | type a slide number |
/// | B . | black screen · W , white screen |
/// | P | presenter view on / off (one display) |
/// | Esc | cancel the typed number, else end · ⌥⌘Return ends |
///
/// Keys with ⌘ or ⌃ are left to the menus (except ⌥⌘Return).
public nonisolated enum PresentationKeyMap {
    /// Hardware key codes (`kVK_…` from Carbon's Events.h).
    public enum KeyCode {
        public static let returnKey: UInt16 = 36
        public static let tab: UInt16 = 48
        public static let space: UInt16 = 49
        public static let delete: UInt16 = 51
        public static let escape: UInt16 = 53
        public static let keypadEnter: UInt16 = 76
        public static let home: UInt16 = 115
        public static let pageUp: UInt16 = 116
        public static let forwardDelete: UInt16 = 117
        public static let end: UInt16 = 119
        public static let pageDown: UInt16 = 121
        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
        public static let downArrow: UInt16 = 125
        public static let upArrow: UInt16 = 126
    }

    public static func command(for key: PresentationKeyPress) -> PresentationCommand? {
        if key.command || key.control {
            // The shortcut that starts a presentation also ends it.
            if key.command, key.option, !key.control,
               key.keyCode == KeyCode.returnKey || key.keyCode == KeyCode.keypadEnter {
                return .end
            }
            return nil
        }
        switch key.keyCode {
        case KeyCode.rightArrow, KeyCode.downArrow, KeyCode.pageDown: return .next
        case KeyCode.space: return key.shift ? .previous : .next
        case KeyCode.returnKey, KeyCode.keypadEnter: return .confirm
        case KeyCode.leftArrow, KeyCode.upArrow, KeyCode.pageUp: return .previous
        case KeyCode.delete, KeyCode.forwardDelete: return .deleteBackward
        case KeyCode.home: return .first
        case KeyCode.end: return .last
        case KeyCode.escape: return .escape
        default: break
        }
        guard key.characters.count == 1, let character = key.characters.lowercased().first else { return nil }
        if let digit = character.wholeNumberValue, character.isASCII { return .digit(digit) }
        switch character {
        case "b", ".": return .toggleBlack
        case "w", ",": return .toggleWhite
        case "p": return .togglePresenterView
        default: return nil
        }
    }
}

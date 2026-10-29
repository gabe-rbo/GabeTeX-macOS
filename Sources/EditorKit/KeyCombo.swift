import AppKit

/// A keyboard shortcut: one key plus modifiers (⌃ ⌥ ⇧ ⌘), as the user records it and as menus show it.
///
/// Used by the editor for its completion trigger (⌃Space by default) and by the app for its customizable
/// command shortcuts (`ShortcutMap`). Pure value type: parsing, a canonical storage string, the menu glyphs
/// and matching against `NSEvent`s.
///
/// Printable keys are stored as their **base character** on the current keyboard layout, lowercased (`"p"`, `"/"`,
/// `"'"`); `⇧` is a separate modifier, so ⇧⌘P is `shift+cmd+p`. Named keys (Return, Tab, Space, arrows, F-keys …)
/// are identified by their key code, so they work on every layout.
public nonisolated struct KeyCombo: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The modifier keys of a shortcut. Caps Lock, Fn and the numeric-pad flag are never part of a shortcut.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// The modifiers of an event (⌃ ⌥ ⇧ ⌘ only).
        public init(_ flags: NSEvent.ModifierFlags) {
            var result: Modifiers = []
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.command) { result.insert(.command) }
            self = result
        }

        /// The equivalent AppKit flags.
        public var eventFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if contains(.control) { flags.insert(.control) }
            if contains(.option) { flags.insert(.option) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.command) { flags.insert(.command) }
            return flags
        }

        /// Menu glyphs in the standard macOS order: ⌃⌥⇧⌘.
        public var glyphs: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
                + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
        }
    }

    /// Keys that have a name instead of a character.
    public enum Special: String, CaseIterable, Hashable, Sendable {
        case `return`, tab, space, delete, forwardDelete, escape
        case upArrow, downArrow, leftArrow, rightArrow, home, end, pageUp, pageDown
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

        /// The hardware key code (keypad Enter maps to `.return`).
        public init?(keyCode: UInt16) {
            switch keyCode {
            case 36, 76: self = .return
            case 48: self = .tab
            case 49: self = .space
            case 51: self = .delete
            case 117: self = .forwardDelete
            case 53: self = .escape
            case 126: self = .upArrow
            case 125: self = .downArrow
            case 123: self = .leftArrow
            case 124: self = .rightArrow
            case 115: self = .home
            case 119: self = .end
            case 116: self = .pageUp
            case 121: self = .pageDown
            default:
                guard let index = Self.functionKeyCodes.firstIndex(of: keyCode) else { return nil }
                self = Self.functionKeys[index]
            }
        }

        /// F1…F20 in order, with their key codes.
        static let functionKeys: [Special] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
                                              .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20]
        static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                                 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

        /// F1 = 1 … F20 = 20; nil for other keys.
        public var functionKeyNumber: Int? {
            Self.functionKeys.firstIndex(of: self).map { $0 + 1 }
        }

        /// The glyph shown in menus (`↩ ⇥ ⌫ ⌦ ⎋ ↑ ↓ ← → ↖ ↘ ⇞ ⇟`, `F5`, localized “Space”).
        public var glyph: String {
            switch self {
            case .return: "↩"
            case .tab: "⇥"
            case .space: String(localized: "Space")
            case .delete: "⌫"
            case .forwardDelete: "⌦"
            case .escape: "⎋"
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .home: "↖"
            case .end: "↘"
            case .pageUp: "⇞"
            case .pageDown: "⇟"
            default: "F\(functionKeyNumber ?? 0)"
            }
        }
    }

    /// The key of a shortcut.
    public enum Key: Hashable, Sendable {
        /// A printable key: its base character on the keyboard layout, lowercased.
        case character(Character)
        case special(Special)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, modifiers: Modifiers = []) {
        if case .character(let c) = key {
            let lower = String(c).lowercased()
            self.key = .character(lower.count == 1 ? lower.first ?? c : c)
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    /// A shortcut with a printable key, e.g. `KeyCombo("b", [.command])`.
    public init(_ character: Character, _ modifiers: Modifiers) {
        self.init(.character(character), modifiers: modifiers)
    }

    /// A shortcut with a named key, e.g. `KeyCombo(.space, [.control])`.
    public init(_ special: Special, _ modifiers: Modifiers) {
        self.init(.special(special), modifiers: modifiers)
    }

    // MARK: Events

    /// The shortcut an event types (nil for events that are not key presses or have no usable key).
    /// Printable keys use the layout's base character (`characters(byApplyingModifiers: [])`), so ⇧⌘P is
    /// `shift+cmd+p` and ⌥⌘L is `opt+cmd+l` whatever the layout makes of ⇧ or ⌥.
    public init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let modifiers = Modifiers(event.modifierFlags)
        if let special = Special(keyCode: event.keyCode) {
            self.init(.special(special), modifiers: modifiers)
            return
        }
        guard let character = Self.baseCharacter(of: event) else { return nil }
        self.init(.character(character), modifiers: modifiers)
    }

    /// Whether `event` presses this shortcut. Printable keys also match the character AppKit reports when
    /// modifiers are ignored, so a shortcut recorded on another layout keeps working where it can.
    public func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard Modifiers(event.modifierFlags) == modifiers else { return false }
        switch key {
        case .special(let special):
            return Special(keyCode: event.keyCode) == special
        case .character(let character):
            if Special(keyCode: event.keyCode) != nil { return false }
            if Self.baseCharacter(of: event) == character { return true }
            let ignoring = event.charactersIgnoringModifiers?.lowercased() ?? ""
            return ignoring.count == 1 && ignoring.first == character
        }
    }

    private static func baseCharacter(of event: NSEvent) -> Character? {
        let candidates = [event.characters(byApplyingModifiers: []), event.charactersIgnoringModifiers]
        for candidate in candidates {
            guard let text = candidate?.lowercased(), text.count == 1, let c = text.first else { continue }
            if isUsableCharacter(c) { return c }
        }
        return nil
    }

    /// Printable, not a control character, not a function-key code point.
    static func isUsableCharacter(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value) { return false }
        return !c.isWhitespace && !"⌘⇧⌥⌃".contains(c)
    }

    // MARK: Text forms

    /// The glyphs shown in menus and Settings: `⇧⌘P`, `⌃Space`, `⌥⌘↩`, `⌘'`.
    public var displayString: String {
        modifiers.glyphs + keyDisplay
    }

    /// The key alone as menus show it (letters uppercase).
    public var keyDisplay: String {
        switch key {
        case .special(let special): special.glyph
        case .character(let c): String(c).uppercased()
        }
    }

    /// The canonical storage form: `ctrl+opt+shift+cmd+<key>` (modifiers in that order, only those present),
    /// the key being a `Special` name or the character itself (`cmd++` for the plus key).
    public var storageString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        switch key {
        case .special(let special): parts.append(special.rawValue)
        case .character(let c): parts.append(String(c))
        }
        return parts.joined(separator: "+")
    }

    public var description: String { storageString }

    /// Parses a shortcut written as the storage form (`shift+cmd+p`, `ctrl+space`, `opt+cmd+return`), with
    /// common aliases (`command`, `alt`, `option`, `control`, `enter`, `esc`, `backspace`, `up` …, in any letter
    /// case), or as menu glyphs (`⇧⌘P`, `⌃Space`, `⌥⌘↩`). Returns nil for anything else (no key, two keys,
    /// unknown names).
    public init?(string: String) {
        var rest = Substring(string.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }
        var modifiers: Modifiers = []
        let names: [(String, Modifiers)] = [
            ("command", .command), ("cmd", .command), ("shift", .shift), ("option", .option), ("opt", .option),
            ("alt", .option), ("control", .control), ("ctrl", .control),
        ]
        let glyphs: [Character: Modifiers] = ["⌘": .command, "⇧": .shift, "⌥": .option, "⌃": .control]
        parsing: while true {
            if let first = rest.first, let modifier = glyphs[first], rest.count > 1 {
                modifiers.insert(modifier)
                rest = rest.dropFirst()
                if rest.first == "+", rest.count > 1 { rest = rest.dropFirst() }
                continue
            }
            for (name, modifier) in names {
                let prefix = name + "+"
                if rest.count > prefix.count, rest.lowercased().hasPrefix(prefix) {
                    modifiers.insert(modifier)
                    rest = rest.dropFirst(prefix.count)
                    continue parsing
                }
            }
            break
        }
        guard let key = Self.parseKey(String(rest)) else { return nil }
        self.init(key, modifiers: modifiers)
    }

    private static func parseKey(_ text: String) -> Key? {
        let lower = text.lowercased()
        if let special = Special.allCases.first(where: { $0.rawValue.lowercased() == lower }) { return .special(special) }
        let aliases: [String: Special] = [
            "enter": .return, "↩": .return, "⏎": .return, "⇥": .tab, "␣": .space, "backspace": .delete, "⌫": .delete,
            "del": .forwardDelete, "⌦": .forwardDelete, "esc": .escape, "⎋": .escape, "up": .upArrow, "↑": .upArrow,
            "down": .downArrow, "↓": .downArrow, "left": .leftArrow, "←": .leftArrow, "right": .rightArrow,
            "→": .rightArrow, "↖": .home, "↘": .end, "pgup": .pageUp, "⇞": .pageUp, "pgdn": .pageDown, "⇟": .pageDown,
        ]
        if let special = aliases[lower] { return .special(special) }
        if lower == String(localized: "Space").lowercased() { return .special(.space) }
        guard text.count == 1, let c = lower.first, isUsableCharacter(c) else { return nil }
        return .character(c)
    }

    // MARK: Codable (as the storage string)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let combo = KeyCombo(string: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a keyboard shortcut: \(text)")
        }
        self = combo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageString)
    }
}

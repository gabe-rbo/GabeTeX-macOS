import Foundation

// MARK: - Reserved combinations

nonisolated extension KeyCombo {
    /// Why a combination cannot be given to a command.
    public enum Reservation: String, Hashable, Sendable {
        /// Used by macOS itself (⌘Q, ⌘H, ⌘Tab, ⌘Space, screenshots …).
        case system
        /// Opens Settings (⌘,).
        case settings
        /// Standard text editing (⌘C ⌘V ⌘X ⌘A ⌘Z ⇧⌘Z).
        case editing
        /// Closes tabs and windows (the ⌘W family; see `SystemCloseItemRemover` in the app).
        case closing
    }

    /// Combinations no command may take.
    public static let reserved: [KeyCombo: Reservation] = {
        let table: [(String, Reservation)] = [
            ("cmd+q", .system), ("cmd+h", .system), ("opt+cmd+h", .system), ("cmd+m", .system), ("opt+cmd+m", .system),
            ("cmd+tab", .system), ("shift+cmd+tab", .system), ("cmd+`", .system), ("shift+cmd+`", .system),
            ("cmd+space", .system), ("opt+cmd+space", .system), ("ctrl+cmd+space", .system),
            ("opt+cmd+escape", .system), ("shift+cmd+3", .system), ("shift+cmd+4", .system), ("shift+cmd+5", .system),
            ("ctrl+shift+cmd+3", .system), ("ctrl+shift+cmd+4", .system), ("ctrl+cmd+q", .system),
            ("ctrl+cmd+f", .system), ("opt+cmd+d", .system), ("shift+cmd+/", .system), ("ctrl+f2", .system),
            ("ctrl+f3", .system), ("ctrl+upArrow", .system), ("ctrl+downArrow", .system), ("ctrl+leftArrow", .system),
            ("ctrl+rightArrow", .system),
            ("cmd+,", .settings),
            ("cmd+c", .editing), ("cmd+v", .editing), ("cmd+x", .editing), ("cmd+a", .editing), ("cmd+z", .editing),
            ("shift+cmd+z", .editing),
            ("cmd+w", .closing), ("shift+cmd+w", .closing), ("opt+cmd+w", .closing), ("opt+shift+cmd+w", .closing),
        ]
        var result: [KeyCombo: Reservation] = [:]
        for (text, reason) in table {
            if let combo = KeyCombo(string: text) { result[combo] = reason }
        }
        return result
    }()

    /// Why this combination is reserved, or nil.
    public var reservation: Reservation? { Self.reserved[self] }
}

// MARK: - Shortcut map

/// The command shortcuts of the app: each command's default plus the user's changes.
///
/// Pure value type (no UserDefaults, no AppKit menus), so its rules are checked headlessly. The app wraps it in
/// an observable store that persists `encodedOverrides()`.
///
/// Rules:
/// - A combination may belong to one command only. Assigning one that another command uses is a **conflict**;
///   the caller may *replace* it (the other command loses its shortcut).
/// - **Refused** combinations: reserved ones (`KeyCombo.reserved`), printable keys without ⌘ or ⌃ (they would
///   type text; ⌥ alone types characters such as π), named editing keys (Return, Tab, arrows …) without ⌘ or ⌃.
///   F-keys are allowed alone.
/// - Commands that are not customizable keep their default (⌘W, ⌘,).
/// - The user's explicit choices beat defaults: a default that equals a combination the user gave to another
///   command is not active. Among stored choices that collide (edited preferences), the first command in
///   definition order keeps it.
public nonisolated struct ShortcutMap: Equatable, Sendable {
    /// One command as far as shortcuts are concerned.
    public struct Definition: Equatable, Sendable {
        public var id: String
        public var defaultCombo: KeyCombo?
        public var isCustomizable: Bool

        public init(id: String, defaultCombo: KeyCombo?, isCustomizable: Bool = true) {
            self.id = id
            self.defaultCombo = defaultCombo
            self.isCustomizable = isCustomizable
        }
    }

    /// Why a combination was refused.
    public enum Refusal: Equatable, Sendable {
        case reserved(KeyCombo.Reservation)
        /// A printable key or an editing key without ⌘ or ⌃.
        case needsModifier
        /// ⌥ (or ⇧⌥) alone with a printable key: that types characters.
        case optionTypesCharacters
        case notCustomizable
        case unknownCommand

        /// A short, localized explanation for Settings.
        public var message: String {
            switch self {
            case .reserved(.system): String(localized: "This shortcut is reserved by macOS.")
            case .reserved(.settings): String(localized: "This shortcut opens Settings.")
            case .reserved(.editing): String(localized: "This shortcut is used for standard text editing.")
            case .reserved(.closing): String(localized: "This shortcut closes tabs and windows.")
            case .needsModifier: String(localized: "Add ⌘ or ⌃ to this key.")
            case .optionTypesCharacters: String(localized: "⌥ alone types special characters; add ⌘ or ⌃.")
            case .notCustomizable: String(localized: "This shortcut can’t be changed.")
            case .unknownCommand: String(localized: "Unknown command.")
            }
        }
    }

    /// The result of checking or making an assignment.
    public enum Outcome: Equatable, Sendable {
        /// Done (or, for `check`, possible).
        case allowed
        /// The command already has exactly this shortcut.
        case unchanged
        case refused(Refusal)
        /// Other commands use the combination; `replaceable` is false when one of them is not customizable.
        case conflict(ids: [String], replaceable: Bool)
    }

    public private(set) var definitions: [Definition]
    /// Combinations the user chose (only those that differ from the default).
    public private(set) var assigned: [String: KeyCombo] = [:]
    /// Commands whose default shortcut the user removed.
    public private(set) var cleared: Set<String> = []
    private var positions: [String: Int] = [:]
    private var effective: [String: KeyCombo] = [:]

    public init(definitions: [Definition]) {
        var unique: [Definition] = []
        var positions: [String: Int] = [:]
        for definition in definitions where positions[definition.id] == nil {
            positions[definition.id] = unique.count
            unique.append(definition)
        }
        self.definitions = unique
        self.positions = positions
        recompute()
    }

    public static func == (lhs: ShortcutMap, rhs: ShortcutMap) -> Bool {
        lhs.definitions == rhs.definitions && lhs.assigned == rhs.assigned && lhs.cleared == rhs.cleared
    }

    // MARK: Reading

    public func definition(for id: String) -> Definition? {
        positions[id].map { definitions[$0] }
    }

    /// The active shortcut of a command.
    public func combo(for id: String) -> KeyCombo? { effective[id] }

    /// Whether the user changed this command's shortcut (assigned another one or removed it).
    public func isCustomized(_ id: String) -> Bool { assigned[id] != nil || cleared.contains(id) }

    /// Whether any shortcut differs from its default.
    public var hasCustomizations: Bool { !assigned.isEmpty || !cleared.isEmpty }

    /// Commands whose active shortcut is `combo` (except `excluded`), in definition order.
    public func commands(using combo: KeyCombo, excluding excluded: String? = nil) -> [String] {
        definitions.compactMap { definition in
            definition.id != excluded && effective[definition.id] == combo ? definition.id : nil
        }
    }

    /// Whether a combination may be used at all (independently of other commands).
    public static func validity(of combo: KeyCombo) -> Refusal? {
        if let reservation = combo.reservation { return .reserved(reservation) }
        let strong = combo.modifiers.contains(.command) || combo.modifiers.contains(.control)
        switch combo.key {
        case .special(let special):
            if special.functionKeyNumber != nil || strong { return nil }
            return .needsModifier
        case .character:
            if strong { return nil }
            return combo.modifiers.contains(.option) ? .optionTypesCharacters : .needsModifier
        }
    }

    /// What assigning `combo` to the command would do, without changing anything.
    public func check(_ combo: KeyCombo, for id: String) -> Outcome {
        guard let definition = definition(for: id) else { return .refused(.unknownCommand) }
        guard definition.isCustomizable else { return .refused(.notCustomizable) }
        if effective[id] == combo { return .unchanged }
        if let refusal = Self.validity(of: combo) { return .refused(refusal) }
        let others = commands(using: combo, excluding: id)
        if others.isEmpty { return .allowed }
        let replaceable = others.allSatisfy { self.definition(for: $0)?.isCustomizable ?? false }
        return .conflict(ids: others, replaceable: replaceable)
    }

    // MARK: Changing

    /// Gives `combo` to the command (nil removes its shortcut). With `replacingConflicts`, commands that used
    /// the combination lose it; otherwise a conflict changes nothing and is returned.
    @discardableResult
    public mutating func assign(_ combo: KeyCombo?, to id: String, replacingConflicts: Bool = false) -> Outcome {
        guard let definition = definition(for: id) else { return .refused(.unknownCommand) }
        guard definition.isCustomizable else { return .refused(.notCustomizable) }
        guard let combo else {
            guard effective[id] != nil || assigned[id] != nil else { return .unchanged }
            assigned[id] = nil
            if definition.defaultCombo != nil { cleared.insert(id) } else { cleared.remove(id) }
            recompute()
            return .allowed
        }
        let outcome = check(combo, for: id)
        switch outcome {
        case .allowed:
            break
        case .conflict(let others, let replaceable) where replacingConflicts && replaceable:
            for other in others { removeShortcut(of: other) }
        default:
            return outcome
        }
        setCombo(combo, for: definition)
        recompute()
        return .allowed
    }

    /// Puts the command's default shortcut back. If another command uses that combination now, returns the
    /// conflict unless `replacingConflicts`.
    @discardableResult
    public mutating func restoreDefault(for id: String, replacingConflicts: Bool = false) -> Outcome {
        guard let definition = definition(for: id) else { return .refused(.unknownCommand) }
        guard definition.isCustomizable else { return .refused(.notCustomizable) }
        guard isCustomized(id) || effective[id] != definition.defaultCombo else { return .unchanged }
        if let combo = definition.defaultCombo {
            let others = commands(using: combo, excluding: id)
            if !others.isEmpty {
                let replaceable = others.allSatisfy { self.definition(for: $0)?.isCustomizable ?? false }
                guard replacingConflicts, replaceable else { return .conflict(ids: others, replaceable: replaceable) }
                for other in others { removeShortcut(of: other) }
            }
        }
        assigned[id] = nil
        cleared.remove(id)
        recompute()
        return .allowed
    }

    /// Every command back to its default.
    public mutating func restoreAllDefaults() {
        assigned = [:]
        cleared = []
        recompute()
    }

    private mutating func setCombo(_ combo: KeyCombo, for definition: Definition) {
        if combo == definition.defaultCombo {
            assigned[definition.id] = nil
        } else {
            assigned[definition.id] = combo
        }
        cleared.remove(definition.id)
    }

    private mutating func removeShortcut(of id: String) {
        guard let definition = definition(for: id) else { return }
        assigned[id] = nil
        if definition.defaultCombo != nil { cleared.insert(id) }
    }

    /// Explicit choices first (definition order), then defaults that are still free.
    private mutating func recompute() {
        var result: [String: KeyCombo] = [:]
        var used: Set<KeyCombo> = []
        for definition in definitions {
            if let combo = assigned[definition.id], !used.contains(combo) {
                result[definition.id] = combo
                used.insert(combo)
            }
        }
        for definition in definitions where assigned[definition.id] == nil && !cleared.contains(definition.id) {
            if let combo = definition.defaultCombo, !used.contains(combo) {
                result[definition.id] = combo
                used.insert(combo)
            }
        }
        effective = result
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var version: Int
        /// Command id → storage string; "" = no shortcut.
        var shortcuts: [String: String]
    }

    /// The user's changes as JSON (`{"version":1,"shortcuts":{"build.compile":"cmd+r","view.quickOpen":""}}`).
    public func encodedOverrides() -> Data {
        var shortcuts: [String: String] = [:]
        for (id, combo) in assigned { shortcuts[id] = combo.storageString }
        for id in cleared { shortcuts[id] = "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Stored(version: 1, shortcuts: shortcuts))) ?? Data()
    }

    /// Replaces the user's changes with those in `data` (from `encodedOverrides()`). Unknown commands, fixed
    /// commands, unreadable or refused combinations are skipped; nothing is thrown.
    public mutating func loadOverrides(from data: Data) {
        assigned = [:]
        cleared = []
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            for definition in definitions where definition.isCustomizable {
                guard let text = stored.shortcuts[definition.id] else { continue }
                if text.isEmpty {
                    if definition.defaultCombo != nil { cleared.insert(definition.id) }
                } else if let combo = KeyCombo(string: text), Self.validity(of: combo) == nil,
                          combo != definition.defaultCombo {
                    assigned[definition.id] = combo
                }
            }
        }
        recompute()
    }

    // MARK: Validation of a default table

    /// Problems in the defaults themselves (for checks): duplicate ids, two commands with one default, and
    /// customizable commands whose default is refused.
    public static func problems(in definitions: [Definition]) -> [String] {
        var problems: [String] = []
        var ids: Set<String> = []
        var owners: [KeyCombo: String] = [:]
        for definition in definitions {
            if !ids.insert(definition.id).inserted { problems.append("duplicate id \(definition.id)") }
            guard let combo = definition.defaultCombo else { continue }
            if let owner = owners[combo] {
                problems.append("\(combo.storageString) is the default of both \(owner) and \(definition.id)")
            } else {
                owners[combo] = definition.id
            }
            if definition.isCustomizable, let refusal = validity(of: combo) {
                problems.append("default \(combo.storageString) of \(definition.id) is refused: \(refusal)")
            }
        }
        return problems
    }
}

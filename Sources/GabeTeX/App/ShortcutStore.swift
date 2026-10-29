import SwiftUI
import AppKit
import Observation
import EditorKit

/// The user's keyboard shortcuts: the registry's defaults plus the changes made in Settings › Shortcuts,
/// persisted in UserDefaults as JSON (`ShortcutMap.encodedOverrides()`, under `defaultsKey`).
///
/// The menus (`AppCommands`), the command palette and the editor's completion trigger all read from here, so a
/// change shows and works everywhere at once.
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()

    /// UserDefaults key of the JSON (a string). `AppCommands` watches it with `@AppStorage` so the menu bar is
    /// rebuilt when a shortcut changes.
    static let defaultsKey = "settings.shortcuts"

    private(set) var map: ShortcutMap
    @ObservationIgnored private let defaults: UserDefaults

    init(registry: CommandRegistry = .shared, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var map = ShortcutMap(definitions: registry.shortcutDefinitions)
        if let json = defaults.string(forKey: Self.defaultsKey), let data = json.data(using: .utf8) {
            map.loadOverrides(from: data)
        }
        self.map = map
    }

    // MARK: Reading

    func combo(for id: CommandID) -> KeyCombo? { map.combo(for: id.rawValue) }

    func defaultCombo(for id: CommandID) -> KeyCombo? { map.definition(for: id.rawValue)?.defaultCombo }

    func isCustomized(_ id: CommandID) -> Bool { map.isCustomized(id.rawValue) }

    var hasCustomizations: Bool { map.hasCustomizations }

    /// The SwiftUI shortcut for a menu item (nil = none).
    func keyboardShortcut(for id: CommandID) -> KeyboardShortcut? {
        combo(for: id).flatMap(Self.keyboardShortcut)
    }

    /// Glyphs for display ("⇧⌘P"), or nil.
    func display(for id: CommandID) -> String? { combo(for: id)?.displayString }

    func check(_ combo: KeyCombo, for id: CommandID) -> ShortcutMap.Outcome { map.check(combo, for: id.rawValue) }

    /// Commands using a combination, as registry commands.
    func commands(using combo: KeyCombo, excluding id: CommandID?) -> [CommandID] {
        map.commands(using: combo, excluding: id?.rawValue).map(CommandID.init(rawValue:))
    }

    // MARK: Changing

    @discardableResult
    func assign(_ combo: KeyCombo?, to id: CommandID, replacingConflicts: Bool = false) -> ShortcutMap.Outcome {
        var map = self.map
        let outcome = map.assign(combo, to: id.rawValue, replacingConflicts: replacingConflicts)
        commit(map, outcome)
        return outcome
    }

    @discardableResult
    func restoreDefault(for id: CommandID, replacingConflicts: Bool = false) -> ShortcutMap.Outcome {
        var map = self.map
        let outcome = map.restoreDefault(for: id.rawValue, replacingConflicts: replacingConflicts)
        commit(map, outcome)
        return outcome
    }

    func restoreAllDefaults() {
        var map = self.map
        map.restoreAllDefaults()
        commit(map, .allowed)
    }

    private func commit(_ newMap: ShortcutMap, _ outcome: ShortcutMap.Outcome) {
        guard outcome == .allowed, newMap != map else { return }
        map = newMap
        if map.hasCustomizations, let json = String(data: map.encodedOverrides(), encoding: .utf8) {
            defaults.set(json, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    // MARK: SwiftUI bridge

    /// `KeyCombo` → SwiftUI `KeyboardShortcut` (function keys use AppKit's function-key code points).
    static func keyboardShortcut(_ combo: KeyCombo) -> KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch combo.key {
        case .character(let character):
            equivalent = KeyEquivalent(character)
        case .special(let special):
            switch special {
            case .return: equivalent = .return
            case .tab: equivalent = .tab
            case .space: equivalent = .space
            case .delete: equivalent = .delete
            case .forwardDelete: equivalent = .deleteForward
            case .escape: equivalent = .escape
            case .upArrow: equivalent = .upArrow
            case .downArrow: equivalent = .downArrow
            case .leftArrow: equivalent = .leftArrow
            case .rightArrow: equivalent = .rightArrow
            case .home: equivalent = .home
            case .end: equivalent = .end
            case .pageUp: equivalent = .pageUp
            case .pageDown: equivalent = .pageDown
            default:
                guard let number = special.functionKeyNumber,
                      let scalar = UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(number - 1)) else { return nil }
                equivalent = KeyEquivalent(Character(scalar))
            }
        }
        var modifiers: EventModifiers = []
        if combo.modifiers.contains(.command) { modifiers.insert(.command) }
        if combo.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if combo.modifiers.contains(.option) { modifiers.insert(.option) }
        if combo.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}

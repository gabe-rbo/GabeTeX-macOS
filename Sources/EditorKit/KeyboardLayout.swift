import AppKit
import Carbon.HIToolbox
import Synchronization

/// Turns key codes into the characters they type under a keyboard layout **without dead-key
/// composition**.
///
/// Why: on layouts such as Brazilian ABNT2 and US-International the keys for `^`, `~`, `` ` `` and `´`
/// are dead keys. `NSEvent.characters` is empty for them (the text input system waits for the next key
/// to compose `ã`, `é` …), which is right while typing text but wrong for Vim's normal/visual/command-line
/// modes, where `^`, `~` and `` ` `` are commands. This type asks the layout (`UCKeyTranslate` with
/// `kUCKeyTranslateNoDeadKeysMask`) which character the key stands for on its own.
///
/// Every translation starts from a fresh dead-key state and the no-dead-keys option never leaves one
/// behind, so a translation can neither be affected by nor affect the next keystroke.
public nonisolated struct KeyboardLayoutTranslator: Sendable {
    /// The layout's `uchr` data (`kTISPropertyUnicodeKeyLayoutData`).
    public let layoutData: Data
    /// The hardware keyboard type passed to `UCKeyTranslate` (ANSI, ISO, JIS …).
    public let keyboardType: UInt32

    /// A translator for explicit `uchr` layout data.
    public init(layoutData: Data, keyboardType: UInt32 = KeyboardLayoutTranslator.hardwareKeyboardType) {
        self.layoutData = layoutData
        self.keyboardType = keyboardType
    }

    /// The type of the keyboard attached to this Mac (`CGEventSource.keyboardType`).
    public static var hardwareKeyboardType: UInt32 {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return 0 }
        return UInt32(truncatingIfNeeded: source.keyboardType)
    }

    /// The characters `keyCode` types with the given modifiers on its own: a dead key yields its
    /// standalone accent (`~`, `^`, `` ` ``, `´` …) instead of waiting for a base letter.
    /// Empty when the layout has no character for the key.
    ///
    /// The result comes from `UCKeyTranslate` with `kUCKeyTranslateNoDeadKeysMask`. Some layouts spell a
    /// dead key's own character with a typographic variant there (US-International: U+02C6 `ˆ` for `^`,
    /// U+02DC `˜` for `~`, while the same key followed by Space types the ASCII character); for those the
    /// plain ASCII character is returned, since that is what Vim commands and TeX markup mean.
    public func characters(forKeyCode keyCode: UInt16, shift: Bool = false, option: Bool = false,
                           capsLock: Bool = false) -> String {
        // UCKeyTranslate takes the Carbon modifier bits shifted right by 8.
        var modifiers: UInt32 = 0
        if shift { modifiers |= UInt32((shiftKey >> 8) & 0xFF) }
        if capsLock { modifiers |= UInt32((alphaLock >> 8) & 0xFF) }
        if option { modifiers |= UInt32((optionKey >> 8) & 0xFF) }
        // Every dead-key state below is a local of this call: nothing carries over to the next key.
        var unused: UInt32 = 0
        let standalone = translate(keyCode, modifiers: modifiers, deadKeys: false, state: &unused)
        if standalone.isEmpty || Self.isPlainASCII(standalone) { return standalone }
        // Possibly a dead key whose character is a typographic variant: press it for real, then Space.
        var deadKeyState: UInt32 = 0
        _ = translate(keyCode, modifiers: modifiers, deadKeys: true, state: &deadKeyState)
        guard deadKeyState != 0 else { return standalone }
        let terminator = translate(UInt16(kVK_Space), modifiers: 0, deadKeys: true, state: &deadKeyState)
        return Self.isPlainASCII(terminator) ? terminator : standalone
    }

    /// One `UCKeyTranslate` call. `deadKeys: false` passes `kUCKeyTranslateNoDeadKeysMask`.
    private func translate(_ keyCode: UInt16, modifiers: UInt32, deadKeys: Bool, state: inout UInt32) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        let options = deadKeys ? OptionBits(0) : OptionBits(kUCKeyTranslateNoDeadKeysMask)
        let status: OSStatus = layoutData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-50) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode,
                                  UInt16(kUCKeyActionDown), modifiers, keyboardType, options, &state,
                                  buffer.count, &length, &buffer)
        }
        guard status == noErr, length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }

    private static func isPlainASCII(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        return (0x20...0x7E).contains(scalar.value)
    }

    // MARK: - Text Input Sources

    /// The layout currently in use for typing (the current keyboard layout, or the current ASCII-capable
    /// layout when an input method is active). Queried on every call: the user may switch layouts at any time.
    @MainActor
    public static func current(keyboardType: UInt32? = nil) -> KeyboardLayoutTranslator? {
        let type = keyboardType ?? hardwareKeyboardType
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(), let data = layoutData(of: source) {
            return KeyboardLayoutTranslator(layoutData: data, keyboardType: type)
        }
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let data = layoutData(of: source) {
            return KeyboardLayoutTranslator(layoutData: data, keyboardType: type)
        }
        return nil
    }

    /// A translator for an installed keyboard layout, e.g. `com.apple.keylayout.Brazilian-ABNT2`
    /// (nil when it is not installed). The layout does not have to be enabled in System Settings.
    @MainActor
    public init?(inputSourceID: String, keyboardType: UInt32? = nil) {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue(),
              let sources = list as? [TISInputSource],
              let data = sources.lazy.compactMap({ Self.layoutData(of: $0) }).first else { return nil }
        self.init(layoutData: data, keyboardType: keyboardType ?? Self.hardwareKeyboardType)
    }

    /// The identifiers of all installed keyboard layouts (for diagnostics and tests).
    @MainActor
    public static var installedLayoutIDs: [String] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue(),
              let sources = list as? [TISInputSource] else { return [] }
        return sources.compactMap { source in
            TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
                Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
            }
        }
    }

    @MainActor
    private static func layoutData(of source: TISInputSource) -> Data? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let cfData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        let length = CFDataGetLength(cfData)
        guard length > 0, let bytes = CFDataGetBytePtr(cfData) else { return nil }
        return Data(bytes: bytes, count: length)   // a private, properly aligned copy
    }
}

extension KeyboardLayoutTranslator {
    /// Test hook: the layout `deadKeyCharacters(for:)` uses instead of the current keyboard layout (switching
    /// the real input source would change the user's system). Backed by a `Mutex` so it is concurrency-safe
    /// under every compiler's isolation inference (a plain mutable static is not).
    nonisolated static var layoutOverride: KeyboardLayoutTranslator? {
        get { layoutOverrideStorage.withLock { $0 } }
        set { layoutOverrideStorage.withLock { $0 = newValue } }
    }

    private nonisolated static let layoutOverrideStorage = Mutex<KeyboardLayoutTranslator?>(nil)

    /// The character a key event stands for when `NSEvent.characters` came back empty (a dead key such as
    /// ABNT2 `~` or US-International `'`), resolved through the current layout. Nil when the key has no
    /// printable character of its own (or has ⌘/⌃ held).
    static func deadKeyCharacters(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control]) else { return nil }
        // Real events carry the keyboard's hardware type; synthesized ones fall back to this Mac's keyboard.
        let reported = event.cgEvent.map { UInt32(truncatingIfNeeded: $0.getIntegerValueField(.keyboardEventKeyboardType)) }
        guard let translator = layoutOverride ?? current(keyboardType: reported.flatMap { $0 == 0 ? nil : $0 }) else { return nil }
        let text = translator.characters(forKeyCode: event.keyCode, shift: flags.contains(.shift),
                                         option: flags.contains(.option), capsLock: flags.contains(.capsLock))
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ isPrintable($0) }) else { return nil }
        return text
    }

    private nonisolated static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        !(scalar.value < 32 || scalar.value == 127 || (0xF700...0xF8FF).contains(scalar.value))
    }
}

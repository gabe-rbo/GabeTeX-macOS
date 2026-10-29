import SwiftUI
import AppKit
import EditorKit

/// Edits one command's shortcut: the recorder, a “Restore Default” button while it differs from the default,
/// and an inline notice for conflicts (with **Replace**) and refused combinations. Used by every row of
/// Settings › Shortcuts and by the Autocomplete section (Show completions).
struct ShortcutEditor: View {
    let id: CommandID
    /// Accessible name of the recorder ("Shortcut for Compile").
    let title: String
    private let store = ShortcutStore.shared

    @LocalState private var notice: ShortcutNotice?

    var body: some View {
        let command = CommandRegistry.shared[id]
        let customizable = command?.isCustomizable ?? false
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                if store.isCustomized(id) {
                    Button {
                        restoreDefault()
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Restore Default")
                    .accessibilityLabel("Restore Default")
                }
                ShortcutRecorder(combo: store.combo(for: id), isEnabled: customizable,
                                 accessibilityTitle: String(localized: "Shortcut for \(title)")) { combo in
                    record(combo)
                }
                .frame(width: 138, height: 24)
                .help(customizable ? String(localized: "Click, then press the new shortcut. ⌫ removes it, Esc cancels.")
                                   : String(localized: "This shortcut can’t be changed."))
            }
            if let notice {
                ShortcutNoticeView(notice: notice) {
                    replace(for: notice)
                } dismiss: {
                    self.notice = nil
                }
            }
        }
        .animation(.smooth(duration: 0.15), value: notice)
        .onChange(of: store.combo(for: id)) { _, _ in
            // Changed elsewhere (another row's Replace, Restore Defaults): an old notice is stale.
            if notice?.isRefusal != true { notice = nil }
        }
    }

    private func record(_ combo: KeyCombo?) {
        guard let combo else {
            store.assign(nil, to: id)
            notice = nil
            return
        }
        switch store.check(combo, for: id) {
        case .allowed:
            store.assign(combo, to: id)
            notice = nil
        case .unchanged:
            notice = nil
        case .refused(let refusal):
            notice = ShortcutNotice(combo: combo, kind: .refused(refusal.message))
        case .conflict(let ids, let replaceable):
            notice = ShortcutNotice(combo: combo, kind: .conflict(ids.map(CommandID.init(rawValue:)),
                                                                  replaceable: replaceable, restoring: false))
        }
    }

    private func restoreDefault() {
        switch store.restoreDefault(for: id) {
        case .conflict(let ids, let replaceable):
            if let combo = store.defaultCombo(for: id) {
                notice = ShortcutNotice(combo: combo, kind: .conflict(ids.map(CommandID.init(rawValue:)),
                                                                      replaceable: replaceable, restoring: true))
            }
        default:
            notice = nil
        }
    }

    private func replace(for notice: ShortcutNotice) {
        guard case .conflict(_, let replaceable, let restoring) = notice.kind, replaceable else { return }
        if restoring {
            store.restoreDefault(for: id, replacingConflicts: true)
        } else {
            store.assign(notice.combo, to: id, replacingConflicts: true)
        }
        self.notice = nil
    }
}

/// What the inline notice under a recorder says.
struct ShortcutNotice: Equatable {
    enum Kind: Equatable {
        /// Other commands use the combination. `restoring`: it is the default being restored.
        case conflict([CommandID], replaceable: Bool, restoring: Bool)
        case refused(String)
    }

    let combo: KeyCombo
    let kind: Kind

    var isRefusal: Bool {
        if case .refused = kind { return true }
        return false
    }
}

private struct ShortcutNoticeView: View {
    let notice: ShortcutNotice
    let replace: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch notice.kind {
            case .conflict(let ids, let replaceable, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(conflictMessage(ids))
                    .fixedSize(horizontal: false, vertical: true)
                if replaceable {
                    Button("Replace", action: replace)
                        .controlSize(.small)
                }
                Button("Cancel", action: dismiss)
                    .controlSize(.small)
            case .refused(let message):
                Image(systemName: "nosign")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(verbatim: "\(notice.combo.displayString) — \(message)")
                    .fixedSize(horizontal: false, vertical: true)
                Button("OK", action: dismiss)
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.trailing)
        .accessibilityElement(children: .contain)
    }

    private func conflictMessage(_ ids: [CommandID]) -> String {
        let names = ids.compactMap { CommandRegistry.shared[$0]?.title }.map { "“\($0)”" }
        let list = ListFormatter.localizedString(byJoining: names)
        return String(localized: "\(notice.combo.displayString) is already used by \(list).")
    }
}

// MARK: - Recorder

/// A shortcut field: click (or focus and press Space) to record, then press the combination. ⌫ removes the
/// shortcut, Esc cancels; clicking elsewhere cancels too. Key equivalents (⌘…) are captured before the menu bar
/// sees them, so recording ⌘Q never quits.
struct ShortcutRecorder: NSViewRepresentable {
    var combo: KeyCombo?
    var isEnabled = true
    var accessibilityTitle: String
    /// The recorded combination; nil when the user removed the shortcut.
    var onRecord: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let control = ShortcutRecorderControl()
        update(control)
        return control
    }

    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        update(control)
    }

    private func update(_ control: ShortcutRecorderControl) {
        control.combo = combo
        control.isEnabled = isEnabled
        control.title = accessibilityTitle
        control.onRecord = onRecord
    }
}

/// The AppKit side of `ShortcutRecorder`.
final class ShortcutRecorderControl: NSView {
    var combo: KeyCombo? { didSet { if combo != oldValue { refresh() } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { if !isEnabled { stopRecording() }; refresh() } } }
    var title = "" { didSet { setAccessibilityLabel(title) } }
    var onRecord: ((KeyCombo?) -> Void)?

    private(set) var isRecording = false
    private var liveModifiers: KeyCombo.Modifiers = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not decodable")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 138, height: 24) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    // MARK: Recording

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if isRecording {
            stopRecording()
        } else {
            window?.makeFirstResponder(self)
            startRecording()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        window?.makeFirstResponder(self)
        startRecording()
        return true
    }

    private func startRecording() {
        isRecording = true
        liveModifiers = []
        refresh()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        liveModifiers = []
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            handle(event)
        } else if isEnabled, event.keyCode == 49 || event.keyCode == 36 {   // Space / Return start recording
            startRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    /// ⌘ and ⌃ combinations arrive here before `keyDown` (and before the menu bar).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        handle(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = KeyCombo.Modifiers(event.modifierFlags)
        refresh()
    }

    private func handle(_ event: NSEvent) {
        let modifiers = KeyCombo.Modifiers(event.modifierFlags)
        if modifiers.isEmpty, event.keyCode == 53 {                          // Esc: cancel
            stopRecording()
            return
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {   // ⌫ / ⌦: remove
            stopRecording()
            onRecord?(nil)
            return
        }
        guard let recorded = KeyCombo(event: event) else {
            NSSound.beep()
            return
        }
        stopRecording()
        onRecord?(recorded)
    }

    // MARK: Drawing

    private var displayText: String {
        if isRecording {
            return liveModifiers.isEmpty ? String(localized: "Type Shortcut") : liveModifiers.glyphs
        }
        return combo?.displayString ?? String(localized: "None")
    }

    private func refresh() {
        setAccessibilityValue(combo?.displayString ?? String(localized: "None"))
        setAccessibilityEnabled(isEnabled)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)).setFill()
        path.fill()
        if isRecording {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let color: NSColor
        if !isEnabled {
            color = .tertiaryLabelColor
        } else if isRecording {
            color = .controlAccentColor
        } else {
            color = combo == nil ? .secondaryLabelColor : .labelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: combo == nil || isRecording ? .regular : .medium),
            .foregroundColor: color,
        ]
        let text = displayText as NSString
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

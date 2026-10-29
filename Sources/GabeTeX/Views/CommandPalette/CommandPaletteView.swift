import SwiftUI
import AppKit
import Observation

/// One row of the palette.
struct CommandPaletteRow: Identifiable, Equatable {
    let id: CommandID
    let title: String
    let category: String
    let symbol: String
    /// Shortcut glyphs ("⇧⌘J"), if the command has one.
    let shortcut: String?
    let isEnabled: Bool
    /// Toggles: whether the command is on (a checkmark); nil for ordinary commands.
    let isOn: Bool?
}

/// State of an open palette: the query, the ranked rows and the selection.
@Observable
final class CommandPaletteModel {
    static let rowHeight: CGFloat = 34
    static let visibleRows = 9
    static let fieldHeight: CGFloat = 54

    var query = ""
    var selection = 0
    private(set) var rows: [CommandPaletteRow] = []

    @ObservationIgnored weak var workspace: ProjectWorkspace?
    let inPDFWindow: Bool
    @ObservationIgnored var onRun: (CommandID) -> Void = { _ in }
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onHeightChange: (CGFloat) -> Void = { _ in }

    init(workspace: ProjectWorkspace, inPDFWindow: Bool) {
        self.workspace = workspace
        self.inPDFWindow = inPDFWindow
        refresh(resetSelection: true)
    }

    /// The panel height that shows the rows without empty space (the list scrolls beyond `visibleRows`).
    var preferredHeight: CGFloat {
        let list = rows.isEmpty ? 64 : CGFloat(min(rows.count, Self.visibleRows)) * (Self.rowHeight + 2) + 12
        return Self.fieldHeight + 1 + list
    }

    func refresh(resetSelection: Bool) {
        let context = CommandContext.live(workspace: workspace, inPDFWindow: inPDFWindow)
        let registry = CommandRegistry.shared
        let shortcuts = ShortcutStore.shared
        let visible = registry.commands.filter(\.showsInPalette)
        let entries = visible.map { command in
            CommandPaletteSearch.Entry(
                id: command.id.rawValue,
                title: command.title(in: context),
                alternates: [command.title, command.category.title] + command.keywords,
                isEnabled: command.isEnabled(context)
            )
        }
        let ranked = CommandPaletteSearch.rank(entries, query: query, recents: CommandRecents.shared.ids)
        rows = ranked.compactMap { entry in
            let id = CommandID(rawValue: entry.id)
            guard let command = registry[id] else { return nil }
            // Without a tab, ⌘W closes the window (see `AppCommands`).
            let shortcutID: CommandID = (id == .closeWindow && !context.closesTab) ? .closeTab : id
            return CommandPaletteRow(id: id, title: entry.title, category: command.category.title, symbol: command.symbol,
                                     shortcut: shortcuts.display(for: shortcutID), isEnabled: entry.isEnabled,
                                     isOn: command.isOn?(context))
        }
        if resetSelection || !rows.indices.contains(selection) { selection = 0 }
        onHeightChange(preferredHeight)
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        if abs(delta) == 1 {
            selection = (selection + delta + rows.count) % rows.count
        } else {
            selection = min(max(selection + delta, 0), rows.count - 1)
        }
    }

    func runSelected() { run(at: selection) }

    func run(at index: Int) {
        guard rows.indices.contains(index) else { return }
        selection = index
        guard rows[index].isEnabled else {
            NSSound.beep()
            return
        }
        onRun(rows[index].id)
    }

    func close() { onClose() }
}

/// The Spotlight-like palette (⇧⌘P): a search field over the ranked commands. ↑↓ (wrapping) and Page Up/Down
/// move, Return runs, Esc closes; unavailable commands are dimmed and do not run.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search commands", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit { model.runSelected() }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.pageUp) { model.move(-(CommandPaletteModel.visibleRows - 1)); return .handled }
                    .onKeyPress(.pageDown) { model.move(CommandPaletteModel.visibleRows - 1); return .handled }
                    .onKeyPress(.escape) { model.close(); return .handled }
                    .accessibilityLabel("Command Palette")
            }
            .padding(.horizontal, 16)
            .frame(height: CommandPaletteModel.fieldHeight)

            Divider()

            if model.rows.isEmpty {
                Text("No matching commands")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                CommandPaletteRowView(row: row, isSelected: index == model.selection)
                                    .id(row.id)
                                    .onTapGesture { model.run(at: index) }
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: model.selection) { _, newValue in
                        if model.rows.indices.contains(newValue) { proxy.scrollTo(model.rows[newValue].id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onAppear {
            isFocused = true
            // The panel becomes key right after the view appears: focus once more on the next turn.
            Task { @MainActor in isFocused = true }
        }
        .onChange(of: model.query) { _, _ in model.refresh(resetSelection: true) }
        .onExitCommand { model.close() }
    }
}

private struct CommandPaletteRowView: View {
    let row: CommandPaletteRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .frame(width: 22)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text(row.title)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(row.category)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if row.isOn == true {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("On")
            }
            if let shortcut = row.shortcut {
                Text(verbatim: shortcut)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: CommandPaletteModel.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(row.isEnabled ? 1 : 0.42)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(row.isEnabled ? Text(verbatim: "") : Text("Unavailable"))
    }
}

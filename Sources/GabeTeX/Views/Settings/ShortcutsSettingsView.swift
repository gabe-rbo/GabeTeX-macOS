import SwiftUI
import EditorKit

/// Settings › Shortcuts: the Autocomplete keys, then every command by category with a shortcut recorder, a
/// search field, and “Restore Defaults” (per row and for everything).
struct ShortcutsSettingsView: View {
    @LocalState private var search = ""
    @LocalState private var confirmingRestore = false
    private let store = ShortcutStore.shared
    private let registry = CommandRegistry.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search Shortcuts", text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search Shortcuts")
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button("Restore Defaults…") { confirmingRestore = true }
                    .disabled(!store.hasCustomizations)
                    .help("Restore every keyboard shortcut to its default")
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 2)

            Form {
                if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    AutocompleteSettingsSection()
                }
                let sections = matchingSections
                ForEach(sections, id: \.category) { section in
                    Section {
                        ForEach(section.commands) { command in
                            ShortcutRow(command: command)
                        }
                    } header: {
                        Text(section.category.title)
                    }
                }
                if sections.isEmpty {
                    Text("No matching commands")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 560)
        .confirmationDialog("Restore all keyboard shortcuts to their defaults?", isPresented: $confirmingRestore) {
            Button("Restore Defaults", role: .destructive) { store.restoreAllDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shortcuts you recorded will be replaced by GabeTeX’s defaults.")
        }
    }

    private struct CategorySection {
        var category: CommandCategory
        var commands: [AppCommand]
    }

    /// Commands that match every word of the search (title, category, keywords or shortcut glyphs).
    private var matchingSections: [CategorySection] {
        let terms = CommandPaletteSearch.fold(search).split(whereSeparator: \.isWhitespace).map(String.init)
        return CommandCategory.allCases.compactMap { category in
            let commands = registry.commands(in: category).filter { command in
                guard command.showsInSettings else { return false }
                guard !terms.isEmpty else { return true }
                let haystack = CommandPaletteSearch.fold(
                    ([command.title, category.title, store.display(for: command.id) ?? ""] + command.keywords)
                        .joined(separator: " "))
                return terms.allSatisfy { haystack.contains($0) }
            }
            return commands.isEmpty ? nil : CategorySection(category: category, commands: commands)
        }
    }
}

/// One command: icon, name and its shortcut editor.
private struct ShortcutRow: View {
    let command: AppCommand

    var body: some View {
        LabeledContent {
            ShortcutEditor(id: command.id, title: command.title)
        } label: {
            Label {
                Text(verbatim: command.title)
            } icon: {
                Image(systemName: command.symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The Autocomplete keys (shown in Settings › Editor and at the top of Settings › Shortcuts).
struct AutocompleteSettingsSection: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Section {
            Toggle("Suggest completions while typing", isOn: $settings.autoCompletion)
            Toggle("Tab completes", isOn: $settings.tabCompletes)
            Picker("Accept completion with", selection: $settings.completionAcceptKeys) {
                Text("Tab and Return").tag(CompletionAcceptKeys.tabAndReturn)
                Text("Tab only").tag(CompletionAcceptKeys.tabOnly)
                Text("Return only").tag(CompletionAcceptKeys.returnOnly)
            }
            LabeledContent("Show completions") {
                ShortcutEditor(id: .complete, title: String(localized: "Show completions"))
            }
        } header: {
            Text("Autocomplete")
        } footer: {
            Text("With “Tab completes”, Tab right after a partial command such as \\sec, or inside \\ref{…}, \\cite{…} or \\begin{…}, completes it with the first suggestion (\\sec becomes \\section). Elsewhere Tab indents and moves between snippet fields as usual. In Vim mode this applies in insert mode.")
        }
    }
}

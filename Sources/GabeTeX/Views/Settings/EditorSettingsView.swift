import SwiftUI
import AppKit

/// Editor appearance and behaviour.
struct EditorSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $settings.fontName) {
                    Text("System Monospaced").tag("")
                    ForEach(fontChoices) { choice in
                        Text(choice.family).tag(choice.postScriptName)
                    }
                }
                Stepper(value: $settings.fontSize, in: 8...40, step: 1) {
                    LabeledContent("Size") {
                        Text("\(Int(settings.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Line height") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.lineHeight, in: 1.0...2.2, step: 0.05) {
                            Text("Line height")
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Text("\(settings.lineHeight.formatted(.number.precision(.fractionLength(2))))×")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                preview
            } header: {
                Text("Font")
            }

            Section {
                Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                Toggle("Wrap long lines", isOn: $settings.wrapLines)
                Toggle("Highlight the current line", isOn: $settings.highlightCurrentLine)
                Toggle("Check spelling while typing", isOn: $settings.spellChecking)
            } header: {
                Text("Display")
            }

            Section {
                Toggle("Close brackets and dollar signs automatically", isOn: $settings.autoPairBrackets)
                Toggle("Add \\end{…} after \\begin{…}", isOn: $settings.autoCloseEnvironments)
                Toggle("Suggest completions while typing", isOn: $settings.autoCompletion)
            } header: {
                Text("Typing")
            } footer: {
                Text("Press ⌃Space at any time to show completions.")
            }

            Section {
                Stepper(value: $settings.indentWidth, in: 1...8) {
                    LabeledContent("Indent width") {
                        Text("\(settings.indentWidth)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle("Indent with spaces", isOn: $settings.insertSpaces)
            } header: {
                Text("Indentation")
            }

            Section {
                Toggle("Vim mode", isOn: $settings.vimMode)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Modal editing with motions, operators, text objects and ex commands such as :w and :make.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Preview

    private var preview: some View {
        Text(verbatim: "\\begin{equation}\n  e^{i\\pi} + 1 = 0\n\\end{equation}")
            .font(Font(Self.font(named: settings.fontName, size: settings.fontSize)))
            .lineSpacing(max(0, (settings.lineHeight - 1) * settings.fontSize * 0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Font preview")
    }

    static func font(named name: String, size: Double) -> NSFont {
        let pointSize = CGFloat(max(8, min(size, 40)))
        if !name.isEmpty, let font = NSFont(name: name, size: pointSize) { return font }
        return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    // MARK: Fonts

    struct FontChoice: Identifiable, Hashable {
        var family: String
        var postScriptName: String
        var id: String { postScriptName }
    }

    /// Fixed-pitch font families, with the PostScript name of their regular face; plus the saved font
    /// when it is no longer installed (so the picker never shows an empty selection).
    private var fontChoices: [FontChoice] {
        var choices = Self.installedMonospacedFonts
        let saved = settings.fontName
        if !saved.isEmpty, !choices.contains(where: { $0.postScriptName == saved }) {
            choices.insert(FontChoice(family: saved, postScriptName: saved), at: 0)
        }
        return choices
    }

    static let installedMonospacedFonts: [FontChoice] = {
        let manager = NSFontManager.shared
        var seen = Set<String>()
        var result: [FontChoice] = []
        for name in manager.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            guard let font = NSFont(name: name, size: 12), let family = font.familyName, !seen.contains(family) else { continue }
            seen.insert(family)
            let members = manager.availableMembers(ofFontFamily: family) ?? []
            let blocked = Int(NSFontTraitMask.italicFontMask.rawValue | NSFontTraitMask.boldFontMask.rawValue)
            let regular = members.first { member in
                guard member.count >= 4, let weight = (member[2] as? NSNumber)?.intValue,
                      let traits = (member[3] as? NSNumber)?.intValue else { return false }
                return weight == 5 && traits & blocked == 0
            }
            let postScript = (regular?.first as? String) ?? name
            result.append(FontChoice(family: family, postScriptName: postScript))
        }
        return result.sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }()
}

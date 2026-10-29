import SwiftUI
import PreviewKit
import TeXToolchain

/// Compilation behaviour: engine, live compile, saving and checks.
struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Default engine", selection: $settings.defaultEngine) {
                    ForEach(TeXEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Toggle("Compile while typing", isOn: $settings.liveCompile)
                LabeledContent("Wait after typing") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.liveDelay, in: 0.5...5, step: 0.5) {
                            Text("Wait after typing")
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Text("\(settings.liveDelay.formatted(.number.precision(.fractionLength(1)))) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!settings.liveCompile)
                Toggle("Compile when saving", isOn: $settings.compileOnSave)
            } header: {
                Text("Compilation")
            } footer: {
                Text("Live compiling uses a private copy of your project, so unsaved text is checked without touching your files. A “% !TEX program = …” comment in the main file overrides the engine.")
            }

            Section {
                Toggle("Check style with chktex", isOn: $settings.chktexEnabled)
            } header: {
                Text("Checks")
            } footer: {
                Text("Structure problems such as unbalanced braces are always reported while you type.")
            }

            Section {
                Picker("Jump to source from PDF", selection: $settings.pdfSyncTrigger) {
                    Text("Double-click").tag(PDFSyncTrigger.doubleClick)
                    Text("⌘-click").tag(PDFSyncTrigger.commandClick)
                }
                Toggle("Show the PDF position after each build", isOn: $settings.syncAfterBuild)
                Toggle("Follow cursor in PDF", isOn: $settings.followCursorInPDF)
            } header: {
                Text("PDF Preview")
            } footer: {
                Text("Clicking text in the PDF takes you to the same word in the source, and ⇧⌘J (Build ▸ Show in PDF) or ⌘-click in the editor shows where a word is in the PDF. “Follow cursor” keeps the PDF scrolled to the cursor once it rests.")
            }
        }
        .formStyle(.grouped)
    }
}

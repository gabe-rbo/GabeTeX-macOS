import SwiftUI
import AppKit
import TeXToolchain

/// The detected TeX distribution, its tools, and the custom folder override.
struct TeXSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    private let toolchain = ToolchainModel.shared

    var body: some View {
        Form {
            distributionSection
            if let distribution = toolchain.distribution {
                toolsSection(distribution)
            }
            customFolderSection
            if toolchain.candidates.count > 1 {
                othersSection
            }
        }
        .formStyle(.grouped)
        .task { await toolchain.ensureLocated() }
    }

    // MARK: Distribution

    @ViewBuilder
    private var distributionSection: some View {
        Section {
            if !toolchain.hasLocated {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for TeX…").foregroundStyle(.secondary)
                }
            } else if let distribution = toolchain.distribution {
                LabeledContent("Distribution") { Text(distribution.name) }
                if let version = distribution.versionDescription, !version.isEmpty {
                    LabeledContent("Version") { Text(version).textSelection(.enabled) }
                }
                LabeledContent("Location") {
                    Text(distribution.binDirectory.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Installing packages") {
                    if distribution.isUserWritable {
                        Label("Without a password", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Needs your administrator password", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("No TeX distribution was found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Install MacTeX to compile documents, or choose the folder that contains pdflatex below.")
                        .foregroundStyle(.secondary)
                    Button("Get MacTeX") {
                        if let url = URL(string: "https://tug.org/mactex/") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        } header: {
            HStack {
                Text("Distribution")
                Spacer()
                Button {
                    Task { await toolchain.relocate() }
                } label: {
                    Label("Detect Again", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.link)
                .disabled(toolchain.isLocating)
                .help("Look for TeX again")
            }
        }
    }

    // MARK: Tools

    private func toolsSection(_ distribution: TeXDistribution) -> some View {
        Section {
            ForEach(TeXTool.allCases, id: \.self) { tool in
                ToolRow(tool: tool, url: distribution.tools[tool], problem: distribution.toolProblems[tool])
            }
        } header: {
            Text("Tools")
        } footer: {
            if !distribution.toolProblems.isEmpty {
                Text("Some tools are installed but do not work. Documents that need them cannot be fully built.")
            }
        }
    }

    // MARK: Custom folder

    private var customFolderSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("Automatic", text: $settings.customBinDirectory, prompt: Text("Detect automatically"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { Task { await toolchain.relocate() } }
                Button("Choose…") { chooseFolder() }
                if !settings.customBinDirectory.isEmpty {
                    Button("Reset") {
                        settings.customBinDirectory = ""
                        Task { await toolchain.relocate() }
                    }
                }
            }
        } header: {
            Text("Custom TeX Folder")
        } footer: {
            Text("The folder that contains pdflatex and latexmk, for example /Library/TeX/texbin. Leave it empty to detect MacTeX, TeX Live or TinyTeX automatically.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Library/TeX", isDirectory: true)
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder that contains pdflatex and latexmk.")
        if panel.runModal() == .OK, let url = panel.url {
            settings.customBinDirectory = url.path
            Task { await toolchain.relocate() }
        }
    }

    // MARK: Other installations

    private var othersSection: some View {
        Section {
            ForEach(toolchain.candidates, id: \.binDirectory) { candidate in
                LabeledContent {
                    Text(candidate.binDirectory.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    HStack(spacing: 6) {
                        Text(candidate.name)
                        if candidate.binDirectory == toolchain.distribution?.binDirectory {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                                .accessibilityLabel("In use")
                        }
                    }
                }
            }
        } header: {
            Text("Installations Found")
        }
    }
}

private struct ToolRow: View {
    let tool: TeXTool
    let url: URL?
    let problem: String?

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                if let problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let url {
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not found")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(verbatim: tool.rawValue).font(.system(size: 12, design: .monospaced))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusText)
    }

    private var symbol: String {
        if problem != nil { return "exclamationmark.triangle.fill" }
        return url != nil ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var tint: Color {
        if problem != nil { return .orange }
        return url != nil ? .green : .red
    }

    private var statusText: Text {
        if problem != nil { return Text("Not working") }
        return url != nil ? Text("Available") : Text("Not found")
    }
}

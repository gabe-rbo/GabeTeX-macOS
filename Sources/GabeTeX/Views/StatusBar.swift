import SwiftUI
import TeXToolchain
import VimKit
import EditorKit

/// Compile state, issue counts, engine, distribution, Vim mode and caret position as glass capsules.
struct StatusBar: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Environment(ToolchainModel.self) private var toolchain

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                CompileStateCapsule()
                IssueCountsCapsule()
                if let message = workspace.statusMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
                if settings.vimMode { VimStatusCapsule(editor: workspace.editor) }
                capsule {
                    Text(workspace.effectiveEngine.displayName)
                }
                if let distribution = toolchain.distribution {
                    capsule {
                        Text(distribution.name)
                    }
                    .help(distribution.versionDescription ?? distribution.name)
                }
                if let format = workspace.currentFile.flatMap({ workspace.formats[$0] }) {
                    capsule {
                        Text(verbatim: format.statusName)
                    }
                    .help("Text encoding of the current file")
                }
                CursorCapsule(editor: workspace.editor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .animation(.smooth(duration: 0.2), value: workspace.statusMessage)
        .accessibilityElement(children: .contain)
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .glassEffect(.regular, in: .capsule)
    }
}

private struct CompileStateCapsule: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: 6) {
            switch workspace.compileState {
            case .compiling:
                ProgressView().controlSize(.mini)
                Text("Compiling…")
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(durationText ?? String(localized: "Compiled"))
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Compiled with errors")
            case .toolError:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Cannot compile")
            case .idle:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                if workspace.hasCompiled { Text("Stopped") } else { Text("Ready") }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .glassEffect(.regular, in: .capsule)
        .help(helpText)
        .accessibilityElement(children: .combine)
    }

    private var durationText: String? {
        guard let duration = workspace.lastCompileDuration else { return nil }
        return String(localized: "Compiled in \(duration.formatted(.number.precision(.fractionLength(1)))) s")
    }

    private var helpText: Text {
        if case .toolError(let message) = workspace.compileState { return Text(message) }
        return Text("Compile status")
    }
}

private struct IssueCountsCapsule: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        Button {
            withAnimation(.smooth) { workspace.showIssues.toggle() }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(workspace.errorCount > 0 ? .red : .secondary)
                    Text("\(workspace.errorCount)").monospacedDigit()
                }
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(workspace.warningCount > 0 ? .orange : .secondary)
                    Text("\(workspace.warningCount)").monospacedDigit()
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 22)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Show or hide the Issues panel (⇧⌘M)")
        .accessibilityLabel("Issues")
        .accessibilityValue(Text("\(workspace.errorCount) errors, \(workspace.warningCount) warnings"))
    }
}

/// Reads only the caret position, so moving the caret re-renders just this capsule.
private struct CursorCapsule: View {
    let editor: EditorController

    var body: some View {
        Text("Ln \(editor.cursor.line), Col \(editor.cursor.column)")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .glassEffect(.regular, in: .capsule)
            .accessibilityLabel("Cursor position")
    }
}

private struct VimStatusCapsule: View {
    let editor: EditorController

    var body: some View {
        HStack(spacing: 6) {
            if let mode = editor.vimMode {
                Text(verbatim: mode.label).fontWeight(.semibold)
            }
            if let command = editor.vimCommandLine {
                Text(verbatim: command).font(.system(size: 11, design: .monospaced))
            } else if !editor.vimPendingKeys.isEmpty {
                Text(verbatim: editor.vimPendingKeys).font(.system(size: 11, design: .monospaced))
            } else if let message = editor.vimMessage, !message.isEmpty {
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: 380)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Vim mode")
    }
}

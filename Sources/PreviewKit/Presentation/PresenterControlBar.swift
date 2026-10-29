import SwiftUI

// MARK: - Control bar

/// The presenter's controls: one Liquid Glass bar of small glass clusters, and the End button.
struct PresenterControlBar: View {
    let controller: PresentationController

    var body: some View {
        let navigator = controller.navigator
        let timer = controller.timer
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 14) {
                BarCluster {
                    BarButton("Previous Slide", systemImage: "chevron.left", help: "Previous Slide (←)",
                              isEnabled: navigator.previousIndex != nil || navigator.blank != .none) {
                        controller.perform(.previous)
                    }
                    BarButton("Next Slide", systemImage: "chevron.right", help: "Next Slide (→)",
                              isEnabled: navigator.nextIndex != nil || navigator.blank != .none) {
                        controller.perform(.next)
                    }
                }
                BarCluster {
                    if timer.isRunning {
                        BarButton("Pause Timer", systemImage: "pause.fill", help: "Pause Timer") {
                            controller.toggleTimer()
                        }
                    } else {
                        BarButton("Resume Timer", systemImage: "play.fill", help: "Resume Timer") {
                            controller.toggleTimer()
                        }
                    }
                    BarButton("Reset Timer", systemImage: "arrow.counterclockwise", help: "Reset Timer") {
                        controller.resetTimer()
                    }
                }
                BarCluster {
                    BarButton("Black Screen", systemImage: navigator.blank == .black ? "eye.slash.fill" : "eye.slash",
                              help: "Black Screen (B)", isOn: navigator.blank == .black) {
                        controller.perform(.toggleBlack)
                    }
                    BarButton("White Screen", systemImage: navigator.blank == .white ? "sun.max.fill" : "sun.max",
                              help: "White Screen (W)", isOn: navigator.blank == .white) {
                        controller.perform(.toggleWhite)
                    }
                }
                BarCluster {
                    NotesMenu(controller: controller)
                    switch controller.layout {
                    case .dual:
                        BarButton("Swap Displays", systemImage: "arrow.left.arrow.right", help: "Swap Displays") {
                            controller.swapDisplays()
                        }
                    case .single:
                        BarButton("Show Slides", systemImage: "rectangle.inset.filled", help: "Show Slides (P)") {
                            controller.perform(.togglePresenterView)
                        }
                    }
                }
                Button {
                    controller.perform(.end)
                } label: {
                    Label("End Presentation", systemImage: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 6)
                        .frame(height: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .focusable(false)
                .help("End Presentation (Esc)")
            }
        }
        .fixedSize()
    }
}

/// A group of icon buttons sharing one glass capsule.
private struct BarCluster<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(5)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Icon-only control of the bar: tooltip, accessibility label, highlighted while `isOn`.
private struct BarButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let help: LocalizedStringKey
    var isEnabled = true
    var isOn = false
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, help: LocalizedStringKey, isEnabled: Bool = true,
         isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.isEnabled = isEnabled
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 42, height: 32)
                .contentShape(.capsule)
        }
        .buttonStyle(PresenterBarButtonStyle(isOn: isOn))
        .disabled(!isEnabled)
        .focusable(false)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// "Notes ▾": where the notes are on the pages.
private struct NotesMenu: View {
    let controller: PresentationController

    var body: some View {
        Menu {
            Picker("Notes On", selection: Binding(
                get: { controller.notesMode },
                set: { controller.notesMode = $0 }
            )) {
                ForEach(PresentationNotesMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 14, weight: .semibold))
                Text("Notes")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(PresenterBarButtonStyle(isOn: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("Where the notes are on the pages")
        .accessibilityLabel(Text("Notes On"))
        .accessibilityValue(Text(controller.notesMode.title))
    }
}

/// Borderless button inside a glass capsule: a faint capsule on hover, a stronger one while pressed or on.
private struct PresenterBarButtonStyle: ButtonStyle {
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        PresenterBarButtonBody(configuration: configuration, isOn: isOn)
    }
}

private struct PresenterBarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    // `@State` is a macro whose plug-in ships only with Xcode; the property-wrapper type works directly.
    private let hover = State(initialValue: false)

    var body: some View {
        let strength: Double = configuration.isPressed ? 0.2 : (hover.wrappedValue && isEnabled ? 0.09 : 0)
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(isOn ? Color.black : Color.white) : AnyShapeStyle(.white.opacity(0.3)))
            .background {
                // "On" (black / white screen showing) is the same orange as the badge above the current slide.
                Capsule().fill(isOn ? AnyShapeStyle(Color.orange.opacity(configuration.isPressed ? 0.75 : 0.9))
                                    : AnyShapeStyle(Color.white.opacity(strength)))
            }
            .onHover { hover.wrappedValue = $0 }
    }
}

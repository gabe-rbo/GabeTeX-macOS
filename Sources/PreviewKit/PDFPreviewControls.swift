import SwiftUI

/// Floating Liquid Glass controls for the preview: zoom −, zoom percentage (click to fit the width), zoom +,
/// and the page indicator "3 / 12", all in one capsule.
///
/// Overlay it on the preview, bottom center (`PDFPreviewPane` does this for you):
///
///     PDFPreviewView(controller: c).overlay(alignment: .bottom) { PDFPreviewControls(controller: c).padding(14) }
public struct PDFPreviewControls: View {
    public var controller: PDFPreviewController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(controller: PDFPreviewController) {
        self.controller = controller
    }

    private var percent: Int { Int((controller.scaleFactor * 100).rounded()) }
    private var total: Int { controller.pageCount }
    private var page: Int { total == 0 ? 0 : min(max(controller.currentPageIndex + 1, 1), total) }

    public var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 2) {
                ControlButton("Zoom Out", systemImage: "minus", isEnabled: controller.canZoomOut) {
                    controller.zoomOut()
                }

                Button {
                    controller.zoomToFitWidth()
                } label: {
                    Text("\(percent)%")
                        .font(.callout.monospacedDigit())
                        .contentTransition(.numericText())
                        .frame(minWidth: 46, minHeight: 24)
                        .contentShape(.capsule)
                }
                .buttonStyle(PreviewControlButtonStyle())
                .disabled(!controller.hasDocument)
                .help("Fit Width")
                .accessibilityLabel("Zoom")
                .accessibilityValue(controller.autoScales ? Text("\(percent) percent, fit width") : Text("\(percent) percent"))
                .accessibilityHint("Fits the page width")

                ControlButton("Zoom In", systemImage: "plus", isEnabled: controller.canZoomIn) {
                    controller.zoomIn()
                }

                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 6)
                    .accessibilityHidden(true)

                Group {
                    if total > 0 {
                        Text("\(page) / \(total)")
                    } else {
                        Text(verbatim: "– / –")
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .padding(.trailing, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(total > 0 ? Text("Page \(page) of \(total)") : Text("No pages"))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .fixedSize()
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: percent)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: page)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PDF zoom and pages")
    }
}

/// Icon-only button of the capsule: tooltip, accessibility label, dimmed when disabled.
private struct ControlButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, isEnabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(.capsule)
        }
        .buttonStyle(PreviewControlButtonStyle())
        .disabled(!isEnabled)
        .help(title)
    }
}

/// Borderless button that shows a faint capsule on hover and a stronger one while pressed – the capsule itself
/// is the glass, so the buttons inside must not add glass of their own.
private struct PreviewControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PreviewControlButtonBody(configuration: configuration)
    }
}

private struct PreviewControlButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    // `@State` is a macro in the macOS 27 SDK whose compiler plugin ships only with Xcode (not with the
    // Command Line Tools), so the property-wrapper type is used directly: SwiftUI still finds it as a
    // `DynamicProperty` stored property.
    private let hover = State(initialValue: false)

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .background {
                Capsule()
                    .fill(.primary.opacity(configuration.isPressed ? 0.16 : (hover.wrappedValue && isEnabled ? 0.08 : 0)))
            }
            .onHover { hover.wrappedValue = $0 }
    }
}

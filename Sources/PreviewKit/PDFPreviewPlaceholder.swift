import SwiftUI

/// Empty state of the preview: shown until the first PDF exists.
///
/// With no `message` it invites the user to compile; with a `message` (an error, e.g. "The last build failed.")
/// it swaps the symbol for a warning triangle and shows the message instead of the hint. The view has no
/// background of its own, so it blends with whatever it sits on (the preview's backdrop in `PDFPreviewPane`),
/// and uses only semantic colours, so it is right in Light and Dark mode.
public struct PDFPreviewPlaceholder: View {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: message == nil ? "doc.richtext" : "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text("No PDF yet")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)

                Group {
                    if let message {
                        Text(verbatim: message)
                            .textSelection(.enabled)
                    } else {
                        Text("Press ⌘B to compile")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(6)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

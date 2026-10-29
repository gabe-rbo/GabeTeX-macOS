import SwiftUI
import TeXCore

/// The completion list: Liquid Glass rounded panel, one row per item (kind badge, monospaced label
/// with the typed prefix emphasized, secondary detail, package badge).
struct CompletionListView: View {
    let model: CompletionModel
    let rowHeight: CGFloat
    let verticalPadding: CGFloat
    var onAccept: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.items.indices, id: \.self) { index in
                        CompletionRow(item: model.items[index], prefix: model.prefix,
                                      isSelected: index == model.selectedIndex)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { onAccept(index) }
                            .id(index)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, verticalPadding)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.scrollRequest) { _, _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(model.selectedIndex)
                }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Completions"))
    }
}

private struct CompletionRow: View {
    let item: CompletionItem
    let prefix: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            KindBadge(kind: item.kind)
            Text(labelText)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)
            Spacer(minLength: 10)
            if let detail = item.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let package = item.package, !package.isEmpty {
                Text(verbatim: package)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background {
                        Capsule().fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                    }
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The label with the typed prefix in semibold.
    private var labelText: AttributedString {
        var text = AttributedString(item.label)
        let label = item.label
        guard !prefix.isEmpty, label.lowercased().hasPrefix(prefix.lowercased()) else { return text }
        let end = text.characters.index(text.startIndex, offsetBy: min(prefix.count, text.characters.count))
        text[text.startIndex..<end].font = .system(size: 12, weight: .semibold, design: .monospaced)
        return text
    }
}

private struct KindBadge: View {
    let kind: CompletionItem.Kind

    var body: some View {
        Text(verbatim: letter)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color))
            .accessibilityLabel(Text(verbatim: accessibilityName))
    }

    private var letter: String {
        switch kind {
        case .command: "\\"
        case .environment: "E"
        case .label: "L"
        case .citation: "B"
        case .file: "F"
        case .package: "P"
        case .snippet: "S"
        }
    }

    private var color: Color {
        switch kind {
        case .command: Color(nsColor: EditorTheme.command)
        case .environment: Color(nsColor: EditorTheme.environmentName)
        case .label: Color(nsColor: EditorTheme.reference)
        case .citation: Color(nsColor: EditorTheme.verbatim)
        case .file: .gray
        case .package: Color(nsColor: EditorTheme.structure)
        case .snippet: Color(nsColor: EditorTheme.math)
        }
    }

    private var accessibilityName: String {
        switch kind {
        case .command: String(localized: "Command")
        case .environment: String(localized: "Environment")
        case .label: String(localized: "Label")
        case .citation: String(localized: "Citation")
        case .file: String(localized: "File")
        case .package: String(localized: "Package")
        case .snippet: String(localized: "Snippet")
        }
    }
}

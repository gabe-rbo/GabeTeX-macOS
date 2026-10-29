import SwiftUI

/// The filter chips above the recent list: “All” plus one glass capsule per label.
/// Single selection; right-click a chip to rename, recolor or delete its label; drop a project row on a chip
/// to give the project that label.
///
/// The chips wrap onto further rows when they do not fit the column, so none is ever cut off or hidden behind
/// a scroll; with a great many labels the block stops at three rows and scrolls.
struct LabelFilterBar: View {
    let labels: [ProjectLabel]
    @Binding var selection: UUID?
    let onRename: (ProjectLabel) -> Void
    let onDelete: (ProjectLabel) -> Void

    /// Three rows of chips.
    private static let maxHeight: CGFloat = 92

    private let store = ProjectLabelStore.shared
    @LocalState private var dropTarget: UUID? = nil

    var body: some View {
        ViewThatFits(in: .vertical) {
            chips
            ScrollView(.vertical, showsIndicators: false) {
                chips
            }
        }
        .frame(maxHeight: Self.maxHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Label filter")
    }

    private var chips: some View {
        GlassEffectContainer(spacing: 6) {
            FlowLayout(spacing: 6, lineSpacing: 8) {
                FilterChip(title: Text("All"), tint: nil, isSelected: selection == nil, isDropTarget: false) {
                    selection = nil
                }
                ForEach(labels) { label in
                    FilterChip(title: Text(verbatim: label.name), tint: label.color.color,
                               isSelected: selection == label.id, isDropTarget: dropTarget == label.id) {
                        selection = selection == label.id ? nil : label.id
                    }
                    .dropDestination(for: ProjectDragItem.self) { items, _ in
                        for item in items {
                            store.setAssigned(true, label, for: URL(fileURLWithPath: item.path, isDirectory: true))
                        }
                        return !items.isEmpty
                    } isTargeted: { targeted in
                        if targeted { dropTarget = label.id } else if dropTarget == label.id { dropTarget = nil }
                    }
                    .contextMenu {
                        Button("Rename…") { onRename(label) }
                        Menu("Color") {
                            ForEach(LabelColor.allCases) { option in
                                Toggle(isOn: Binding(
                                    get: { label.color == option },
                                    set: { _ in store.setColor(option, for: label.id) }
                                )) {
                                    Label {
                                        Text(option.displayName)
                                    } icon: {
                                        Image(nsImage: option.menuImage)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Delete Label", role: .destructive) { onDelete(label) }
                    }
                }
            }
            .padding(.vertical, 3)
        }
    }
}

/// Lays its children out left to right and starts a new row when the next one does not fit. A child wider than
/// the whole row is squeezed to it (its text truncates).
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: usedWidth, height: frames.isEmpty ? 0 : y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(maxWidth: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

/// One glass capsule: an optional color dot and a title. The selected chip is tinted with its color.
private struct FilterChip: View {
    let title: Text
    let tint: Color?
    let isSelected: Bool
    let isDropTarget: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }
                title
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint((tint ?? .accentColor).opacity(0.4)).interactive() : .regular.interactive(), in: .capsule)
        .overlay {
            if isDropTarget {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

import SwiftUI

/// “New Label” / “Rename Label”: a name field and the color swatches.
struct LabelEditorSheet: View {
    let request: LabelEditorRequest
    @Environment(\.dismiss) private var dismiss
    private let store = ProjectLabelStore.shared

    @LocalState private var name: String
    @LocalState private var color: LabelColor
    @FocusState private var nameFocused: Bool

    init(request: LabelEditorRequest) {
        self.request = request
        let store = ProjectLabelStore.shared
        switch request.mode {
        case .create:
            _name = LocalState(wrappedValue: "")
            _color = LocalState(wrappedValue: store.suggestedColor())
        case .edit(let id):
            let label = store.label(withID: id)
            _name = LocalState(wrappedValue: label?.name ?? "")
            _color = LocalState(wrappedValue: label?.color ?? store.suggestedColor())
        }
    }

    private var editingID: UUID? {
        if case .edit(let id) = request.mode { return id }
        return nil
    }

    private var canCommit: Bool { store.isNameAvailable(name, excluding: editingID) }

    private var nameIsTaken: Bool {
        !ProjectLabelStore.normalizedName(name).isEmpty && !canCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingID == nil ? "New Label" : "Rename Label")
                .font(.headline)

            TextField("Label name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(commit)
                .onChange(of: name) { _, newValue in
                    if newValue.count > ProjectLabelStore.maxNameLength {
                        name = String(newValue.prefix(ProjectLabelStore.maxNameLength))
                    }
                }

            HStack(spacing: 11) {
                ForEach(LabelColor.allCases) { option in
                    swatch(option)
                }
            }

            if nameIsTaken {
                Text("A label with this name already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editingID == nil ? "Create" : "Save", action: commit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 330)
        .task {
            await Task.yield()
            nameFocused = true
        }
    }

    private func swatch(_ option: LabelColor) -> some View {
        Button {
            color = option
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: 22, height: 22)
                .overlay {
                    if option == color {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.6), lineWidth: 2)
                            .padding(-4)
                    }
                }
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(option.displayName)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(option == color ? .isSelected : [])
    }

    private func commit() {
        guard canCommit else { return }
        switch request.mode {
        case .create(let project):
            guard let label = store.createLabel(name: name, color: color) else { return }
            if let project { store.setAssigned(true, label, for: project) }
        case .edit(let id):
            guard store.renameLabel(id, to: name) else { return }
            store.setColor(color, for: id)
        }
        dismiss()
    }
}

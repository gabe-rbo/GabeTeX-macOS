import SwiftUI
import AppKit
import TeXCore

/// “New Project…”: choose a template, a title, an author and where to create the folder.
struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss

    @LocalState private var templateID = ProjectTemplates.all.first?.id ?? ""
    @LocalState private var title = ""
    @LocalState private var author = NewProjectView.storedAuthor
    @LocalState private var location = NewProjectView.storedLocation
    @LocalState private var folderName = ""
    @LocalState private var folderNameEdited = false
    @LocalState private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    private static let authorKey = "newProject.author"
    private static let locationKey = "newProject.location"

    static var storedAuthor: String {
        UserDefaults.standard.string(forKey: authorKey) ?? NSFullUserName()
    }

    static var storedLocation: URL {
        if let path = UserDefaults.standard.string(forKey: locationKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private var template: ProjectTemplate? {
        ProjectTemplates.all.first { $0.id == templateID }
    }

    var body: some View {
        HStack(spacing: 0) {
            templateList
                .frame(width: 270)
            Divider()
            details
                .frame(width: 430)
        }
        .frame(height: 470)
        .containerBackground(.regularMaterial, for: .window)
        .onAppear { titleFocused = true }
    }

    // MARK: Templates

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose a Template")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(ProjectTemplates.all) { item in
                        TemplateRow(template: item, isSelected: item.id == templateID)
                            .onTapGesture { templateID = item.id }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let template {
                HStack(spacing: 12) {
                    Image(systemName: template.symbolName)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name).font(.title3.weight(.semibold))
                        Text(template.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Form {
                TextField("Title", text: $title, prompt: Text("Untitled Project"))
                    .focused($titleFocused)
                    .onChange(of: title) { _, _ in
                        if !folderNameEdited { folderName = ProjectCreator.suggestedFolderName(for: title) }
                    }
                TextField("Author", text: $author)
                TextField("Folder name", text: Binding(
                    get: { folderName },
                    set: { folderName = $0; folderNameEdited = true }
                ), prompt: Text("Untitled Project"))
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text((location.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseLocation() }
                    }
                }
            }
            .formStyle(.columns)

            if let template {
                filesPreview(template)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(template == nil)
            }
            .controlSize(.large)
        }
        .padding(20)
    }

    private func filesPreview(_ template: ProjectTemplate) -> some View {
        let names = template.files.keys.sorted { a, b in
            if a == template.mainFile { return true }
            if b == template.mainFile { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Files")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(names, id: \.self) { name in
                    Label {
                        Text(name).font(.system(size: 12, design: .monospaced))
                    } icon: {
                        Image(systemName: name == template.mainFile ? "star.fill" : "doc.text")
                            .foregroundStyle(name == template.mainFile ? Color.yellow : .secondary)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    // MARK: Actions

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = location
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder in which the project folder will be created.")
        if panel.runModal() == .OK, let url = panel.url { location = url }
    }

    private func create() {
        guard let template else { return }
        errorMessage = nil
        let name = ProjectCreator.sanitized(folderName.isEmpty ? ProjectCreator.suggestedFolderName(for: title) : folderName)
        let folder = location.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        let projectTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Untitled Project") : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try ProjectCreator.write(template: template, title: projectTitle, author: projectAuthor, to: folder)
        } catch let error as ProjectCreator.CreationError {
            errorMessage = error.message
            return
        } catch {
            errorMessage = String(localized: "The project could not be created: \(error.localizedDescription)")
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(projectAuthor, forKey: Self.authorKey)
        defaults.set(location.path, forKey: Self.locationKey)
        if template.engine != AppSettings.shared.defaultEngine.rawValue {
            defaults.set(template.engine, forKey: "project.\(folder.path).engine")
        }
        let main = folder.appendingPathComponent(template.mainFile).standardizedFileURL
        AppRouter.shared.open(folder: folder, file: main)
        dismiss()
    }
}

private struct TemplateRow: View {
    let template: ProjectTemplate
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: template.symbolName)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(template.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

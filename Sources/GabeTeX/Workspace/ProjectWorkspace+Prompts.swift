import SwiftUI

/// A “type a name” dialog requested by the sidebar or the File menu.
struct NamePrompt: Identifiable {
    enum Kind {
        case newFile(in: URL)
        case newFolder(in: URL)
        case rename(URL)
        case goToLine
    }

    let id = UUID()
    var kind: Kind
    /// Text the field starts with.
    var initialText: String

    var title: String {
        switch kind {
        case .newFile: String(localized: "New File")
        case .newFolder: String(localized: "New Folder")
        case .rename(let url): String(localized: "Rename “\(url.lastPathComponent)”")
        case .goToLine: String(localized: "Go to Line")
        }
    }

    var message: String {
        switch kind {
        case .newFile: String(localized: "Enter a name for the new file. “.tex” is added if you leave out an extension.")
        case .newFolder: String(localized: "Enter a name for the new folder.")
        case .rename: String(localized: "Enter a new name.")
        case .goToLine: String(localized: "Enter a line number.")
        }
    }

    var fieldLabel: String {
        switch kind {
        case .goToLine: String(localized: "Line")
        default: String(localized: "Name")
        }
    }

    var confirmTitle: String {
        switch kind {
        case .rename: String(localized: "Rename")
        case .goToLine: String(localized: "Go")
        default: String(localized: "Create")
        }
    }
}

extension ProjectWorkspace {
    func promptNewFile(in directory: URL? = nil) {
        namePrompt = NamePrompt(kind: .newFile(in: directory ?? newItemDirectory), initialText: "")
    }

    func promptNewFolder(in directory: URL? = nil) {
        namePrompt = NamePrompt(kind: .newFolder(in: directory ?? newItemDirectory), initialText: "")
    }

    func promptGoToLine() {
        namePrompt = NamePrompt(kind: .goToLine, initialText: "")
    }

    func promptRename(_ url: URL) {
        namePrompt = NamePrompt(kind: .rename(url), initialText: url.lastPathComponent)
    }

    /// Applies the dialog: `text` is what the user typed.
    func commit(_ prompt: NamePrompt, text: String) {
        namePrompt = nil
        switch prompt.kind {
        case .newFile(let directory): createFile(named: text, in: directory)
        case .newFolder(let directory): createFolder(named: text, in: directory)
        case .rename(let url): rename(url, to: text)
        case .goToLine:
            if let line = Int(text.trimmingCharacters(in: .whitespaces)), line > 0 {
                editor.goTo(line: line, column: nil, highlight: true)
                editor.focus()
            } else {
                flash(String(localized: "Enter a positive line number."))
            }
        }
    }
}

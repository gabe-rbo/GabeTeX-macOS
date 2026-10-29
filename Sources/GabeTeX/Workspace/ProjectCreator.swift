import Foundation
import TeXCore

/// Creates a project folder from a template (used by the New Project window).
enum ProjectCreator {
    struct CreationError: Error {
        var message: String
    }

    /// Writes the template into `folder`, which must not exist or must be empty (hidden files aside).
    static func write(template: ProjectTemplate, title: String, author: String, to folder: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            if !isDirectory.boolValue || contents.contains(where: { !$0.hasPrefix(".") }) {
                throw CreationError(message: String(localized: "“\(folder.lastPathComponent)” already exists in this location. Choose another name or location."))
            }
        } else {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw CreationError(message: String(localized: "The folder could not be created. Check that you have permission to write in this location."))
            }
        }
        for (relative, contents) in template.instantiate(title: latexSafe(title), author: latexSafe(author)) {
            let components = relative.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains(".."), !relative.hasPrefix("/") else { continue }
            let url = components.reduce(folder) { $0.appendingPathComponent($1) }
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url, options: .atomic)
            } catch {
                throw CreationError(message: String(localized: "“\(relative)” could not be written: \(error.localizedDescription)"))
            }
        }
    }

    /// Makes plain text safe inside `\title{…}` / `\author{…}` (“Notes on R & D” would otherwise fail to
    /// compile). Text that already contains math (`$`) or commands (`\`) is taken to be LaTeX and kept.
    static func latexSafe(_ text: String) -> String {
        if text.contains("$") || text.contains("\\") { return text }
        var result = ""
        for character in text {
            switch character {
            case "&": result += "\\&"
            case "%": result += "\\%"
            case "#": result += "\\#"
            case "_": result += "\\_"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "~": result += "\\textasciitilde{}"
            case "^": result += "\\textasciicircum{}"
            default: result.append(character)
            }
        }
        return result
    }

    /// A folder name derived from the title (“Untitled Project” when empty).
    static func suggestedFolderName(for title: String) -> String {
        let cleaned = sanitized(title)
        return cleaned.isEmpty ? String(localized: "Untitled Project") : cleaned
    }

    /// Removes characters that are not allowed (or are awkward) in folder names.
    static func sanitized(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let cleaned = raw.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        var result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        return result
    }
}

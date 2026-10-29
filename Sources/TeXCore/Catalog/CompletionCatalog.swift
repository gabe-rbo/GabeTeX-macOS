import Foundation

/// Built-in completion data. The tables live in `Catalog*.swift` files as raw multi-line strings
/// (fast to compile, easy to edit) and are parsed once, lazily.
///
/// Table format — one entry per line, fields separated by "¦" (U+00A6 BROKEN BAR), blank lines and
/// lines starting with "#" ignored. Inside fields "⏎" means newline and "⇥" means one indent level.
///
///   commandsTable / mathCommandsTable:   label¦insertSnippet¦detail¦package
///       \frac¦\frac{${1:num}}{${2:den}}¦Fraction¦
///       (empty insertSnippet → the label itself)
///   environmentsTable:                   name¦argumentsSnippet¦bodySnippet¦detail¦package
///       tabular¦{${1:cc}}¦$0¦Table¦
///       itemize¦¦\item $0¦Bulleted list¦
///   packagesTable:                       name¦detail
///       amsmath¦AMS mathematical facilities
public enum CompletionCatalog {
    /// Text-mode and general commands.
    public static let commands: [CompletionItem] = parseCommands(commandsTable, kind: .command)
    /// Math-mode commands (Greek letters, operators, arrows, accents, ...).
    public static let mathCommands: [CompletionItem] = parseCommands(mathCommandsTable, kind: .command)
    /// Environments. `insertText` is what replaces the typed name after `\begin{`:
    /// `name}` + arguments + `\n\t` + body (each body line indented) + `\n\end{name}`.
    public static let environments: [CompletionItem] = parseEnvironments(environmentsTable)
    public static let packages: [CompletionItem] = parsePackages(packagesTable)

    /// All commands, text first then math, de-duplicated by label.
    public static let allCommands: [CompletionItem] = {
        var seen = Set<String>()
        return (commands + mathCommands).filter { seen.insert($0.label).inserted }
    }()

    // MARK: - Parsing

    static func fields(_ line: Substring) -> [String] {
        line.split(separator: "¦", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
              .replacingOccurrences(of: "⏎", with: "\n")
              .replacingOccurrences(of: "⇥", with: "\t")
        }
    }

    static func rows(_ table: String) -> [[String]] {
        table.split(whereSeparator: \.isNewline).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            return fields(Substring(trimmed))
        }
    }

    static func parseCommands(_ table: String, kind: CompletionItem.Kind) -> [CompletionItem] {
        rows(table).compactMap { f in
            guard let label = f.first, !label.isEmpty else { return nil }
            let insert = f.count > 1 && !f[1].isEmpty ? f[1] : label
            let detail = f.count > 2 && !f[2].isEmpty ? f[2] : nil
            let package = f.count > 3 && !f[3].isEmpty ? f[3] : nil
            return CompletionItem(kind: kind, label: label, insertText: insert, detail: detail, package: package)
        }
    }

    static func parseEnvironments(_ table: String) -> [CompletionItem] {
        rows(table).compactMap { f in
            guard let name = f.first, !name.isEmpty else { return nil }
            let args = f.count > 1 ? f[1] : ""
            let body = f.count > 2 && !f[2].isEmpty ? f[2] : "$0"
            let detail = f.count > 3 && !f[3].isEmpty ? f[3] : nil
            let package = f.count > 4 && !f[4].isEmpty ? f[4] : nil
            let indentedBody = body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "\t" + $0 }
                .joined(separator: "\n")
            let insert = "\(name)}\(args)\n\(indentedBody)\n\\end{\(name)}"
            return CompletionItem(kind: .environment, label: name, insertText: insert, detail: detail, package: package)
        }
    }

    static func parsePackages(_ table: String) -> [CompletionItem] {
        rows(table).compactMap { f in
            guard let name = f.first, !name.isEmpty else { return nil }
            let detail = f.count > 1 && !f[1].isEmpty ? f[1] : nil
            return CompletionItem(kind: .package, label: name, insertText: name, detail: detail)
        }
    }
}

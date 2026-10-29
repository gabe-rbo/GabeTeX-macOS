import Foundation
import CheckKit
import TeXCore

@MainActor
func runModelChecks() async {
    await Check.suite("LineIndex") {
        let idx = LineIndex("ab\ncd\r\nef\rg")
        Check.equal(idx.lineCount, 4)
        Check.equal(idx.position(ofOffset: 3), SourcePosition(line: 2, column: 1))
        Check.equal(idx.offset(of: SourcePosition(line: 3, column: 2)), 8)
        Check.equal(idx.contentsRange(ofLine: 2), NSRange(location: 3, length: 2))
        Check.equal(LineIndex("").lineCount, 1)
        Check.equal(LineIndex("a\n").lineCount, 2)
        Check.equal(LineIndex("é😀x").position(ofOffset: 3), SourcePosition(line: 1, column: 4), "columns are UTF-16 units")
    }

    await Check.suite("CompletionCatalog parses") {
        Check.expect(!CompletionCatalog.allCommands.isEmpty)
        Check.expect(CompletionCatalog.environments.contains { $0.label == "itemize" })
        Check.expect(CompletionCatalog.packages.contains { $0.label == "amsmath" })
        Check.expect(CompletionCatalog.mathCommands.contains { $0.label == "\\alpha" })
        let labels = CompletionCatalog.allCommands.map(\.label)
        Check.equal(Set(labels).count, labels.count, "allCommands is de-duplicated")
    }

    await Check.suite("ProjectTemplates") {
        Check.expect(!ProjectTemplates.all.isEmpty)
        var ids = Set<String>()
        for template in ProjectTemplates.all {
            Check.expect(ids.insert(template.id).inserted, "unique id \(template.id)")
            Check.expect(template.files[template.mainFile] != nil, "\(template.id): main file \(template.mainFile) exists")
            let files = template.instantiate(title: "My Title", author: "Gabe", date: Date(timeIntervalSince1970: 0))
            Check.expect(files.values.allSatisfy { !$0.contains("{{") }, "\(template.id): placeholders replaced")
            let main = files[template.mainFile] ?? ""
            Check.expect(LaTeXScanner.isRootDocument(main), "\(template.id): main file is a root document")
            // Every file reachable from the main file exists in the template.
            let index = ProjectIndex.build(
                rootFile: fileURL(template.mainFile),
                read: { url in files[String(url.path.dropFirst("/proj/".count))] },
                fileExists: { url in files[String(url.path.dropFirst("/proj/".count))] != nil }
            )
            for reference in LaTeXScanner.includes(in: main) where [.input, .include, .subfile].contains(reference.kind) {
                let resolved = ProjectIndex.resolve(reference, includingFile: fileURL(template.mainFile), rootFile: fileURL(template.mainFile),
                                                    fileExists: { files[String(($0).path.dropFirst("/proj/".count))] != nil })
                Check.expect(resolved != nil, "\(template.id): \\\(reference.kind.rawValue){\(reference.argument)} resolves")
            }
            Check.expect(index.files.count >= 1)
        }
    }
}

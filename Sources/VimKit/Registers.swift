import Foundation

/// A register's content. Linewise text always ends with a newline.
struct Register: Equatable {
    var text: String
    var linewise: Bool
}

/// All internal registers.
struct RegisterFile {
    var unnamed: Register?
    var named: [Character: Register] = [:]
    /// Index 0 is `"0` (last yank), 1...9 are `"1`...`"9` (delete history).
    var numbered: [Register?] = Array(repeating: nil, count: 10)
    var smallDelete: Register?
    var lastInserted: String = ""
    var lastExCommand: String = ""
}

extension VimEngine {

    // MARK: Writing

    /// Stores yanked text. `reg` is the register named with `"x` (nil = unnamed).
    func storeYank(_ text: String, linewise: Bool, register reg: Character?) {
        if reg == "_" { return }
        let value = Register(text: text, linewise: linewise)
        if let r = reg, r != "\"" {
            write(value, to: r)
            return
        }
        regs.unnamed = value
        regs.numbered[0] = value
        mirrorToClipboard(value)
    }

    /// Stores deleted text (also used by `c`). `forceNumbered` is set for motions that always use `"1`.
    func storeDelete(_ text: String, linewise: Bool, register reg: Character?, forceNumbered: Bool = false) {
        if reg == "_" || text.isEmpty { return }
        let value = Register(text: text, linewise: linewise)
        if let r = reg, r != "\"" {
            write(value, to: r)
            return
        }
        regs.unnamed = value
        if linewise || text.containsLineBreak || forceNumbered {
            var i = 9
            while i > 1 {
                regs.numbered[i] = regs.numbered[i - 1]
                i -= 1
            }
            regs.numbered[1] = value
        } else {
            regs.smallDelete = value
        }
        if mirrorDeletesToClipboard { mirrorToClipboard(value) } else { clipboardSnapshot = readClipboard?() }
    }

    private func write(_ value: Register, to name: Character) {
        var v = value
        switch name {
        case "+", "*":
            writeClipboard?(v.text)
            clipboardSnapshot = readClipboard?()
        case "a"..."z":
            regs.named[name] = v
        case "A"..."Z":
            let key = Character(name.lowercased())
            if let old = regs.named[key] {
                if v.linewise && !old.linewise {
                    v.text = old.text + (old.text.endsWithLineBreak ? "" : "\n") + v.text
                } else if old.linewise && !v.linewise {
                    v.text = old.text + v.text + "\n"
                    v.linewise = true
                } else {
                    v.text = old.text + v.text
                    v.linewise = old.linewise
                }
            }
            regs.named[key] = v
        case "0"..."9":
            regs.numbered[Int(name.asciiValue ?? 48) - 48] = v
        case "-":
            regs.smallDelete = v
        default:
            break
        }
        regs.unnamed = v
    }

    private func mirrorToClipboard(_ value: Register) {
        guard clipboardUnnamed, let write = writeClipboard else {
            clipboardSnapshot = readClipboard?()
            return
        }
        write(value.text)
        clipboardSnapshot = readClipboard?() ?? value.text
    }

    // MARK: Reading

    /// The register content for `p`, `Ctrl-r` … (nil when empty).
    func readRegister(_ name: Character?) -> Register? {
        switch name {
        case nil, "\"":
            if clipboardUnnamed, let cur = readClipboard?(), !cur.isEmpty, cur != clipboardSnapshot {
                return Register(text: cur, linewise: cur.endsWithLineBreak)
            }
            return regs.unnamed
        case "+"?, "*"?:
            guard let cur = readClipboard?(), !cur.isEmpty else { return regs.unnamed }
            if let u = regs.unnamed, u.text == cur { return u }
            return Register(text: cur, linewise: cur.endsWithLineBreak)
        default: break
        }
        guard let n = name else { return regs.unnamed }
        switch n {
        case "0"..."9": return regs.numbered[Int(n.asciiValue ?? 48) - 48]
        case "a"..."z": return regs.named[n]
        case "A"..."Z": return regs.named[Character(n.lowercased())]
        case "-": return regs.smallDelete
        case "/": return lastSearch.map { Register(text: $0.pattern, linewise: false) }
        case ".": return regs.lastInserted.isEmpty ? nil : Register(text: regs.lastInserted, linewise: false)
        case ":": return regs.lastExCommand.isEmpty ? nil : Register(text: regs.lastExCommand, linewise: false)
        default: return nil
        }
    }
}

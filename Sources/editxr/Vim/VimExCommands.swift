import Foundation

/// Ex (`:`) commands: line ranges, the command table, and each command.
extension VimEngine {
    /// Commands and their shortest accepted abbreviation, in the order Vim
    /// resolves ambiguous prefixes.
    private static let exCommands: [(name: String, min: Int)] = [
        ("substitute", 1), ("set", 2), ("setlocal", 4), ("setglobal", 4), ("sort", 3),
        ("startinsert", 4), ("saveas", 3),
        ("buffer", 1), ("bNext", 2), ("bdelete", 2), ("bfirst", 2), ("blast", 2), ("bnext", 2),
        ("bprevious", 2), ("buffers", 7),
        ("config", 4), ("copy", 2),
        ("delete", 1), ("display", 2),
        ("edit", 1), ("echo", 2), ("enew", 3), ("exit", 3),
        ("file", 1), ("files", 5), ("find", 3),
        ("global", 1),
        ("help", 1),
        ("join", 1), ("jumps", 2),
        ("k", 1),
        ("ls", 2),
        ("move", 1), ("mark", 2), ("map", 3), ("mapclear", 4), ("marks", 5), ("messages", 3),
        ("nmap", 2), ("nnoremap", 2), ("noremap", 2), ("nunmap", 3), ("nmapclear", 5),
        ("nohlsearch", 3), ("normal", 4), ("number", 2),
        ("open", 1), ("omap", 2), ("onoremap", 3), ("ounmap", 2),
        ("imap", 2), ("inoremap", 3), ("iunmap", 2), ("imapclear", 5),
        ("cmap", 2), ("cnoremap", 3), ("cunmap", 2),
        ("vmap", 2), ("vnoremap", 2), ("vunmap", 2), ("vmapclear", 5),
        ("xmap", 2), ("xnoremap", 2), ("xunmap", 2), ("unmap", 3),
        ("print", 1), ("put", 2), ("pwd", 2),
        ("quit", 1), ("qall", 2), ("quitall", 5),
        ("read", 1), ("redo", 3), ("registers", 3), ("retab", 3),
        ("t", 1), ("tabNext", 4), ("tabclose", 4), ("tabedit", 4), ("tabfirst", 6), ("tablast", 4),
        ("tabnew", 6), ("tabnext", 4), ("tabprevious", 4), ("tabrewind", 4),
        ("undo", 1), ("update", 2),
        ("vglobal", 1), ("version", 2),
        ("write", 1), ("wall", 2), ("wq", 2), ("wqall", 3),
        ("xit", 1), ("xall", 2),
        ("yank", 1),
    ]

    static func resolveExCommand(_ typed: String) -> String? {
        if let exact = exCommands.first(where: { $0.name == typed }) { return exact.name }
        return exCommands.first { $0.name.hasPrefix(typed) && typed.count >= $0.min }?.name
    }

    struct ExError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Run one command line. `|` separates commands, except after commands
    /// that take it as part of their argument (`:g`, `:normal`).
    func runEx(_ input: String) {
        for part in splitBars(input) {
            do {
                try runSingleEx(part)
            } catch let error as ExError {
                message(error.message, error: true)
                return
            } catch {
                message("\(error)", error: true)
                return
            }
        }
    }

    private func splitBars(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var chars = Array(input)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            if c == "\\" && chars.first == "|" {
                current.append("|")
                chars = chars.dropFirst()
                continue
            }
            if c == "|" {
                // Commands that own the rest of the line, bars included.
                let head = current.trimmingCharacters(in: .whitespaces)
                let name = String(head.drop { !$0.isLetter }.prefix { $0.isLetter })
                if let resolved = VimEngine.resolveExCommand(name), ["global", "vglobal", "normal"].contains(resolved) {
                    current.append(c)
                    continue
                }
                parts.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        parts.append(current)
        return parts
    }

    // MARK: - Ranges

    private var exLastLine: Int { VimText.lastContentLine(exLines) }

    /// Parse `[range]` from the front of `s`. Returns nil when no range was
    /// given; addresses are 0-based line indexes.
    private func parseRange(_ s: inout Substring) throws -> (start: Int, end: Int, addresses: Int)? {
        s = s.drop { $0 == " " || $0 == ":" }
        if s.first == "%" {
            s = s.dropFirst()
            return (0, exLastLine, 2)
        }
        guard var first = try parseAddress(&s) else {
            if s.first == "," || s.first == ";" {
                // ",5" means ".,5".
                let here = exCursor.line
                s = s.dropFirst()
                let second = try parseAddress(&s) ?? here
                return (here, second, 2)
            }
            return nil
        }
        var addresses = 1
        var last = first
        while s.first == "," || s.first == ";" {
            if s.first == ";" { exCursor = CursorPosition(line: max(0, min(last, exLastLine)), column: 0) }
            s = s.dropFirst()
            let next = try parseAddress(&s) ?? exCursor.line
            if addresses >= 2 { first = last }
            last = next
            addresses = 2
        }
        return (first, last, addresses)
    }

    private func parseAddress(_ s: inout Substring) throws -> Int? {
        s = s.drop { $0 == " " }
        var base: Int?
        guard let c = s.first else { return nil }
        if c.isASCII && c.isNumber {
            let digits = s.prefix { $0.isASCII && $0.isNumber }
            s = s.dropFirst(digits.count)
            base = (Int(digits) ?? 1) - 1
        } else if c == "." {
            s = s.dropFirst()
            base = exCursor.line
        } else if c == "$" {
            s = s.dropFirst()
            base = exLastLine
        } else if c == "'" {
            s = s.dropFirst()
            guard let m = s.first else { throw ExError("E20: Mark not set") }
            s = s.dropFirst()
            if m == "<" || m == ">" {
                guard let marks = exVisualMarks else { throw ExError("E20: Mark not set") }
                base = m == "<" ? marks.0.line : marks.1.line
            } else {
                guard let p = exMark(m) else { throw ExError("E20: Mark not set") }
                base = p.line
            }
        } else if c == "/" || c == "?" {
            s = s.dropFirst()
            var pattern = ""
            while let ch = s.first, ch != c {
                if ch == "\\", s.dropFirst().first == c {
                    pattern.append(c)
                    s = s.dropFirst(2)
                    continue
                }
                pattern.append(ch)
                s = s.dropFirst()
            }
            if s.first == c { s = s.dropFirst() }
            if pattern.isEmpty {
                guard let last = lastSearch else { throw ExError("E35: No previous regular expression") }
                pattern = last.pattern
            } else {
                setLastSearch(pattern, forward: c == "/")
            }
            guard let regex = compile(pattern) else { throw ExError("E486: Pattern not found: \(pattern)") }
            base = try findLine(regex, forward: c == "/", from: exCursor.line, pattern: pattern)
        }
        while let sign = s.first, sign == "+" || sign == "-" {
            s = s.dropFirst()
            let digits = s.prefix { $0.isASCII && $0.isNumber }
            s = s.dropFirst(digits.count)
            let n = Int(digits) ?? 1
            base = (base ?? exCursor.line) + (sign == "+" ? n : -n)
        }
        return base
    }

    private func findLine(_ regex: VimRegex, forward: Bool, from: Int, pattern: String) throws -> Int {
        let all = exLines
        let count = exLastLine + 1
        for step in 1...max(1, count) {
            let l = forward ? (from + step) % count : ((from - step) % count + count) % count
            if regex.firstMatch(in: all[l]) != nil { return l }
        }
        throw ExError("E486: Pattern not found: \(pattern)")
    }

    // MARK: - Dispatch

    private func runSingleEx(_ raw: String) throws {
        var s = Substring(raw)
        let range = try parseRange(&s)
        s = s.drop { $0 == " " }

        // A bare address jumps to that line.
        if s.isEmpty {
            guard let r = range else { return }
            let target = max(0, min(r.end, exLastLine))
            exJumpRecorded(from: exCursor)
            exCursor = CursorPosition(line: target, column: exFirstNonBlank(target))
            return
        }

        // Non-letter commands.
        if let c = s.first, !c.isLetter {
            switch c {
            case "&":
                // `:&&` keeps the previous flags; substituteRepeat reads the "&".
                try substituteRepeat(range: range, flags: String(s.dropFirst()))
            case "~":
                try substituteRepeat(range: range, flags: String(s.dropFirst()), useLastSearch: true)
            case ">", "<":
                let times = s.prefix { $0 == c }.count
                let countText = s.dropFirst(times).trimmingCharacters(in: .whitespaces)
                let (a, b) = try lineRange(range, count: Int(countText))
                exState.beginUndoGroup()
                shiftLines(a...b, by: c == ">" ? 1 : -1, times: times)
                exState.endUndoGroup()
            case "=":
                message("\((range?.end ?? exLastLine) + 1)")
            case "!":
                throw ExError("E: Shell commands aren't supported")
            case "#":
                try printLines(range, numbered: true)
            default:
                throw ExError("E492: Not an editor command: \(raw.trimmingCharacters(in: .whitespaces))")
            }
            return
        }

        var name = String(s.prefix { $0.isLetter })
        s = s.dropFirst(name.count)
        // `:ka` is `:k a`; `:s#a#b#` and `:g!/x/` keep their delimiters.
        if name.count == 2, name.first == "k", VimEngine.resolveExCommand(name) == nil {
            s = Substring(String(name.last!)) + s
            name = "k"
        }
        var bang = false
        if s.first == "!" {
            bang = true
            s = s.dropFirst()
        }
        guard let command = VimEngine.resolveExCommand(name) else {
            throw ExError("E492: Not an editor command: \(raw.trimmingCharacters(in: .whitespaces))")
        }
        if let r = range {
            // Line 0 is only meaningful as "before the first line" for :put.
            let lowest = command == "put" ? -1 : 0
            if min(r.start, r.end) < lowest || max(r.start, r.end) > exLastLine {
                throw ExError("E16: Invalid range")
            }
        }
        let args = String(s).trimmingCharacters(in: .whitespaces)
        let rawArgs = String(s)
        try execute(command, bang: bang, range: range, args: args, rawArgs: rawArgs)
    }

    /// The command's line span: the range, else the cursor line, extended by a
    /// trailing count (`:d 3` deletes three lines from the range's end).
    private func lineRange(_ range: (start: Int, end: Int, addresses: Int)?, count: Int?) throws -> (Int, Int) {
        var a = range?.start ?? exCursor.line
        var b = range?.end ?? exCursor.line
        if a > b { swap(&a, &b) }
        if let n = count {
            guard n > 0 else { throw ExError("E939: Positive count required") }
            a = b
            b = min(exLastLine, b + n - 1)
        }
        return (max(0, a), min(exLastLine, b))
    }

    /// Split "x 3" style arguments into an optional register and a count.
    private func registerAndCount(_ args: String) -> (Character?, Int?) {
        var rest = Substring(args)
        var reg: Character?
        if let c = rest.first, !c.isNumber, VimEngine.isValidRegister(c) {
            reg = c
            rest = rest.dropFirst().drop { $0 == " " }
        }
        return (reg, Int(rest.trimmingCharacters(in: .whitespaces)))
    }

    private func execute(_ command: String, bang: Bool, range: (start: Int, end: Int, addresses: Int)?,
                         args: String, rawArgs: String) throws {
        switch command {
        // Files.
        case "write":
            if args.hasPrefix("!") { throw ExError("E: Shell commands aren't supported") }
            try write(range: range, path: args, force: bang)
        case "update":
            if exState.isDirty { try write(range: nil, path: "", force: bang) }
        case "wq", "xit", "exit":
            if command == "wq" || exState.isDirty || !args.isEmpty {
                try write(range: range, path: args, force: bang)
            }
            if let error = host?.vimQuit(force: bang) { throw ExError(error) }
        case "wall":
            if host?.vimSaveAll() == false { throw ExError("E141: Some files could not be written") }
        case "wqall", "xall":
            if host?.vimSaveAll() == false { throw ExError("E141: Some files could not be written") }
            if let error = host?.vimQuitAll(force: bang) { throw ExError(error) }
        case "quit":
            if let error = host?.vimQuit(force: bang) { throw ExError(error) }
        case "qall", "quitall":
            if let error = host?.vimQuitAll(force: bang) { throw ExError(error) }
        case "edit", "tabedit", "tabnew", "find", "open":
            if args.isEmpty {
                if command == "edit" {
                    if let error = host?.vimEdit(path: nil, force: bang) { throw ExError(error) }
                } else {
                    host?.vimOpenQuickSwitcher()
                }
                return
            }
            if let error = host?.vimEdit(path: (args as NSString).expandingTildeInPath, force: bang) {
                throw ExError(error)
            }
        case "enew", "saveas":
            throw ExError("E: :\(command) isn't supported — use :e {file}")
        case "read":
            if args.hasPrefix("!") { throw ExError("E: Shell commands aren't supported") }
            let path = (args as NSString).expandingTildeInPath
            guard !args.isEmpty, let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw ExError("E484: Can't open file \(args)")
            }
            var newLines = sanitizedForEditing(content).components(separatedBy: "\n")
            if newLines.last == "" { newLines.removeLast() }
            let after = range?.end ?? exCursor.line
            exWillEdit()
            exLines.insert(contentsOf: newLines, at: min(after + 1, exLines.count))
            exEnsureTrailingLine()
            exCursor = CursorPosition(line: min(after + 1, exLastLine), column: 0)
        case "file":
            fileInfo()
        case "pwd":
            message(FileManager.default.currentDirectoryPath)

        // Tabs.
        case "bnext", "tabnext":
            if let n = Int(args), command == "tabnext" { host?.vimGoToTab(n - 1) } else { host?.vimSwitchTab(by: Int(args) ?? 1) }
        case "bprevious", "bNext", "tabprevious", "tabNext":
            host?.vimSwitchTab(by: -(Int(args) ?? 1))
        case "bfirst", "tabfirst", "tabrewind":
            host?.vimGoToTab(0)
        case "blast", "tablast":
            host?.vimGoToTab(Int.max)
        case "buffer":
            guard let n = Int(args) ?? range.map({ $0.end + 1 }) else { return }
            host?.vimGoToTab(n - 1)
        case "bdelete", "tabclose":
            if let error = host?.vimQuit(force: bang) { throw ExError(error) }
        case "buffers", "files", "ls":
            let rows = (host?.vimTabList() ?? []).enumerated().map { i, tab in
                ("\(i + 1) \(tab.active ? "%a" : "  ") \(tab.name)", tab.modified ? "+" : "")
            }
            host?.vimShowList(title: "Buffers", rows: rows)

        // Editing.
        case "substitute":
            try substitute(range: range, args: rawArgs.trimmingCharacters(in: .init(charactersIn: " ")))
        case "global", "vglobal":
            try global(range: range, invert: bang || command == "vglobal", args: rawArgs.trimmingCharacters(in: .whitespaces))
        case "delete", "yank":
            let (reg, count) = registerAndCount(args)
            let (a, b) = try lineRange(range, count: count)
            let r = OpRange(start: CursorPosition(line: a, column: 0), end: CursorPosition(line: b, column: 0), linewise: true)
            exState.beginUndoGroup()
            applyOperator(command == "delete" ? .delete : .yank, range: r, register: reg, count: 1)
            exState.endUndoGroup()
        case "put":
            let reg: Character? = args.first
            let line = range?.end ?? exCursor.line
            guard let r = register(reg) else { throw ExError("E353: Nothing in register \(reg.map(String.init) ?? "\"")") }
            let block = r.text.components(separatedBy: "\n")
            exWillEdit()
            let at = (bang || line < 0) ? max(0, line) : min(line + 1, exLines.count)
            exLines.insert(contentsOf: block, at: at)
            exEnsureTrailingLine()
            let lastPut = at + block.count - 1
            exCursor = CursorPosition(line: lastPut, column: exFirstNonBlank(lastPut))
        case "copy", "t", "move":
            var dest = Substring(args)
            guard let target = try parseAddress(&dest) else { throw ExError("E14: Invalid address") }
            let (a, b) = try lineRange(range, count: nil)
            guard target >= -1, target <= exLastLine else { throw ExError("E16: Invalid range") }
            let block = Array(exLines[a...b])
            exWillEdit()
            if command == "move" {
                guard target < a || target >= b else {
                    if target >= a && target < b { throw ExError("E134: Cannot move a range of lines into itself") }
                    return
                }
                exLines.removeSubrange(a...b)
                let insertAt = target < a ? target + 1 : target + 1 - block.count
                exLines.insert(contentsOf: block, at: insertAt)
                exCursor = CursorPosition(line: insertAt + block.count - 1, column: exFirstNonBlank(insertAt + block.count - 1))
            } else {
                exLines.insert(contentsOf: block, at: target + 1)
                exCursor = CursorPosition(line: target + block.count, column: exFirstNonBlank(target + block.count))
            }
            exEnsureTrailingLine()
        case "join":
            let count = Int(args)
            var (a, b) = try lineRange(range, count: nil)
            if let n = count { b = min(exLastLine, b + n - 1) } else if a == b { b = min(exLastLine, a + 1) }
            exState.beginUndoGroup()
            join(from: a, count: max(2, b - a + 1), spaces: !bang)
            exState.endUndoGroup()
        case "normal":
            var keysText = rawArgs
            if keysText.first == " " { keysText.removeFirst() }
            let keys = VimKey.parse(terminal: keysText)
            guard !keys.isEmpty else { return }
            exState.beginUndoGroup()
            if let r = range {
                var targets = Array(min(r.start, r.end)...max(r.start, r.end))
                var idx = 0
                while idx < targets.count {
                    let l = targets[idx]
                    guard l <= exLastLine else { break }
                    let before = exLines.count
                    exCursor = CursorPosition(line: l, column: 0)
                    exNormal(keys)
                    let delta = exLines.count - before
                    for j in (idx + 1)..<max(idx + 1, targets.count) { targets[j] += delta }
                    idx += 1
                }
            } else {
                exNormal(keys)
            }
            exState.endUndoGroup()
        case "undo":
            exState.undo()
        case "redo":
            exState.redo()
        case "retab":
            try retab(range: range, bang: bang, args: args)
        case "sort":
            try sort(range: range, reverse: bang, options: args)
        case "startinsert":
            exStartInsert(append: bang)

        // Marks, registers, info.
        case "k", "mark":
            guard let m = args.first, args.count == 1 else { throw ExError("E471: Argument required") }
            let line = range?.end ?? exCursor.line
            setMark(m, at: CursorPosition(line: line, column: 0))
        case "marks":
            let rows = exMarksList.map { (name, p) in
                ("\(name)", "line \(p.line + 1), col \(p.column)")
            }
            host?.vimShowList(title: "Marks", rows: rows)
        case "registers", "display":
            var rows: [(String, String)] = []
            let order: [Character] = Array("\"0123456789-abcdefghijklmnopqrstuvwxyz.:/%")
            for name in order where args.isEmpty || args.contains(name) {
                guard let r = register(name) else { continue }
                let shown = (r.keys.map { $0.map(\.notation).joined() } ?? r.text)
                    .replacingOccurrences(of: "\n", with: "^J")
                rows.append(("\"\(name)", String(shown.prefix(60)) + (r.linewise ? " ⏎" : "")))
            }
            host?.vimShowList(title: "Registers", rows: rows)
        case "jumps":
            let rows = exJumpList.enumerated().map { i, p in ("\(i + 1)", "line \(p.line + 1), col \(p.column)") }
            host?.vimShowList(title: "Jumps", rows: rows)
        case "messages":
            host?.vimShowList(title: "Messages", rows: messages.map { ($0, "") })
        case "version":
            message("\(AppInfo.name) \(AppInfo.version) — Vim mode")
        case "echo":
            message(args.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
        case "print", "number":
            try printLines(range, numbered: command == "number")
        case "nohlsearch":
            break

        // Mappings.
        case "map", "nmap", "vmap", "xmap", "omap", "imap", "cmap",
             "noremap", "nnoremap", "vnoremap", "xnoremap", "onoremap", "inoremap", "cnoremap":
            try defineMapping(command, bang: bang, args: rawArgs)
        case "unmap", "nunmap", "vunmap", "xunmap", "ounmap", "iunmap", "cunmap":
            try removeMapping(command, bang: bang, args: args)
        case "mapclear", "nmapclear", "vmapclear", "imapclear":
            for m in VimEngine.mapModes(command.hasPrefix("map") ? "map" : String(command.prefix(1)) + "map", bang: bang) {
                mappings[m] = nil
            }

        // Settings and UI.
        case "set", "setlocal", "setglobal":
            try setOptions(args)
        case "config":
            host?.vimOpenConfig()
        case "help":
            host?.vimOpenHelp()

        default:
            throw ExError("E492: Not an editor command: \(command)")
        }
    }

    // MARK: - Mappings

    /// Mode letters a `:map`-family command applies to (`:map` = n v o,
    /// `:map!` = i c, `:xmap` is treated as `:vmap`).
    static func mapModes(_ command: String, bang: Bool) -> [Character] {
        let base = command.replacingOccurrences(of: "noremap", with: "map").replacingOccurrences(of: "unmap", with: "map")
        switch base {
        case "map": return bang ? ["i", "c"] : ["n", "v", "o"]
        case "nmap": return ["n"]
        case "vmap", "xmap": return ["v"]
        case "omap": return ["o"]
        case "imap": return ["i"]
        case "cmap": return ["c"]
        default: return []
        }
    }

    /// Mapping notation: `<Esc>`, `<CR>`, `<C-x>`, `<Leader>` (backslash).
    private static func mapKeys(_ notation: String) -> [VimKey] {
        let expanded = notation.replacingOccurrences(of: "<leader>", with: "\\", options: .caseInsensitive)
        return VimKey.parse(notation: expanded)
    }

    private func defineMapping(_ command: String, bang: Bool, args: String) throws {
        var rest = Substring(args).drop { $0 == " " }
        // Modifiers that don't change anything here.
        while let r = rest.range(of: "^<(silent|buffer|nowait|unique|special|expr|script)>\\s*",
                                 options: [.regularExpression, .caseInsensitive]) {
            if rest[r].lowercased().hasPrefix("<expr>") { throw ExError("E: <expr> mappings aren't supported") }
            rest = rest[r.upperBound...]
        }
        let modes = VimEngine.mapModes(command, bang: bang)
        let lhsText = String(rest.prefix { $0 != " " })
        let rhsText = String(rest.dropFirst(lhsText.count).drop { $0 == " " })
        if lhsText.isEmpty || rhsText.isEmpty {
            // List mappings (optionally those starting with lhs).
            var rows: [(String, String)] = []
            for m in modes {
                for mapping in mappings[m] ?? [] {
                    let lhs = mapping.lhs.map(\.notation).joined()
                    guard lhsText.isEmpty || lhs.hasPrefix(lhsText) else { continue }
                    rows.append(("\(m)  \(lhs)", (mapping.recursive ? "" : "* ") + mapping.rhs.map(\.notation).joined()))
                }
            }
            host?.vimShowList(title: "Mappings", rows: rows)
            return
        }
        let lhs = VimEngine.mapKeys(lhsText)
        let rhs = VimEngine.mapKeys(rhsText)
        let mapping = Mapping(lhs: lhs, rhs: rhs, recursive: !command.contains("noremap"))
        for m in modes {
            var table = mappings[m] ?? []
            table.removeAll { $0.lhs == lhs }
            table.append(mapping)
            mappings[m] = table
        }
    }

    private func removeMapping(_ command: String, bang: Bool, args: String) throws {
        let lhs = VimEngine.mapKeys(args)
        var found = false
        for m in VimEngine.mapModes(command, bang: bang) {
            let before = mappings[m]?.count ?? 0
            mappings[m]?.removeAll { $0.lhs == lhs }
            if (mappings[m]?.count ?? 0) != before { found = true }
        }
        if !found { throw ExError("E31: No such mapping") }
    }

    // MARK: - Writing

    private func write(range: (start: Int, end: Int, addresses: Int)?, path: String, force: Bool) throws {
        if path.isEmpty {
            if range != nil, range!.start != 0 || range!.end != exLastLine {
                throw ExError("E140: Use ! to write partial buffer")
            }
            if exState.fileChangedExternally && !force {
                throw ExError("W10: The file has been changed since reading it (add ! to override)")
            }
            guard host?.vimSave() == true else { throw ExError("E212: Can't open file for writing") }
            let n = VimText.lastContentLine(exLines) + 1
            message("\"\((exState.filePath as NSString).lastPathComponent)\" \(n)L written")
            return
        }
        let target = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: target) && !force {
            throw ExError("E13: File exists (add ! to override)")
        }
        let (a, b) = range.map { ($0.start, $0.end) } ?? (0, exLastLine)
        var out = Array(exLines[a...b])
        out.append("")
        do {
            try exState.write(lines: out, toPath: target)
        } catch {
            throw ExError("E212: Can't open file for writing: \(path)")
        }
        message("\"\(path)\" \(b - a + 1)L written")
    }

    // MARK: - Substitute

    private func substitute(range: (start: Int, end: Int, addresses: Int)?, args: String) throws {
        guard let delimiter = args.first, !delimiter.isLetter, !delimiter.isNumber,
              delimiter != "\\", delimiter != "\"", delimiter != "|", delimiter != " " else {
            // `:s` / `:s g` repeats the last substitute.
            try substituteRepeat(range: range, flags: args)
            return
        }
        var parts: [String] = [""]
        var chars = Array(args.dropFirst())[...]
        while let c = chars.first, parts.count <= 3 {
            chars = chars.dropFirst()
            if c == "\\", let next = chars.first {
                chars = chars.dropFirst()
                if next == delimiter {
                    parts[parts.count - 1].append(next)
                } else {
                    parts[parts.count - 1].append("\\")
                    parts[parts.count - 1].append(next)
                }
                continue
            }
            if c == delimiter && parts.count < 3 {
                parts.append("")
                continue
            }
            parts[parts.count - 1].append(c)
        }
        var pattern = parts[0]
        var replacement = parts.count > 1 ? parts[1] : ""
        let tail = parts.count > 2 ? parts[2] : ""
        if pattern.isEmpty {
            guard let last = lastSearch?.pattern ?? lastSubstitute?.pattern else {
                throw ExError("E35: No previous regular expression")
            }
            pattern = last
        }
        if replacement == "~" { replacement = lastSubstitute?.replacement ?? "" }
        let flags = String(tail.prefix { !$0.isNumber && $0 != " " })
        let count = Int(tail.dropFirst(flags.count).trimmingCharacters(in: .whitespaces))
        lastSubstitute = (pattern, replacement, flags)
        setLastSearch(pattern, forward: true)
        try performSubstitute(range: range, pattern: pattern, replacement: replacement, flags: flags, count: count)
    }

    private func substituteRepeat(range: (start: Int, end: Int, addresses: Int)?, flags: String,
                                  useLastSearch: Bool = false) throws {
        guard let last = lastSubstitute else { throw ExError("E35: No previous regular expression") }
        var f = flags.trimmingCharacters(in: .whitespaces)
        if f.hasPrefix("&") { f = last.flags + f.dropFirst() }
        let pattern = useLastSearch ? (lastSearch?.pattern ?? last.pattern) : last.pattern
        let countText = f.drop { !$0.isNumber }
        f = String(f.prefix { !$0.isNumber && $0 != " " })
        try performSubstitute(range: range, pattern: pattern, replacement: last.replacement,
                              flags: f, count: Int(countText))
    }

    private func performSubstitute(range: (start: Int, end: Int, addresses: Int)?, pattern: String,
                                   replacement: String, flags: String, count: Int?) throws {
        if flags.contains("c") { throw ExError("E: The c (confirm) flag isn't supported") }
        let global = flags.contains("g")
        let countOnly = flags.contains("n")
        let quiet = flags.contains("e")
        let caseless = flags.contains("i") ? true : (flags.contains("I") ? false : ignoreCase)
        let regex: VimRegex
        do {
            regex = try VimRegex(pattern, ignoreCase: caseless, smartCase: flags.contains("I") ? false : smartCase)
        } catch {
            throw ExError("E486: Invalid pattern: \(pattern)")
        }
        let span = try lineRange(range, count: count)
        var b = span.1
        var substitutions = 0
        var changedLines = 0
        var lastChanged = -1
        var edited = false
        var l = span.0
        while l <= b && l < exLines.count {
            let line = exLines[l]
            var hits = regex.matches(in: line)
            if !global, let first = hits.first { hits = [first] }
            guard !hits.isEmpty else { l += 1; continue }
            substitutions += hits.count
            changedLines += 1
            if countOnly { l += 1; continue }
            let chars = Array(line)
            var out = ""
            var pos = 0
            for h in hits {
                out += String(chars[pos..<h.column])
                out += VimRegex.expandReplacement(replacement, match: h, in: line)
                pos = h.column + h.length
            }
            out += String(chars[min(pos, chars.count)...])
            if !edited {
                exWillEdit()
                edited = true
            }
            let pieces = out.components(separatedBy: "\n")
            exLines.replaceSubrange(l...l, with: pieces)
            lastChanged = l + pieces.count - 1
            b += pieces.count - 1
            l += pieces.count
        }
        if substitutions == 0 {
            if !quiet { throw ExError("E486: Pattern not found: \(pattern)") }
            return
        }
        if countOnly {
            message("\(substitutions) match\(substitutions == 1 ? "" : "es") on \(changedLines) line\(changedLines == 1 ? "" : "s")")
            return
        }
        exEnsureTrailingLine()
        exCursor = CursorPosition(line: lastChanged, column: exFirstNonBlank(lastChanged))
        if changedLines > 2 {
            message("\(substitutions) substitution\(substitutions == 1 ? "" : "s") on \(changedLines) lines")
        }
    }

    // MARK: - Global

    private func global(range: (start: Int, end: Int, addresses: Int)?, invert: Bool, args: String) throws {
        guard let delimiter = args.first, !delimiter.isLetter, delimiter != "\\", delimiter != "\"" else {
            throw ExError("E146: Regular expressions can't be delimited by letters")
        }
        var pattern = ""
        var rest = args.dropFirst()
        while let c = rest.first, c != delimiter {
            if c == "\\", rest.dropFirst().first == delimiter {
                pattern.append(delimiter)
                rest = rest.dropFirst(2)
                continue
            }
            pattern.append(c)
            rest = rest.dropFirst()
        }
        if rest.first == delimiter { rest = rest.dropFirst() }
        var command = String(rest).trimmingCharacters(in: .whitespaces)
        if command.isEmpty { command = "p" }
        if pattern.isEmpty {
            guard let last = lastSearch?.pattern else { throw ExError("E35: No previous regular expression") }
            pattern = last
        }
        setLastSearch(pattern, forward: true)
        guard let regex = compile(pattern) else { return }
        let a = range?.start ?? 0
        let b = range?.end ?? exLastLine
        var targets: [Int] = []
        for l in min(a, b)...min(max(a, b), exLastLine) where (regex.firstMatch(in: exLines[l]) != nil) != invert {
            targets.append(l)
        }
        guard !targets.isEmpty else {
            message(invert ? "E538: Pattern found in every line: \(pattern)" : "E486: Pattern not found: \(pattern)",
                    error: true)
            return
        }
        if command == "p" || command == "print" || command == "#" || command == "nu" || command == "number" {
            let numbered = command != "p" && command != "print"
            host?.vimShowList(title: ":g/\(pattern)/", rows: targets.map {
                (numbered ? "\($0 + 1)  \(exLines[$0])" : exLines[$0], "")
            })
            return
        }
        exState.beginUndoGroup()
        defer { exState.endUndoGroup() }
        var idx = 0
        while idx < targets.count {
            let l = targets[idx]
            guard l >= 0, l <= exLastLine else { idx += 1; continue }
            let before = exLines.count
            exCursor = CursorPosition(line: l, column: 0)
            try runSingleEx(command)
            let delta = exLines.count - before
            if delta != 0 {
                for j in (idx + 1)..<max(idx + 1, targets.count) { targets[j] += delta }
            }
            idx += 1
        }
    }

    // MARK: - Sort, retab, print

    private func sort(range: (start: Int, end: Int, addresses: Int)?, reverse: Bool, options: String) throws {
        let a = range?.start ?? 0
        let b = range?.end ?? exLastLine
        guard a < b else { return }
        if options.contains("/") { throw ExError("E: :sort with a pattern isn't supported") }
        let ignoreCase = options.contains("i")
        let numeric = options.contains("n")
        let unique = options.contains("u")
        var block = Array(exLines[a...b])
        func number(_ s: String) -> Double? {
            guard let r = s.range(of: "-?[0-9]+(\\.[0-9]+)?", options: .regularExpression) else { return nil }
            return Double(s[r])
        }
        block.sort { x, y in
            if numeric {
                // Lines without a number sort first, as in Vim.
                switch (number(x), number(y)) {
                case (nil, nil): return false
                case (nil, _): return true
                case (_, nil): return false
                case let (nx?, ny?): return nx < ny
                }
            }
            return ignoreCase ? x.lowercased() < y.lowercased() : x < y
        }
        if reverse { block.reverse() }
        if unique {
            var seen: [String] = []
            block = block.filter { line in
                let key = ignoreCase ? line.lowercased() : line
                if seen.last == key { return false }
                seen.append(key)
                return true
            }
        }
        exWillEdit()
        exLines.replaceSubrange(a...b, with: block)
        exEnsureTrailingLine()
        exCursor = CursorPosition(line: a, column: 0)
    }

    private func retab(range: (start: Int, end: Int, addresses: Int)?, bang: Bool, args: String) throws {
        let width = Int(args) ?? exState.tabWidth
        guard width > 0 else { throw ExError("E487: Argument must be positive") }
        let a = range?.start ?? 0
        let b = range?.end ?? exLastLine
        let spaces = String(repeating: " ", count: width)
        exWillEdit()
        for l in a...b {
            let line = exLines[l]
            if expandTab {
                exLines[l] = line.replacingOccurrences(of: "\t", with: spaces)
            } else if bang {
                var lead = String(line.prefix { $0 == " " || $0 == "\t" })
                let body = line.dropFirst(lead.count)
                lead = lead.replacingOccurrences(of: spaces, with: "\t")
                exLines[l] = lead + body
            }
        }
        if Int(args) != nil {
            host?.vimChangeConfig { $0.tabWidth = max(Config.tabWidthRange.lowerBound, min(Config.tabWidthRange.upperBound, width)) }
        }
    }

    private func printLines(_ range: (start: Int, end: Int, addresses: Int)?, numbered: Bool) throws {
        let (a, b) = try lineRange(range, count: nil)
        host?.vimShowList(title: "Lines", rows: (a...b).map { (numbered ? "\($0 + 1)  \(exLines[$0])" : exLines[$0], "") })
    }

    // MARK: - Options

    private enum OptionKind { case bool, number, string }

    private static let options: [(name: String, short: String, kind: OptionKind)] = [
        ("number", "nu", .bool), ("wrap", "wrap", .bool), ("ignorecase", "ic", .bool),
        ("smartcase", "scs", .bool), ("wrapscan", "ws", .bool), ("hlsearch", "hls", .bool),
        ("incsearch", "is", .bool), ("expandtab", "et", .bool), ("autoindent", "ai", .bool),
        ("relativenumber", "rnu", .bool), ("list", "list", .bool), ("spell", "spell", .bool),
        ("tabstop", "ts", .number), ("shiftwidth", "sw", .number), ("softtabstop", "sts", .number),
        ("scrolloff", "so", .number), ("textwidth", "tw", .number), ("timeoutlen", "tm", .number),
        ("clipboard", "cb", .string),
    ]

    private func setOptions(_ args: String) throws {
        if args.isEmpty || args == "all" {
            let names = VimEngine.options.map(\.name).filter { !["list", "spell"].contains($0) }
            host?.vimShowList(title: "Options", rows: names.map { ($0, optionValue($0)) })
            return
        }
        for token in args.split(separator: " ") {
            try setOption(String(token))
        }
    }

    private func setOption(_ token: String) throws {
        var name = token
        var value: String?
        var query = false
        var boolValue: Bool?
        var invert = false
        if let eq = token.firstIndex(where: { $0 == "=" || $0 == ":" }) {
            name = String(token[..<eq])
            value = String(token[token.index(after: eq)...])
        } else if token.hasSuffix("?") {
            name = String(token.dropLast())
            query = true
        } else if token.hasSuffix("!") {
            name = String(token.dropLast())
            invert = true
        } else if token.hasPrefix("no") && VimEngine.lookupOption(String(token.dropFirst(2))) != nil {
            name = String(token.dropFirst(2))
            boolValue = false
        } else if token.hasPrefix("inv") && VimEngine.lookupOption(String(token.dropFirst(3))) != nil {
            name = String(token.dropFirst(3))
            invert = true
        }
        guard let option = VimEngine.lookupOption(name) else { throw ExError("E518: Unknown option: \(name)") }
        if query || (option.kind != .bool && value == nil) {
            message("  \(option.name)=\(optionValue(option.name))")
            if option.kind == .bool { message("  \(optionValue(option.name) == "on" ? "" : "no")\(option.name)") }
            return
        }
        switch option.kind {
        case .bool:
            guard value == nil else { throw ExError("E474: Invalid argument: \(token)") }
            let currentValue = optionValue(option.name) == "on"
            let new = invert ? !currentValue : (boolValue ?? true)
            try applyBool(option.name, new)
        case .number:
            guard let text = value, let n = Int(text) else { throw ExError("E521: Number required after =: \(token)") }
            try applyNumber(option.name, n)
        case .string:
            let v = value ?? ""
            guard option.name == "clipboard" else { return }
            guard v.isEmpty || v == "unnamed" || v == "unnamedplus" else { throw ExError("E474: Invalid argument: \(token)") }
            systemClipboard = !v.isEmpty
        }
    }

    private static func lookupOption(_ name: String) -> (name: String, short: String, kind: OptionKind)? {
        options.first { $0.name == name || $0.short == name }
    }

    private func optionValue(_ name: String) -> String {
        func flag(_ b: Bool) -> String { b ? "on" : "off" }
        switch name {
        case "number": return flag(exState.showLineNumbers)
        case "wrap": return flag(exState.wordWrap)
        case "ignorecase": return flag(ignoreCase)
        case "smartcase": return flag(smartCase)
        case "wrapscan": return flag(wrapScan)
        case "hlsearch": return flag(hlSearch)
        case "incsearch": return flag(incSearch)
        case "expandtab": return flag(expandTab)
        case "autoindent": return flag(autoIndent)
        case "relativenumber": return flag(exState.relativeLineNumbers)
        case "list", "spell": return "off"
        case "timeoutlen": return "1000"
        case "tabstop": return "\(exState.tabWidth)"
        case "shiftwidth": return "\(shiftWidth)"
        case "softtabstop": return "0"
        case "scrolloff": return "\(exState.scrollMargin)"
        case "textwidth": return "\(textWidth)"
        case "clipboard": return systemClipboard ? "unnamedplus" : ""
        default: return "?"
        }
    }

    private func applyBool(_ name: String, _ value: Bool) throws {
        switch name {
        case "number": host?.vimChangeConfig { $0.showLineNumbers = value }
        case "wrap": host?.vimChangeConfig { $0.wordWrap = value }
        case "ignorecase": ignoreCase = value
        case "smartcase": smartCase = value
        case "wrapscan": wrapScan = value
        case "hlsearch": hlSearch = value
        case "incsearch": incSearch = value
        case "expandtab": expandTab = value
        case "autoindent": autoIndent = value
        case "relativenumber": exState.relativeLineNumbers = value
        default:
            if value { throw ExError("E: '\(name)' isn't supported") }
        }
    }

    private func applyNumber(_ name: String, _ value: Int) throws {
        switch name {
        case "tabstop":
            guard Config.tabWidthRange.contains(value) else { throw ExError("E487: Argument must be 1–16") }
            host?.vimChangeConfig { $0.tabWidth = value }
        case "scrolloff":
            guard Config.scrollOffRange.contains(value) else { throw ExError("E487: Argument must be 0–20") }
            host?.vimChangeConfig { $0.scrollOff = value }
        case "shiftwidth":
            guard value >= 0 else { throw ExError("E487: Argument must be positive") }
            shiftWidth = value
        case "textwidth":
            guard value >= 0 else { throw ExError("E487: Argument must be positive") }
            textWidth = value
        case "softtabstop", "timeoutlen":
            break   // accepted for compatibility; no effect
        default:
            break
        }
    }
}

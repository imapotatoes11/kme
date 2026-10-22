import Foundation

enum VimMode: Equatable {
    case normal
    case insert
    case replace
    case visual
    case visualLine
    case commandLine
}

/// Everything the engine needs from the application: the active document,
/// the viewport, and the app-level actions behind Ex commands.
protocol VimHost: AnyObject {
    var vimState: EditorState { get }
    var vimViewportHeight: Int { get }
    func vimMessage(_ text: String, error: Bool)
    func vimShowList(title: String, rows: [(String, String)])
    /// Save the active document; false if writing failed.
    func vimSave() -> Bool
    func vimSaveAll() -> Bool
    /// Close the active tab (quitting with the last one). Returns an error.
    func vimQuit(force: Bool) -> String?
    func vimQuitAll(force: Bool) -> String?
    /// Open `path` in a tab (nil: reload the active file). Returns an error.
    func vimEdit(path: String?, force: Bool) -> String?
    func vimSwitchTab(by delta: Int)
    func vimGoToTab(_ index: Int)
    func vimAlternateFile()
    func vimTabList() -> [(name: String, active: Bool, modified: Bool)]
    func vimOpenConfig()
    func vimOpenHelp()
    func vimOpenQuickSwitcher()
    func vimFollowLink()
    /// Change a persisted editor setting (`:set number`, `:set wrap`, …).
    func vimChangeConfig(_ change: @escaping (inout Config) -> Void)
}

struct VimRegister: Equatable {
    var text: String
    var linewise: Bool
    /// Keystrokes for a recorded macro, kept alongside the text so replaying
    /// `<Esc>O…` can't be misread as a terminal escape sequence.
    var keys: [VimKey]? = nil
}

/// Modal Vim-style editing on top of EditorState. The engine owns only Vim's
/// own state (mode, pending keys, registers, marks, search, repeat, macros);
/// every edit goes through the document and EditorState's undo stack.
///
/// Normal/Visual input is parsed from the pending key buffer on every key:
/// a complete command runs, a prefix waits for more, anything else is
/// dropped — the classic structure that makes counts, registers, operators
/// and `.` compose.
final class VimEngine {
    weak var host: VimHost?

    private(set) var mode: VimMode = .normal
    private var pending: [VimKey] = []

    // Options (`:set`). Editor-backed ones (number, wrap, tabstop, scrolloff)
    // live on EditorState instead.
    var ignoreCase = false
    var smartCase = false
    var systemClipboard = false
    var wrapScan = true
    var incSearch = true
    var hlSearch = false
    var autoIndent = false
    var expandTab = false
    /// 0 means "use the tab width".
    var shiftWidth = 0
    /// Width `gq` formats to; 0 means 79, as in Vim.
    var textWidth = 0

    // Key mappings (`:map` family), per mode letter: n, v, o, i, c.
    struct Mapping: Equatable {
        let lhs: [VimKey]
        let rhs: [VimKey]
        let recursive: Bool
    }
    var mappings: [Character: [Mapping]] = [:]
    /// Typed keys that are a prefix of a mapping, waiting for more (or the
    /// timeout, see `flushPendingMapping`).
    private var mapPending: [VimKey] = []
    private var mapDepth = 0

    // Registers, marks, search.
    var registers: [Character: VimRegister] = [:]
    var lastInsertedText = ""
    var lastExCommand: String?
    private(set) var lastSearch: (pattern: String, forward: Bool)?
    var lastSubstitute: (pattern: String, replacement: String, flags: String)?
    private var lastFind: (char: Character, forward: Bool, till: Bool)?
    private var marks: [String: [Character: CursorPosition]] = [:]
    private var globalMarks: [Character: (path: String, position: CursorPosition)] = [:]
    private var jumps: [CursorPosition] = []
    private var jumpIndex = 0
    /// Positions of recent changes (`g;` / `g,`).
    private var changes: [CursorPosition] = []
    private var changeIndex = 0
    /// Column j/k try to keep (`curswant`); Int.max after `$`.
    private var desiredColumn: Int?

    // Insert session.
    private enum InsertKind { case insert, openBelow, openAbove }
    private var insertKind = InsertKind.insert
    private var insertCount = 1
    private var insertKeys: [VimKey] = []
    private var insertAwaitingRegister = false
    private var insertLiteralNext = false
    private var replacedOriginals: [Character?] = []
    private var lastInsertPosition: CursorPosition?
    /// Ctrl+O from Insert: run one Normal command, then resume inserting.
    private var oneShotNormal = false
    /// Ctrl+N / Ctrl+P keyword completion in progress.
    private struct Completion {
        let start: CursorPosition       // where the completed word begins
        let prefix: String
        let candidates: [String]
        var index: Int                  // -1 = the original prefix
    }
    private var completion: Completion?

    // Visual.
    private var visualAnchor = CursorPosition(line: 0, column: 0)
    private var lastVisual: (anchor: CursorPosition, cursor: CursorPosition, linewise: Bool)?

    // Command line (`:`, `/`, `?`).
    private struct CommandLine {
        var kind: Character
        var text: String
        var origin: CursorPosition
        var fromVisual: Bool
        var pendingOperator: PendingOperator?
        var historyIndex: Int?
        var awaitingRegister = false
    }
    private struct PendingOperator {
        let op: Operator
        let register: Character?
        let count: Int
        let keys: [VimKey]
    }
    private var commandLine: CommandLine?
    private var exHistory: [String] = []
    private var searchHistory: [String] = []

    // Repeat (`.`) and macros.
    private var lastChange: [VimKey] = []
    private var changeRecording: [VimKey]?
    private var dotReplaying = false
    private var replayDepth = 0
    private(set) var recordingRegister: Character?
    private var macroKeys: [VimKey] = []
    private var lastMacroRegister: Character?
    private(set) var messages: [String] = []

    /// The document being edited, refreshed from the host on every key.
    private var current: EditorState!

    init(host: VimHost) {
        self.host = host
    }

    // MARK: - Status

    var modeLabel: String {
        switch mode {
        case .normal: return oneShotNormal ? "(insert)" : "NORMAL"
        case .insert: return "INSERT"
        case .replace: return "REPLACE"
        case .visual: return "VISUAL"
        case .visualLine: return "V-LINE"
        case .commandLine:
            if let line = commandLine, line.fromVisual { return "VISUAL" }
            return "COMMAND"
        }
    }

    /// Keys typed so far for an unfinished command (Vim's `showcmd`).
    var pendingDisplay: String { (pending + mapPending).map(\.notation).joined() }

    /// Keys are being held for a possible mapping; the host should call
    /// `flushPendingMapping` after Vim's 1 s `timeoutlen` if nothing arrives.
    var hasPendingMapping: Bool { !mapPending.isEmpty }

    /// The command line as shown on the status bar (`:wq`, `/foo`), if open.
    var commandLineDisplay: String? {
        guard let line = commandLine else { return nil }
        return "\(line.kind)\(line.text)"
    }

    /// Whether the app may run its own shortcut for `char` right now: only
    /// between commands, never while one is half-typed.
    func allowsAppShortcut(_ char: Character) -> Bool {
        guard pending.isEmpty, commandLine == nil, !insertAwaitingRegister, !insertLiteralNext else { return false }
        let always: Set<Character> = [Key.ctrlS, Key.ctrlQ, Key.ctrlK, Key.ctrlSpace,
                                      Key.ctrlSlash, Key.ctrlRightBracket]
        if always.contains(char) { return true }
        // Ctrl+P is the palette, except in Insert where it completes (Ctrl+N's pair).
        if char == Key.ctrlP { return mode != .insert && mode != .replace }
        // Ctrl+T toggles a task in Normal mode (Insert uses it to indent).
        return char == Key.ctrlT && (mode == .normal || mode == .visual || mode == .visualLine)
    }

    // MARK: - Entry points

    func handle(_ keys: [VimKey]) {
        for key in keys { handle(key) }
    }

    func handle(_ key: VimKey) {
        guard let state = host?.vimState else { return }
        current = state
        if recordingRegister != nil && replayDepth == 0 { macroKeys.append(key) }
        if activeMappings().isEmpty && mapPending.isEmpty {
            dispatch(key)
        } else {
            mapPending.append(key)
            resolveMappings(final: false)
        }
    }

    /// The timeout passed: run the held keys, expanding a mapping that
    /// matches them exactly.
    func flushPendingMapping() {
        guard let state = host?.vimState, !mapPending.isEmpty else { return }
        current = state
        resolveMappings(final: true)
    }

    /// Mappings that apply right now. Normal/Visual maps only start a command
    /// (after a count or register is fine); `o` maps apply after an operator;
    /// arguments (the char after `f`, `r`, `m` …) are never mapped.
    private func activeMappings() -> [Mapping] {
        switch mode {
        case .insert, .replace:
            return insertAwaitingRegister || insertLiteralNext ? [] : mappings["i"] ?? []
        case .commandLine:
            return commandLine?.awaitingRegister == true ? [] : mappings["c"] ?? []
        case .normal, .visual, .visualLine:
            let letter: Character = mode == .normal ? "n" : "v"
            var i = 0
            if pending.first == .char("\""), pending.count >= 2 { i = 2 }
            while i < pending.count, let c = pending[i].character, c.isASCII, c.isNumber { i += 1 }
            if i == pending.count { return mappings[letter] ?? [] }
            if mode == .normal, let (_, length, _) = operatorAt(pending, i), length > 0 {
                var j = i + length
                while j < pending.count, let c = pending[j].character, c.isASCII, c.isNumber { j += 1 }
                if j == pending.count { return mappings["o"] ?? [] }
            }
            return []
        }
    }

    private func resolveMappings(final: Bool) {
        while !mapPending.isEmpty {
            let table = activeMappings()
            let candidates = table.filter { $0.lhs.starts(with: mapPending) }
            if let exact = candidates.first(where: { $0.lhs == mapPending }), candidates.count == 1 || final {
                mapPending = []
                expand(exact)
                continue
            }
            if !candidates.isEmpty && !final { return }   // wait for more keys
            // The longest mapping that is a prefix of what's held, if any.
            if let shorter = table.filter({ mapPending.starts(with: $0.lhs) })
                .max(by: { $0.lhs.count < $1.lhs.count }) {
                let rest = Array(mapPending.dropFirst(shorter.lhs.count))
                mapPending = []
                expand(shorter)
                mapPending = rest + mapPending
                continue
            }
            dispatch(mapPending.removeFirst())
        }
    }

    private func expand(_ mapping: Mapping) {
        guard mapDepth < 50 else { return }   // a mapping that maps to itself
        mapDepth += 1
        for key in mapping.rhs {
            if mapping.recursive && !activeMappings().isEmpty {
                mapPending.append(key)
                resolveMappings(final: false)
            } else {
                dispatch(key)
            }
        }
        if mapping.recursive { resolveMappings(final: true) }
        mapDepth -= 1
    }

    private func dispatch(_ key: VimKey) {
        let isCompletionKey = key == .char(Key.ctrlN) || key == .char(Key.ctrlP)
        if changeRecording != nil && !dotReplaying && (mode == .insert || mode == .replace)
            && !(isCompletionKey && !insertAwaitingRegister && !insertLiteralNext) {
            changeRecording?.append(key)
        }
        adoptMouseSelection()
        switch mode {
        case .normal, .visual, .visualLine:
            handleCommandKey(key)
        case .insert, .replace:
            handleInsertKey(key)
        case .commandLine:
            handleCommandLineKey(key)
        }
    }

    /// Leave whatever mode is active (tab switch, Vim mode turned off).
    func reset() {
        if let state = host?.vimState { current = state }
        if mode == .insert || mode == .replace { current?.endUndoGroup() }
        pending.removeAll()
        mapPending.removeAll()
        completion = nil
        commandLine = nil
        oneShotNormal = false
        insertAwaitingRegister = false
        insertLiteralNext = false
        current?.document.selectionOverride = nil
        mode = .normal
        jumps.removeAll()
        jumpIndex = 0
        if current != nil { clampToNormal() }
    }

    /// A mouse press starts afresh: drop a Visual selection (a drag will make
    /// a new one) and leave a half-typed command.
    func prepareForMouse() {
        guard let state = host?.vimState else { return }
        current = state
        pending.removeAll()
        if mode == .visual || mode == .visualLine { exitVisual() }
    }

    /// A mouse drag made a selection: carry it on as Visual mode, the way
    /// `mouse=a` does. A plain click just moves the cursor.
    private func adoptMouseSelection() {
        guard mode == .normal || mode == .visual || mode == .visualLine else { return }
        let doc = current.document
        guard doc.selectionOverride == nil, let anchor = doc.selectionAnchor else { return }
        if doc.hasSelection {
            let c = doc.cursorPosition
            current.document.selectionAnchor = nil
            visualAnchor = anchor
            if VimText.less(anchor, c) {
                cursor = previousPosition(c)
            }
            mode = .visual
            updateVisual()
        } else {
            current.document.selectionAnchor = nil
        }
        if mode == .normal { clampToNormal() }
    }

    // MARK: - Document access

    private var cursor: CursorPosition {
        get { current.document.cursorPosition }
        set {
            current.document.cursorLine = newValue.line
            current.document.cursorColumn = newValue.column
        }
    }

    private var lines: [String] { current.document.lines }
    /// Vim's last line. The editor keeps a trailing empty line for the file's
    /// final newline; Vim doesn't count that as a line, so neither do we.
    private var lastLineIndex: Int { VimText.lastContentLine(current.document.lines) }
    private func text() -> VimText { VimText(current.document.lines) }
    private func lineLength(_ l: Int) -> Int { current.document.lines[l].count }

    private func clampToNormal() {
        guard !current.document.lines.isEmpty else { return }
        let l = max(0, min(cursor.line, lastLineIndex))
        let c = max(0, min(cursor.column, max(0, lineLength(l) - 1)))
        cursor = CursorPosition(line: l, column: c)
    }

    private func previousPosition(_ p: CursorPosition) -> CursorPosition {
        if p.column > 0 { return CursorPosition(line: p.line, column: p.column - 1) }
        if p.line > 0 { return CursorPosition(line: p.line - 1, column: max(0, lineLength(p.line - 1) - 1)) }
        return p
    }

    /// Record an undo point and mark the document modified before an edit.
    private func willEdit() {
        current.recordUndoSnapshot()
        current.markDirty()
    }

    private func ensureTrailingEmptyLine() {
        current.document.ensureTrailingEmptyLine()
    }

    private var indentUnit: String {
        let width = shiftWidth > 0 ? shiftWidth : current.tabWidth
        return expandTab ? String(repeating: " ", count: width) : "\t"
    }

    func message(_ text: String, error: Bool = false) {
        messages.append(text)
        if messages.count > 100 { messages.removeFirst() }
        host?.vimMessage(text, error: error)
    }

    // MARK: - Command parsing

    enum Operator: Equatable {
        case delete, change, yank, indent, outdent, toggleCase, lowercase, uppercase, rot13
        /// `gq` (cursor to the last formatted line) / `gw` (cursor stays).
        case format(keepCursor: Bool)
    }

    indirect enum Motion: Equatable {
        case left, right, up, down, displayUp, displayDown
        case backspaceLeft, spaceRight
        case lineStart, firstNonBlank, lineEnd, lastNonBlank, column
        case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool), wordEndBackward(big: Bool)
        case find(Character, forward: Bool, till: Bool), repeatFind(reverse: Bool)
        case gotoLine, gotoFirstLine, percent
        case paragraphForward, paragraphBackward, sentenceForward, sentenceBackward
        case searchNext(reverse: Bool), searchWord(forward: Bool, whole: Bool)
        case mark(Character, exact: Bool)
        case screenTop, screenMiddle, screenBottom
        case nextLineStart, previousLineStart, currentLineStart
    }

    private enum Target: Equatable {
        case motion(Motion, count: Int?)
        case object(Character, around: Bool, count: Int?)
        case lines(count: Int?)
        case search(forward: Bool)
    }

    private enum Command: Equatable {
        case motion(Motion)
        case op(Operator, Target)
        case simple(String, Character?)
    }

    private struct Parsed: Equatable {
        var register: Character?
        var count: Int?
        var command: Command
    }

    private enum ParseResult: Equatable {
        case incomplete
        case invalid
        case complete(Parsed)
    }

    private func parse(_ keys: [VimKey], visual: Bool) -> ParseResult {
        var i = 0
        func peek() -> VimKey? { i < keys.count ? keys[i] : nil }
        func readCount() -> Int? {
            var digits = ""
            while let k = peek(), let c = k.character, c.isASCII, c.isNumber, !(digits.isEmpty && c == "0") {
                digits.append(c)
                i += 1
            }
            return digits.isEmpty ? nil : min(Int(digits) ?? 1, 99_999)
        }

        var register: Character?
        if peek() == .char("\"") {
            i += 1
            guard let k = peek() else { return .incomplete }
            guard let r = k.character, VimEngine.isValidRegister(r) else { return .invalid }
            register = r
            i += 1
        }
        let count = readCount()
        if register == nil, peek() == .char("\"") {
            // Count before the register ("3"ayy) is fine too.
            i += 1
            guard let k = peek() else { return .incomplete }
            guard let r = k.character, VimEngine.isValidRegister(r) else { return .invalid }
            register = r
            i += 1
        }
        guard let key = peek() else { return .incomplete }

        func done(_ command: Command) -> ParseResult {
            .complete(Parsed(register: register, count: count, command: command))
        }

        // Operators (in Normal mode; Visual applies them to the selection).
        if !visual, let (op, length, doubled) = operatorAt(keys, i) {
            if length < 0 { return .incomplete }
            i += length
            let count2 = readCount()
            guard let t = peek() else { return .incomplete }
            if doubled.count == 2 && t.character == doubled.last {
                return done(.op(op, .lines(count: count2)))
            }
            if t.character == doubled.first {
                if doubled.count == 1 { return done(.op(op, .lines(count: count2))) }
                i += 1
                guard let t2 = peek() else { return .incomplete }
                if t2.character == doubled.last { return done(.op(op, .lines(count: count2))) }
                return .invalid
            }
            if let c = t.character, c == "i" || c == "a" {
                i += 1
                guard let obj = peek()?.character else { return .incomplete }
                guard VimEngine.isTextObject(obj) else { return .invalid }
                return done(.op(op, .object(obj, around: c == "a", count: count2)))
            }
            if t == .char("/") || t == .char("?") {
                return done(.op(op, .search(forward: t == .char("/"))))
            }
            switch parseMotion(keys, &i) {
            case .incomplete: return .incomplete
            case .invalid: return .invalid
            case .motion(let m): return done(.op(op, .motion(m, count: count2)))
            }
        }

        // Visual-mode text objects extend the selection.
        if visual, let c = key.character, c == "i" || c == "a" {
            i += 1
            guard let obj = peek()?.character else { return .incomplete }
            guard VimEngine.isTextObject(obj) else { return .invalid }
            return done(.simple(c == "a" ? "a-object" : "i-object", obj))
        }

        var probe = i
        switch parseMotion(keys, &probe) {
        case .motion(let m): return done(.motion(m))
        case .incomplete: return .incomplete
        case .invalid: break
        }

        guard let c = key.character else {
            switch key {
            case .escape: return done(.simple("<Esc>", nil))
            case .delete: return done(.simple("x", nil))
            case .insert: return done(.simple("i", nil))
            case .pageDown: return done(.simple("^F", nil))
            case .pageUp: return done(.simple("^B", nil))
            default: return .invalid
            }
        }
        i += 1
        func withArg(_ name: String) -> ParseResult {
            guard let a = peek() else { return .incomplete }
            if a == .escape { return .invalid }
            guard let ch = a.character else { return .invalid }
            return done(.simple(name, ch))
        }
        switch c {
        case "r", "m", "@":
            return withArg(String(c))
        case "q":
            if recordingRegister != nil { return done(.simple("q", nil)) }
            return withArg("q")
        case "z", "Z":
            guard let k = peek() else { return .incomplete }
            guard let a = k.character else { return .invalid }
            return done(.simple(String(c) + String(a), nil))
        case "g":
            guard let k = peek() else { return .incomplete }
            guard let a = k.character else { return .invalid }
            return done(.simple("g" + String(a), nil))
        case "\t":
            return done(.simple("\t", nil))
        case "x", "X", "s", "S", "C", "D", "Y", "p", "P", "J", "~", "u", "U", ".", "i", "a", "I", "A",
             "o", "O", "v", "V", "R", ":", "/", "?", "&", "Q", "K", "d", "y", "c", "<", ">", "=", "!":
            return done(.simple(String(c), nil))
        default:
            if let v = c.unicodeScalars.first?.value, v < 32 || v == 127 {
                return done(.simple(VimKey.char(c).notation, nil))
            }
            return .invalid
        }
    }

    /// The operator starting at `keys[i]`: (operator, keys it spans — -1 when
    /// more are needed, the key sequence that repeats it for linewise).
    private func operatorAt(_ keys: [VimKey], _ i: Int) -> (Operator, Int, String)? {
        guard i < keys.count, let c = keys[i].character else { return nil }
        switch c {
        case "d": return (.delete, 1, "d")
        case "c": return (.change, 1, "c")
        case "y": return (.yank, 1, "y")
        case ">": return (.indent, 1, ">")
        case "<": return (.outdent, 1, "<")
        case "g":
            guard i + 1 < keys.count else {
                return nil   // "g" alone: let the motion/command parser ask for more
            }
            switch keys[i + 1].character {
            case "~": return (.toggleCase, 2, "g~")
            case "u": return (.lowercase, 2, "gu")
            case "U": return (.uppercase, 2, "gU")
            case "?": return (.rot13, 2, "g?")
            case "q": return (.format(keepCursor: false), 2, "gq")
            case "w": return (.format(keepCursor: true), 2, "gw")
            default: return nil
            }
        default:
            return nil
        }
    }

    private enum MotionParse { case incomplete, invalid, motion(Motion) }

    private func parseMotion(_ keys: [VimKey], _ i: inout Int) -> MotionParse {
        guard i < keys.count else { return .incomplete }
        let key = keys[i]
        i += 1
        func arg() -> Character? {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return keys[i].character
        }
        switch key {
        case .left: return .motion(.left)
        case .right: return .motion(.right)
        case .up: return .motion(.up)
        case .down: return .motion(.down)
        case .home: return .motion(.lineStart)
        case .end: return .motion(.lineEnd)
        case .escape, .delete, .insert, .pageUp, .pageDown, .shiftTab: return .invalid
        case .char(let c):
            switch c {
            case "h": return .motion(.left)
            case "\u{08}", "\u{7F}": return .motion(.backspaceLeft)
            case "l": return .motion(.right)
            case " ": return .motion(.spaceRight)
            case "j", Key.ctrlJ, Key.ctrlN: return .motion(.down)
            case "k": return .motion(.up)
            case "0": return .motion(.lineStart)
            case "^": return .motion(.firstNonBlank)
            case "$": return .motion(.lineEnd)
            case "|": return .motion(.column)
            case "w": return .motion(.wordForward(big: false))
            case "W": return .motion(.wordForward(big: true))
            case "b": return .motion(.wordBackward(big: false))
            case "B": return .motion(.wordBackward(big: true))
            case "e": return .motion(.wordEnd(big: false))
            case "E": return .motion(.wordEnd(big: true))
            case "G": return .motion(.gotoLine)
            case "H": return .motion(.screenTop)
            case "M": return .motion(.screenMiddle)
            case "L": return .motion(.screenBottom)
            case "%": return .motion(.percent)
            case "(": return .motion(.sentenceBackward)
            case ")": return .motion(.sentenceForward)
            case "{": return .motion(.paragraphBackward)
            case "}": return .motion(.paragraphForward)
            case ";": return .motion(.repeatFind(reverse: false))
            case ",": return .motion(.repeatFind(reverse: true))
            case "n": return .motion(.searchNext(reverse: false))
            case "N": return .motion(.searchNext(reverse: true))
            case "*": return .motion(.searchWord(forward: true, whole: true))
            case "#": return .motion(.searchWord(forward: false, whole: true))
            case "+", "\r": return .motion(.nextLineStart)
            case "-": return .motion(.previousLineStart)
            case "_": return .motion(.currentLineStart)
            case "f", "F", "t", "T":
                guard i < keys.count else { return .incomplete }
                if keys[i] == .escape { return .invalid }
                guard let ch = arg() else { return .invalid }
                return .motion(.find(ch, forward: c == "f" || c == "t", till: c == "t" || c == "T"))
            case "'", "`":
                guard i < keys.count else { return .incomplete }
                guard let ch = arg() else { return .invalid }
                return .motion(.mark(ch, exact: c == "`"))
            case "g":
                guard i < keys.count else { return .incomplete }
                switch keys[i].character {
                case "g": i += 1; return .motion(.gotoFirstLine)
                case "e": i += 1; return .motion(.wordEndBackward(big: false))
                case "E": i += 1; return .motion(.wordEndBackward(big: true))
                case "j": i += 1; return .motion(.displayDown)
                case "k": i += 1; return .motion(.displayUp)
                case "_": i += 1; return .motion(.lastNonBlank)
                case "0": i += 1; return .motion(.lineStart)
                case "$": i += 1; return .motion(.lineEnd)
                case "*": i += 1; return .motion(.searchWord(forward: true, whole: false))
                case "#": i += 1; return .motion(.searchWord(forward: false, whole: false))
                default: return .invalid
                }
            default:
                return .invalid
            }
        }
    }

    static func isValidRegister(_ r: Character) -> Bool {
        r.isASCII && (r.isLetter || r.isNumber) || "\"-_+*.:/%".contains(r)
    }

    static func isTextObject(_ c: Character) -> Bool {
        "wWspbB()[]{}<>\"'`".contains(c)
    }

    // MARK: - Normal / Visual dispatch

    private func handleCommandKey(_ key: VimKey) {
        pending.append(key)
        let visual = mode == .visual || mode == .visualLine
        switch parse(pending, visual: visual) {
        case .incomplete:
            return
        case .invalid:
            pending.removeAll()
        case .complete(let parsed):
            let keys = pending
            pending.removeAll()
            current.beginUndoGroup()
            let wasVisual = visual
            if visual {
                executeVisual(parsed, keys: keys)
            } else {
                executeNormal(parsed, keys: keys)
            }
            if mode != .insert && mode != .replace {
                current.endUndoGroup()
            }
            if oneShotNormal && (mode == .normal) && !wasVisual {
                oneShotNormal = false
                mode = .insert
                return
            }
            if mode == .normal { clampToNormal() }
            if mode == .visual || mode == .visualLine { updateVisual() }
        }
    }

    /// Commands that change text and so can be repeated with `.`.
    private static let changeCommands: Set<String> = [
        "x", "X", "s", "S", "C", "D", "p", "P", "J", "~", "i", "a", "I", "A", "o", "O", "R", "r",
        "gi", "gI", "gp", "gP", "gJ", "^A", "^X", "&", "g&",
    ]

    private func executeNormal(_ p: Parsed, keys: [VimKey]) {
        let count = p.count ?? 1
        switch p.command {
        case .motion(let m):
            moveCursor(m, count: p.count)
        case .op(let op, let target):
            if op != .yank && !dotReplaying { changeRecording = keys }
            if case .search(let forward) = target {
                beginCommandLine(forward ? "/" : "?", pendingOperator: PendingOperator(
                    op: op, register: p.register, count: count, keys: keys))
                return
            }
            guard let range = operatorRange(target, op: op, count: count, countGiven: p.count != nil) else {
                changeRecording = nil
                return
            }
            applyOperator(op, range: range, register: p.register, count: count)
            finishChange()
        case .simple(let name, let arg):
            let isChange = VimEngine.changeCommands.contains(name)
            if isChange && !dotReplaying { changeRecording = keys }
            runSimple(name, arg: arg, count: p.count, register: p.register, keys: keys)
            if isChange { finishChange() }
        }
    }

    /// A change that didn't enter Insert mode is complete: remember it for `.`.
    private func finishChange() {
        guard !dotReplaying, let recorded = changeRecording, mode != .insert, mode != .replace else { return }
        lastChange = recorded
        changeRecording = nil
    }

    // MARK: - Motions

    private struct MotionResult {
        var position: CursorPosition
        var linewise: Bool
        var inclusive: Bool
        var jump: Bool
        /// Leaves the cursor's preferred column (`curswant`) alone (j/k).
        var keepsColumn: Bool = false
    }

    private func moveCursor(_ m: Motion, count: Int?) {
        let from = cursor
        guard let r = evaluate(m, count: count, from: from, forOperator: false) else { return }
        if r.jump { recordJump(from) }
        cursor = r.position
        if !r.keepsColumn {
            desiredColumn = (m == .lineEnd) ? Int.max : r.position.column
        }
    }

    private func evaluate(_ m: Motion, count: Int?, from: CursorPosition, forOperator: Bool) -> MotionResult? {
        let n = count ?? 1
        let t = text()
        let last = t.lastLine
        func result(_ p: CursorPosition, linewise: Bool = false, inclusive: Bool = false, jump: Bool = false) -> MotionResult {
            MotionResult(position: p, linewise: linewise, inclusive: inclusive, jump: jump)
        }
        func lineMove(_ target: Int) -> MotionResult {
            let l = max(0, min(target, last))
            let want = desiredColumn ?? from.column
            let maxCol = forOperator ? t.length(l) : t.lastColumn(l)
            let col = want == Int.max ? t.lastColumn(l) : min(want, maxCol)
            var r = result(CursorPosition(line: l, column: max(0, col)), linewise: true)
            r.keepsColumn = true
            return r
        }
        switch m {
        case .left:
            guard from.column > 0 else { return forOperator ? nil : result(from) }
            return result(CursorPosition(line: from.line, column: max(0, from.column - n)))
        case .right:
            let limit = forOperator ? t.length(from.line) : t.lastColumn(from.line)
            guard from.column < limit else { return forOperator ? nil : result(from) }
            return result(CursorPosition(line: from.line, column: min(limit, from.column + n)))
        case .backspaceLeft:
            var p = from
            for _ in 0..<n {
                if p.column > 0 { p.column -= 1 }
                else if p.line > 0 { p = CursorPosition(line: p.line - 1, column: t.lastColumn(p.line - 1)) }
            }
            return result(p)
        case .spaceRight:
            var p = from
            for _ in 0..<n {
                if p.column < t.lastColumn(p.line) { p.column += 1 }
                else if p.line < last { p = CursorPosition(line: p.line + 1, column: 0) }
            }
            return result(p)
        case .up:
            guard from.line > 0 else { return forOperator ? nil : result(from) }
            return lineMove(from.line - n)
        case .down:
            guard from.line < last else { return forOperator ? nil : result(from) }
            return lineMove(from.line + n)
        case .displayDown, .displayUp:
            for _ in 0..<n {
                if m == .displayDown { current.moveDown() } else { current.moveUp() }
            }
            let p = cursor
            cursor = from
            return result(p)
        case .lineStart:
            return result(CursorPosition(line: from.line, column: 0))
        case .firstNonBlank:
            return result(CursorPosition(line: from.line, column: t.firstNonBlank(from.line)))
        case .currentLineStart:
            let l = min(last, from.line + n - 1)
            return result(CursorPosition(line: l, column: t.firstNonBlank(l)), linewise: true)
        case .lineEnd:
            let l = min(last, from.line + n - 1)
            let col = forOperator ? max(0, t.length(l) - 1) : t.lastColumn(l)
            return result(CursorPosition(line: l, column: col), inclusive: true)
        case .lastNonBlank:
            let l = min(last, from.line + n - 1)
            let chars = t.chars(l)
            var c = chars.count - 1
            while c > 0 && chars[c].isWhitespace { c -= 1 }
            return result(CursorPosition(line: l, column: max(0, c)), inclusive: true)
        case .column:
            return result(CursorPosition(line: from.line, column: min(max(0, n - 1), t.lastColumn(from.line))))
        case .wordForward(let big):
            var p = from
            for step in 0..<n {
                let next = t.wordForward(p, big: big)
                // An operator never carries the last word's motion onto the
                // next line: `dw` on the last word stops at end of line.
                if forOperator && step == n - 1 && next.line > p.line {
                    let lineEnd = CursorPosition(line: p.line, column: t.length(p.line))
                    if t.length(p.line) > 0 && p.column < t.length(p.line) { p = lineEnd; break }
                }
                p = next
            }
            if !forOperator && p.column >= t.length(p.line) && t.length(p.line) > 0 {
                p.column = t.lastColumn(p.line)
            }
            return result(p)
        case .wordBackward(let big):
            var p = from
            for _ in 0..<n { p = t.wordBackward(p, big: big) }
            return result(p)
        case .wordEnd(let big):
            var p = from
            for _ in 0..<n { p = t.wordEnd(p, big: big) }
            return result(p, inclusive: true)
        case .wordEndBackward(let big):
            var p = from
            for _ in 0..<n { p = t.wordEndBackward(p, big: big) }
            return result(p, inclusive: true)
        case .find(let ch, let forward, let till):
            lastFind = (ch, forward, till)
            guard let col = t.find(ch, from: from, forward: forward, till: till, count: n) else { return nil }
            return result(CursorPosition(line: from.line, column: col), inclusive: forward)
        case .repeatFind(let reverse):
            guard let f = lastFind else { return nil }
            let forward = reverse ? !f.forward : f.forward
            guard let col = t.find(f.char, from: from, forward: forward, till: f.till, count: n, repeating: true) else {
                return nil
            }
            return result(CursorPosition(line: from.line, column: col), inclusive: forward)
        case .gotoLine:
            let l = count.map { $0 - 1 } ?? last
            let target = max(0, min(l, last))
            return result(CursorPosition(line: target, column: t.firstNonBlank(target)), linewise: true, jump: true)
        case .gotoFirstLine:
            let target = max(0, min((count ?? 1) - 1, last))
            return result(CursorPosition(line: target, column: t.firstNonBlank(target)), linewise: true, jump: true)
        case .percent:
            if let c = count {
                let target = max(0, min((c * t.lineCount + 99) / 100 - 1, last))
                return result(CursorPosition(line: target, column: t.firstNonBlank(target)), linewise: true, jump: true)
            }
            guard let p = t.matchPair(from) else { return nil }
            return result(p, inclusive: true, jump: true)
        case .paragraphForward:
            return result(t.paragraphForward(from, count: n), jump: true)
        case .paragraphBackward:
            return result(t.paragraphBackward(from, count: n), jump: true)
        case .sentenceForward:
            return result(t.sentenceForward(from, count: n), jump: true)
        case .sentenceBackward:
            return result(t.sentenceBackward(from, count: n), jump: true)
        case .searchNext(let reverse):
            guard let s = lastSearch else {
                message("E35: No previous regular expression", error: true)
                return nil
            }
            let forward = reverse ? !s.forward : s.forward
            guard let p = search(s.pattern, forward: forward, from: from, count: n) else { return nil }
            return result(forOperator ? p : applySearchOffset(p, pattern: s.pattern), jump: true)
        case .searchWord(let forward, let whole):
            guard let word = wordUnderCursor(from) else {
                message("E348: No string under cursor", error: true)
                return nil
            }
            let escaped = VimEngine.escapePattern(word)
            let pattern = whole ? "\\<\(escaped)\\>" : escaped
            lastSearch = (pattern, forward)
            pushSearchHistory(pattern)
            // Start from the word's beginning so `#` skips the current word.
            let start = forward ? from : (t.wordObject(from, big: false, around: false, count: 1)?.start ?? from)
            guard let p = search(pattern, forward: forward, from: start, count: n) else { return nil }
            return result(p, jump: true)
        case .mark(let name, let exact):
            guard let p = markPosition(name) else {
                message("E20: Mark not set", error: true)
                return nil
            }
            let l = min(p.line, last)
            if exact {
                return result(CursorPosition(line: l, column: min(p.column, t.lastColumn(l))), jump: true)
            }
            return result(CursorPosition(line: l, column: t.firstNonBlank(l)), linewise: true, jump: true)
        case .screenTop, .screenMiddle, .screenBottom:
            let height = max(1, host?.vimViewportHeight ?? 24)
            let top = current.lineAtViewportRow(0)
            let bottom = min(last, current.lineAtViewportRow(height - 1))
            let l: Int
            switch m {
            case .screenTop: l = min(bottom, top + n - 1)
            case .screenBottom: l = max(top, bottom - (n - 1))
            default: l = (top + bottom) / 2
            }
            return result(CursorPosition(line: l, column: t.firstNonBlank(l)), linewise: true, jump: true)
        case .nextLineStart:
            guard from.line < last || !forOperator else { return nil }
            let l = min(last, from.line + n)
            return result(CursorPosition(line: l, column: t.firstNonBlank(l)), linewise: true)
        case .previousLineStart:
            guard from.line > 0 || !forOperator else { return nil }
            let l = max(0, from.line - n)
            return result(CursorPosition(line: l, column: t.firstNonBlank(l)), linewise: true)
        }
    }

    private func wordUnderCursor(_ p: CursorPosition) -> String? {
        let chars = text().chars(p.line)
        guard !chars.isEmpty else { return nil }
        // The keyword under or after the cursor, else the non-blank WORD.
        var c = min(p.column, chars.count - 1)
        while c < chars.count && VimText.wordClass(chars[c], big: false) != 2 { c += 1 }
        let big = c >= chars.count
        if big {
            c = min(p.column, chars.count - 1)
            while c < chars.count && chars[c].isWhitespace { c += 1 }
            guard c < chars.count else { return nil }
        }
        let k = VimText.wordClass(chars[c], big: big)
        var s = c
        while s > 0 && VimText.wordClass(chars[s - 1], big: big) == k { s -= 1 }
        var e = c
        while e + 1 < chars.count && VimText.wordClass(chars[e + 1], big: big) == k { e += 1 }
        return String(chars[s...e])
    }

    static func escapePattern(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\/.*$^~[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: - Jumps and marks

    private func recordJump(_ from: CursorPosition) {
        setMark("'", at: from)
        if jumpIndex < jumps.count { jumps.removeSubrange(jumpIndex...) }
        jumps.removeAll { $0.line == from.line }
        jumps.append(from)
        if jumps.count > 100 { jumps.removeFirst() }
        jumpIndex = jumps.count
    }

    private func jumpOlder(_ count: Int) {
        guard !jumps.isEmpty else { return }
        if jumpIndex >= jumps.count {
            let here = cursor
            jumps.removeAll { $0.line == here.line }
            jumps.append(here)
            jumpIndex = jumps.count - 1
        }
        let target = max(0, jumpIndex - count)
        guard target != jumpIndex else { return }
        jumpIndex = target
        cursor = clampPosition(jumps[target])
    }

    private func jumpNewer(_ count: Int) {
        let target = jumpIndex + count
        guard target < jumps.count else { return }
        jumpIndex = target
        cursor = clampPosition(jumps[target])
    }

    private func clampPosition(_ p: CursorPosition) -> CursorPosition {
        let l = max(0, min(p.line, lastLineIndex))
        return CursorPosition(line: l, column: max(0, min(p.column, max(0, lineLength(l) - 1))))
    }

    private var fileKey: String { current.filePath }

    func setMark(_ name: Character, at p: CursorPosition) {
        if name == "." && !(changes.last.map { $0.line == p.line } ?? false) {
            changes.append(p)
            if changes.count > 100 { changes.removeFirst() }
            changeIndex = changes.count
        }
        if name.isUppercase && name.isLetter {
            globalMarks[name] = (current.filePath, p)
        } else {
            marks[fileKey, default: [:]][name == "`" ? "'" : name] = p
        }
    }

    private func markPosition(_ name: Character) -> CursorPosition? {
        switch name {
        case "<", ">":
            guard let last = lastVisual else { return nil }
            let first = VimText.less(last.cursor, last.anchor) ? last.cursor : last.anchor
            let second = VimText.less(last.cursor, last.anchor) ? last.anchor : last.cursor
            let p = name == "<" ? first : second
            return last.linewise ? CursorPosition(line: p.line, column: name == "<" ? 0 : max(0, lineLength(p.line) - 1)) : p
        case "`": return marks[fileKey]?["'"]
        default:
            if name.isUppercase && name.isLetter {
                guard let g = globalMarks[name] else { return nil }
                if g.path != current.filePath {
                    if let error = host?.vimEdit(path: g.path, force: false) {
                        message(error, error: true)
                        return nil
                    }
                    if let state = host?.vimState { current = state }
                }
                return g.position
            }
            return marks[fileKey]?[name]
        }
    }

    var markListForTest: [Character: CursorPosition] { marks[fileKey] ?? [:] }

    // MARK: - Operator ranges

    struct OpRange: Equatable {
        var start: CursorPosition
        /// Exclusive end for charwise ranges; the last line for linewise ones.
        var end: CursorPosition
        var linewise: Bool
    }

    private func operatorRange(_ target: Target, op: Operator, count: Int, countGiven: Bool) -> OpRange? {
        let from = cursor
        let t = text()
        switch target {
        case .lines(let count2):
            let n = count * (count2 ?? 1)
            let end = min(t.lastLine, from.line + n - 1)
            return OpRange(start: CursorPosition(line: from.line, column: 0),
                           end: CursorPosition(line: end, column: 0), linewise: true)
        case .object(let obj, let around, let count2):
            let n = count * (count2 ?? 1)
            guard let r = textObject(obj, around: around, count: n, at: from) else { return nil }
            return OpRange(start: r.start, end: r.end, linewise: r.linewise)
        case .motion(let m, let count2):
            let n: Int? = (count2 == nil && !countGiven) ? nil : count * (count2 ?? 1)
            var motion = m
            // `cw` on a word changes to its end, not across the following blanks.
            if op == .change, case .wordForward(let big) = m {
                let chars = t.chars(from.line)
                if from.column < chars.count && !chars[from.column].isWhitespace {
                    motion = .wordEnd(big: big)
                    if from.column + 1 < chars.count,
                       VimText.wordClass(chars[from.column + 1], big: big) != VimText.wordClass(chars[from.column], big: big),
                       (n ?? 1) == 1 {
                        return OpRange(start: from, end: CursorPosition(line: from.line, column: from.column + 1),
                                       linewise: false)
                    }
                }
            }
            guard let r = evaluate(motion, count: n, from: from, forOperator: true) else { return nil }
            if r.jump { setMark("'", at: from) }
            return rangeFor(motionResult: r, from: from)
        case .search:
            return nil
        }
    }

    private func rangeFor(motionResult r: MotionResult, from: CursorPosition) -> OpRange {
        let t = text()
        if r.linewise {
            let a = min(from.line, r.position.line)
            let b = max(from.line, r.position.line)
            return OpRange(start: CursorPosition(line: a, column: 0), end: CursorPosition(line: b, column: 0), linewise: true)
        }
        var start = from
        var end = r.position
        if VimText.less(end, start) { swap(&start, &end) }
        var inclusive = r.inclusive
        // Exclusive motions ending in column 0 (`d}`, `dw` across lines):
        if !inclusive && end.column == 0 && end.line > start.line {
            if start.column <= t.firstNonBlank(start.line) || t.length(start.line) == 0 {
                return OpRange(start: CursorPosition(line: start.line, column: 0),
                               end: CursorPosition(line: end.line - 1, column: 0), linewise: true)
            }
            end = CursorPosition(line: end.line - 1, column: max(0, t.length(end.line - 1) - 1))
            inclusive = t.length(end.line) > 0
        }
        if inclusive {
            end = CursorPosition(line: end.line, column: min(end.column + 1, t.length(end.line)))
        }
        return OpRange(start: start, end: end, linewise: false)
    }

    private func textObject(_ obj: Character, around: Bool, count: Int, at p: CursorPosition) -> VimText.Range? {
        let t = text()
        switch obj {
        case "w": return t.wordObject(p, big: false, around: around, count: count)
        case "W": return t.wordObject(p, big: true, around: around, count: count)
        case "p": return t.paragraphObject(p, around: around, count: count)
        case "s": return t.sentenceObject(p, around: around)
        case "(", ")", "b": return t.bracketObject(p, open: "(", around: around, count: count)
        case "[", "]": return t.bracketObject(p, open: "[", around: around, count: count)
        case "{", "}", "B": return t.bracketObject(p, open: "{", around: around, count: count)
        case "<", ">": return angleObject(p, around: around)
        case "\"", "'", "`": return t.quoteObject(p, quote: obj, around: around)
        default: return nil
        }
    }

    private func angleObject(_ p: CursorPosition, around: Bool) -> VimText.Range? {
        let chars = text().chars(p.line)
        guard !chars.isEmpty else { return nil }
        var o = min(p.column, chars.count - 1)
        while o >= 0 && chars[o] != "<" { o -= 1 }
        guard o >= 0 else { return nil }
        var c = o + 1
        while c < chars.count && chars[c] != ">" { c += 1 }
        guard c < chars.count, c >= p.column || o == p.column else { return nil }
        return around
            ? VimText.Range(start: CursorPosition(line: p.line, column: o), end: CursorPosition(line: p.line, column: c + 1), linewise: false)
            : VimText.Range(start: CursorPosition(line: p.line, column: o + 1), end: CursorPosition(line: p.line, column: c), linewise: false)
    }

    // MARK: - Applying operators

    func extract(_ r: OpRange) -> String {
        if r.linewise {
            return lines[r.start.line...min(r.end.line, lastLineIndex)].joined(separator: "\n")
        }
        return current.document.textInRange((r.start, r.end))
    }

    func applyOperator(_ op: Operator, range r: OpRange, register: Character?, count: Int) {
        switch op {
        case .yank:
            let text = extract(r)
            store(VimRegister(text: text, linewise: r.linewise), name: register, yank: true)
            setMark("[", at: r.start)
            setMark("]", at: r.linewise ? CursorPosition(line: r.end.line, column: 0) : r.end)
            if r.linewise {
                if cursor.line > r.start.line { cursor = CursorPosition(line: r.start.line, column: cursor.column) }
            } else {
                cursor = r.start
            }
            let n = r.linewise ? r.end.line - r.start.line + 1 : 0
            if n > 2 { message("\(n) lines yanked") }
        case .delete:
            deleteRange(r, register: register)
        case .change:
            changeRange(r, register: register)
        case .indent, .outdent:
            shiftLines(r.start.line...r.end.line, by: op == .indent ? 1 : -1, times: 1)
        case .toggleCase, .lowercase, .uppercase, .rot13:
            transformCase(r, op: op)
        case .format(let keepCursor):
            let before = cursor
            formatLines(r.start.line...min(r.end.line, lastLineIndex))
            if keepCursor { cursor = clampPosition(before) }
        }
    }

    /// `gq`: re-wrap each paragraph in `range` to `textwidth` (79 when 0). A
    /// Markdown list marker or quote bar stays on the first line, and the
    /// continuation lines are indented to match.
    func formatLines(_ range: ClosedRange<Int>) {
        let width = textWidth > 0 ? textWidth : 79
        willEdit()
        var out: [String] = []
        var paragraph: [String] = []
        func flush() {
            guard let first = paragraph.first else { return }
            let indent = leadingWhitespace(first)
            var lead = indent
            let body = first.dropFirst(indent.count)
            if let marker = body.range(of: "^([-*+]( \\[.\\])?|[0-9]+[.)]|>) ", options: .regularExpression) {
                lead += body[marker]
            }
            let hanging = String(repeating: " ", count: lead.count)
            let quote = body.hasPrefix(">") ? indent + "> " : nil
            var words: [String] = []
            for (i, line) in paragraph.enumerated() {
                var text = Substring(line)
                if i == 0 { text = text.dropFirst(lead.count) }
                else if let q = quote, text.hasPrefix(q.trimmingCharacters(in: .whitespaces)) {
                    text = text.drop { $0 == " " || $0 == "\t" }.dropFirst().drop { $0 == " " }
                }
                words += text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
            var line = lead
            var lineHasWord = false
            for word in words {
                if lineHasWord && line.count + 1 + word.count > width {
                    out.append(line)
                    line = (quote ?? hanging) + word
                } else {
                    line += (lineHasWord ? " " : "") + word
                }
                lineHasWord = true
            }
            out.append(line)
            paragraph = []
        }
        for l in range {
            let line = lines[l]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                out.append(line)
            } else if !paragraph.isEmpty, current.listContinuationPrefix(after: line) != nil,
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                // A new list item starts a new paragraph.
                flush()
                paragraph = [line]
            } else {
                paragraph.append(line)
            }
        }
        flush()
        current.document.lines.replaceSubrange(range, with: out)
        ensureTrailingEmptyLine()
        let lastFormatted = range.lowerBound + out.count - 1
        cursor = CursorPosition(line: lastFormatted, column: firstNonBlank(lastFormatted))
    }

    private func deleteRange(_ r: OpRange, register: Character?) {
        let text = extract(r)
        store(VimRegister(text: text, linewise: r.linewise), name: register, yank: false)
        willEdit()
        if r.linewise {
            let endLine = min(r.end.line, lastLineIndex)
            current.document.lines.removeSubrange(r.start.line...endLine)
            if current.document.lines.isEmpty { current.document.lines = [""] }
            ensureTrailingEmptyLine()
            let l = min(r.start.line, lastLineIndex)
            cursor = CursorPosition(line: l, column: firstNonBlank(l))
            let n = endLine - r.start.line + 1
            if n > 2 { message("\(n) fewer lines") }
        } else {
            current.document.clearSelection()
            current.document.replaceRange((r.start, r.end), with: "")
            ensureTrailingEmptyLine()
            cursor = r.start
        }
        setMark(".", at: cursor)
        setMark("[", at: cursor)
        setMark("]", at: cursor)
    }

    private func firstNonBlank(_ l: Int) -> Int { VimText(current.document.lines).firstNonBlank(l) }

    /// Where `I` inserts: the first non-blank, or the end of a blank line.
    private func insertColumnForI(_ l: Int) -> Int {
        lines[l].prefix { $0 == " " || $0 == "\t" }.count
    }

    private func changeRange(_ r: OpRange, register: Character?) {
        let text = extract(r)
        store(VimRegister(text: text, linewise: r.linewise), name: register, yank: false)
        willEdit()
        if r.linewise {
            let endLine = min(r.end.line, lastLineIndex)
            let indent = autoIndent ? leadingWhitespace(lines[r.start.line]) : ""
            current.document.lines.replaceSubrange(r.start.line...endLine, with: [indent])
            ensureTrailingEmptyLine()
            cursor = CursorPosition(line: r.start.line, column: indent.count)
        } else {
            current.document.clearSelection()
            current.document.replaceRange((r.start, r.end), with: "")
            ensureTrailingEmptyLine()
            cursor = r.start
        }
        startInsert(kind: .insert, count: 1, alreadyGrouped: true)
    }

    private func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    func shiftLines(_ range: ClosedRange<Int>, by direction: Int, times: Int) {
        let last = lastLineIndex
        let lo = max(0, range.lowerBound)
        let hi = min(last, range.upperBound)
        guard lo <= hi else { return }
        willEdit()
        let width = shiftWidth > 0 ? shiftWidth : current.tabWidth
        for l in lo...hi {
            var line = lines[l]
            for _ in 0..<max(1, times) {
                if direction > 0 {
                    if !line.isEmpty { line = indentUnit + line }
                } else {
                    if line.hasPrefix("\t") { line.removeFirst() }
                    else {
                        var n = 0
                        while n < width && line.dropFirst(n).first == " " { n += 1 }
                        line.removeFirst(n)
                    }
                }
            }
            current.document.lines[l] = line
        }
        cursor = CursorPosition(line: lo, column: firstNonBlank(lo))
        let n = hi - lo + 1
        if n > 2 { message("\(n) lines \(direction > 0 ? ">" : "<")ed \(max(1, times)) time\(times > 1 ? "s" : "")") }
    }

    private func transformCase(_ r: OpRange, op: Operator) {
        willEdit()
        func convert(_ s: String) -> String {
            switch op {
            case .lowercase: return s.lowercased()
            case .uppercase: return s.uppercased()
            case .rot13:
                return String(s.map { ch -> Character in
                    guard let v = ch.unicodeScalars.first?.value, ch.isASCII, ch.isLetter else { return ch }
                    let base: UInt32 = ch.isUppercase ? 65 : 97
                    return Character(UnicodeScalar((v - base + 13) % 26 + base)!)
                })
            default:
                return String(s.map { ch -> Character in
                    let s = String(ch)
                    return Character(ch.isUppercase ? s.lowercased() : s.uppercased())
                })
            }
        }
        if r.linewise {
            for l in r.start.line...min(r.end.line, lastLineIndex) {
                current.document.lines[l] = convert(lines[l])
            }
            cursor = CursorPosition(line: r.start.line, column: cursor.line == r.start.line ? cursor.column : 0)
        } else {
            let original = extract(r)
            current.document.replaceRange((r.start, r.end), with: convert(original))
            cursor = r.start
        }
    }

    // MARK: - Registers

    /// Store text the way Vim does: yanks fill "0, deletes shift "1–"9 (or "-
    /// for a small delete), a named register (uppercase appends) only gets the
    /// text when asked for, and the unnamed register always follows.
    func store(_ reg: VimRegister, name: Character?, yank: Bool) {
        if name == "_" { return }
        if let n = name, n.isUppercase, n.isLetter {
            let lower = Character(n.lowercased())
            if var existing = registers[lower] {
                if reg.linewise || existing.linewise {
                    existing.text += "\n" + reg.text
                    existing.linewise = true
                } else {
                    existing.text += reg.text
                }
                existing.keys = nil
                registers[lower] = existing
            } else {
                registers[lower] = reg
            }
            registers["\""] = registers[lower]
            return
        }
        if let n = name {
            if n == "+" || n == "*" {
                _ = SystemClipboard.write(reg.text + (reg.linewise ? "\n" : ""))
            } else if n != "\"" {
                registers[n] = reg
            }
        }
        if name == nil || name == "\"" {
            if yank {
                registers["0"] = reg
            } else if reg.linewise || reg.text.contains("\n") {
                for d in stride(from: 9, to: 1, by: -1) {
                    let to = Character(String(d))
                    let from = Character(String(d - 1))
                    if let r = registers[from] { registers[to] = r }
                }
                registers["1"] = reg
            } else {
                registers["-"] = reg
            }
            if systemClipboard {
                _ = SystemClipboard.write(reg.text + (reg.linewise ? "\n" : ""))
            }
        }
        registers["\""] = reg
    }

    func register(_ name: Character?) -> VimRegister? {
        let n = name.map { $0.isUppercase && $0.isLetter ? Character($0.lowercased()) : $0 } ?? "\""
        switch n {
        case "\"":
            if systemClipboard, let text = SystemClipboard.read(), !text.isEmpty {
                return VimEngine.clipboardRegister(text)
            }
            return registers["\""]
        case "+", "*":
            guard let text = SystemClipboard.read(), !text.isEmpty else { return nil }
            return VimEngine.clipboardRegister(text)
        case ".":
            return lastInsertedText.isEmpty ? nil : VimRegister(text: lastInsertedText, linewise: false)
        case ":":
            return lastExCommand.map { VimRegister(text: $0, linewise: false) }
        case "/":
            return lastSearch.map { VimRegister(text: $0.pattern, linewise: false) }
        case "%":
            return VimRegister(text: current.filePath, linewise: false)
        case "_":
            return nil
        default:
            return registers[n]
        }
    }

    private static func clipboardRegister(_ text: String) -> VimRegister {
        let clean = sanitizedForEditing(text)
        if clean.hasSuffix("\n") {
            return VimRegister(text: String(clean.dropLast()), linewise: true)
        }
        return VimRegister(text: clean, linewise: false)
    }

    // MARK: - Put

    func put(after: Bool, register name: Character?, count: Int, cursorAfter: Bool) {
        guard let reg = register(name), !(reg.text.isEmpty && !reg.linewise) else {
            message("E353: Nothing in register \(name.map(String.init) ?? "\"")", error: true)
            return
        }
        willEdit()
        let n = max(1, count)
        if reg.linewise {
            let block = reg.text.components(separatedBy: "\n")
            var inserted: [String] = []
            for _ in 0..<n { inserted += block }
            let at = after ? min(cursor.line + 1, current.document.lines.count) : cursor.line
            current.document.lines.insert(contentsOf: inserted, at: at)
            ensureTrailingEmptyLine()
            if cursorAfter {
                let l = min(at + inserted.count, lastLineIndex)
                cursor = CursorPosition(line: l, column: 0)
            } else {
                cursor = CursorPosition(line: at, column: firstNonBlank(at))
            }
            setMark("[", at: CursorPosition(line: at, column: 0))
            setMark("]", at: CursorPosition(line: at + inserted.count - 1, column: 0))
        } else {
            let pasted = String(repeating: reg.text, count: n)
            let len = lineLength(cursor.line)
            let col = after && len > 0 ? min(cursor.column + 1, len) : min(cursor.column, len)
            let start = CursorPosition(line: cursor.line, column: col)
            current.document.clearSelection()
            current.document.replaceRange((start, start), with: pasted)
            let end = cursor   // replaceRange leaves the cursor after the text
            ensureTrailingEmptyLine()
            if cursorAfter {
                cursor = end
            } else if pasted.contains("\n") {
                cursor = start
            } else {
                cursor = CursorPosition(line: end.line, column: max(0, end.column - 1))
            }
            setMark("[", at: start)
            setMark("]", at: end)
        }
        setMark(".", at: cursor)
    }

    // MARK: - Simple commands

    private func runSimple(_ name: String, arg: Character?, count given: Int?, register: Character?, keys: [VimKey]) {
        let count = given ?? 1
        let t = text()
        switch name {
        case "<Esc>", "^C":
            break
        case "x", "X", "s":
            let len = t.length(cursor.line)
            guard len > 0 else {
                if name == "s" { startInsert(kind: .insert, count: 1, alreadyGrouped: true) }
                return
            }
            if name == "X" {
                guard cursor.column > 0 else { return }
                let start = CursorPosition(line: cursor.line, column: max(0, cursor.column - count))
                deleteRange(OpRange(start: start, end: cursor, linewise: false), register: register)
                return
            }
            let end = CursorPosition(line: cursor.line, column: min(len, cursor.column + count))
            let r = OpRange(start: cursor, end: end, linewise: false)
            if name == "s" { changeRange(r, register: register) } else { deleteRange(r, register: register) }
        case "S":
            changeRange(OpRange(start: CursorPosition(line: cursor.line, column: 0),
                                end: CursorPosition(line: min(lastLineIndex, cursor.line + count - 1), column: 0),
                                linewise: true), register: register)
        case "C", "D":
            let lastL = min(lastLineIndex, cursor.line + count - 1)
            let r = OpRange(start: cursor, end: CursorPosition(line: lastL, column: t.length(lastL)), linewise: false)
            if name == "C" { changeRange(r, register: register) } else {
                deleteRange(r, register: register)
            }
        case "Y":
            applyOperator(.yank, range: OpRange(start: CursorPosition(line: cursor.line, column: 0),
                                                end: CursorPosition(line: min(lastLineIndex, cursor.line + count - 1), column: 0),
                                                linewise: true), register: register, count: count)
        case "p", "P", "gp", "gP":
            put(after: name.hasSuffix("p"), register: register, count: count, cursorAfter: name.hasPrefix("g"))
        case "J", "gJ":
            join(from: cursor.line, count: max(2, count), spaces: name == "J")
        case "~":
            let len = t.length(cursor.line)
            guard len > 0 else { return }
            let end = min(len, cursor.column + count)
            transformCase(OpRange(start: cursor, end: CursorPosition(line: cursor.line, column: end), linewise: false),
                          op: .toggleCase)
            cursor = CursorPosition(line: cursor.line, column: min(end, len - 1))
        case "r":
            guard let ch = arg else { return }
            replaceChars(with: ch, count: count)
        case "u":
            for _ in 0..<count { current.undo() }
        case "^R":
            for _ in 0..<count { current.redo() }
        case "U":
            message("U (undo line) isn't supported — use u", error: true)
        case ".":
            repeatLastChange(count: given)
        case "i", "a", "I", "A", "gi", "gI":
            enterInsert(name, count: count)
        case "o", "O":
            openLine(below: name == "o")
            startInsert(kind: name == "o" ? .openBelow : .openAbove, count: count, alreadyGrouped: true)
        case "R":
            startInsert(kind: .insert, count: count, alreadyGrouped: true)
            mode = .replace
            replacedOriginals = []
        case "v", "V":
            visualAnchor = cursor
            mode = name == "v" ? .visual : .visualLine
            updateVisual()
        case "gv":
            guard let last = lastVisual else { return }
            visualAnchor = clampPosition(last.anchor)
            cursor = clampPosition(last.cursor)
            mode = last.linewise ? .visualLine : .visual
            updateVisual()
        case ":":
            beginCommandLine(":", initial: given.map { $0 > 1 ? ".,.+\($0 - 1)" : "." } ?? "")
        case "/", "?":
            beginCommandLine(Character(name))
        case "&":
            runEx("s")
        case "g&":
            runEx("%s//~/&")
        case "m":
            guard let ch = arg, ch.isLetter || "'`[]<>".contains(ch) else { return }
            setMark(ch, at: cursor)
        case "q":
            if let reg = recordingRegister {
                stopRecording(into: reg)
            } else if let ch = arg, ch.isLetter || ch.isNumber || ch == "\"" {
                recordingRegister = ch
                macroKeys = []
            }
        case "@":
            guard var ch = arg else { return }
            if ch == "@" {
                guard let last = lastMacroRegister else {
                    message("E748: No previously used register", error: true)
                    return
                }
                ch = last
            }
            if ch == ":" {
                lastMacroRegister = ":"
                guard let cmd = lastExCommand else {
                    message("E30: No previous command line", error: true)
                    return
                }
                for _ in 0..<count { runEx(cmd) }
                return
            }
            runMacro(ch, count: count)
        case "^A", "^X":
            increment(by: name == "^A" ? count : -count)
        case "^D", "^U":
            let height = max(1, host?.vimViewportHeight ?? 24)
            let amount = given ?? max(1, height / 2)
            let delta = name == "^D" ? amount : -amount
            current.scrollViewport(lines: delta, viewportHeight: height, viewportWidth: current.viewportWidth)
            let l = max(0, min(lastLineIndex, cursor.line + delta))
            cursor = CursorPosition(line: l, column: firstNonBlank(l))
        case "^F", "^B":
            let height = max(1, host?.vimViewportHeight ?? 24)
            for _ in 0..<count {
                if name == "^F" { current.pageDown(viewportHeight: height) } else { current.pageUp(viewportHeight: height) }
            }
            cursor = CursorPosition(line: cursor.line, column: firstNonBlank(cursor.line))
        case "^E", "^Y":
            let height = max(1, host?.vimViewportHeight ?? 24)
            current.scrollViewport(lines: name == "^E" ? count : -count, viewportHeight: height,
                                   viewportWidth: current.viewportWidth)
        case "zz", "z.", "zt", "z\r", "zb", "z-":
            let height = max(1, host?.vimViewportHeight ?? 24)
            if let n = given {
                let l = max(0, min(lastLineIndex, n - 1))
                cursor = CursorPosition(line: l, column: cursor.column)
            }
            if name == "z." || name == "z\r" || name == "z-" {
                cursor = CursorPosition(line: cursor.line, column: firstNonBlank(cursor.line))
            }
            switch name {
            case "zt", "z\r": current.scrollCursor(to: .top, viewportHeight: height)
            case "zb", "z-": current.scrollCursor(to: .bottom, viewportHeight: height)
            default: current.scrollCursor(to: .center, viewportHeight: height)
            }
        case "ZZ":
            runEx("x")
        case "ZQ":
            runEx("q!")
        case "^G":
            fileInfo()
        case "ga":
            let chars = t.chars(cursor.line)
            guard cursor.column < chars.count else { message("NUL"); return }
            let ch = chars[cursor.column]
            let v = ch.unicodeScalars.first!.value
            message("<\(ch)> \(v), Hex \(String(v, radix: 16)), Oct \(String(v, radix: 8))")
        case "g;", "g,":
            guard !changes.isEmpty else {
                message("E664: Change list is empty", error: true)
                return
            }
            let target = name == "g;" ? changeIndex - count : changeIndex + count
            guard target >= 0, target < changes.count else {
                message(name == "g;" ? "E662: At start of changelist" : "E663: At end of changelist", error: true)
                return
            }
            changeIndex = target
            cursor = clampPosition(changes[target])
        case "^O":
            jumpOlder(count)
        case "\t":
            jumpNewer(count)
        case "^^":
            host?.vimAlternateFile()
        case "gt":
            if let n = given { host?.vimGoToTab(n - 1) } else { host?.vimSwitchTab(by: 1) }
        case "gT":
            host?.vimSwitchTab(by: -count)
        case "gx", "gf":
            host?.vimFollowLink()
        case "^L":
            break
        case "^V":
            message("Visual block mode isn't supported", error: true)
        case "Q", "gQ":
            message("Ex mode isn't supported — use :", error: true)
        case "K":
            message("K (keyword lookup) isn't supported", error: true)
        case "!", "=":
            message("\(name) (filter / reindent) isn't supported", error: true)
        default:
            break
        }
    }

    private func enterInsert(_ name: String, count: Int) {
        let len = lineLength(cursor.line)
        switch name {
        case "a":
            if len > 0 { cursor = CursorPosition(line: cursor.line, column: min(len, cursor.column + 1)) }
        case "A":
            cursor = CursorPosition(line: cursor.line, column: len)
        case "I":
            cursor = CursorPosition(line: cursor.line, column: insertColumnForI(cursor.line))
        case "gI":
            cursor = CursorPosition(line: cursor.line, column: 0)
        case "gi":
            if let p = lastInsertPosition {
                let l = min(p.line, lastLineIndex)
                cursor = CursorPosition(line: l, column: min(p.column, lineLength(l)))
            }
        default:
            break
        }
        startInsert(kind: .insert, count: count, alreadyGrouped: true)
    }

    /// Open a new line below/above the cursor, continuing a list item or quote
    /// marker like Enter does (and the indent, with `autoindent`).
    private func openLine(below: Bool) {
        willEdit()
        let line = lines[cursor.line]
        var prefix = current.listContinuationPrefix(after: line) ?? ""
        if prefix.isEmpty && autoIndent { prefix = leadingWhitespace(line) }
        let at = below ? cursor.line + 1 : cursor.line
        current.document.lines.insert(prefix, at: at)
        ensureTrailingEmptyLine()
        cursor = CursorPosition(line: at, column: prefix.count)
    }

    func join(from line: Int, count: Int, spaces: Bool) {
        let last = lastLineIndex
        guard line < last else { return }
        let joins = min(count - 1, last - line)
        guard joins > 0 else { return }
        willEdit()
        var joinColumn = 0
        for _ in 0..<joins {
            guard line + 1 < current.document.lines.count else { break }
            let cur = current.document.lines[line]
            var next = current.document.lines[line + 1]
            var joined: String
            if spaces {
                next = String(next.drop { $0 == " " || $0 == "\t" })
                if next.isEmpty {
                    joined = cur
                    joinColumn = max(0, cur.count - 1)
                } else if cur.isEmpty || cur.hasSuffix(" ") || cur.hasSuffix("\t") || next.hasPrefix(")") {
                    joined = cur + next
                    joinColumn = cur.count
                } else {
                    joined = cur + " " + next
                    joinColumn = cur.count
                }
            } else {
                joined = cur + next
                joinColumn = cur.count
            }
            current.document.lines[line] = joined
            current.document.lines.remove(at: line + 1)
        }
        ensureTrailingEmptyLine()
        cursor = CursorPosition(line: line, column: joinColumn)
    }

    private func replaceChars(with ch: Character, count: Int) {
        let len = lineLength(cursor.line)
        guard cursor.column + count <= len else { return }
        willEdit()
        let start = cursor
        let end = CursorPosition(line: cursor.line, column: cursor.column + count)
        if ch == "\r" || ch == "\n" {
            current.document.replaceRange((start, end), with: "\n")
            cursor = CursorPosition(line: start.line + 1, column: 0)
            ensureTrailingEmptyLine()
            return
        }
        current.document.replaceRange((start, end), with: String(repeating: String(ch), count: count))
        cursor = CursorPosition(line: start.line, column: end.column - 1)
    }

    /// Ctrl+A / Ctrl+X: add to the number at or after the cursor.
    private func increment(by delta: Int) {
        let chars = Array(lines[cursor.line])
        var i = cursor.column
        // If inside a number, back up to its start.
        while i > 0 && i < chars.count && chars[i].isNumber && chars[i - 1].isNumber { i -= 1 }
        if i < chars.count && !chars[i].isNumber {
            while i < chars.count && !chars[i].isNumber { i += 1 }
        }
        guard i < chars.count, chars[i].isASCII, chars[i].isNumber else { return }
        var start = i
        var end = i
        while end < chars.count && chars[end].isASCII && chars[end].isNumber { end += 1 }
        let negative = start > 0 && chars[start - 1] == "-"
        if negative { start -= 1 }
        guard let value = Int(String(chars[start..<end])) else { return }
        let replacement = String(value + delta)
        willEdit()
        current.document.replaceRange((CursorPosition(line: cursor.line, column: start),
                                       CursorPosition(line: cursor.line, column: end)), with: replacement)
        cursor = CursorPosition(line: cursor.line, column: start + replacement.count - 1)
    }

    func fileInfo() {
        let name = (current.filePath as NSString).lastPathComponent
        let total = max(1, current.document.lines.count)
        let pct = (cursor.line + 1) * 100 / total
        message("\"\(name)\"\(current.isDirty ? " [Modified]" : "") \(total) line\(total == 1 ? "" : "s") --\(pct)%--")
    }

    // MARK: - Repeat and macros

    private func repeatLastChange(count: Int?) {
        guard !lastChange.isEmpty else { return }
        var keys = lastChange
        if let n = count {
            var prefix: [VimKey] = []
            var i = 0
            if keys.first == .char("\""), keys.count > 1 {
                prefix = Array(keys[0...1])
                i = 2
            }
            while i < keys.count, let c = keys[i].character, c.isASCII, c.isNumber { i += 1 }
            keys = prefix + String(n).map { VimKey.char($0) } + Array(keys[i...])
        }
        dotReplaying = true
        replayDepth += 1
        current.beginUndoGroup()
        for key in keys { handle(key) }
        if mode == .insert || mode == .replace { handle(.escape) }
        current.endUndoGroup()
        replayDepth -= 1
        dotReplaying = false
    }

    private func stopRecording(into reg: Character) {
        // Drop the `q` that ended the recording.
        if macroKeys.last == .char("q") { macroKeys.removeLast() }
        let text = macroKeys.map(\.rawText).joined()
        recordingRegister = nil
        if reg.isUppercase, var existing = registers[Character(reg.lowercased())] {
            existing.text += text
            existing.keys = (existing.keys ?? VimKey.parse(terminal: existing.text)) + macroKeys
            registers[Character(reg.lowercased())] = existing
        } else {
            registers[Character(reg.lowercased())] = VimRegister(text: text, linewise: false, keys: macroKeys)
        }
        macroKeys = []
    }

    private func runMacro(_ name: Character, count: Int) {
        guard let reg = register(name) else {
            message("E748: No previously used register", error: true)
            return
        }
        lastMacroRegister = name
        let keys = reg.keys ?? VimKey.parse(terminal: reg.text + (reg.linewise ? "\n" : ""))
        guard replayDepth < 20 else { return }   // a macro calling itself
        replayDepth += 1
        current.beginUndoGroup()
        for _ in 0..<count {
            for key in keys { handle(key) }
        }
        current.endUndoGroup()
        replayDepth -= 1
    }

    // MARK: - Visual mode

    private func visualRange() -> OpRange {
        let a = visualAnchor
        let c = cursor
        let start = VimText.less(c, a) ? c : a
        let end = VimText.less(c, a) ? a : c
        if mode == .visualLine {
            return OpRange(start: CursorPosition(line: start.line, column: 0),
                           end: CursorPosition(line: end.line, column: 0), linewise: true)
        }
        let len = lineLength(end.line)
        let exclusive: CursorPosition
        if end.column < len {
            exclusive = CursorPosition(line: end.line, column: end.column + 1)
        } else if end.line < lastLineIndex {
            exclusive = CursorPosition(line: end.line + 1, column: 0)
        } else {
            exclusive = CursorPosition(line: end.line, column: len)
        }
        return OpRange(start: start, end: exclusive, linewise: false)
    }

    private func updateVisual() {
        guard mode == .visual || mode == .visualLine else { return }
        let r = visualRange()
        current.document.selectionAnchor = nil
        if r.linewise {
            current.document.selectionOverride = (r.start, CursorPosition(line: r.end.line, column: lineLength(r.end.line)))
        } else {
            current.document.selectionOverride = (r.start, r.end)
        }
    }

    private func exitVisual() {
        lastVisual = (visualAnchor, cursor, mode == .visualLine)
        current.document.selectionOverride = nil
        current.document.selectionAnchor = nil
        mode = .normal
    }

    private func executeVisual(_ p: Parsed, keys: [VimKey]) {
        let count = p.count ?? 1
        switch p.command {
        case .motion(let m):
            moveCursor(m, count: p.count)
            if mode == .visual {
                cursor = CursorPosition(line: cursor.line, column: min(cursor.column, lineLength(cursor.line)))
            }
        case .op:
            break   // operators are applied below as simple commands in Visual mode
        case .simple(let name, let arg):
            runVisual(name, arg: arg, count: count, given: p.count, register: p.register, keys: keys)
        }
    }

    private func runVisual(_ name: String, arg: Character?, count: Int, given: Int?, register: Character?, keys: [VimKey]) {
        let r = visualRange()
        let lineSpan = r.end.line - r.start.line + 1
        func recordVisualChange(_ op: [VimKey]) {
            guard !dotReplaying else { return }
            var replay: [VimKey] = [.char(r.linewise ? "V" : "v")]
            if r.linewise {
                if lineSpan > 1 { replay += "\(lineSpan - 1)j".map { VimKey.char($0) } }
            } else if r.start.line == r.end.line {
                let len = r.end.column - r.start.column
                if len > 1 { replay += "\(len - 1)l".map { VimKey.char($0) } }
            } else {
                replay += "\(lineSpan - 1)j0".map { VimKey.char($0) }
                if r.end.column > 1 { replay += "\(r.end.column - 1)l".map { VimKey.char($0) } }
            }
            changeRecording = replay + op
        }
        switch name {
        case "<Esc>", "^C":
            exitVisual()
        case "v", "V":
            let target: VimMode = name == "v" ? .visual : .visualLine
            if mode == target { exitVisual() } else { mode = target }
        case "o", "O":
            let a = visualAnchor
            visualAnchor = cursor
            cursor = a
        case "d", "x", "X", "D":
            recordVisualChange(keys)
            var range = r
            if name == "X" || name == "D" { range = linewiseVersion(r) }
            exitVisual()
            deleteRange(range, register: register)
            finishChange()
        case "y", "Y":
            let range = name == "Y" ? linewiseVersion(r) : r
            exitVisual()
            applyOperator(.yank, range: range, register: register, count: 1)
        case "c", "s", "C", "S", "R":
            recordVisualChange(keys)
            var range = r
            if name != "c" && name != "s" { range = linewiseVersion(r) }
            exitVisual()
            changeRange(range, register: register)
        case "r":
            guard let ch = arg else { return }
            recordVisualChange(keys)
            exitVisual()
            willEdit()
            if r.linewise {
                for l in r.start.line...r.end.line {
                    current.document.lines[l] = String(repeating: String(ch), count: lineLength(l))
                }
            } else {
                let original = extract(r)
                let replaced = String(original.map { $0 == "\n" ? $0 : ch })
                current.document.replaceRange((r.start, r.end), with: replaced)
            }
            cursor = r.start
            finishChange()
        case "J", "gJ":
            recordVisualChange(keys)
            exitVisual()
            join(from: r.start.line, count: max(2, lineSpan), spaces: name == "J")
            finishChange()
        case "~", "u", "U", "g~", "gu", "gU", "g?":
            recordVisualChange(keys)
            exitVisual()
            let op: Operator = (name == "u" || name == "gu") ? .lowercase
                : (name == "U" || name == "gU") ? .uppercase
                : name == "g?" ? .rot13 : .toggleCase
            transformCase(r, op: op)
            cursor = r.start
            finishChange()
        case ">", "<":
            recordVisualChange(keys)
            exitVisual()
            shiftLines(r.start.line...r.end.line, by: name == ">" ? 1 : -1, times: count)
            finishChange()
        case "gq", "gw":
            recordVisualChange(keys)
            let before = cursor
            exitVisual()
            formatLines(r.start.line...r.end.line)
            if name == "gw" { cursor = clampPosition(before) }
            finishChange()
        case "p", "P":
            recordVisualChange(keys)
            exitVisual()
            replaceSelection(r, register: register, count: count, keepRegister: name == "P")
            finishChange()
        case "I", "A":
            exitVisual()
            if name == "I" {
                cursor = r.linewise ? CursorPosition(line: r.start.line, column: firstNonBlank(r.start.line)) : r.start
            } else {
                let endLine = r.linewise ? r.end.line : r.end.line
                cursor = r.linewise ? CursorPosition(line: endLine, column: lineLength(endLine))
                    : (r.end.column == 0 && r.end.line > r.start.line
                        ? CursorPosition(line: r.end.line - 1, column: lineLength(r.end.line - 1)) : r.end)
            }
            startInsert(kind: .insert, count: 1, alreadyGrouped: true)
        case ":":
            lastVisual = (visualAnchor, cursor, mode == .visualLine)
            beginCommandLine(":", initial: "'<,'>", fromVisual: true)
        case "gv":
            guard let last = lastVisual else { return }
            let mine = (visualAnchor, cursor, mode == .visualLine)
            visualAnchor = clampPosition(last.anchor)
            cursor = clampPosition(last.cursor)
            mode = last.linewise ? .visualLine : .visual
            lastVisual = mine
        case "i-object", "a-object":
            guard let obj = arg, let o = textObject(obj, around: name == "a-object", count: count, at: cursor) else { return }
            if o.linewise {
                mode = .visualLine
                visualAnchor = o.start
                cursor = CursorPosition(line: o.end.line, column: 0)
            } else {
                visualAnchor = o.start
                cursor = previousPosition(o.end)
                if o.end.column == 0 && o.end.line > o.start.line {
                    cursor = CursorPosition(line: o.end.line - 1, column: lineLength(o.end.line - 1))
                }
            }
        case "/", "?":
            beginCommandLine(Character(name), fromVisual: true)
        case "m":
            if let ch = arg { setMark(ch, at: cursor) }
        case "\"":
            break
        default:
            // Commands with no Visual meaning act on the cursor as in Normal.
            if name == "^D" || name == "^U" || name == "^F" || name == "^B" || name == "^E" || name == "^Y"
                || name.hasPrefix("z") {
                runSimple(name, arg: arg, count: given, register: register, keys: keys)
            }
        }
    }

    private func linewiseVersion(_ r: OpRange) -> OpRange {
        if r.linewise { return r }
        let endLine = (r.end.column == 0 && r.end.line > r.start.line) ? r.end.line - 1 : r.end.line
        return OpRange(start: CursorPosition(line: r.start.line, column: 0),
                       end: CursorPosition(line: endLine, column: 0), linewise: true)
    }

    /// Visual `p`: replace the selection with a register. The replaced text
    /// goes to the unnamed register (except with `P`).
    private func replaceSelection(_ r: OpRange, register name: Character?, count: Int, keepRegister: Bool) {
        guard let reg = register(name) else {
            message("E353: Nothing in register \(name.map(String.init) ?? "\"")", error: true)
            return
        }
        let removed = VimRegister(text: extract(r), linewise: r.linewise)
        willEdit()
        let pasted = Array(repeating: reg.text, count: max(1, count)).joined(separator: reg.linewise ? "\n" : "")
        if r.linewise {
            let newLines = pasted.components(separatedBy: "\n")
            current.document.lines.replaceSubrange(r.start.line...min(r.end.line, lastLineIndex), with: newLines)
            ensureTrailingEmptyLine()
            cursor = CursorPosition(line: r.start.line, column: firstNonBlank(r.start.line))
        } else {
            let text = reg.linewise ? "\n" + pasted + "\n" : pasted
            current.document.replaceRange((r.start, r.end), with: text)
            ensureTrailingEmptyLine()
            cursor = reg.linewise ? CursorPosition(line: r.start.line + 1, column: 0) : previousPosition(cursor)
        }
        if !keepRegister { store(removed, name: nil, yank: false) }
    }

    // MARK: - Insert and Replace modes

    private func startInsert(kind: InsertKind, count: Int, alreadyGrouped: Bool) {
        if !alreadyGrouped { current.beginUndoGroup() }
        insertKind = kind
        insertCount = max(1, count)
        insertKeys = []
        replacedOriginals = []
        mode = .insert
        current.document.clearSelection()
    }

    private func handleInsertKey(_ key: VimKey) {
        if insertAwaitingRegister {
            insertAwaitingRegister = false
            if let c = key.character, let reg = register(c) {
                let text = reg.linewise ? reg.text + "\n" : reg.text
                insertKeys.append(contentsOf: text.map { VimKey.char($0 == "\n" ? "\r" : $0) })
                current.insertAtCursor(text)
            }
            return
        }
        if insertLiteralNext {
            insertLiteralNext = false
            if let c = key.character {
                insertKeys.append(.char(c))
                current.document.insertCharacter(c)
                current.markDirty()
            }
            return
        }
        switch key {
        case .escape, .char(Key.ctrlC):
            finishInsert()
            return
        case .char(Key.ctrlO):
            oneShotNormal = true
            mode = .normal
            return
        case .char(Key.ctrlR):
            insertAwaitingRegister = true
            return
        case .char(Key.ctrlV):
            insertLiteralNext = true
            return
        case .char(Key.ctrlN), .char(Key.ctrlP):
            complete(forward: key == .char(Key.ctrlN))
            return
        default:
            completion = nil
        }
        insertKeys.append(key)
        applyInsertKey(key)
    }

    /// Ctrl+N / Ctrl+P: complete the word before the cursor from the words in
    /// the document (nearest after the cursor first). Pressing again cycles,
    /// back to what was typed; any other key keeps the current choice.
    private func complete(forward: Bool) {
        if completion == nil {
            let chars = Array(lines[cursor.line])
            var s = min(cursor.column, chars.count)
            while s > 0 && VimText.wordClass(chars[s - 1], big: false) == 2 { s -= 1 }
            let prefix = String(chars[s..<min(cursor.column, chars.count)])
            var seen = Set<String>([prefix])
            var found: [String] = []
            let all = current.document.lines
            let order = Array(cursor.line..<all.count) + Array(0..<cursor.line)
            for l in order {
                var word = ""
                for ch in all[l] + " " {
                    if VimText.wordClass(ch, big: false) == 2 {
                        word.append(ch)
                    } else {
                        if word.count > prefix.count, word.hasPrefix(prefix), seen.insert(word).inserted {
                            found.append(word)
                        }
                        word = ""
                    }
                }
            }
            guard !found.isEmpty else {
                message("Pattern not found", error: true)
                return
            }
            completion = Completion(start: CursorPosition(line: cursor.line, column: s), prefix: prefix,
                                    candidates: found, index: -1)
        }
        guard var c = completion else { return }
        let total = c.candidates.count + 1   // including the original prefix
        c.index = ((c.index + 1 + (forward ? 1 : -1)) % total + total) % total - 1
        let previous = Array(lines[c.start.line])[c.start.column..<cursor.column]
        let word = c.index >= 0 ? c.candidates[c.index] : c.prefix
        willEdit()
        current.document.replaceRange((c.start, cursor), with: word)
        completion = c
        // Record the result as plain typing, so `.` and counts repeat the
        // same text rather than re-running the completion.
        let typed = Array(repeating: VimKey.backspace, count: max(0, previous.count - c.prefix.count))
            + word.dropFirst(c.prefix.count).map { VimKey.char($0) }
        insertKeys += typed
        if changeRecording != nil && !dotReplaying { changeRecording! += typed }
    }

    /// The effect of one key in Insert/Replace mode (shared by typing and by
    /// replaying an insert for a count or `.`).
    private func applyInsertKey(_ key: VimKey) {
        switch key {
        case .char("\r"), .char(Key.ctrlJ):
            current.handleNewline()
        case .char(Key.backspace), .char(Key.ctrlH):
            if mode == .replace, let original = replacedOriginals.popLast() {
                guard cursor.column > 0 else { return }
                cursor = CursorPosition(line: cursor.line, column: cursor.column - 1)
                let at = cursor
                let end = CursorPosition(line: at.line, column: at.column + 1)
                current.document.replaceRange((at, end), with: original.map(String.init) ?? "")
                cursor = at
            } else if mode == .replace {
                if cursor.column > 0 { cursor = CursorPosition(line: cursor.line, column: cursor.column - 1) }
            } else {
                current.handleBackspace()
            }
        case .char(Key.ctrlW):
            current.deleteWordBackward()
        case .char(Key.ctrlU):
            let fnb = firstNonBlank(cursor.line)
            let from = cursor.column > fnb ? fnb : 0
            guard cursor.column > from else { return }
            willEdit()
            current.document.replaceRange((CursorPosition(line: cursor.line, column: from), cursor), with: "")
        case .char(Key.tab):
            current.handleTabKey()
        case .shiftTab:
            current.handleShiftTabKey()
        case .char(Key.ctrlT), .char(Key.ctrlD):
            let before = lineLength(cursor.line)
            let col = cursor.column
            shiftLines(cursor.line...cursor.line, by: key == .char(Key.ctrlT) ? 1 : -1, times: 1)
            let delta = lineLength(cursor.line) - before
            cursor = CursorPosition(line: cursor.line, column: max(0, min(lineLength(cursor.line), col + delta)))
        case .char(Key.ctrlE), .char(Key.ctrlY):
            let source = key == .char(Key.ctrlE) ? cursor.line + 1 : cursor.line - 1
            guard source >= 0, source <= lastLineIndex else { return }
            let chars = Array(lines[source])
            guard cursor.column < chars.count else { return }
            current.handleCharacter(chars[cursor.column])
        case .char(Key.ctrlA):
            current.insertAtCursor(lastInsertedText)
        case .left:
            if cursor.column > 0 { cursor = CursorPosition(line: cursor.line, column: cursor.column - 1) }
        case .right:
            if cursor.column < lineLength(cursor.line) { cursor = CursorPosition(line: cursor.line, column: cursor.column + 1) }
        case .up:
            if cursor.line > 0 {
                cursor = CursorPosition(line: cursor.line - 1, column: min(cursor.column, lineLength(cursor.line - 1)))
            }
        case .down:
            if cursor.line < lastLineIndex {
                cursor = CursorPosition(line: cursor.line + 1, column: min(cursor.column, lineLength(cursor.line + 1)))
            }
        case .home:
            cursor = CursorPosition(line: cursor.line, column: 0)
        case .end:
            cursor = CursorPosition(line: cursor.line, column: lineLength(cursor.line))
        case .delete:
            let len = lineLength(cursor.line)
            if cursor.column < len {
                willEdit()
                current.document.replaceRange((cursor, CursorPosition(line: cursor.line, column: cursor.column + 1)), with: "")
            } else if cursor.line < lastLineIndex {
                let at = cursor
                join(from: cursor.line, count: 2, spaces: false)
                cursor = at
            }
        case .char(let c):
            guard let v = c.unicodeScalars.first?.value, v >= 32, v != 127 else { return }
            if mode == .replace {
                let len = lineLength(cursor.line)
                if cursor.column < len {
                    let chars = Array(lines[cursor.line])
                    replacedOriginals.append(chars[cursor.column])
                    willEdit()
                    let at = cursor
                    current.document.replaceRange((at, CursorPosition(line: at.line, column: at.column + 1)), with: String(c))
                } else {
                    replacedOriginals.append(nil)
                    current.handleCharacter(c)
                }
            } else {
                current.handleCharacter(c)
            }
        default:
            break
        }
    }

    private func finishInsert() {
        let keys = insertKeys
        if insertCount > 1 && (!keys.isEmpty || insertKind != .insert) {
            for _ in 1..<insertCount {
                switch insertKind {
                case .openBelow: openLine(below: true)
                case .openAbove: openLine(below: false)
                case .insert: break
                }
                for k in keys { applyInsertKey(k) }
            }
        }
        lastInsertedText = VimEngine.insertedText(keys)
        lastInsertPosition = cursor
        setMark("^", at: cursor)
        setMark(".", at: cursor)
        insertCount = 1
        insertKeys = []
        replacedOriginals = []
        oneShotNormal = false
        mode = .normal
        current.endUndoGroup()
        if cursor.column > 0 { cursor = CursorPosition(line: cursor.line, column: cursor.column - 1) }
        clampToNormal()
        if !dotReplaying, let recorded = changeRecording {
            lastChange = recorded
            changeRecording = nil
        }
    }

    /// What an insert session typed, for the `.` register and Ctrl+A.
    static func insertedText(_ keys: [VimKey]) -> String {
        var out = ""
        for k in keys {
            switch k {
            case .char("\r"), .char(Key.ctrlJ): out.append("\n")
            case .char(Key.backspace), .char(Key.ctrlH): if !out.isEmpty { out.removeLast() }
            case .char(let c):
                if let v = c.unicodeScalars.first?.value, v >= 32 || c == "\t" { out.append(c) }
            default: break
            }
        }
        return out
    }

    // MARK: - Command line

    private func beginCommandLine(_ kind: Character, initial: String = "", fromVisual: Bool = false,
                                  pendingOperator: PendingOperator? = nil) {
        commandLine = CommandLine(kind: kind, text: initial, origin: cursor, fromVisual: fromVisual,
                                  pendingOperator: pendingOperator, historyIndex: nil)
        if fromVisual {
            lastVisual = (visualAnchor, cursor, mode == .visualLine)
        }
        mode = .commandLine
    }

    private func endCommandLine(cancelled: Bool) {
        guard let line = commandLine else { return }
        commandLine = nil
        if line.fromVisual && line.kind != ":" && cancelled, let last = lastVisual {
            // `/` from Visual: back to the selection.
            mode = last.linewise ? .visualLine : .visual
            visualAnchor = last.anchor
            cursor = line.origin
            updateVisual()
            return
        }
        if line.fromVisual {
            current.document.selectionOverride = nil
        }
        mode = .normal
        if cancelled {
            cursor = line.origin
            if line.pendingOperator != nil { changeRecording = nil }
        }
    }

    private func handleCommandLineKey(_ key: VimKey) {
        guard var line = commandLine else { mode = .normal; return }
        if line.awaitingRegister {
            line.awaitingRegister = false
            if key == .char(Key.ctrlW) {
                line.text += wordUnderCursor(line.origin) ?? ""
            } else if let c = key.character, let reg = register(c) {
                line.text += reg.text.replacingOccurrences(of: "\n", with: "\r")
            }
            commandLine = line
            return
        }
        switch key {
        case .escape, .char(Key.ctrlC):
            endCommandLine(cancelled: true)
            clampToNormal()
            return
        case .char("\r"), .char("\n"):
            executeCommandLine(line)
            return
        case .char(Key.backspace), .char(Key.ctrlH):
            if line.text.isEmpty {
                endCommandLine(cancelled: true)
                clampToNormal()
                return
            }
            line.text.removeLast()
        case .char(Key.ctrlU):
            line.text = ""
        case .char(Key.ctrlW):
            var t = line.text
            while t.last == " " { t.removeLast() }
            while let l = t.last, VimText.wordClass(l, big: false) == 2 { t.removeLast() }
            if t == line.text, !t.isEmpty { t.removeLast() }
            line.text = t
        case .char(Key.ctrlR):
            line.awaitingRegister = true
        case .up, .down:
            let history = line.kind == ":" ? exHistory : searchHistory
            guard !history.isEmpty else { break }
            var idx = line.historyIndex ?? history.count
            idx += key == .up ? -1 : 1
            if idx < 0 { idx = 0 }
            if idx >= history.count {
                line.historyIndex = nil
                line.text = ""
            } else {
                line.historyIndex = idx
                line.text = history[idx]
            }
        case .char(let c):
            guard let v = c.unicodeScalars.first?.value, v >= 32 || c == "\t", v != 127 else { break }
            line.text.append(c)
        default:
            break
        }
        commandLine = line
        if line.kind != ":" && incSearch { previewSearch(line) }
    }

    private func previewSearch(_ line: CommandLine) {
        guard !line.text.isEmpty else { cursor = line.origin; return }
        if let p = findMatch(VimEngine.stripSearchDelimiter(line.text, line.kind), forward: line.kind == "/",
                             from: line.origin, quiet: true) {
            cursor = p
        } else {
            cursor = line.origin
        }
    }

    static func stripSearchDelimiter(_ text: String, _ kind: Character) -> String {
        guard text.last == kind else { return text }
        var backslashes = 0
        var i = text.index(before: text.endIndex)
        while i > text.startIndex {
            i = text.index(before: i)
            if text[i] == "\\" { backslashes += 1 } else { break }
        }
        return backslashes % 2 == 0 ? String(text.dropLast()) : text
    }

    private func executeCommandLine(_ line: CommandLine) {
        let text = line.text
        commandLine = nil
        if line.kind == ":" {
            if line.fromVisual {
                current.document.selectionOverride = nil
            }
            mode = .normal
            cursor = line.origin
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                exHistory.removeAll { $0 == text }
                exHistory.append(text)
                lastExCommand = text
            }
            runEx(text)
            if mode == .normal { clampToNormal() }
            return
        }
        // Search.
        let forward = line.kind == "/"
        let (rawPattern, offset) = VimEngine.splitSearchOffset(text, line.kind)
        var pattern = rawPattern
        if pattern.isEmpty {
            guard let last = lastSearch else {
                message("E35: No previous regular expression", error: true)
                endAfterSearch(line)
                return
            }
            pattern = last.pattern
        }
        lastSearch = (pattern, forward)
        lastSearchOffset = offset
        pushSearchHistory(pattern)
        let count = line.pendingOperator?.count ?? 1
        guard let target = search(pattern, forward: forward, from: line.origin, count: count) else {
            cursor = line.origin
            endAfterSearch(line)
            return
        }
        if let pending = line.pendingOperator {
            mode = .normal
            cursor = line.origin
            let r = rangeFor(motionResult: MotionResult(position: target, linewise: false, inclusive: false, jump: true),
                             from: line.origin)
            current.beginUndoGroup()
            applyOperator(pending.op, range: r, register: pending.register, count: 1)
            if mode != .insert { current.endUndoGroup() }
            if !dotReplaying && pending.op != .yank {
                changeRecording = pending.keys + Array(text).map { VimKey.char($0) } + [.enter]
                finishChange()
            }
            if mode == .normal { clampToNormal() }
            return
        }
        if line.fromVisual, let last = lastVisual {
            mode = last.linewise ? .visualLine : .visual
            visualAnchor = last.anchor
            cursor = target
            updateVisual()
            return
        }
        mode = .normal
        recordJump(line.origin)
        cursor = applySearchOffset(target, pattern: pattern)
        desiredColumn = cursor.column
    }

    /// The `e`, `s`/`b` or line offset of the last `/` search (`/foo/e+1`).
    var lastSearchOffset: String?

    static func splitSearchOffset(_ text: String, _ kind: Character) -> (String, String?) {
        var pattern = ""
        var chars = Array(text)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            if c == "\\", let n = chars.first {
                pattern.append(c)
                pattern.append(n)
                chars = chars.dropFirst()
                continue
            }
            if c == kind { return (pattern, String(chars)) }
            pattern.append(c)
        }
        return (pattern, nil)
    }

    private func applySearchOffset(_ p: CursorPosition, pattern: String) -> CursorPosition {
        guard let offset = lastSearchOffset, !offset.isEmpty else { return p }
        var kind = offset.first!
        var amountText = Substring(offset)
        if "esb".contains(kind) { amountText = amountText.dropFirst() } else { kind = "l" }
        let amount = amountText.isEmpty ? 0 : (Int(amountText) ?? (amountText == "+" ? 1 : amountText == "-" ? -1 : 0))
        switch kind {
        case "l":
            let l = max(0, min(lastLineIndex, p.line + amount))
            return CursorPosition(line: l, column: firstNonBlank(l))
        case "e":
            let length = (try? VimRegex(pattern, ignoreCase: ignoreCase, smartCase: smartCase))?
                .matches(in: lines[p.line]).first { $0.column == p.column }?.length ?? 1
            return clampPosition(CursorPosition(line: p.line, column: p.column + max(0, length - 1) + amount))
        default:
            return clampPosition(CursorPosition(line: p.line, column: p.column + amount))
        }
    }

    private func endAfterSearch(_ line: CommandLine) {
        if line.fromVisual, let last = lastVisual {
            mode = last.linewise ? .visualLine : .visual
            visualAnchor = last.anchor
            updateVisual()
        } else {
            mode = .normal
            clampToNormal()
        }
    }

    private func pushSearchHistory(_ pattern: String) {
        searchHistory.removeAll { $0 == pattern }
        searchHistory.append(pattern)
    }

    func setLastSearch(_ pattern: String, forward: Bool) {
        lastSearch = (pattern, forward)
        pushSearchHistory(pattern)
    }

    // MARK: - Search

    func compile(_ pattern: String) -> VimRegex? {
        do {
            return try VimRegex(pattern, ignoreCase: ignoreCase, smartCase: smartCase)
        } catch {
            message((error as? LocalizedError)?.errorDescription ?? "E486: Invalid pattern", error: true)
            return nil
        }
    }

    /// The `count`th match of `pattern` from `from`, wrapping when `wrapscan`.
    func search(_ pattern: String, forward: Bool, from: CursorPosition, count: Int) -> CursorPosition? {
        var pos = from
        for _ in 0..<max(1, count) {
            guard let next = findMatch(pattern, forward: forward, from: pos, quiet: false) else { return nil }
            pos = next
        }
        return pos
    }

    private func findMatch(_ pattern: String, forward: Bool, from: CursorPosition, quiet: Bool) -> CursorPosition? {
        guard let regex = quiet ? (try? VimRegex(pattern, ignoreCase: ignoreCase, smartCase: smartCase)) : compile(pattern) else {
            return nil
        }
        let all = current.document.lines
        let count = all.count
        if forward {
            for step in 0...count {
                let l = (from.line + step) % count
                if step == count && l != from.line { break }
                let hits = regex.matches(in: all[l])
                let hit: VimRegex.Match?
                if step == 0 {
                    hit = hits.first { $0.column > from.column }
                } else if step == count {
                    hit = hits.first { $0.column <= from.column }
                } else {
                    hit = hits.first
                }
                if let h = hit {
                    if from.line + step >= count {
                        if !wrapScan { break }
                        if !quiet { message("search hit BOTTOM, continuing at TOP") }
                    }
                    return CursorPosition(line: l, column: h.column)
                }
            }
        } else {
            for step in 0...count {
                let l = ((from.line - step) % count + count) % count
                let hits = regex.matches(in: all[l])
                let hit: VimRegex.Match?
                if step == 0 {
                    hit = hits.last { $0.column < from.column }
                } else if step == count {
                    hit = hits.last { $0.column >= from.column }
                } else {
                    hit = hits.last
                }
                if let h = hit {
                    if from.line - step < 0 {
                        if !wrapScan { break }
                        if !quiet { message("search hit TOP, continuing at BOTTOM") }
                    }
                    return CursorPosition(line: l, column: h.column)
                }
            }
        }
        if !quiet { message("E486: Pattern not found: \(pattern)", error: true) }
        return nil
    }

    // MARK: - Ex bridge

    /// The document lines, for Ex commands.
    var exLines: [String] {
        get { current.document.lines }
        set { current.document.lines = newValue }
    }

    var exCursor: CursorPosition {
        get { cursor }
        set { cursor = newValue }
    }

    var exState: EditorState { current }

    var exVisualMarks: (CursorPosition, CursorPosition)? {
        guard let last = lastVisual else { return nil }
        let a = last.anchor
        let c = last.cursor
        return VimText.less(c, a) ? (c, a) : (a, c)
    }

    func exMark(_ name: Character) -> CursorPosition? { markPosition(name) }

    func exWillEdit() { willEdit() }

    func exEnsureTrailingLine() { ensureTrailingEmptyLine() }

    func exFirstNonBlank(_ line: Int) -> Int { firstNonBlank(line) }

    /// Run Normal-mode keys from `:normal`, finishing any half-typed command
    /// or open Insert mode the way Vim does.
    func exNormal(_ keys: [VimKey]) {
        replayDepth += 1
        for key in keys { handle(key) }
        if mode == .insert || mode == .replace || mode == .commandLine { handle(.escape) }
        if mode == .visual || mode == .visualLine { handle(.escape) }
        pending.removeAll()
        replayDepth -= 1
    }

    func exStartInsert(append: Bool) {
        if append { cursor = CursorPosition(line: cursor.line, column: lineLength(cursor.line)) }
        startInsert(kind: .insert, count: 1, alreadyGrouped: false)
    }

    func exJumpRecorded(from: CursorPosition) { recordJump(from) }

    var exMarksList: [(Character, CursorPosition)] {
        var all: [(Character, CursorPosition)] = (marks[fileKey] ?? [:]).map { ($0.key, $0.value) }
        for (k, v) in globalMarks where v.path == current.filePath { all.append((k, v.position)) }
        return all.sorted { String($0.0) < String($1.0) }
    }

    var exJumpList: [CursorPosition] { jumps }
}

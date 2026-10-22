import Foundation

/// One keypress as the Vim engine sees it. Printable characters, Enter
/// (`\r`), Backspace (DEL), Tab and Ctrl+letters arrive as `.char`; the rest
/// are named so escape sequences never leak into the text.
enum VimKey: Equatable, Hashable {
    case char(Character)
    case escape
    case up, down, left, right
    case home, end, pageUp, pageDown
    case delete, insert
    case shiftTab

    static let enter = VimKey.char("\r")
    static let backspace = VimKey.char("\u{7F}")
    static let tab = VimKey.char("\t")

    static func ctrl(_ letter: Character) -> VimKey {
        let upper = letter.uppercased().unicodeScalars.first!.value
        return .char(Character(UnicodeScalar(upper - 64)!))
    }

    var character: Character? {
        if case .char(let c) = self { return c }
        return nil
    }

    /// The bytes a terminal would send for this key; how macros and the
    /// `.`/`@` registers store keystrokes as text.
    var rawText: String {
        switch self {
        case .char(let c): return String(c)
        case .escape: return "\u{1B}"
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
        case .right: return "\u{1B}[C"
        case .left: return "\u{1B}[D"
        case .home: return "\u{1B}[H"
        case .end: return "\u{1B}[F"
        case .pageUp: return "\u{1B}[5~"
        case .pageDown: return "\u{1B}[6~"
        case .delete: return "\u{1B}[3~"
        case .insert: return "\u{1B}[2~"
        case .shiftTab: return "\u{1B}[Z"
        }
    }

    // MARK: - Terminal input

    /// Split a chunk of terminal input into keys. CSI / SS3 sequences become
    /// named keys (modifiers are ignored: Shift+Up is Up); an ESC followed by
    /// anything else is the Escape key followed by that key, which is what a
    /// fast `<Esc>` + command looks like.
    static func parse(terminal input: String) -> [VimKey] {
        let chars = Array(input)
        var keys: [VimKey] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "\u{1B}" else {
                keys.append(.char(c))
                i += 1
                continue
            }
            guard i + 1 < chars.count else {
                keys.append(.escape)
                i += 1
                continue
            }
            let next = chars[i + 1]
            if next == "[" {
                // CSI: parameter bytes up to the final byte (0x40–0x7E).
                var j = i + 2
                var params = ""
                while j < chars.count, let v = chars[j].unicodeScalars.first?.value, !(0x40...0x7E).contains(v) {
                    params.append(chars[j])
                    j += 1
                }
                guard j < chars.count else { i = chars.count; break }
                if let key = csiKey(final: chars[j], params: params) { keys.append(key) }
                i = j + 1
            } else if next == "O", i + 2 < chars.count {
                switch chars[i + 2] {
                case "A": keys.append(.up)
                case "B": keys.append(.down)
                case "C": keys.append(.right)
                case "D": keys.append(.left)
                case "H": keys.append(.home)
                case "F": keys.append(.end)
                default: break
                }
                i += 3
            } else {
                keys.append(.escape)
                i += 1
            }
        }
        return keys
    }

    private static func csiKey(final: Character, params: String) -> VimKey? {
        switch final {
        case "A": return .up
        case "B": return .down
        case "C": return .right
        case "D": return .left
        case "H": return .home
        case "F": return .end
        case "Z": return .shiftTab
        case "~":
            switch params.split(separator: ";").first.map(String.init) ?? "" {
            case "1", "7": return .home
            case "4", "8": return .end
            case "2": return .insert
            case "3": return .delete
            case "5": return .pageUp
            case "6": return .pageDown
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Key notation

    /// Parse Vim key notation (`ihello<Esc>`, `<C-r>`, `<CR>`, `<lt>`) — used by
    /// tests and readable enough for anything typed into a mapping.
    static func parse(notation: String) -> [VimKey] {
        let chars = Array(notation)
        var keys: [VimKey] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "<", let close = chars[(i + 1)...].firstIndex(of: ">"), close > i + 1,
               let key = named(String(chars[(i + 1)..<close])) {
                keys.append(key)
                i = close + 1
            } else {
                keys.append(.char(chars[i]))
                i += 1
            }
        }
        return keys
    }

    private static func named(_ name: String) -> VimKey? {
        let lower = name.lowercased()
        switch lower {
        case "esc": return .escape
        case "cr", "enter", "return": return .enter
        case "bs": return .backspace
        case "tab": return .tab
        case "s-tab": return .shiftTab
        case "space": return .char(" ")
        case "lt": return .char("<")
        case "bar": return .char("|")
        case "bslash": return .char("\\")
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "del": return .delete
        case "insert": return .insert
        case "nl": return .char("\n")
        default:
            if lower.hasPrefix("c-"), lower.count == 3, let letter = lower.last {
                if letter == "[" { return .escape }
                if letter.isLetter { return .ctrl(letter) }
                if letter == "^" || letter == "6" { return .char("\u{1E}") }
                if letter == "]" { return .char("\u{1D}") }
                if letter == "@" || letter == " " { return .char("\u{00}") }
            }
            return nil
        }
    }

    /// Readable notation for display (`:reg`, status line showcmd).
    var notation: String {
        switch self {
        case .char(let c):
            switch c {
            case "\r": return "<CR>"
            case "\u{7F}": return "<BS>"
            case "\t": return "<Tab>"
            case " ": return " "
            default:
                if let v = c.unicodeScalars.first?.value, v < 32 {
                    return "^" + String(Character(UnicodeScalar(v + 64)!))
                }
                return String(c)
            }
        case .escape: return "<Esc>"
        case .up: return "<Up>"
        case .down: return "<Down>"
        case .left: return "<Left>"
        case .right: return "<Right>"
        case .home: return "<Home>"
        case .end: return "<End>"
        case .pageUp: return "<PageUp>"
        case .pageDown: return "<PageDown>"
        case .delete: return "<Del>"
        case .insert: return "<Insert>"
        case .shiftTab: return "<S-Tab>"
        }
    }
}

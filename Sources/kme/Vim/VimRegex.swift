import Foundation

/// A compiled Vim search pattern. Vim's regex dialect (magic by default: `\(`
/// groups, `\|` alternation, `\<` word starts, `\v` very magic, `\c` case) is
/// translated to ICU syntax for NSRegularExpression. Matching is per line, and
/// every position is a Character offset to match the editor's cursor model.
struct VimRegex {
    let regex: NSRegularExpression

    struct Match: Equatable {
        let column: Int
        let length: Int
        /// Capture groups 0...9 as Character ranges in the line (nil = unset).
        let groups: [Range<Int>?]
    }

    enum CompileError: Error, LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let pattern): return "E486: Invalid pattern: \(pattern)"
            }
        }
    }

    /// `ignoreCase`/`smartCase` are the options; `\c` / `\C` in the pattern win.
    init(_ pattern: String, ignoreCase: Bool, smartCase: Bool) throws {
        var source = pattern
        var caseless = ignoreCase
        if source.contains("\\c") {
            caseless = true
            source = source.replacingOccurrences(of: "\\c", with: "")
        } else if source.contains("\\C") {
            caseless = false
            source = source.replacingOccurrences(of: "\\C", with: "")
        } else if ignoreCase && smartCase && source.contains(where: { $0.isUppercase }) {
            caseless = false
        }
        let translated = VimRegex.translate(source)
        do {
            regex = try NSRegularExpression(pattern: translated, options: caseless ? [.caseInsensitive] : [])
        } catch {
            throw CompileError.invalid(pattern)
        }
    }

    /// All non-overlapping matches in `line`, left to right.
    func matches(in line: String) -> [Match] {
        let ns = line as NSString
        let results = regex.matches(in: line, options: [], range: NSRange(location: 0, length: ns.length))
        guard !results.isEmpty else { return [] }
        let offsets = VimRegex.characterOffsets(line)
        return results.compactMap { result in
            guard let whole = VimRegex.charRange(result.range, offsets) else { return nil }
            var groups: [Range<Int>?] = []
            for g in 0..<min(10, result.numberOfRanges) {
                groups.append(VimRegex.charRange(result.range(at: g), offsets))
            }
            return Match(column: whole.lowerBound, length: whole.count, groups: groups)
        }
    }

    func firstMatch(in line: String) -> Match? { matches(in: line).first }

    /// UTF-16 offset → Character offset for each character boundary.
    private static func characterOffsets(_ line: String) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var utf16 = 0
        var index = 0
        for ch in line {
            map[utf16] = index
            utf16 += ch.utf16.count
            index += 1
        }
        map[utf16] = index
        return map
    }

    private static func charRange(_ range: NSRange, _ offsets: [Int: Int]) -> Range<Int>? {
        guard range.location != NSNotFound,
              let start = offsets[range.location],
              let end = offsets[range.location + range.length] else { return nil }
        return start..<end
    }

    // MARK: - Translation

    private enum Magic { case veryMagic, magic, noMagic, veryNoMagic }

    /// Translate a Vim pattern to ICU regex syntax.
    static func translate(_ pattern: String) -> String {
        let chars = Array(pattern)
        var out = ""
        var magic = Magic.magic
        var i = 0
        // Characters ICU treats specially that Vim (magic) treats literally.
        let icuSpecial: Set<Character> = ["(", ")", "|", "+", "?", "{", "}"]

        func literal(_ c: Character) -> String {
            "\\^$.*+?()[]{}|/".contains(c) ? "\\" + String(c) : String(c)
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let n = chars[i + 1]
                i += 2
                switch n {
                case "v": magic = .veryMagic
                case "m": magic = .magic
                case "M": magic = .noMagic
                case "V": magic = .veryNoMagic
                case "<", ">": out += "\\b"
                case "s", "S", "d", "D", "w", "W", "t", "n": out += "\\" + String(n)
                case "a": out += "[A-Za-z]"
                case "A": out += "[^A-Za-z]"
                case "l": out += "[a-z]"
                case "L": out += "[^a-z]"
                case "u": out += "[A-Z]"
                case "U": out += "[^A-Z]"
                case "x": out += "[0-9A-Fa-f]"
                case "X": out += "[^0-9A-Fa-f]"
                case "o": out += "[0-7]"
                case "h": out += "[A-Za-z_]"
                case "e": out += "\\x{1B}"
                case "r": out += "\\r"
                case "z":
                    // \zs / \ze aren't supported; drop the marker.
                    if i < chars.count { i += 1 }
                case "{" where magic != .veryMagic:
                    // \{n,m} (closed by a plain or escaped '}'), \{-…} lazy.
                    var j = i
                    var body = ""
                    while j < chars.count && chars[j] != "}" {
                        if chars[j] != "\\" { body.append(chars[j]) }
                        j += 1
                    }
                    i = min(chars.count, j + 1)
                    let lazy = body.hasPrefix("-")
                    if lazy { body.removeFirst() }
                    let quantifier: String
                    if body.isEmpty { quantifier = "*" }
                    else if body.hasPrefix(",") { quantifier = "{0\(body)}" }
                    else { quantifier = "{\(body)}" }
                    out += quantifier + (lazy ? "?" : "")
                case "(", ")", "|", "+", "?", "=", "{", "}":
                    if magic == .veryMagic {
                        out += literal(n)
                    } else {
                        out += n == "=" ? "?" : String(n)
                    }
                case ".", "*", "[", "~", "^", "$":
                    if magic == .noMagic || magic == .veryNoMagic {
                        out += n == "~" ? "~" : String(n)   // escaped → special
                    } else {
                        out += literal(n)
                    }
                case "/": out += "/"
                case "\\": out += "\\\\"
                default:
                    out += literal(n)
                }
                continue
            }

            switch magic {
            case .veryNoMagic:
                out += literal(c)
            case .noMagic:
                if c == "^" && out.isEmpty { out += "^" }
                else if c == "$" && i == chars.count - 1 { out += "$" }
                else { out += literal(c) }
            case .magic, .veryMagic:
                if c == "[" {
                    // Copy a character class through, escaping a nested '['.
                    var j = i + 1
                    var cls = "["
                    if j < chars.count && chars[j] == "^" { cls += "^"; j += 1 }
                    if j < chars.count && chars[j] == "]" { cls += "\\]"; j += 1 }
                    while j < chars.count && chars[j] != "]" {
                        if chars[j] == "\\" && j + 1 < chars.count {
                            cls += "\\" + String(chars[j + 1])
                            j += 2
                            continue
                        }
                        cls += chars[j] == "[" ? "\\[" : String(chars[j])
                        j += 1
                    }
                    if j < chars.count {
                        out += cls + "]"
                        i = j + 1
                    } else {
                        out += "\\["          // unterminated: literal '['
                        i += 1
                    }
                    continue
                }
                if magic == .veryMagic {
                    if c == "<" || c == ">" { out += "\\b" }
                    else if c == "=" { out += "?" }
                    else if c == "~" { out += "~" }
                    else { out.append(c) }
                } else if icuSpecial.contains(c) {
                    out += "\\" + String(c)
                } else if c == "~" {
                    out += "~"
                } else {
                    out.append(c)
                }
            }
            i += 1
        }
        return out
    }

    // MARK: - Replacement

    /// Expand a `:s` replacement for one match: `&`/`\0` whole match, `\1`–`\9`
    /// groups, `\r`/`\n` line break, `\t` tab, `\u` `\l` next char case,
    /// `\U` `\L` … `\e`/`\E` case runs, `\&` and `\\` literals.
    static func expandReplacement(_ replacement: String, match: Match, in line: String) -> String {
        let lineChars = Array(line)
        func group(_ n: Int) -> String {
            guard n < match.groups.count, let r = match.groups[n] else { return "" }
            return String(lineChars[r])
        }
        enum CaseRun { case none, upper, lower }
        var run = CaseRun.none
        var oneShot: CaseRun = .none
        var out = ""
        func emit(_ s: String) {
            for ch in s {
                var piece = String(ch)
                if oneShot != .none {
                    piece = oneShot == .upper ? piece.uppercased() : piece.lowercased()
                    oneShot = .none
                } else if run != .none {
                    piece = run == .upper ? piece.uppercased() : piece.lowercased()
                }
                out += piece
            }
        }
        let chars = Array(replacement)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "&" {
                emit(group(0))
                i += 1
                continue
            }
            if c == "\\" && i + 1 < chars.count {
                let n = chars[i + 1]
                i += 2
                switch n {
                case "0"..."9": emit(group(Int(String(n))!))
                case "n", "r": out += "\n"
                case "t": out += "\t"
                case "u": oneShot = .upper
                case "l": oneShot = .lower
                case "U": run = .upper
                case "L": run = .lower
                case "e", "E": run = .none
                case "&": emit("&")
                default: emit(String(n))
                }
                continue
            }
            emit(String(c))
            i += 1
        }
        return out
    }
}

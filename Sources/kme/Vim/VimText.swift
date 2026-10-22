import Foundation

/// Cursor arithmetic behind Vim's motions and text objects, over raw document
/// lines. Pure: it never touches editor state, so each rule can be tested on
/// its own. Columns are Character offsets, like the editor's cursor.
final class VimText {
    private let source: [String]
    private var cache: [Int: [Character]] = [:]

    init(_ lines: [String]) {
        source = lines.isEmpty ? [""] : lines
        lastLine = VimText.lastContentLine(source)
    }

    /// The last line Vim sees. The document's trailing empty line stands for
    /// the file's final newline, not a line of its own.
    static func lastContentLine(_ lines: [String]) -> Int {
        lines.count > 1 && lines.last == "" ? lines.count - 2 : max(0, lines.count - 1)
    }

    var lineCount: Int { lastLine + 1 }
    let lastLine: Int

    func chars(_ line: Int) -> [Character] {
        if let cached = cache[line] { return cached }
        let c = Array(source[max(0, min(line, source.count - 1))])
        cache[line] = c
        return c
    }

    func length(_ line: Int) -> Int { chars(line).count }

    func isEmpty(_ line: Int) -> Bool { source[line].isEmpty }

    /// Word class: 0 blank, 1 punctuation, 2 keyword (letters, digits, `_`).
    /// For WORDs every non-blank is the same class.
    static func wordClass(_ c: Character, big: Bool) -> Int {
        if c.isWhitespace { return 0 }
        if big { return 2 }
        return (c.isLetter || c.isNumber || c == "_") ? 2 : 1
    }

    private func cls(_ c: Character, _ big: Bool) -> Int { VimText.wordClass(c, big: big) }

    func firstNonBlank(_ line: Int) -> Int {
        let c = chars(line)
        var i = 0
        while i < c.count && (c[i] == " " || c[i] == "\t") { i += 1 }
        return i < c.count ? i : max(0, c.count - 1)
    }

    /// Last column a Normal-mode cursor can sit on.
    func lastColumn(_ line: Int) -> Int { max(0, length(line) - 1) }

    // MARK: - Words

    /// `w` / `W`: start of the next word. An empty line counts as a word. At
    /// the end of the buffer returns the position past the last character.
    func wordForward(_ p: CursorPosition, big: Bool) -> CursorPosition {
        var l = p.line
        var c = p.column
        var line = chars(l)
        if c < line.count {
            let k = cls(line[c], big)
            if k != 0 { while c < line.count && cls(line[c], big) == k { c += 1 } }
        }
        while true {
            while c < line.count && cls(line[c], big) == 0 { c += 1 }
            if c < line.count { return CursorPosition(line: l, column: c) }
            if l >= lastLine { return CursorPosition(line: l, column: line.count) }
            l += 1
            c = 0
            line = chars(l)
            if line.isEmpty { return CursorPosition(line: l, column: 0) }
        }
    }

    /// `b` / `B`: start of the current or previous word.
    func wordBackward(_ p: CursorPosition, big: Bool) -> CursorPosition {
        var l = p.line
        var c = min(p.column, length(l))
        var line = chars(l)
        func stepBack() -> Bool {
            if c > 0 { c -= 1; return true }
            if l == 0 { return false }
            l -= 1
            line = chars(l)
            c = line.count            // the end-of-line slot, treated as blank
            return true
        }
        guard stepBack() else { return CursorPosition(line: 0, column: 0) }
        while true {
            if line.isEmpty { return CursorPosition(line: l, column: 0) }
            if c < line.count && cls(line[c], big) != 0 { break }
            guard stepBack() else { return CursorPosition(line: 0, column: 0) }
        }
        let k = cls(line[c], big)
        while c > 0 && cls(line[c - 1], big) == k { c -= 1 }
        return CursorPosition(line: l, column: c)
    }

    /// `e` / `E`: end of the current or next word (empty lines are skipped).
    func wordEnd(_ p: CursorPosition, big: Bool) -> CursorPosition {
        var l = p.line
        var c = p.column
        var line = chars(l)
        func stepForward() -> Bool {
            if c + 1 < line.count { c += 1; return true }
            if l >= lastLine { return false }
            l += 1
            line = chars(l)
            c = 0
            return true
        }
        guard stepForward() else { return p }
        while line.isEmpty || cls(line[c], big) == 0 {
            guard stepForward() else { return CursorPosition(line: l, column: max(0, line.count - 1)) }
        }
        let k = cls(line[c], big)
        while c + 1 < line.count && cls(line[c + 1], big) == k { c += 1 }
        return CursorPosition(line: l, column: c)
    }

    /// `ge` / `gE`: end of the previous word.
    func wordEndBackward(_ p: CursorPosition, big: Bool) -> CursorPosition {
        var l = p.line
        var c = min(p.column, max(0, length(l) - 1))
        var line = chars(l)
        func stepBack() -> Bool {
            if c > 0 { c -= 1; return true }
            if l == 0 { return false }
            l -= 1
            line = chars(l)
            c = max(0, line.count - 1)
            return true
        }
        if c < line.count, cls(line[c], big) != 0 {
            let k = cls(line[c], big)
            while c > 0 && cls(line[c - 1], big) == k { c -= 1 }
        }
        guard stepBack() else { return CursorPosition(line: 0, column: 0) }
        while !line.isEmpty && (c >= line.count || cls(line[c], big) == 0) {
            guard stepBack() else { return CursorPosition(line: 0, column: 0) }
        }
        return CursorPosition(line: l, column: c)
    }

    // MARK: - Characters in a line

    /// `f`/`t` (forward) and `F`/`T` (backward): the column `count` matches
    /// of `target` away, stopping before it for `till`. nil when not found.
    /// `repeating` (`;` / `,` after `t`) skips a target right next to the
    /// cursor, so the repeat doesn't get stuck in front of it.
    func find(_ target: Character, from p: CursorPosition, forward: Bool, till: Bool, count: Int,
              repeating: Bool = false) -> Int? {
        let skip = till && repeating && count == 1
        let line = chars(p.line)
        var c = p.column
        var found = 0
        if forward {
            // `t` repeated with `;` must not get stuck just before its target.
            var i = c + (skip && c + 1 < line.count && line[c + 1] == target ? 2 : 1)
            while i < line.count {
                if line[i] == target {
                    found += 1
                    if found == count { c = i; break }
                }
                i += 1
            }
            guard found == count else { return nil }
            return till ? c - 1 : c
        } else {
            var i = c - (skip && c - 1 >= 0 && c - 1 < line.count && line[c - 1] == target ? 2 : 1)
            while i >= 0 {
                if i < line.count && line[i] == target {
                    found += 1
                    if found == count { c = i; break }
                }
                i -= 1
            }
            guard found == count else { return nil }
            return till ? c + 1 : c
        }
    }

    // MARK: - Paragraphs and sentences

    /// `}`: the next empty line after the current paragraph, or the end.
    func paragraphForward(_ p: CursorPosition, count: Int) -> CursorPosition {
        var l = p.line
        for _ in 0..<max(1, count) {
            while l < lastLine && isEmpty(l) { l += 1 }
            while l < lastLine && !isEmpty(l) { l += 1 }
        }
        if l == lastLine && !isEmpty(l) {
            return CursorPosition(line: l, column: max(0, length(l) - 1))
        }
        return CursorPosition(line: l, column: 0)
    }

    /// `{`: the previous empty line before the current paragraph, or the start.
    func paragraphBackward(_ p: CursorPosition, count: Int) -> CursorPosition {
        var l = p.line
        for _ in 0..<max(1, count) {
            while l > 0 && isEmpty(l) { l -= 1 }
            while l > 0 && !isEmpty(l) { l -= 1 }
        }
        return CursorPosition(line: l, column: 0)
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    private static let sentenceClosers: Set<Character> = [")", "]", "\"", "'"]

    /// Every sentence start in the document, in order. A sentence ends at
    /// `.`, `!` or `?` (plus closing brackets/quotes) followed by a blank or
    /// end of line; empty lines are boundaries of their own.
    func sentenceStarts() -> [CursorPosition] {
        var starts: [CursorPosition] = []
        var expectStart = true
        for l in 0...lastLine {
            let line = chars(l)
            if line.isEmpty {
                starts.append(CursorPosition(line: l, column: 0))
                expectStart = true
                continue
            }
            var i = 0
            while i < line.count {
                let ch = line[i]
                if expectStart && !ch.isWhitespace {
                    starts.append(CursorPosition(line: l, column: i))
                    expectStart = false
                }
                if VimText.sentenceEnders.contains(ch) {
                    var j = i + 1
                    while j < line.count && VimText.sentenceClosers.contains(line[j]) { j += 1 }
                    if j >= line.count || line[j].isWhitespace {
                        expectStart = true
                        i = j
                        continue
                    }
                }
                i += 1
            }
        }
        return starts
    }

    func sentenceForward(_ p: CursorPosition, count: Int) -> CursorPosition {
        let starts = sentenceStarts()
        var pos = p
        for _ in 0..<max(1, count) {
            guard let next = starts.first(where: { VimText.less(pos, $0) }) else {
                return CursorPosition(line: lastLine, column: max(0, length(lastLine) - 1))
            }
            pos = next
        }
        return pos
    }

    func sentenceBackward(_ p: CursorPosition, count: Int) -> CursorPosition {
        let starts = sentenceStarts()
        var pos = p
        for _ in 0..<max(1, count) {
            guard let prev = starts.last(where: { VimText.less($0, pos) }) else {
                return CursorPosition(line: 0, column: 0)
            }
            pos = prev
        }
        return pos
    }

    // MARK: - Brackets

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", ")": "(", "]": "[", "}": "{"]
    private static let openers: Set<Character> = ["(", "[", "{"]

    /// `%`: the bracket matching the first one at or after the cursor on its line.
    func matchPair(_ p: CursorPosition) -> CursorPosition? {
        let line = chars(p.line)
        guard let start = (p.column..<max(p.column, line.count)).first(where: { VimText.pairs[line[$0]] != nil }) else {
            return nil
        }
        return match(CursorPosition(line: p.line, column: start))
    }

    /// The bracket matching the one at `p`, honouring nesting across lines.
    func match(_ p: CursorPosition) -> CursorPosition? {
        let line = chars(p.line)
        guard p.column < line.count, let partner = VimText.pairs[line[p.column]] else { return nil }
        let me = line[p.column]
        let forward = VimText.openers.contains(me)
        var depth = 0
        var l = p.line
        var c = p.column
        while true {
            let cur = chars(l)
            if c >= 0 && c < cur.count {
                if cur[c] == me { depth += 1 }
                else if cur[c] == partner {
                    depth -= 1
                    if depth == 0 { return CursorPosition(line: l, column: c) }
                }
            }
            if forward {
                c += 1
                if c >= cur.count {
                    if l >= lastLine { return nil }
                    l += 1
                    c = 0
                    if length(l) == 0 { c = -1 }
                }
            } else {
                c -= 1
                if c < 0 {
                    if l == 0 { return nil }
                    l -= 1
                    c = length(l) - 1
                }
            }
        }
    }

    /// The `open` bracket enclosing `p` (the cursor itself may sit on either
    /// bracket of the pair), and its match. `count` > 1 widens outwards.
    func enclosingPair(_ p: CursorPosition, open: Character, count: Int) -> (CursorPosition, CursorPosition)? {
        guard let close = VimText.pairs[open] else { return nil }
        var from = p
        let here = chars(p.line)
        var result: (CursorPosition, CursorPosition)?
        for level in 0..<max(1, count) {
            var opener: CursorPosition?
            if level == 0, p.column < here.count, here[p.column] == open {
                opener = p
            } else if level == 0, p.column < here.count, here[p.column] == close {
                opener = match(p)
            } else {
                opener = scanBackForOpener(from, open: open, close: close)
            }
            guard let o = opener, let m = match(o) else { return result }
            result = (o, m)
            // Next level starts just before this opener.
            if o.column > 0 {
                from = CursorPosition(line: o.line, column: o.column - 1)
            } else if o.line > 0 {
                from = CursorPosition(line: o.line - 1, column: max(0, length(o.line - 1) - 1))
            } else {
                return result
            }
            if level + 1 < count, from.column >= 0 {
                // Include `from` itself in the next backward scan.
                from = CursorPosition(line: from.line, column: from.column + 1)
            }
        }
        return result
    }

    private func scanBackForOpener(_ p: CursorPosition, open: Character, close: Character) -> CursorPosition? {
        var depth = 0
        var l = p.line
        var c = p.column - 1
        while true {
            let cur = chars(l)
            if c >= 0 && c < cur.count {
                if cur[c] == close { depth += 1 }
                else if cur[c] == open {
                    if depth == 0 { return CursorPosition(line: l, column: c) }
                    depth -= 1
                }
            }
            c -= 1
            if c < 0 {
                if l == 0 { return nil }
                l -= 1
                c = length(l) - 1
            }
        }
    }

    // MARK: - Text objects

    /// A text object's extent: charwise `[start, end)` or whole lines.
    struct Range: Equatable {
        var start: CursorPosition
        var end: CursorPosition       // exclusive for charwise, last line for linewise
        var linewise: Bool
    }

    /// `iw` / `aw` / `iW` / `aW`.
    func wordObject(_ p: CursorPosition, big: Bool, around: Bool, count: Int) -> Range? {
        let line = chars(p.line)
        guard !line.isEmpty else { return nil }
        let col = min(p.column, line.count - 1)
        func runEnd(_ from: Int) -> Int {
            let k = cls(line[from], big)
            var e = from
            while e + 1 < line.count && cls(line[e + 1], big) == k { e += 1 }
            return e
        }
        let k = cls(line[col], big)
        var start = col
        while start > 0 && cls(line[start - 1], big) == k { start -= 1 }
        var end = runEnd(col)
        if around {
            if k != 0 {
                if end + 1 < line.count && cls(line[end + 1], big) == 0 {
                    end = runEnd(end + 1)
                } else {
                    while start > 0 && cls(line[start - 1], big) == 0 { start -= 1 }
                }
            } else if end + 1 < line.count {
                end = runEnd(end + 1)
            }
        }
        for _ in 1..<max(1, count) where end + 1 < line.count {
            end = runEnd(end + 1)
            if around && end + 1 < line.count && cls(line[end + 1], big) == 0 { end = runEnd(end + 1) }
        }
        return Range(start: CursorPosition(line: p.line, column: start),
                     end: CursorPosition(line: p.line, column: end + 1), linewise: false)
    }

    /// `i"` / `a"` (also `'` and `` ` ``), within the cursor's line.
    func quoteObject(_ p: CursorPosition, quote: Character, around: Bool) -> Range? {
        let line = chars(p.line)
        var quotes: [Int] = []
        for (i, ch) in line.enumerated() where ch == quote && (i == 0 || line[i - 1] != "\\") {
            quotes.append(i)
        }
        guard quotes.count >= 2 else { return nil }
        var open: Int?
        var close: Int?
        if let k = quotes.firstIndex(of: p.column) {
            if k % 2 == 0, k + 1 < quotes.count { open = quotes[k]; close = quotes[k + 1] }
            else if k % 2 == 1 { open = quotes[k - 1]; close = quotes[k] }
        } else {
            let before = quotes.filter { $0 < p.column }
            let after = quotes.filter { $0 > p.column }
            if before.count % 2 == 1, let a = after.first {
                open = before.last
                close = a
            } else if after.count >= 2 {
                open = after[0]
                close = after[1]
            }
        }
        guard let o = open, let c = close else { return nil }
        if !around {
            return Range(start: CursorPosition(line: p.line, column: o + 1),
                         end: CursorPosition(line: p.line, column: c), linewise: false)
        }
        var s = o
        var e = c + 1
        if e < line.count && line[e].isWhitespace {
            while e < line.count && line[e].isWhitespace { e += 1 }
        } else {
            while s > 0 && line[s - 1].isWhitespace { s -= 1 }
        }
        return Range(start: CursorPosition(line: p.line, column: s),
                     end: CursorPosition(line: p.line, column: e), linewise: false)
    }

    /// `i(` / `a(` and friends. An inner block whose brackets sit alone at the
    /// ends of their lines covers just the lines between them (linewise).
    func bracketObject(_ p: CursorPosition, open: Character, around: Bool, count: Int) -> Range? {
        guard let (o, c) = enclosingPair(p, open: open, count: count) else { return nil }
        if around {
            return Range(start: o, end: CursorPosition(line: c.line, column: c.column + 1), linewise: false)
        }
        if o.column == length(o.line) - 1, c.line > o.line + 1,
           c.column <= firstNonBlank(c.line) {
            return Range(start: CursorPosition(line: o.line + 1, column: 0),
                         end: CursorPosition(line: c.line - 1, column: 0), linewise: true)
        }
        var start = CursorPosition(line: o.line, column: o.column + 1)
        if start.column >= length(o.line) && o.line < c.line {
            start = CursorPosition(line: o.line + 1, column: 0)
        }
        return Range(start: start, end: c, linewise: false)
    }

    /// `ip` / `ap`: a run of non-empty lines (or of empty lines), linewise.
    func paragraphObject(_ p: CursorPosition, around: Bool, count: Int) -> Range {
        func blockEnd(_ from: Int) -> Int {
            let blank = isEmpty(from)
            var e = from
            while e < lastLine && isEmpty(e + 1) == blank { e += 1 }
            return e
        }
        let blank = isEmpty(p.line)
        var start = p.line
        while start > 0 && isEmpty(start - 1) == blank { start -= 1 }
        var end = blockEnd(p.line)
        var blocks = around ? 2 : 1
        blocks += (max(1, count) - 1) * (around ? 2 : 1)
        for _ in 1..<blocks where end < lastLine { end = blockEnd(end + 1) }
        if around && end == blockEnd(p.line) {
            // No trailing blank block: take the preceding one instead.
            while start > 0 && isEmpty(start - 1) != blank { start -= 1 }
        }
        return Range(start: CursorPosition(line: start, column: 0),
                     end: CursorPosition(line: end, column: 0), linewise: true)
    }

    /// `is` / `as`: the sentence under the cursor (`as` adds trailing blanks).
    func sentenceObject(_ p: CursorPosition, around: Bool) -> Range? {
        let starts = sentenceStarts()
        guard let start = starts.last(where: { !VimText.less(p, $0) }) else { return nil }
        let next = starts.first(where: { VimText.less(start, $0) })
        var end = next ?? CursorPosition(line: lastLine, column: length(lastLine))
        if !around, let n = next {
            // Back off the blanks before the next sentence.
            var l = n.line
            var c = n.column
            while true {
                if c > 0 {
                    if !chars(l)[c - 1].isWhitespace { break }
                    c -= 1
                } else if l > start.line {
                    l -= 1
                    c = length(l)
                    if c == 0 { break }
                } else { break }
            }
            end = CursorPosition(line: l, column: c)
        }
        return Range(start: start, end: end, linewise: false)
    }

    static func less(_ a: CursorPosition, _ b: CursorPosition) -> Bool {
        a.line < b.line || (a.line == b.line && a.column < b.column)
    }
}

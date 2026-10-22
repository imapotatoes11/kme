import XCTest
@testable import editxr

/// Cursor motions, as Vim defines them.
final class VimMotionTests: VimTestCase {

    func testBasicMovementAndCounts() {
        checkCursor("abcdef\nxyz", "lll", [0, 3])
        checkCursor("abcdef\nxyz", "$j", [1, 2])
        checkCursor("abcdef\nxyz", "3l2h", [0, 1])
        checkCursor("abcdef", "10l", [0, 5])
        checkCursor("abc", "h", [0, 0])
        checkCursor("a\nb\nc\nd", "2j", [2, 0])
        checkCursor("a\nb\nc\nd", "G2k", [1, 0])
    }

    func testVerticalMotionKeepsDesiredColumn() {
        checkCursor("abcdef\nab\nabcdef", "4ljj", [2, 4])
        checkCursor("abcdef\nab\nabcdef", "$jj", [2, 5])
    }

    func testLineMotions() {
        checkCursor("   abc  ", at: [0, 6], "0", [0, 0])
        checkCursor("   abc  ", "^", [0, 3])
        checkCursor("   abc  ", "$", [0, 7])
        checkCursor("   abc  ", "g_", [0, 5])
        checkCursor("abcdef", "4|", [0, 3])
        checkCursor("a\n  b\nc", "+", [1, 2])
        checkCursor("  a\nb", at: [1, 0], "-", [0, 2])
        checkCursor("a\n  b\nc", "<CR>", [1, 2])
    }

    func testWordMotions() {
        let s = "foo bar.baz  qux"
        checkCursor(s, "w", [0, 4])
        checkCursor(s, "ww", [0, 7])
        checkCursor(s, "www", [0, 8])
        checkCursor(s, "W", [0, 4])
        checkCursor(s, "WW", [0, 13])
        checkCursor(s, "e", [0, 2])
        checkCursor(s, "ee", [0, 6])
        checkCursor(s, "E", [0, 2])
        checkCursor(s, "EE", [0, 10])
        checkCursor(s, at: [0, 15], "b", [0, 13])
        checkCursor(s, at: [0, 15], "bb", [0, 8])
        checkCursor(s, at: [0, 15], "B", [0, 13])
        checkCursor(s, at: [0, 15], "BB", [0, 4])
        checkCursor(s, at: [0, 13], "ge", [0, 10])
        checkCursor(s, at: [0, 13], "gE", [0, 10])
    }

    func testWordMotionsCrossLinesAndStopOnEmptyLines() {
        checkCursor("foo\n\nbar", "w", [1, 0])
        checkCursor("foo\n\nbar", "ww", [2, 0])
        checkCursor("foo\nbar", at: [1, 0], "b", [0, 0])
        checkCursor("foo\n  bar", at: [0, 2], "e", [1, 4])
        checkCursor("a b", "5w", [0, 2])
    }

    func testFindCharMotionsAndRepeat() {
        let s = "a,b,c,d"
        checkCursor(s, "f,", [0, 1])
        checkCursor(s, "2f,", [0, 3])
        checkCursor(s, "f,;", [0, 3])
        checkCursor(s, "f,;,", [0, 1])
        checkCursor(s, "t,", [0, 0])
        checkCursor(s, "t,;", [0, 2], )
        checkCursor(s, at: [0, 6], "F,", [0, 5])
        checkCursor(s, at: [0, 6], "T,", [0, 6])
        checkCursor(s, "fz", [0, 0])
    }

    func testFileMotions() {
        let s = "one\n  two\nthree\nfour"
        checkCursor(s, "G", [3, 0])
        checkCursor(s, at: [3, 2], "gg", [0, 0])
        checkCursor(s, "2G", [1, 2])
        checkCursor(s, "3gg", [2, 0])
        checkCursor(s, "50%", [1, 2])
    }

    func testGIgnoresTheTrailingFinalNewlineLine() {
        // The editor keeps an empty line for the final newline; Vim's G lands
        // on the last real line.
        let (app, state) = makeVim("a\nb\n")
        XCTAssertEqual(state.document.lines, ["a", "b", ""])
        app.vimKeysForTest("G")
        XCTAssertEqual(cursor(state), [1, 0])
        app.vimKeysForTest("j")
        XCTAssertEqual(cursor(state), [1, 0])
    }

    func testMatchingBracket() {
        checkCursor("if (a[1] == b) {", "%", [0, 13])
        checkCursor("if (a[1] == b) {", at: [0, 13], "%", [0, 3])
        checkCursor("x [a] y", "%", [0, 4])
        checkCursor("{\n  (x)\n}", "%", [2, 0])
    }

    func testParagraphMotions() {
        let s = "a\nb\n\nc\nd\n\ne"
        checkCursor(s, "}", [2, 0])
        checkCursor(s, "}}", [5, 0])
        checkCursor(s, "}}}", [6, 0])
        checkCursor(s, at: [6, 0], "{", [5, 0])
        checkCursor(s, at: [4, 0], "{", [2, 0])
    }

    func testSentenceMotions() {
        let s = "One two. Three four! Five?"
        checkCursor(s, ")", [0, 9])
        checkCursor(s, "))", [0, 21])
        checkCursor(s, at: [0, 23], "(", [0, 21])
        checkCursor(s, at: [0, 23], "((", [0, 9])
    }

    func testSearchMotions() {
        let s = "foo bar\nbaz foo\nfoo"
        checkCursor(s, "/foo<CR>", [1, 4])
        checkCursor(s, "/foo<CR>n", [2, 0])
        checkCursor(s, "/foo<CR>nn", [0, 0])
        checkCursor(s, "/foo<CR>N", [0, 0])
        checkCursor(s, at: [2, 0], "?bar<CR>", [0, 4])
        checkCursor(s, "/ba[rz]<CR>n", [1, 0])
        checkCursor(s, "*", [1, 4])
        checkCursor(s, "#", [2, 0])
        checkCursor("foo food", "*", [0, 0])
        checkCursor("foo food", "g*", [0, 4])
    }

    func testSearchIsIncrementalAndEscapeRestores() {
        let (app, state) = makeVim("abc\nxyz\nabc")
        app.vimKeysForTest("/xy")
        XCTAssertEqual(cursor(state), [1, 0], "incsearch previews the match")
        app.vimKeysForTest("<Esc>")
        XCTAssertEqual(cursor(state), [0, 0])
    }

    func testSearchCaseOptions() {
        checkCursor("Foo foo", "/foo<CR>", [0, 4])
        checkCursor("foo Foo", "/\\cFOO<CR>", [0, 4])
        let (app, state) = makeVim("x Foo foo")
        app.vimKeysForTest(":set ic<CR>/foo<CR>")
        XCTAssertEqual(cursor(state), [0, 2])
        app.vimKeysForTest("0:set scs<CR>/Foo<CR>n")
        XCTAssertEqual(cursor(state), [0, 2], "smartcase: an uppercase letter forces a case match")
    }

    func testSearchPatternNotFoundLeavesCursor() {
        let (app, state) = makeVim("abc", line: 0, col: 1)
        app.vimKeysForTest("/zzz<CR>")
        XCTAssertEqual(cursor(state), [0, 1])
        XCTAssertEqual(app.toastForTest, "E486: Pattern not found: zzz")
    }

    func testMarks() {
        let s = "aaa\n  bbb\nccc"
        checkCursor(s, at: [1, 4], "mxgg'x", [1, 2])
        checkCursor(s, at: [1, 4], "mxgg`x", [1, 4])
        checkCursor(s, at: [1, 4], "G''", [1, 2])
        checkCursor(s, at: [1, 4], "G``", [1, 4])
    }

    func testJumpListBackAndForward() {
        let s = (1...20).map { "l\($0)" }.joined(separator: "\n")
        checkCursor(s, "G<C-o>", [0, 0])
        checkCursor(s, "5GG<C-o>", [4, 0])
        checkCursor(s, "5GG<C-o><C-o><Tab>", [4, 0])
        checkCursor(s, "5GG<C-o><C-o><Tab><Tab>", [19, 0])
    }

    func testScreenMotions() {
        let s = (1...100).map { "l\($0)" }.joined(separator: "\n")
        let (app, state) = makeVim(s)
        _ = app.renderEditorLinesForTest(width: 80, height: 24)
        app.vimKeysForTest("L")
        XCTAssertGreaterThan(state.document.cursorLine, 10)
        app.vimKeysForTest("H")
        XCTAssertEqual(state.document.cursorLine, 0)
        app.vimKeysForTest("M")
        XCTAssertGreaterThan(state.document.cursorLine, 3)
    }

    // MARK: - VimText primitives

    func testTextObjectPrimitives() {
        let t = VimText(["say \"hi there\" (a (b) c) end"])
        let quote = t.quoteObject(CursorPosition(line: 0, column: 7), quote: "\"", around: false)
        XCTAssertEqual(quote?.start.column, 5)
        XCTAssertEqual(quote?.end.column, 13)
        let inner = t.bracketObject(CursorPosition(line: 0, column: 17), open: "(", around: false, count: 1)
        XCTAssertEqual(inner?.start.column, 16)
        XCTAssertEqual(inner?.end.column, 23)
        let onClose = t.bracketObject(CursorPosition(line: 0, column: 20), open: "(", around: false, count: 1)
        XCTAssertEqual(onClose?.start.column, 19, "on a bracket: that pair")
        let outer = t.bracketObject(CursorPosition(line: 0, column: 19), open: "(", around: false, count: 2)
        XCTAssertEqual(outer?.start.column, 16)
        XCTAssertEqual(outer?.end.column, 23)
        let nested = t.bracketObject(CursorPosition(line: 0, column: 19), open: "(", around: true, count: 1)
        XCTAssertEqual(nested?.start.column, 18)
        XCTAssertEqual(nested?.end.column, 21)
    }
}

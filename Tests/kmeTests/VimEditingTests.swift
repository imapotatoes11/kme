import XCTest
@testable import kme

/// Operators with motions and text objects, simple editing commands,
/// registers, undo grouping, `.` repeat, macros, and Visual-mode operators.
final class VimEditingTests: VimTestCase {

    // MARK: - Operator + motion

    func testDeleteWord() {
        check("foo bar baz", "dw", gives: "bar baz", cursor: [0, 0])
        check("foo bar baz", "2dw", gives: "baz")
        check("foo bar baz", "d2w", gives: "baz")
        check("foo bar baz", at: [0, 4], "dw", gives: "foo baz")
        check("foo bar.baz", at: [0, 4], "dW", gives: "foo ")
    }

    func testDeleteWordAtEndOfLineDoesNotJoin() {
        check("foo bar\nnext", at: [0, 4], "dw", gives: "foo \nnext")
        check("foo\n  next", "dw", gives: "\n  next")
    }

    func testDeleteToLineEndAndStart() {
        check("hello world", at: [0, 5], "d$", gives: "hello", cursor: [0, 4])
        check("hello world", at: [0, 5], "D", gives: "hello")
        check("hello world", at: [0, 6], "d0", gives: "world", cursor: [0, 0])
        check("   hello", at: [0, 6], "d^", gives: "   lo")
        check("a\nb\nc", "2D", gives: "\nc")
    }

    func testLinewiseDeletes() {
        check("a\nb\nc\nd", at: [1, 0], "dd", gives: "a\nc\nd", cursor: [1, 0])
        check("a\nb\nc\nd", at: [1, 0], "2dd", gives: "a\nd")
        check("a\nb\nc\nd", at: [1, 0], "dj", gives: "a\nd")
        check("a\nb\nc\nd", at: [2, 0], "dk", gives: "a\nd")
        check("a\nb\nc\nd", at: [1, 0], "dG", gives: "a")
        check("a\nb\nc\nd", at: [2, 0], "dgg", gives: "d")
        check("a\nb\n\nc", "d}", gives: "\nc")
        check("only", "dd", gives: "")
        check("a\n  b", "d+", gives: "")
    }

    func testFindAndTillOperators() {
        check("a,b,c", "df,", gives: "b,c")
        check("a,b,c", "dt,", gives: ",b,c")
        check("a,b,c", "d2f,", gives: "c")
        check("a,b,c", at: [0, 4], "dF,", gives: "a,bc")
        check("(a + b)", "d%", gives: "")
    }

    func testChangeOperator() {
        check("foo bar", "cwxy<Esc>", gives: "xy bar", cursor: [0, 1])
        check("foo bar", "cWxy<Esc>", gives: "xy bar")
        check("foo bar", "c2wxy<Esc>", gives: "xy")
        check("foo bar", at: [0, 4], "c$end<Esc>", gives: "foo end")
        check("foo bar", at: [0, 4], "Cend<Esc>", gives: "foo end")
        check("a\nfoo\nb", at: [1, 1], "ccnew<Esc>", gives: "a\nnew\nb")
        check("a\nfoo\nb", at: [1, 1], "Snew<Esc>", gives: "a\nnew\nb")
        check("abc", "sX<Esc>", gives: "Xbc")
        check("abc", "2sX<Esc>", gives: "Xc")
        check("a b", "cw<Esc>", gives: " b")
    }

    func testYankAndPut() {
        check("foo bar", "ywP", gives: "foo foo bar")
        check("foo bar", "yw$p", gives: "foo barfoo ")
        check("a\nb", "yyp", gives: "a\na\nb", cursor: [1, 0])
        check("a\nb", "yyP", gives: "a\na\nb", cursor: [0, 0])
        check("a\nb", "yy3p", gives: "a\na\na\na\nb")
        check("a\nb\nc", "ddp", gives: "b\na\nc")
        check("abc", "xp", gives: "bac")
        check("ab", "yl2p", gives: "aaab")
        check("a\nb", "yjGp", gives: "a\nb\na\nb")
        check("abc", "ylgpx", gives: "aac")
    }

    func testCaseAndShiftOperators() {
        check("hello world", "gUiw", gives: "HELLO world")
        check("HELLO world", "guw", gives: "hello world")
        check("Hello", "g~~", gives: "hELLO")
        check("abc", "gUU", gives: "ABC")
        check("Hello", "g??", gives: "Uryyb")
        check("abc", "~~", gives: "ABc", cursor: [0, 2])
        check("a\nb", ">>", gives: "\ta\nb")
        check("a\nb", ">j", gives: "\ta\n\tb")
        check("\t\ta", "<<", gives: "\ta")
        check("        a", "<<", gives: "a")
    }

    func testTextObjects() {
        check("foo bar baz", at: [0, 5], "diw", gives: "foo  baz")
        check("foo bar baz", at: [0, 5], "daw", gives: "foo baz")
        check("foo bar", at: [0, 5], "daw", gives: "foo")
        check("foo bar baz", at: [0, 5], "ciwX<Esc>", gives: "foo X baz")
        check("say \"hi there\" now", at: [0, 7], "di\"", gives: "say \"\" now")
        check("say \"hi there\" now", at: [0, 7], "da\"", gives: "say now")
        check("say 'x' and 'y'", "ci'Z<Esc>", gives: "say 'Z' and 'y'")
        check("f(a, (b), c)", at: [0, 3], "di(", gives: "f()")
        check("f(a, (b), c)", at: [0, 6], "dib", gives: "f(a, (), c)")
        check("f(a, (b), c)", at: [0, 6], "da(", gives: "f(a, , c)")
        check("f(a, (b), c)", at: [0, 6], "d2i(", gives: "f()")
        check("x[1, 2]", at: [0, 3], "ci[9<Esc>", gives: "x[9]")
        check("{\n  a\n  b\n}", at: [1, 2], "di{", gives: "{\n}")
        check("a <b> c", at: [0, 3], "di<", gives: "a <> c")
        check("p1\np1\n\np2", "dip", gives: "\np2")
        check("p1\np1\n\np2", "dap", gives: "p2")
        check("One two. Three four.", at: [0, 10], "dis", gives: "One two. ")
        check("foo", "yiwP", gives: "foofoo")
    }

    // MARK: - Simple commands

    func testDeleteCharacters() {
        check("abcdef", at: [0, 2], "x", gives: "abdef", cursor: [0, 2])
        check("abcdef", at: [0, 2], "3x", gives: "abf")
        check("abcdef", at: [0, 5], "x", gives: "abcde", cursor: [0, 4])
        check("abcdef", at: [0, 2], "X", gives: "acdef", cursor: [0, 1])
        check("abcdef", at: [0, 3], "2X", gives: "adef")
        check("", "x", gives: "")
    }

    func testReplaceChar() {
        check("abc", "rx", gives: "xbc", cursor: [0, 0])
        check("abc", "2rx", gives: "xxc", cursor: [0, 1])
        check("abc", "5rx", gives: "abc")
        check("abc", "lr<CR>", gives: "a\nc")
    }

    func testJoinLines() {
        check("a\n  b\nc", "J", gives: "a b\nc", cursor: [0, 1])
        check("a\nb\nc", "3J", gives: "a b c")
        check("a \nb", "J", gives: "a b")
        check("f(\n)", "J", gives: "f()")
        check("a\n  b", "gJ", gives: "a  b")
        check("a", "J", gives: "a")
    }

    func testIncrementDecrement() {
        check("x 41 y", "<C-a>", gives: "x 42 y", cursor: [0, 3])
        check("x 41 y", "5<C-x>", gives: "x 36 y")
        check("v-3", "<C-a>", gives: "v-2")
        check("10", "15<C-x>", gives: "-5")
        check("no number", "<C-a>", gives: "no number")
    }

    // MARK: - Registers

    func testNamedRegisters() {
        check("one\ntwo", "\"ayyj\"ap", gives: "one\ntwo\none")
        check("one\ntwo", "\"ayyj\"Ayy\"ap", gives: "one\ntwo\none\ntwo")
        check("abc", "\"qyl$\"qp", gives: "abca")
    }

    func testNumberedAndSmallDeleteRegisters() {
        let (app, state) = makeVim("one\ntwo\nthree four")
        app.vimKeysForTest("yyjddjdw")
        XCTAssertEqual(vim(app).register("0")?.text, "one")
        XCTAssertEqual(vim(app).register("1")?.text, "two")
        XCTAssertEqual(vim(app).register("-")?.text, "three ")
        app.vimKeysForTest("\"0P")
        XCTAssertEqual(text(state), "one\none\nfour")
    }

    func testBlackHoleRegisterKeepsUnnamed() {
        check("keep\ndrop\nx", "yyj\"_ddp", gives: "keep\nx\nkeep")
    }

    func testDeleteRingShifts() {
        let (app, _) = makeVim("a\nb\nc")
        app.vimKeysForTest("dddddd")
        XCTAssertEqual(vim(app).register("1")?.text, "c")
        XCTAssertEqual(vim(app).register("2")?.text, "b")
        XCTAssertEqual(vim(app).register("3")?.text, "a")
    }

    func testLastInsertedRegister() {
        check("", "ihi<Esc>\".p", gives: "hihi")
    }

    // MARK: - Undo grouping

    func testInsertSessionIsOneUndoStep() {
        let (app, state) = makeVim("start")
        app.vimKeysForTest("A one two three<Esc>")
        XCTAssertEqual(text(state), "start one two three")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "start")
        app.vimKeysForTest("<C-r>")
        XCTAssertEqual(text(state), "start one two three")
    }

    func testChangeWithTypingIsOneUndoStep() {
        let (app, state) = makeVim("foo bar")
        app.vimKeysForTest("ciwreplacement<Esc>")
        XCTAssertEqual(text(state), "replacement bar")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "foo bar")
    }

    func testCountedCommandsAreOneUndoStep() {
        let (app, state) = makeVim("a\nb\nc\nd\ne")
        app.vimKeysForTest("3dd")
        XCTAssertEqual(text(state), "d\ne")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "a\nb\nc\nd\ne")
        app.vimKeysForTest("3J")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "a\nb\nc\nd\ne")
        app.vimKeysForTest("3o<Esc>")
        XCTAssertEqual(state.document.lines.count, 9)
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "a\nb\nc\nd\ne")
    }

    func testOpenLineWithTextIsOneUndoStep() {
        let (app, state) = makeVim("- a")
        app.vimKeysForTest("onext item<Esc>")
        XCTAssertEqual(text(state), "- a\n- next item")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "- a")
    }

    func testUndoCountAndCursorRestore() {
        let (app, state) = makeVim("abcdef", line: 0, col: 3)
        app.vimKeysForTest("xxx")
        XCTAssertEqual(text(state), "abc")
        app.vimKeysForTest("2u")
        XCTAssertEqual(text(state), "abcef")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "abcdef")
        XCTAssertEqual(cursor(state), [0, 3])
    }

    // MARK: - Dot repeat

    func testDotRepeatsOperators() {
        check("a b c d e", "dw..", gives: "d e")
        check("a b c d e", "dw2.", gives: "d e")
        check("one two three", "cwX<Esc>w.", gives: "X X three")
        check("a\nb\nc\nd", "dd.", gives: "c\nd")
        check("abcdef", "x3.", gives: "ef")
        check("x\ny", "A;<Esc>j.", gives: "x;\ny;")
        check("a\nb", ">>j.", gives: "\ta\n\tb")
        check("foo foo foo", "ciwbar<Esc>ww.", gives: "bar foo bar")
    }

    func testDotRepeatOfInsertCommands() {
        check("x", "ia<Esc>.", gives: "aax")
        check("a\nb", "oz<Esc>j.", gives: "a\nz\nb\nz")
        check("ab", "rx.", gives: "xb")
    }

    func testDotRepeatIsOneUndoStep() {
        let (app, state) = makeVim("a b c d")
        app.vimKeysForTest("d2w.")
        XCTAssertEqual(text(state), "")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "c d")
    }

    func testDotRepeatsVisualOperation() {
        check("abcdef\nabcdef", "vld.", gives: "ef\nabcdef")
        check("a\nb\nc\nd", "Vjd.", gives: "")
    }

    // MARK: - Macros

    func testRecordAndReplayMacro() {
        check("1\n2\n3\n4", "qaA.<Esc>jq2@a", gives: "1.\n2.\n3.\n4")
        check("1\n2\n3\n4", "qaA.<Esc>jq@a@@", gives: "1.\n2.\n3.\n4")
        check("a\nb\nc", "qqI- <Esc>jq2@q", gives: "- a\n- b\n- c")
    }

    func testMacroWithEscapeFollowedByOpenLine() {
        check("x", "qwAa<Esc>Ob<Esc>jq", gives: "b\nxa")
        check("x\ny", "qwAa<Esc>Ob<Esc>jjq@w", gives: "b\nxa\nb\nya")
    }

    func testMacroIsStoredInItsRegister() {
        let (app, _) = makeVim("x")
        app.vimKeysForTest("qaxq")
        XCTAssertEqual(vim(app).register("a")?.text, "x")
        XCTAssertNil(vim(app).recordingRegister)
    }

    // MARK: - Visual operators

    func testVisualCharwiseOperators() {
        check("hello world", "vlld", gives: "lo world")
        check("hello world", "vey$p", gives: "hello worldhello")
        check("hello world", "vecX<Esc>", gives: "X world")
        check("hello world", "veU", gives: "HELLO world")
        check("Hello", "v$~", gives: "hELLO")
        check("hello", "vlrx", gives: "xxllo")
        check("ab\ncd", "lvjd", gives: "a")
        check("one two", "wviwd", gives: "one ")
        check("abc def", "wvhhd", gives: "abef")
    }

    func testVisualLineOperators() {
        check("a\nb\nc", "Vjd", gives: "c")
        check("a\nb\nc", "Vjyjjp", gives: "a\nb\nc\na\nb")
        check("a\nb\nc", "Vj>", gives: "\ta\n\tb\nc")
        check("a\nb\nc", "VjJ", gives: "a b\nc")
        check("a\nb", "VjcX<Esc>", gives: "X")
        check("abc\ndef", "VU", gives: "ABC\ndef")
    }

    func testVisualPutReplacesSelection() {
        check("foo bar", "yiwwviwp", gives: "foo foo")
        let (app, state) = makeVim("foo bar")
        app.vimKeysForTest("yiwwviwp")
        XCTAssertEqual(vim(app).register(nil)?.text, "bar", "the replaced text goes to the unnamed register")
        XCTAssertEqual(text(state), "foo foo")
    }

    func testVisualSwapEndsAndReselect() {
        let (app, state) = makeVim("abcdef", line: 0, col: 2)
        app.vimKeysForTest("vllo")
        XCTAssertEqual(cursor(state), [0, 2])
        app.vimKeysForTest("<Esc>0gv")
        XCTAssertEqual(vim(app).mode, .visual)
        app.vimKeysForTest("d")
        XCTAssertEqual(text(state), "abf")
    }

    func testVisualTextObjectsExtendSelection() {
        check("say (a b) x", at: [0, 6], "vi(d", gives: "say () x")
        check("p\np\n\nq", "vipd", gives: "\nq")
    }

    func testVisualInsertAppend() {
        check("abc def", "wveIX<Esc>", gives: "abc Xdef")
        check("abc def", "veAX<Esc>", gives: "abcX def")
    }

    func testVisualColonUsesSelectionRange() {
        check("a\nb\nc\nd", at: [1, 0], "Vj:s/$/!/<CR>", gives: "a\nb!\nc!\nd")
    }
}

import XCTest
@testable import editxr

/// Mappings, startup commands, gq formatting, the change list, search
/// offsets, keyword completion and relativenumber.
final class VimExtrasTests: VimTestCase {

    // MARK: - Mappings

    func testInsertMappingJKToEscape() {
        let (app, state) = makeVim("")
        app.vimKeysForTest(":inoremap jk <lt>Esc><CR>")
        app.vimKeysForTest("ihijk")
        XCTAssertEqual(vim(app).mode, .normal)
        XCTAssertEqual(text(state), "hi")
        // A lone j waits for the timeout, then types itself.
        app.vimKeysForTest("aj")
        XCTAssertTrue(vim(app).hasPendingMapping)
        XCTAssertEqual(text(state), "hi")
        vim(app).flushPendingMapping()
        XCTAssertEqual(text(state), "hij")
        // j followed by something else types both.
        app.vimKeysForTest("jx<Esc>")
        XCTAssertEqual(text(state), "hijjx")
    }

    func testNormalMappingsRecursiveAndNot() {
        check("a\nb\nc", ":nnoremap Q dd<CR>Q", gives: "b\nc")
        check("abc", ":nmap x dd<CR>:nmap Y x<CR>Y", gives: "", cursor: [0, 0])
        check("abc", ":nmap x dd<CR>:nnoremap Y x<CR>Y", gives: "bc", cursor: [0, 0])
    }

    func testLeaderAndUnmap() {
        let (app, state) = makeVim("abc")
        app.vimKeysForTest(":nnoremap <leader>d dd<CR>\\d")
        XCTAssertEqual(text(state), "")
        app.vimKeysForTest("u:nunmap <leader>d<CR>")
        XCTAssertTrue(vim(app).mappings["n"]?.isEmpty ?? true)
        app.vimKeysForTest(":nunmap <leader>d<CR>")
        XCTAssertEqual(app.toastForTest, "E31: No such mapping")
    }

    func testMappingsDontApplyToCommandArguments() {
        check("axb", ":nnoremap x dd<CR>fxr!", gives: "a!b")
    }

    func testOperatorPendingMapping() {
        check("foo(bar) baz", at: [0, 5], ":onoremap p i(<CR>dp", gives: "foo() baz")
    }

    func testStartupCommandsFromConfig() {
        let (app, state) = makeVim("abc", configExtra: #", "vim": {"startupCommands": ["inoremap jk <Esc>", "set ic"]}"#)
        XCTAssertTrue(vim(app).ignoreCase)
        app.vimKeysForTest("Axjk")
        XCTAssertEqual(vim(app).mode, .normal)
        XCTAssertEqual(text(state), "abcx")
    }

    // MARK: - Formatting

    func testGqRewrapsParagraph() {
        let (app, state) = makeVim("one two three four five\nsix seven\n\nnext")
        app.vimKeysForTest(":set tw=10<CR>gqap")
        XCTAssertEqual(text(state), "one two\nthree four\nfive six\nseven\n\nnext")
        XCTAssertEqual(state.document.cursorLine, 4)
    }

    func testGqKeepsListMarkersAndGwKeepsCursor() {
        let (app, state) = makeVim("- alpha beta gamma delta\n- second item")
        app.vimKeysForTest(":set tw=12<CR>gwip")
        XCTAssertEqual(text(state), "- alpha beta\n  gamma\n  delta\n- second\n  item")
        XCTAssertEqual(cursor(state), [0, 0])
    }

    func testGqJoinsShortLines() {
        check("a\nb\nc", "gqip", gives: "a b c")
        check("a\nb\nc", "Vjgq", gives: "a b\nc")
    }

    // MARK: - Change list, search offsets

    func testChangeList() {
        let s = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let (app, state) = makeVim(s)
        app.vimKeysForTest("2Gx8GxG")
        app.vimKeysForTest("g;")
        XCTAssertEqual(state.document.cursorLine, 7)
        app.vimKeysForTest("g;")
        XCTAssertEqual(state.document.cursorLine, 1)
        app.vimKeysForTest("g,")
        XCTAssertEqual(state.document.cursorLine, 7)
    }

    func testSearchOffsets() {
        checkCursor("say hello there", "/hello/e<CR>", [0, 8])
        checkCursor("say hello there", "/hello/e-1<CR>", [0, 7])
        checkCursor("say hello there", "/hello/s+2<CR>", [0, 6])
        checkCursor("a\nfoo\n  bar", "/foo/+1<CR>", [2, 2])
    }

    // MARK: - Completion

    func testKeywordCompletionAndCycling() {
        let (app, state) = makeVim("alpha alpine\n")
        app.vimKeysForTest("oal<C-n>")
        XCTAssertEqual(state.document.lines[1], "alpha")
        app.vimKeysForTest("<C-n>")
        XCTAssertEqual(state.document.lines[1], "alpine")
        app.vimKeysForTest("<C-n>")
        XCTAssertEqual(state.document.lines[1], "al", "cycles back to what was typed")
        app.vimKeysForTest("<C-p>!<Esc>")
        XCTAssertEqual(state.document.lines[1], "alpine!")
    }

    func testCompletionRepeatsAsText() {
        check("unicorn\n", "ouni<C-n><Esc>.", gives: "unicorn\nunicorn\nunicorn")
    }

    // MARK: - relativenumber

    func testRelativeNumberGutter() {
        let (app, state) = makeVim("a\nb\nc\nd", line: 2)
        app.vimKeysForTest(":set rnu<CR>")
        XCTAssertTrue(state.relativeLineNumbers)
        let rows = app.renderContentLinesForTest(width: 40, height: 4).map(RenderTests.plain)
        XCTAssertEqual(rows.map { $0.trimmingCharacters(in: .whitespaces).prefix(3) }, ["2 a", "1 b", "0 c", "1 d"])
        app.vimKeysForTest(":set nu<CR>")
        let numbered = app.renderContentLinesForTest(width: 40, height: 4).map(RenderTests.plain)
        XCTAssertTrue(numbered[2].trimmingCharacters(in: .whitespaces).hasPrefix("3 c"))
    }
}

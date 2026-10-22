import XCTest
@testable import kme

/// Ex command-line commands: files, ranges, substitute, global, and friends.
final class VimExTests: VimTestCase {

    // MARK: - Files

    func testWriteSavesTheFile() throws {
        let (app, state) = makeVim("abc")
        app.vimKeysForTest("x:w<CR>")
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(try String(contentsOfFile: state.filePath, encoding: .utf8), "bc\n")
        XCTAssertFalse(exited)
    }

    func testQuitRefusesWithUnsavedChanges() {
        let (app, state) = makeVim("abc")
        app.vimKeysForTest("x:q<CR>")
        XCTAssertFalse(exited)
        XCTAssertEqual(app.toastForTest, "E37: No write since last change (add ! to override)")
        XCTAssertTrue(state.isDirty)
        app.vimKeysForTest(":q!<CR>")
        XCTAssertTrue(exited)
    }

    func testWriteQuitVariants() throws {
        var (app, state) = makeVim("abc")
        app.vimKeysForTest("x:wq<CR>")
        XCTAssertTrue(exited)
        XCTAssertEqual(try String(contentsOfFile: state.filePath, encoding: .utf8), "bc\n")

        (app, state) = makeVim("abc")
        exited = false
        app.vimKeysForTest(":x<CR>")
        XCTAssertTrue(exited, ":x on an unmodified buffer just quits")

        (app, state) = makeVim("abc")
        exited = false
        app.vimKeysForTest("xZZ")
        XCTAssertTrue(exited)
        XCTAssertFalse(state.isDirty)

        (app, state) = makeVim("abc")
        exited = false
        app.vimKeysForTest("xZQ")
        XCTAssertTrue(exited)
        XCTAssertEqual(try String(contentsOfFile: state.filePath, encoding: .utf8), "abc")
    }

    func testWriteToAnotherFile() throws {
        let (app, state) = makeVim("a\nb\nc")
        let other = dir + "/copy.md"
        app.vimKeysForTest(":2,3w \(other)<CR>")
        XCTAssertEqual(try String(contentsOfFile: other, encoding: .utf8), "b\nc\n")
        XCTAssertNotEqual(state.filePath, other)
        app.vimKeysForTest(":w \(other)<CR>")
        XCTAssertEqual(app.toastForTest, "E13: File exists (add ! to override)")
    }

    func testEditOpensAnotherFileInATab() throws {
        let (app, _) = makeVim("a")
        let other = dir + "/other.md"
        try "other text".write(toFile: other, atomically: true, encoding: .utf8)
        app.vimKeysForTest(":e \(other)<CR>")
        XCTAssertEqual(app.tabCountForTest, 2)
        XCTAssertEqual(app.activeFileForTest, other)
        app.vimKeysForTest("x")
        app.vimKeysForTest(":tabp<CR>")
        XCTAssertEqual(app.activeTabForTest, 0)
        app.vimKeysForTest("gt")
        XCTAssertEqual(app.activeTabForTest, 1)
    }

    func testReadInsertsFileBelow() throws {
        let other = dir + "/inc.md"
        try "x\ny\n".write(toFile: other, atomically: true, encoding: .utf8)
        check("a\nb", ":r \(other)<CR>", gives: "a\nx\ny\nb")
    }

    // MARK: - Ranges and line commands

    func testGoToLine() {
        checkCursor("a\nb\nc", ":3<CR>", [2, 0])
        checkCursor("a\nb\nc", ":$<CR>", [2, 0])
        checkCursor("a\nb\nc", ":99<CR>", [2, 0])
        checkCursor("a\nb\nc", ":/c/<CR>", [2, 0])
        checkCursor("a\nb\nc", "G:-1<CR>", [1, 0])
    }

    func testDeleteYankPutMoveCopy() {
        check("a\nb\nc\nd", ":2,3d<CR>", gives: "a\nd")
        check("a\nb\nc\nd", ":d 2<CR>", gives: "c\nd")
        check("a\nb\nc\nd", ":%d<CR>", gives: "")
        check("a\nb\nc", ":1y<CR>:$put<CR>", gives: "a\nb\nc\na")
        check("a\nb\nc", ":1y<CR>:0put<CR>", gives: "a\na\nb\nc")
        check("a\nb\nc", ":1m$<CR>", gives: "b\nc\na")
        check("a\nb\nc", ":3m0<CR>", gives: "c\na\nb")
        check("a\nb\nc", ":1t.<CR>", gives: "a\na\nb\nc")
        check("a\nb\nc", ":1,2co$<CR>", gives: "a\nb\nc\na\nb")
        check("a\nb\nc", ":1,3j<CR>", gives: "a b c")
        check("a\nb", ":j!<CR>", gives: "ab")
        check("a\nb\nc", ":2,3><CR>", gives: "a\n\tb\n\tc")
        check("a\nb", ":%>><CR>", gives: "\t\ta\n\t\tb")
    }

    func testMarksAsRanges() {
        check("a\nb\nc\nd", "jmajmb:'a,'bd<CR>", gives: "a\nd")
    }

    func testInvalidRangeAndUnknownCommand() {
        let (app, state) = makeVim("a\nb")
        app.vimKeysForTest(":5,6d<CR>")
        XCTAssertEqual(app.toastForTest, "E16: Invalid range")
        app.vimKeysForTest(":frobnicate<CR>")
        XCTAssertEqual(app.toastForTest, "E492: Not an editor command: frobnicate")
        XCTAssertEqual(text(state), "a\nb")
    }

    // MARK: - Substitute

    func testSubstitute() {
        check("foo foo\nfoo", ":s/foo/bar/<CR>", gives: "bar foo\nfoo")
        check("foo foo\nfoo", ":s/foo/bar/g<CR>", gives: "bar bar\nfoo")
        check("foo foo\nfoo", ":%s/foo/bar/g<CR>", gives: "bar bar\nbar")
        check("foo\nfoo", ":%s/FOO/x/i<CR>", gives: "x\nx")
        check("a-b", ":s/-/\\r/<CR>", gives: "a\nb")
        check("john smith", ":s/\\(\\w\\+\\) \\(\\w\\+\\)/\\2 \\1/<CR>", gives: "smith john")
        check("john smith", ":s/\\v(\\w+) (\\w+)/\\u\\2, \\U\\1/<CR>", gives: "Smith, JOHN")
        check("a.b", ":s/./x/g<CR>", gives: "xxx")
        check("a.b", ":s/\\./x/<CR>", gives: "axb")
        check("price 5", ":s/\\d\\+/[&]/<CR>", gives: "price [5]")
        check("a/b", ":s#/#+#<CR>", gives: "a+b")
        check("aaa", ":s/a\\{2}/b/<CR>", gives: "ba")
        check("hello", ":s/\\<hel/X/<CR>", gives: "Xlo")
    }

    func testSubstituteRepeatAndAmpersand() {
        check("a a\na a", ":s/a/b/<CR>j:s<CR>", gives: "b a\nb a")
        check("a a\na a", ":s/a/b/g<CR>j&", gives: "b b\nb a")
        check("a a\na a", ":s/a/b/g<CR>j:&&<CR>", gives: "b b\nb b")
        check("a\na\na", ":s/a/b/<CR>g&", gives: "b\nb\nb")
    }

    func testSubstituteUsesLastSearchWhenPatternEmpty() {
        check("foo bar", "/bar<CR>:s//baz/<CR>", gives: "foo baz")
    }

    func testSubstituteIsOneUndoStep() {
        let (app, state) = makeVim("a\na\na")
        app.vimKeysForTest(":%s/a/b/<CR>")
        XCTAssertEqual(text(state), "b\nb\nb")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "a\na\na")
    }

    func testSubstituteNotFound() {
        let (app, _) = makeVim("abc")
        app.vimKeysForTest(":s/zzz/y/<CR>")
        XCTAssertEqual(app.toastForTest, "E486: Pattern not found: zzz")
        app.vimKeysForTest(":s/zzz/y/e<CR>")
    }

    // MARK: - Global, normal, sort

    func testGlobal() {
        check("keep\ndrop 1\nkeep\ndrop 2", ":g/drop/d<CR>", gives: "keep\nkeep")
        check("keep\ndrop 1\nkeep\ndrop 2", ":v/drop/d<CR>", gives: "drop 1\ndrop 2")
        check("keep\ndrop 1\nkeep\ndrop 2", ":g!/drop/d<CR>", gives: "drop 1\ndrop 2")
        check("a1\nb\na2", ":g/a/s/\\d/N/<CR>", gives: "aN\nb\naN")
        check("a\nb\na", ":g/a/normal A;<CR>", gives: "a;\nb\na;")
        check("x\ny\nz", ":g/^/m0<CR>", gives: "z\ny\nx")
        check("a\nb", ":g/a/t.<CR>", gives: "a\na\nb")
    }

    func testGlobalIsOneUndoStep() {
        let (app, state) = makeVim("a\nb\na\nb")
        app.vimKeysForTest(":g/a/d<CR>")
        XCTAssertEqual(text(state), "b\nb")
        app.vimKeysForTest("u")
        XCTAssertEqual(text(state), "a\nb\na\nb")
    }

    func testNormalCommand() {
        check("a\nb\nc", ":%norm A!<CR>", gives: "a!\nb!\nc!")
        check("a\nb\nc", ":2,3normal Ix<CR>", gives: "a\nxb\nxc")
        check("one two", ":norm dw<CR>", gives: "two")
        check("a\nb", ":%norm yyp<CR>", gives: "a\na\nb\nb")
    }

    func testSort() {
        check("c\na\nb", ":sort<CR>", gives: "a\nb\nc")
        check("c\na\nb", ":sort!<CR>", gives: "c\nb\na")
        check("10\n9\n100", ":sort n<CR>", gives: "9\n10\n100")
        check("b\na\nb\na", ":sort u<CR>", gives: "a\nb")
        check("B\na\nC", ":sort i<CR>", gives: "a\nB\nC")
        check("z\nc\na\nb", ":2,$sort<CR>", gives: "z\na\nb\nc")
    }

    // MARK: - Options, registers, info

    func testSetOptions() {
        let (app, state) = makeVim("abc")
        app.vimKeysForTest(":set nu<CR>")
        XCTAssertTrue(state.showLineNumbers)
        XCTAssertTrue(ConfigStore(path: configPath).current.showLineNumbers, "editor-backed options persist")
        app.vimKeysForTest(":set nonu<CR>")
        XCTAssertFalse(state.showLineNumbers)
        app.vimKeysForTest(":set nowrap ts=4<CR>")
        XCTAssertFalse(state.wordWrap)
        XCTAssertEqual(state.tabWidth, 4)
        app.vimKeysForTest(":set ic! sw=2 et<CR>")
        XCTAssertTrue(vim(app).ignoreCase)
        XCTAssertEqual(vim(app).shiftWidth, 2)
        XCTAssertTrue(vim(app).expandTab)
        app.vimKeysForTest(">>")
        XCTAssertEqual(state.document.lines[0], "  abc")
        app.vimKeysForTest(":set bogus<CR>")
        XCTAssertEqual(app.toastForTest, "E518: Unknown option: bogus")
        app.vimKeysForTest(":set ts?<CR>")
        XCTAssertEqual(app.toastForTest, "  tabstop=4")
    }

    func testRegistersAndMarksListsOpenThePanel() throws {
        let (app, _) = makeVim("abc")
        app.vimKeysForTest("\"ayy:reg<CR>")
        let panel = try XCTUnwrap(app.commandPanelForTest)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.titleForTest, "Registers")
        XCTAssertTrue(panel.rowTitlesForTest.contains("\"a"))
    }

    func testCommandHistoryAndRepeatLastEx() {
        check("a\na\na", ":s/a/b/<CR>j@:j@@", gives: "b\nb\nb")
        let (app, state) = makeVim("abc")
        app.vimKeysForTest(":s/a/x/<CR>:<Up><Esc>")
        XCTAssertEqual(text(state), "xbc")
    }

    func testCommandLineEditingKeys() {
        let (app, _) = makeVim("abc")
        app.vimKeysForTest(":foo bar<C-w>")
        XCTAssertEqual(vim(app).commandLineDisplay, ":foo ")
        app.vimKeysForTest("<C-u>")
        XCTAssertEqual(vim(app).commandLineDisplay, ":")
        app.vimKeysForTest("<BS>")
        XCTAssertEqual(vim(app).mode, .normal, "backspace on an empty line leaves")
    }

    func testCtrlRInsertsRegisterInCommandLine() {
        check("foo", "yiw:s/<C-r>\"/bar/<CR>", gives: "bar")
    }
}

import XCTest
@testable import kme

/// Mode transitions, input routing, status display, and how Vim mode sits on
/// top of the existing editor (and stays out of the way when it's off).
final class VimModeTests: VimTestCase {

    // MARK: - Modes

    func testStartsInNormalModeAndKeysDontInsert() {
        let (app, state) = makeVim("hello")
        XCTAssertEqual(vim(app).mode, .normal)
        app.vimKeysForTest("jk")
        XCTAssertEqual(text(state), "hello")
        XCTAssertFalse(state.isDirty)
    }

    func testInsertAndEscapeMovesCursorLeft() {
        let (app, state) = makeVim("")
        app.vimKeysForTest("ihello")
        XCTAssertEqual(vim(app).mode, .insert)
        XCTAssertEqual(cursor(state), [0, 5])
        app.vimKeysForTest("<Esc>")
        XCTAssertEqual(vim(app).mode, .normal)
        XCTAssertEqual(text(state), "hello")
        XCTAssertEqual(cursor(state), [0, 4])
    }

    func testEscapeThroughRawTerminalInput() {
        let (app, state) = makeVim("")
        app.processInputForTest("ihi")
        app.processInputForTest("\u{1B}")
        XCTAssertEqual(vim(app).mode, .normal)
        XCTAssertEqual(text(state), "hi")
        // A fast "<Esc>x" arriving in one read is Escape followed by x.
        app.processInputForTest("A!\u{1B}x")
        XCTAssertEqual(text(state), "hi")
    }

    func testArrowKeysStillMoveInNormalMode() {
        let (app, state) = makeVim("abc\ndef")
        app.processInputForTest("\u{1B}[C")
        app.processInputForTest("\u{1B}[B")
        XCTAssertEqual(cursor(state), [1, 1])
    }

    func testInsertEntryCommands() {
        check("abc", at: [0, 1], "aX<Esc>", gives: "abXc", cursor: [0, 2])
        check("abc", at: [0, 1], "AX<Esc>", gives: "abcX", cursor: [0, 3])
        check("   abc", at: [0, 5], "IX<Esc>", gives: "   Xabc", cursor: [0, 3])
        check("   abc", at: [0, 5], "gIX<Esc>", gives: "X   abc")
        check("a\nb", "oX<Esc>", gives: "a\nX\nb", cursor: [1, 0])
        check("a\nb", at: [1, 0], "OX<Esc>", gives: "a\nX\nb", cursor: [1, 0])
    }

    func testInsertCountRepeatsText() {
        check("", "3ia<Esc>", gives: "aaa", cursor: [0, 2])
        check("x", "2oab<Esc>", gives: "x\nab\nab")
    }

    func testVisualModesAndEscape() {
        let (app, state) = makeVim("one two\nthree")
        app.vimKeysForTest("v")
        XCTAssertEqual(vim(app).mode, .visual)
        XCTAssertNotNil(state.document.selectionOverride)
        app.vimKeysForTest("V")
        XCTAssertEqual(vim(app).mode, .visualLine)
        app.vimKeysForTest("<Esc>")
        XCTAssertEqual(vim(app).mode, .normal)
        XCTAssertNil(state.document.selectionOverride)
        XCTAssertFalse(state.document.hasSelection)
    }

    func testCommandLineModeAndCancel() {
        let (app, state) = makeVim("abc")
        app.vimKeysForTest(":wq")
        XCTAssertEqual(vim(app).mode, .commandLine)
        XCTAssertEqual(vim(app).commandLineDisplay, ":wq")
        app.vimKeysForTest("<Esc>")
        XCTAssertEqual(vim(app).mode, .normal)
        XCTAssertFalse(exited)
        XCTAssertEqual(text(state), "abc")
    }

    func testReplaceModeOverwritesAndBackspaceRestores() {
        check("abcd", "RXY<Esc>", gives: "XYcd", cursor: [0, 1])
        check("ab", "RXYZ<Esc>", gives: "XYZ")
        check("abcd", "RXY<BS><BS><Esc>", gives: "abcd")
    }

    func testCtrlOInInsertRunsOneNormalCommand() {
        let (app, state) = makeVim("abc def")
        app.vimKeysForTest("A!<C-o>0")
        XCTAssertEqual(vim(app).mode, .insert)
        app.vimKeysForTest("X<Esc>")
        XCTAssertEqual(text(state), "Xabc def!")
    }

    // MARK: - Status bar

    func testStatusBarShowsModeAndPendingKeys() {
        let (app, _) = makeVim("abc")
        func status() -> String {
            RenderTests.plain(app.renderEditorLinesForTest(width: 80, height: 12).joined(separator: "\n"))
        }
        XCTAssertTrue(status().contains("NORMAL"))
        app.vimKeysForTest("i")
        XCTAssertTrue(status().contains("INSERT"))
        app.vimKeysForTest("<Esc>v")
        XCTAssertTrue(status().contains("VISUAL"))
        app.vimKeysForTest("<Esc>V")
        XCTAssertTrue(status().contains("V-LINE"))
        app.vimKeysForTest("<Esc>2d")
        XCTAssertTrue(status().contains("2d"), "pending operator is shown")
        app.vimKeysForTest("<Esc>qa")
        XCTAssertTrue(status().contains("recording @a"))
        app.vimKeysForTest("q:set nu")
        XCTAssertTrue(status().contains(":set nu"))
    }

    // MARK: - Shortcut conflicts

    func testAppShortcutsStillWorkBetweenCommands() throws {
        let (app, state) = makeVim("abc")
        app.vimKeysForTest("x")
        XCTAssertTrue(state.isDirty)
        app.vimKeysForTest("<C-s>")
        XCTAssertFalse(state.isDirty, "Ctrl+S saves in Normal mode")
        app.vimKeysForTest("<C-p>")
        XCTAssertTrue(app.commandPanelForTest?.isVisible ?? false, "Ctrl+P opens the palette")
    }

    func testVimMeaningsWinForConflictingControlKeys() {
        let (app, state) = makeVim((1...60).map { "line \($0)" }.joined(separator: "\n"))
        app.vimKeysForTest("<C-d>")
        XCTAssertFalse(exited, "Ctrl+D scrolls in Vim, it doesn't quit")
        XCTAssertGreaterThan(state.document.cursorLine, 0)
        app.vimKeysForTest("x<C-r>")
        XCTAssertEqual(state.viewMode, .normal, "Ctrl+R is redo, not the raw-view toggle")
        app.vimKeysForTest("u<C-r>")
        XCTAssertTrue(text(state).contains("ine"))
    }

    func testCtrlDInInsertOutdentsInsteadOfQuitting() {
        let (app, state) = makeVim("\tabc")
        app.vimKeysForTest("A<C-d>")
        XCTAssertFalse(exited)
        XCTAssertEqual(state.document.lines[0], "abc")
        app.vimKeysForTest("<C-t>")
        XCTAssertEqual(state.document.lines[0], "\tabc")
    }

    func testConfigCommandOpensSettings() throws {
        let (app, _) = makeVim("abc")
        app.vimKeysForTest(":config<CR>")
        let panel = try XCTUnwrap(app.commandPanelForTest)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.titleForTest, ConfigPanel.rootTitle)
    }

    // MARK: - Markdown integration

    func testOpenLineContinuesMarkdownLists() {
        check("- item", "oitem2<Esc>", gives: "- item\n- item2")
        check("- [x] done", "onext<Esc>", gives: "- [x] done\n- [ ] next")
        check("> quote", "omore<Esc>", gives: "> quote\n> more")
    }

    func testInsertModeEnterKeepsListContinuation() {
        check("- a", "A<CR>b<Esc>", gives: "- a\n- b")
    }

    func testCursorRendersOnTheRightCharacterInsideCollapsedMarkdown() {
        let (app, state) = makeVim("a **bold** b")
        // `fo` lands on the 'o' of bold: the span expands to raw text and the
        // block cursor sits on that raw character.
        app.vimKeysForTest("fo")
        XCTAssertEqual(cursor(state), [0, 5])
        let row = app.renderContentLinesForTest(width: 40, height: 3)[0]
        XCTAssertTrue(row.contains("\(Theme.inverse)o"), "cursor drawn on 'o': \(row.debugDescription)")
        XCTAssertTrue(RenderTests.plain(row).hasPrefix("a **bold** b"))
        // Moving off the line collapses it again.
        app.vimKeysForTest("$")
        XCTAssertEqual(cursor(state), [0, 11])
    }

    func testVisualSelectionIsRenderedInclusive() {
        let (app, _) = makeVim("abcdef")
        app.vimKeysForTest("lvl")
        let row = app.renderContentLinesForTest(width: 40, height: 3)[0]
        XCTAssertTrue(row.contains("\(Theme.selectionBg)\(Theme.selectionFg)bc"),
                      "both b and c highlighted: \(row.debugDescription)")
    }

    func testDisplayLineMotionsFollowWordWrap() {
        let long = String(repeating: "word ", count: 30)
        let (app, state) = makeVim(long + "\nnext")
        _ = app.renderEditorLinesForTest(width: 40, height: 20)
        app.vimKeysForTest("gj")
        XCTAssertEqual(state.document.cursorLine, 0, "gj stays in the wrapped line")
        XCTAssertGreaterThan(state.document.cursorColumn, 20)
        app.vimKeysForTest("0j")
        XCTAssertEqual(cursor(state), [1, 0], "j moves by real lines")
    }

    func testUnicodeAwareEditing() {
        check("héllo 世界 🎉 ok", "wx", gives: "héllo 界 🎉 ok")
        check("héllo 世界 🎉 ok", "3wx", gives: "héllo 世界 🎉 k")
        check("🎉🎉x", "lx", gives: "🎉x")
        checkCursor("añb", "$", [0, 2])
    }

    func testMouseDragBecomesVisualSelection() {
        let (app, state) = makeVim("hello world")
        state.document.selectionAnchor = CursorPosition(line: 0, column: 0)
        state.document.cursorColumn = 5
        app.vimKeysForTest("d")
        XCTAssertEqual(text(state), " world", "the dragged range (inclusive) is deleted")
    }

    // MARK: - Enabling / disabling

    func testDisabledVimModeLeavesTheDefaultEditorAlone() {
        let (app, state) = makeVim("abc", vimMode: false)
        XCTAssertNil(app.vimForTest)
        app.processInputForTest("dd")
        XCTAssertEqual(state.document.lines[0], "ddabc", "keys insert text as before")
        app.processInputForTest(":q")
        XCTAssertEqual(state.document.lines[0], "dd:qabc")
        XCTAssertFalse(exited)
        let frame = RenderTests.plain(app.renderEditorLinesForTest(width: 80, height: 12).joined(separator: "\n"))
        XCTAssertFalse(frame.contains("NORMAL"))
    }

    func testTogglingVimModeAtRuntime() {
        let (app, state) = makeVim("abc", vimMode: false)
        app.changeConfig { $0.vimMode = true }
        XCTAssertNotNil(app.vimForTest)
        app.vimKeysForTest("x")
        XCTAssertEqual(text(state), "bc")
        app.changeConfig { $0.vimMode = false }
        XCTAssertNil(app.vimForTest)
        XCTAssertTrue(ConfigStore(path: configPath).current.vimMode == false, "persisted")
        app.processInputForTest("x")
        XCTAssertEqual(text(state), "xbc")
    }

    func testVimOptionsComeFromConfig() {
        let (app, _) = makeVim("abc", configExtra: #", "vim": {"ignoreCase": true, "smartCase": true}"#)
        XCTAssertTrue(vim(app).ignoreCase)
        XCTAssertTrue(vim(app).smartCase)
    }
}

import XCTest
@testable import editxr

/// Shared setup for Vim tests: a throwaway config with Vim mode on, an app
/// around one document, and helpers to type key notation and read state back.
class VimTestCase: XCTestCase {
    var dir: String!
    private var savedShared: ConfigStore!
    var exited = false

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "editxr-vim-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        savedShared = ConfigStore.shared
        exited = false
    }

    override func tearDown() {
        ConfigStore.shared = savedShared
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    var configPath: String { dir + "/config.json" }

    /// `content` opened with the cursor at (`line`, `col`).
    func makeVim(_ content: String, line: Int = 0, col: Int = 0, vimMode: Bool = true,
                 configExtra: String = "") -> (EditorApp, EditorState) {
        let json = #"{"ai": {}, "vimMode": \#(vimMode), "blockMode": false, "leftMargin": 0\#(configExtra)}"#
        try? json.write(toFile: configPath, atomically: true, encoding: .utf8)
        ConfigStore.shared = ConfigStore(path: configPath)
        let file = dir + "/doc-\(UUID().uuidString).md"
        try? content.write(toFile: file, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: file)
        let app = EditorApp(states: [state])
        app.terminate = { [weak self] in self?.exited = true }
        let l = max(0, min(line, state.document.lines.count - 1))
        state.document.cursorLine = l
        state.document.cursorColumn = min(col, state.document.lines[l].count)
        _ = app.renderEditorLinesForTest(width: 80, height: 24)
        return (app, state)
    }

    func vim(_ app: EditorApp) -> VimEngine { app.vimForTest! }

    /// The document as Vim sees it (without the trailing final-newline line).
    func text(_ state: EditorState) -> String {
        var lines = state.document.lines
        if lines.count > 1 && lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    func cursor(_ state: EditorState) -> [Int] {
        [state.document.cursorLine, state.document.cursorColumn]
    }

    /// Run `keys` on `content` and compare the resulting text and cursor.
    func check(_ content: String, at pos: [Int] = [0, 0], _ keys: String, gives expected: String,
               cursor expectedCursor: [Int]? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let (app, state) = makeVim(content, line: pos[0], col: pos[1])
        app.vimKeysForTest(keys)
        XCTAssertEqual(text(state), expected, "keys: \(keys)", file: file, line: line)
        if let c = expectedCursor {
            XCTAssertEqual(cursor(state), c, "cursor after: \(keys)", file: file, line: line)
        }
    }

    /// Run `keys` and compare only the cursor.
    func checkCursor(_ content: String, at pos: [Int] = [0, 0], _ keys: String, _ expected: [Int],
                     file: StaticString = #filePath, line: UInt = #line) {
        let (app, state) = makeVim(content, line: pos[0], col: pos[1])
        app.vimKeysForTest(keys)
        XCTAssertEqual(cursor(state), expected, "keys: \(keys)", file: file, line: line)
    }
}

import XCTest
@testable import kme

/// The unified settings UI and AI enable/disable, driven through the app's
/// real input path against a throwaway config.json.
final class ConfigPanelTests: XCTestCase {
    private var dir: String!
    private var savedShared: ConfigStore!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "kme-cfgpanel-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        savedShared = ConfigStore.shared
    }

    override func tearDown() {
        ConfigStore.shared = savedShared
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private var configPath: String { dir + "/config.json" }

    private func makeApp(configJSON: String? = nil, content: String = "hello\nworld\n") -> (EditorApp, EditorState) {
        if let json = configJSON {
            try? json.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        ConfigStore.shared = ConfigStore(path: configPath)
        let file = dir + "/doc-\(UUID().uuidString).md"
        try? content.write(toFile: file, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: file)
        return (EditorApp(states: [state]), state)
    }

    private func diskConfig() -> Config { ConfigStore(path: configPath).current }

    /// Move the selection to the row titled `title` with j presses.
    private func select(_ title: String, in panel: CommandPanel, app: EditorApp, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<40 {
            if panel.selectedTitleForTest == title { return }
            app.processInputForTest("j")
        }
        XCTFail("row \(title) not found; rows: \(panel.rowTitlesForTest)", file: file, line: line)
    }

    // MARK: - Opening

    func testPaletteSettingsEntryOpensTheConfigurationUI() throws {
        let (app, _) = makeApp()
        app.processInputForTest(String(Key.ctrlP))
        let panel = try XCTUnwrap(app.commandPanelForTest)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(app.paletteTitlesForTest().contains("Settings"))
        // Search the palette for Settings and run it.
        for ch in "settings" { app.processInputForTest(String(ch)) }
        app.processInputForTest("\r")
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.titleForTest, ConfigPanel.rootTitle)
        XCTAssertTrue(panel.keyNavigation)
        XCTAssertEqual(panel.rowTitlesForTest, ["Editor", "Appearance", "Markdown", "AI", "Vault", "Configuration"])
    }

    func testOldSettingsSubmenusAreGoneFromThePalette() {
        let (app, _) = makeApp()
        let titles = app.paletteTitlesForTest()
        for old in ["Editor settings", "LLM settings", "Theme & appearance", "Vault settings"] {
            XCTAssertFalse(titles.contains(old), "\(old) is now part of Settings")
        }
    }

    func testPaletteSearchStillFindsIndividualSettings() throws {
        let (app, _) = makeApp()
        app.processInputForTest(String(Key.ctrlP))
        for ch in "word wrap" { app.processInputForTest(String(ch)) }
        let panel = try XCTUnwrap(app.commandPanelForTest)
        XCTAssertEqual(panel.selectedTitleForTest, "Word Wrap")
    }

    // MARK: - Navigation and editing

    func testJKNavigationAndToggleAppliesAndPersists() throws {
        let (app, state) = makeApp()
        app.openConfigPanelForTest()
        let panel = try XCTUnwrap(app.commandPanelForTest)
        XCTAssertEqual(panel.selectedTitleForTest, "Editor")
        app.processInputForTest("j")
        XCTAssertEqual(panel.selectedTitleForTest, "Appearance")
        app.processInputForTest("k")
        app.processInputForTest("\r")          // into Editor
        XCTAssertEqual(panel.titleForTest, "Editor")
        select("Word Wrap", in: panel, app: app)
        XCTAssertEqual(panel.rowShortcutForTest("Word Wrap"), "[Enabled]")
        app.processInputForTest("\r")
        XCTAssertFalse(state.wordWrap, "applies immediately")
        XCTAssertFalse(diskConfig().wordWrap, "and persists")
        XCTAssertEqual(panel.rowShortcutForTest("Word Wrap"), "[Disabled]", "the row shows the new value")
        XCTAssertTrue(panel.isVisible, "toggles keep the panel open")

        // h goes back a level; Escape at the root closes.
        app.processInputForTest("h")
        XCTAssertEqual(panel.titleForTest, ConfigPanel.rootTitle)
        app.processInputForTest("\u{1B}")
        XCTAssertFalse(panel.isVisible)
    }

    func testNumericSettingValidatesInput() throws {
        let (app, state) = makeApp()
        app.openConfigPanelForTest()
        let panel = try XCTUnwrap(app.commandPanelForTest)
        app.processInputForTest("\r")          // Editor
        select("Tab Width", in: panel, app: app)
        app.processInputForTest("\r")
        XCTAssertTrue(panel.isInputForTest)
        app.processInputForTest(String(Key.ctrlU))
        for ch in "40" { app.processInputForTest(String(ch)) }
        app.processInputForTest("\r")
        XCTAssertTrue(panel.isInputForTest, "an out-of-range value is refused")
        XCTAssertEqual(panel.inputErrorForTest, "Must be between 1 and 16")
        app.processInputForTest(String(Key.backspace))
        app.processInputForTest(String(Key.backspace))
        app.processInputForTest("4")
        app.processInputForTest("\r")
        XCTAssertFalse(panel.isInputForTest)
        XCTAssertEqual(state.tabWidth, 4)
        XCTAssertEqual(diskConfig().tabWidth, 4)
        XCTAssertEqual(panel.rowShortcutForTest("Tab Width"), "[4]")
    }

    func testEnumSettingOpensOptionsAndMarksCurrent() throws {
        let (app, state) = makeApp()
        app.openConfigPanelForTest()
        let panel = try XCTUnwrap(app.commandPanelForTest)
        app.processInputForTest("\r")
        select("Sidebar", in: panel, app: app)
        XCTAssertEqual(panel.rowShortcutForTest("Sidebar"), "[Off] →")
        app.processInputForTest("\r")
        XCTAssertEqual(panel.rowShortcutForTest("Off"), "● current")
        select("Outline", in: panel, app: app)
        app.processInputForTest("\r")
        XCTAssertEqual(state.sidebarMode, .outline)
        XCTAssertEqual(panel.rowShortcutForTest("Outline"), "● current")
        app.processInputForTest("h")
        XCTAssertEqual(panel.rowShortcutForTest("Sidebar"), "[Outline] →")
        XCTAssertEqual(diskConfig().sidebar, .outline)
    }

    func testSlashSearchesWithinTheConfigPanel() throws {
        let (app, _) = makeApp()
        app.openConfigPanelForTest()
        let panel = try XCTUnwrap(app.commandPanelForTest)
        for ch in "/line num" { app.processInputForTest(String(ch)) }
        XCTAssertEqual(panel.selectedTitleForTest, "Line Numbers")
        // While searching, j/k are letters, not navigation.
        XCTAssertTrue(panel.rowTitlesForTest.contains("Line Numbers"))
        app.processInputForTest("\u{1B}")         // clears the search, panel stays
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.selectedTitleForTest, "Editor")
    }

    func testAPIKeyIsMaskedEverywhere() throws {
        let (app, _) = makeApp(configJSON: #"{"ai": {"enabled": true, "provider": "openRouter", "openRouterKey": "sk-hidden-123"}}"#)
        app.openConfigPanelForTest()
        let panel = try XCTUnwrap(app.commandPanelForTest)
        select("AI", in: panel, app: app)
        app.processInputForTest("\r")
        XCTAssertEqual(panel.rowShortcutForTest("API Key"), "[Configured]")
        let frame = app.renderEditorLinesForTest(width: 100, height: 40).joined(separator: "\n")
        XCTAssertFalse(frame.contains("sk-hidden-123"))
        select("API Key", in: panel, app: app)
        app.processInputForTest("\r")
        for ch in "sk-new" { app.processInputForTest(String(ch)) }
        let inputFrame = app.renderEditorLinesForTest(width: 100, height: 40).joined(separator: "\n")
        XCTAssertFalse(inputFrame.contains("sk-new"), "typed secrets are masked")
        app.processInputForTest("\r")
        XCTAssertEqual(diskConfig().ai.openRouterKey, "sk-new")
    }

    func testReloadFromDiskAppliesHandEdits() throws {
        let (app, state) = makeApp(configJSON: #"{"ai": {}, "tabWidth": 8}"#)
        XCTAssertEqual(state.tabWidth, 8)
        try #"{"ai": {}, "tabWidth": 2, "showLineNumbers": true}"#.write(toFile: configPath, atomically: true, encoding: .utf8)
        app.reloadConfigForTest()
        XCTAssertEqual(state.tabWidth, 2)
        XCTAssertTrue(state.showLineNumbers)
    }

    func testSavingConfigFileInATabReloadsIt() throws {
        _ = makeApp(configJSON: #"{"ai": {}, "tabWidth": 8}"#)
        let configTab = EditorState(filePath: configPath)
        let app = EditorApp(states: [configTab])
        configTab.document = Document(content: #"{"ai": {}, "tabWidth": 5}"#)
        XCTAssertTrue(configTab.save())
        XCTAssertEqual(ConfigStore.shared.current.tabWidth, 5)
        XCTAssertEqual(configTab.tabWidth, 5, "the saved file is applied straight away")
        withExtendedLifetime(app) {}
    }

    // MARK: - AI enable / disable

    func testAIDisabledByDefaultStartsNoServices() {
        let (app, _) = makeApp()
        XCTAssertFalse(app.aiServicesActiveForTest)
        XCTAssertFalse(app.paletteTitlesForTest().contains("AI assist"))
        app.processInputForTest(String(Key.ctrlSpace))
        XCTAssertFalse(app.llmModalVisibleForTest)
        XCTAssertFalse(app.aiServicesActiveForTest, "Ctrl+Space must not create a service")
        let hintBar = app.renderEditorLinesForTest(width: 100, height: 24).last ?? ""
        XCTAssertFalse(RenderTests.plain(hintBar).contains("LM Studio"))
    }

    func testTestConnectionWhileDisabledMakesNoRequest() {
        let (app, _) = makeApp()
        app.testAIConnection()
        XCTAssertFalse(app.aiServicesActiveForTest)
        XCTAssertEqual(app.toastForTest, "AI is off — enable it first")
    }

    func testEnablingAIFromSettingsStartsServicesAndKeepsCredentials() throws {
        let (app, _) = makeApp(configJSON: #"{"ai": {"enabled": false, "provider": "mock", "openRouterKey": "sk-kept"}}"#)
        XCTAssertFalse(app.aiServicesActiveForTest)
        app.openConfigPanelForTest()
        let panel = try XCTUnwrap(app.commandPanelForTest)
        select("AI", in: panel, app: app)
        app.processInputForTest("\r")
        XCTAssertEqual(panel.rowShortcutForTest("Enable AI Features"), "[Disabled]")
        app.processInputForTest("\r")          // first row: the enable toggle
        XCTAssertTrue(app.aiServicesActiveForTest)
        XCTAssertTrue(diskConfig().ai.enabled)
        XCTAssertTrue(app.paletteTitlesForTest().contains("AI assist"))

        app.processInputForTest("\r")          // and off again
        XCTAssertFalse(app.aiServicesActiveForTest, "disabling tears the services down")
        XCTAssertEqual(diskConfig().ai.openRouterKey, "sk-kept")
        XCTAssertEqual(diskConfig().ai.provider, .mock)
    }

    func testMigratedLegacyConfigKeepsAIWorking() {
        let (app, _) = makeApp(configJSON: #"{"llmProvider": "mock", "wordWrap": true, "renderMarkdown": true}"#)
        XCTAssertTrue(app.aiServicesActiveForTest)
        app.processInputForTest(String(Key.ctrlSpace))
        XCTAssertTrue(app.llmModalVisibleForTest)
    }
}

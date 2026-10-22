import XCTest
@testable import editxr

/// The palette's "Open vault" action: it appears only when a vault is
/// configured, and running it points the file-explorer sidebar at the vault
/// root (opening the vault's primary file when the active tab is elsewhere).
final class OpenVaultCommandTests: XCTestCase {

    private var savedCommandLineRoot: String?

    override func tearDown() {
        Vault.commandLineRoot = savedCommandLineRoot
        savedCommandLineRoot = nil
        super.tearDown()
    }

    /// A vault on disk plus a file outside it, so "elsewhere" is a real case.
    private func makeVault() -> (vault: String, outside: String) {
        let fm = FileManager.default
        let vault = NSTemporaryDirectory() + "editxr-openvault-\(UUID().uuidString)"
        let outside = NSTemporaryDirectory() + "editxr-outside-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: vault + "/notes", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try? "home".write(toFile: vault + "/README.md", atomically: true, encoding: .utf8)
        try? "note".write(toFile: vault + "/notes/a.md", atomically: true, encoding: .utf8)
        try? "out".write(toFile: outside + "/b.md", atomically: true, encoding: .utf8)
        if savedCommandLineRoot == nil { savedCommandLineRoot = Vault.commandLineRoot }
        Vault.commandLineRoot = vault
        return (vault, outside)
    }

    func testOpenVaultRowAppearsOnlyWhenAVaultIsConfigured() {
        let (vault, _) = makeVault()
        let state = EditorState(filePath: vault + "/README.md")
        let app = EditorApp(states: [state])
        XCTAssertTrue(app.vaultMenuTitlesForTest().contains("Open vault"))

        // The negative case depends on the machine's real config (Vault reads
        // config.vaultPath), so only assert it when nothing is configured there.
        Vault.commandLineRoot = nil
        if ConfigStore.shared.current.vaultPath == nil {
            let unconfigured = EditorApp(states: [EditorState(filePath: vault + "/README.md")])
            XCTAssertFalse(unconfigured.vaultMenuTitlesForTest().contains("Open vault"),
                           "no configured vault → no Open vault row")
        }
    }

    func testOpenVaultFromOutsideOpensThePrimaryFileAndFileSidebar() {
        let (vault, outside) = makeVault()
        let state = EditorState(filePath: outside + "/b.md")
        let app = EditorApp(states: [state])

        app.openConfiguredVaultForTest()

        XCTAssertEqual(app.activeFileForTest, vault + "/README.md",
                       "the vault's primary file is opened when the active tab is outside")
        XCTAssertEqual(app.activeSidebarModeForTest, .files)
    }

    func testOpenVaultFromInsideKeepsTheCurrentFile() {
        let (vault, _) = makeVault()
        let state = EditorState(filePath: vault + "/notes/a.md")
        let app = EditorApp(states: [state])

        app.openConfiguredVaultForTest()

        XCTAssertEqual(app.activeFileForTest, vault + "/notes/a.md",
                       "a file already inside the vault is kept")
        XCTAssertEqual(app.activeSidebarModeForTest, .files)
    }
}

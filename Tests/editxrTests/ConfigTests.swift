import XCTest
@testable import editxr

/// Config decoding/validation/migration and ConfigStore persistence. Every
/// test runs against a throwaway config.json, never the user's real one.
final class ConfigTests: XCTestCase {
    private var dir: String!
    private var path: String!
    private var savedShared: ConfigStore!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "editxr-config-\(UUID().uuidString)"
        path = dir + "/config.json"
        savedShared = ConfigStore.shared
    }

    override func tearDown() {
        ConfigStore.shared = savedShared
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func writeFile(_ json: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func readJSON() -> [String: Any] {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    // MARK: - Decoding

    func testMissingFileGivesDefaultsWithAIDisabled() {
        let store = ConfigStore(path: path)
        XCTAssertEqual(store.current, Config())
        XCTAssertFalse(store.current.ai.enabled, "new installs start with AI off")
        XCTAssertFalse(store.current.vimMode)
        XCTAssertNil(store.lastError)
    }

    func testPartialFileKeepsDefaultsForMissingKeys() {
        writeFile(#"{"ai": {"enabled": false}, "tabWidth": 4, "vimMode": true}"#)
        let store = ConfigStore(path: path)
        XCTAssertEqual(store.current.tabWidth, 4)
        XCTAssertTrue(store.current.vimMode)
        XCTAssertTrue(store.current.wordWrap, "absent keys take their defaults")
        XCTAssertTrue(store.current.renderMarkdown)
        XCTAssertEqual(store.current.scrollOff, 4)
        XCTAssertTrue(store.issues.isEmpty)
    }

    func testIntegerOneIsNotMistakenForABoolean() {
        writeFile(#"{"ai": {}, "leftMargin": 1, "wordWrap": 1}"#)
        let store = ConfigStore(path: path)
        XCTAssertEqual(store.current.leftMargin, 1)
        XCTAssertEqual(store.issues.map(\.key), ["wordWrap"], "1 is a number, not true")
    }

    func testInvalidValuesAreReportedAndReplaced() {
        writeFile(#"{"ai": {"endpoint": "localhost", "provider": "skynet"}, "tabWidth": "wide", "scrollOff": 99, "sidebar": "left", "wordWrap": "yes"}"#)
        let store = ConfigStore(path: path)
        XCTAssertEqual(store.current.tabWidth, 8)
        XCTAssertEqual(store.current.scrollOff, 20, "out-of-range numbers clamp")
        XCTAssertEqual(store.current.sidebar, .off)
        XCTAssertTrue(store.current.wordWrap)
        XCTAssertEqual(store.current.ai.endpoint, AIConfig.defaultEndpoint)
        XCTAssertEqual(store.current.ai.provider, .lmStudio)
        let keys = Set(store.issues.map(\.key))
        XCTAssertEqual(keys, ["tabWidth", "scrollOff", "sidebar", "wordWrap", "ai.endpoint", "ai.provider"])
        XCTAssertTrue(store.issues.first { $0.key == "tabWidth" }!.message.contains("expected a number"))
    }

    func testIssuesNeverEchoSecretValues() {
        writeFile(#"{"ai": {"openRouterKey": 12345678}}"#)
        let store = ConfigStore(path: path)
        XCTAssertEqual(store.issues.map(\.key), ["ai.openRouterKey"])
        XCTAssertFalse(store.issues[0].message.contains("12345678"))
    }

    // MARK: - Migration

    func testLegacyConfigMigratesAIAndKeepsItEnabled() {
        writeFile("""
        {"llmProvider": "openRouter", "openRouterKey": "sk-legacy", "openRouterModel": "m/x",
         "wordWrap": false, "renderMarkdown": true, "showOutline": true, "theme": "nord"}
        """)
        let store = ConfigStore(path: path)
        XCTAssertTrue(store.needsMigration)
        XCTAssertTrue(store.current.ai.enabled, "existing installs keep AI on")
        XCTAssertEqual(store.current.ai.provider, .openRouter)
        XCTAssertEqual(store.current.ai.openRouterKey, "sk-legacy")
        XCTAssertEqual(store.current.ai.openRouterModel, "m/x")
        XCTAssertEqual(store.current.sidebar, .outline, "legacy showOutline still maps to the sidebar")
        XCTAssertFalse(store.current.wordWrap)

        // The next save writes the new layout: ai section in, flat keys out,
        // unrelated settings untouched.
        store.update { $0.tabWidth = 2 }
        let json = readJSON()
        XCTAssertNil(json["llmProvider"])
        XCTAssertNil(json["openRouterKey"])
        XCTAssertNil(json["showOutline"])
        let ai = json["ai"] as? [String: Any]
        XCTAssertEqual(ai?["provider"] as? String, "openRouter")
        XCTAssertEqual(ai?["openRouterKey"] as? String, "sk-legacy")
        XCTAssertEqual(ai?["enabled"] as? Bool, true)
        XCTAssertEqual(json["theme"] as? String, "nord")
        XCTAssertEqual(json["wordWrap"] as? Bool, false)
        XCTAssertFalse(ConfigStore(path: path).needsMigration)
    }

    func testMigratedFileWithAIOffStaysOff() {
        writeFile(#"{"ai": {"enabled": false, "provider": "mock"}, "llmProvider": "openRouter"}"#)
        let store = ConfigStore(path: path)
        XCTAssertFalse(store.current.ai.enabled)
        XCTAssertEqual(store.current.ai.provider, .mock, "the ai section wins over stale flat keys")
    }

    // MARK: - Persistence

    func testSavePreservesUnknownKeys() {
        writeFile(#"{"ai": {"enabled": true, "futureKnob": 3}, "myPlugin": {"x": 1}, "tabWidth": 4}"#)
        let store = ConfigStore(path: path)
        store.update { $0.wordWrap = false }
        let json = readJSON()
        XCTAssertEqual((json["myPlugin"] as? [String: Any])?["x"] as? Int, 1)
        XCTAssertEqual((json["ai"] as? [String: Any])?["futureKnob"] as? Int, 3)
        XCTAssertEqual(json["tabWidth"] as? Int, 4)
        XCTAssertEqual(json["wordWrap"] as? Bool, false)
    }

    func testUpdateIsAPatchThatKeepsExternalEdits() {
        let store = ConfigStore(path: path)
        store.update { $0.tabWidth = 4 }
        // Someone edits the file by hand while the editor runs.
        var json = readJSON()
        json["scrollOff"] = 7
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: URL(fileURLWithPath: path))

        store.update { $0.showLineNumbers = true }
        let after = readJSON()
        XCTAssertEqual(after["scrollOff"] as? Int, 7, "the hand edit survives")
        XCTAssertEqual(after["showLineNumbers"] as? Bool, true)
        XCTAssertEqual(after["tabWidth"] as? Int, 4)
        XCTAssertEqual(store.current.scrollOff, 7)
    }

    func testInvalidJSONIsNeverOverwritten() {
        let broken = #"{"tabWidth": 4,,}"#
        writeFile(broken)
        let store = ConfigStore(path: path)
        XCTAssertNotNil(store.lastError)
        let saved = store.update { $0.wordWrap = false }
        XCTAssertFalse(saved)
        XCTAssertFalse(store.current.wordWrap, "the change still applies for the session")
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), broken)
        guard case .invalidJSON = store.lastError else { return XCTFail("expected invalidJSON") }
    }

    func testReloadPicksUpExternalChanges() {
        let store = ConfigStore(path: path)
        store.update { $0.tabWidth = 4 }
        XCTAssertFalse(store.hasChangedOnDisk)
        writeFile(#"{"ai": {"enabled": true}, "tabWidth": 2, "vimMode": true}"#)
        XCTAssertTrue(store.hasChangedOnDisk)
        XCTAssertTrue(store.reload())
        XCTAssertEqual(store.current.tabWidth, 2)
        XCTAssertTrue(store.current.vimMode)
        XCTAssertTrue(store.current.ai.enabled)
        XCTAssertFalse(store.hasChangedOnDisk)
    }

    func testFailedReloadKeepsPreviousSettings() {
        let store = ConfigStore(path: path)
        store.update { $0.tabWidth = 4 }
        writeFile("not json")
        XCTAssertFalse(store.reload())
        XCTAssertEqual(store.current.tabWidth, 4)
        XCTAssertNotNil(store.lastError)
    }

#if !os(Windows)
    func testNewConfigIsOwnerOnlyAndExistingPermissionsArePreserved() throws {
        let store = ConfigStore(path: path)
        store.update { $0.tabWidth = 4 }
        var perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        store.update { $0.tabWidth = 2 }
        perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o640)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "atomic write cleans up its temp file")
    }
#endif

    func testResetKeepsCredentials() {
        let store = ConfigStore(path: path)
        store.update {
            $0.tabWidth = 3
            $0.vimMode = true
            $0.ai.enabled = true
            $0.ai.openRouterKey = "sk-keep"
        }
        store.resetToDefaults()
        XCTAssertEqual(store.current.tabWidth, 8)
        XCTAssertFalse(store.current.vimMode)
        XCTAssertFalse(store.current.ai.enabled)
        XCTAssertEqual(store.current.ai.openRouterKey, "sk-keep")
    }

    func testDescriptionRedactsSecrets() {
        var config = Config()
        config.ai.openRouterKey = "sk-very-secret"
        config.ai.openAIAccessToken = "tok-secret"
        let text = "\(config) \(String(reflecting: config))"
        XCTAssertFalse(text.contains("sk-very-secret"))
        XCTAssertFalse(text.contains("tok-secret"))
        XCTAssertTrue(text.contains("<redacted>"))
    }

    func testEncodeDecodeRoundTrip() throws {
        var config = Config()
        config.vimMode = true
        config.sidebar = .files
        config.theme = "nord"
        config.ai.enabled = true
        config.ai.provider = .openRouter
        config.ai.endpoint = "http://10.0.0.2:8080"
        config.vim.smartCase = true
        let decoded = try ConfigCodec.decode(ConfigCodec.encode(config))
        XCTAssertEqual(decoded.config, config)
        XCTAssertTrue(decoded.issues.isEmpty)
    }
}

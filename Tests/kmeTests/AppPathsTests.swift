import XCTest
@testable import kme

/// The config directory moved from ~/.config/editxr to ~/.config/kme with the
/// rename; the first run copies the old one across.
final class AppPathsTests: XCTestCase {

    private var home: String!

    override func setUpWithError() throws {
        home = (NSTemporaryDirectory() as NSString).appendingPathComponent("kme-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    func testConfigLivesUnderKme() {
        XCTAssertEqual(AppPaths.configDirectory(home: "/h"), "/h/.config/kme")
        XCTAssertEqual(AppPaths.legacyConfigDirectory(home: "/h"), "/h/.config/editxr")
    }

    func testMigrationCopiesLegacyDirectoryAndKeepsIt() throws {
        let legacy = AppPaths.legacyConfigDirectory(home: home)
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        try #"{"vimMode": true}"#.write(toFile: "\(legacy)/config.json", atomically: true, encoding: .utf8)
        try "{}".write(toFile: "\(legacy)/positions.json", atomically: true, encoding: .utf8)

        XCTAssertTrue(AppPaths.migrateLegacyConfigDirectory(home: home))

        let target = AppPaths.configDirectory(home: home)
        XCTAssertEqual(try String(contentsOfFile: "\(target)/config.json", encoding: .utf8), #"{"vimMode": true}"#)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(target)/positions.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(legacy)/config.json"), "the old directory stays for editxr")
    }

    func testMigrationNeverTouchesAnExistingKmeDirectory() throws {
        let legacy = AppPaths.legacyConfigDirectory(home: home)
        let target = AppPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try "old".write(toFile: "\(legacy)/config.json", atomically: true, encoding: .utf8)
        try "new".write(toFile: "\(target)/config.json", atomically: true, encoding: .utf8)

        XCTAssertFalse(AppPaths.migrateLegacyConfigDirectory(home: home))
        XCTAssertEqual(try String(contentsOfFile: "\(target)/config.json", encoding: .utf8), "new")
    }

    func testMigrationWithoutLegacyDirectoryDoesNothing() {
        XCTAssertFalse(AppPaths.migrateLegacyConfigDirectory(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.configDirectory(home: home)))
    }
}

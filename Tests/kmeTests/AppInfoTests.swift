import XCTest
@testable import kme

final class AppInfoTests: XCTestCase {
    func testTaskTabFixReleaseIdentity() {
        XCTAssertEqual(AppInfo.version, "1.9.0")
        XCTAssertTrue(AppInfo.helpText.hasPrefix("kme 1.9.0 —"))
    }

    func testHelpDocumentsBareVault() {
        XCTAssertTrue(AppInfo.helpText.contains("--vault         Open the configured vault"),
                      "the bare --vault form must be discoverable in the help")
    }
}

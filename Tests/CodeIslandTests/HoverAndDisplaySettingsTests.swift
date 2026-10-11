import XCTest
@testable import CodeIsland
import CodeIslandCore

final class HoverAndDisplaySettingsTests: XCTestCase {
    // MARK: - Content font size

    func testContentFontSizeGoesUpTo16pt() {
        XCTAssertEqual(ContentFontSize.choices.first, 10)
        XCTAssertEqual(ContentFontSize.choices.last, 16)
        XCTAssertEqual(ContentFontSize.choices, Array(10...16), "every step is selectable")
        XCTAssertTrue(ContentFontSize.choices.contains(SettingsDefaults.contentFontSize))
    }
}

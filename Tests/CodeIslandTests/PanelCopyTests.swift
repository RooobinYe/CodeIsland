import XCTest
@testable import CodeIsland

/// Names and tooltips that explain the panel's terse controls.
final class PanelCopyTests: XCTestCase {
    func testAboutPageCountsTheIntegrationsInsteadOfHardcodingThem() {
        // It said "Supports 11 CLI/IDE tools" long after there were 30+.
        XCTAssertGreaterThanOrEqual(ConfigInstaller.builtInIntegrationCount, 30)
        for (lang, table) in L10n.strings {
            let text = table["about_desc2"] ?? ""
            XCTAssertTrue(text.contains("%d"), "\(lang) about_desc2 has no count placeholder: \(text)")
            XCTAssertFalse(text.contains("11"), "\(lang) about_desc2 still hardcodes a count: \(text)")
        }
    }

}

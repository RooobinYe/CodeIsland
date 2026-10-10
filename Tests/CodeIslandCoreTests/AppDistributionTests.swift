import XCTest
@testable import CodeIslandCore

final class AppDistributionTests: XCTestCase {
    // MARK: - Release notes link

    func testReleaseNotesPointAtTheVersionTag() {
        XCTAssertEqual(
            ReleaseNotesLink.url(forVersion: "1.0.34").absoluteString,
            "https://github.com/wxtsky/CodeIsland/releases/tag/v1.0.34"
        )
    }

    func testAlreadyPrefixedOrPaddedVersionsAreNotDoublePrefixed() {
        XCTAssertEqual(
            ReleaseNotesLink.url(forVersion: " v1.0.34\n").absoluteString,
            "https://github.com/wxtsky/CodeIsland/releases/tag/v1.0.34"
        )
    }

    func testPrereleaseSuffixIsKept() {
        XCTAssertEqual(
            ReleaseNotesLink.url(forVersion: "1.1.0-beta.2").absoluteString,
            "https://github.com/wxtsky/CodeIsland/releases/tag/v1.1.0-beta.2"
        )
    }

    func testUnusableVersionFallsBackToTheReleaseList() {
        for bad in ["", "   ", "dev build", "../../evil", "1.0/2"] {
            XCTAssertEqual(
                ReleaseNotesLink.url(forVersion: bad).absoluteString,
                "https://github.com/wxtsky/CodeIsland/releases",
                "\"\(bad)\""
            )
        }
    }

}

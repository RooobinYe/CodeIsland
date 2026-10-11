import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// hideWhenNoSession hides the island while nothing runs; the session list
/// can still be summoned explicitly and hides again once it collapses.
@MainActor
final class AppStateSummonTests: XCTestCase {
    private var savedHide: Any?

    override func setUp() {
        super.setUp()
        savedHide = UserDefaults.standard.object(forKey: SettingsKey.hideWhenNoSession)
        UserDefaults.standard.set(true, forKey: SettingsKey.hideWhenNoSession)
    }

    override func tearDown() {
        if let savedHide {
            UserDefaults.standard.set(savedHide, forKey: SettingsKey.hideWhenNoSession)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.hideWhenNoSession)
        }
        super.tearDown()
    }

    private func idleSession(_ appState: AppState, id: String) throws {
        for name in ["UserPromptSubmit", "Stop"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": name,
                "session_id": id,
                "_source": "claude",
                "cwd": NSTemporaryDirectory(),
            ])
            appState.handleEvent(try XCTUnwrap(HookEvent(from: data)))
        }
        XCTAssertNotNil(appState.sessions[id])
        XCTAssertEqual(appState.activeSessionCount, 0)
    }

    func testAutoHiddenOnlyWithSettingOnAndNothingActive() {
        let appState = AppState()
        XCTAssertTrue(appState.isAutoHidden(hideWhenNoSession: true))
        XCTAssertFalse(appState.isAutoHidden(hideWhenNoSession: false))
    }

    func testSummonWithoutSessionsDoesNothing() {
        let appState = AppState()
        appState.toggleSessionList()
        XCTAssertFalse(appState.isSummoned)
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertTrue(appState.isAutoHidden(hideWhenNoSession: true))
    }

    func testSummonShowsPastSessionsAndHidesAgainAfterCollapse() async throws {
        let appState = AppState()
        try idleSession(appState, id: "s-past")

        appState.toggleSessionList()
        XCTAssertTrue(appState.isSummoned)
        XCTAssertEqual(appState.surface, .sessionList)
        XCTAssertFalse(appState.isAutoHidden(hideWhenNoSession: true))

        XCTAssertFalse(appState.hidesCollapsedBar(hideWhenNoSession: true))

        appState.toggleSessionList()
        XCTAssertEqual(appState.surface, .collapsed)
        // Stays visible through the close animation, then hides — shrinking
        // into the notch rather than onto the collapsed bar.
        XCTAssertTrue(appState.isSummoned)
        XCTAssertTrue(appState.hidesCollapsedBar(hideWhenNoSession: true))
        for _ in 0..<200 where appState.isSummoned {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(appState.isSummoned)
        XCTAssertTrue(appState.isAutoHidden(hideWhenNoSession: true))
    }

    func testReopeningDuringCloseKeepsSummon() async throws {
        let appState = AppState()
        try idleSession(appState, id: "s-past")

        appState.toggleSessionList()
        appState.toggleSessionList()
        appState.toggleSessionList()
        try await Task.sleep(for: .seconds(NotchAnimationMetrics.closeResponse + 0.3))
        XCTAssertTrue(appState.isSummoned)
        XCTAssertEqual(appState.surface, .sessionList)
    }
}

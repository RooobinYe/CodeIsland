import XCTest
@testable import CodeIsland
import CodeIslandCore

/// What sound a hook event produces is a decision of its own — not the same
/// question as "should a card open" — and until #312 nothing in the app could
/// assert it. These are the cases that were previously only readable, not
/// checkable.
@MainActor
final class SoundBehaviourTests: XCTestCase {
    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.soundEnabled,
        SettingsKey.soundApprovalNeeded,
        SettingsKey.soundSessionStart,
        SettingsKey.quietHoursEnabled,
        SettingsKey.quietHoursStart,
        SettingsKey.quietHoursEnd,
        SettingsKey.smartSuppress,
    ]

    override func setUp() {
        super.setUp()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in
            self?.played.append(name)
        }
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundApprovalNeeded)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        for key in watchedKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    // MARK: - Blocked sessions

    /// The chime marks a session becoming blocked. A replay of the same
    /// request (or a second one while it still waits) is no new interruption.
    func testASessionChimesOnceWhenItBecomesBlocked() throws {
        let appState = AppState()
        appState.handleBlockingRequest(try makePermissionEvent(sessionId: "snd-once"), status: .waitingApproval)
        appState.handleBlockingRequest(try makePermissionEvent(sessionId: "snd-once"), status: .waitingApproval)
        XCTAssertEqual(played, ["8bit_approval"])
    }

    func testEachBlockedSessionChimes() throws {
        let appState = AppState()
        for index in 0..<2 {
            appState.handleBlockingRequest(try makePermissionEvent(sessionId: "snd-\(index)"), status: .waitingApproval)
        }
        XCTAssertEqual(played, ["8bit_approval", "8bit_approval"])
    }

    /// Nothing opens for a blocked session: the sound and the collapsed bar's
    /// bell are the signal.
    func testBlockedSessionChimesWithoutOpeningAnything() throws {
        let appState = AppState()
        appState.handleBlockingRequest(try makePermissionEvent(sessionId: "snd-collapsed"), status: .waitingApproval)
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(played, ["8bit_approval"])
    }

    // MARK: - Gates

    func testMasterToggleOffSilencesEverything() {
        UserDefaults.standard.set(false, forKey: SettingsKey.soundEnabled)
        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, [])
    }

    func testPerEventToggleOffSilencesOnlyThatEvent() {
        UserDefaults.standard.set(false, forKey: SettingsKey.soundApprovalNeeded)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundSessionStart)

        SoundManager.shared.handleEvent("PermissionRequest")
        SoundManager.shared.handleEvent("SessionStart")

        XCTAssertEqual(played, ["8bit_start"])
    }

    func testQuietHoursSilenceEventSounds() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        UserDefaults.standard.set(true, forKey: SettingsKey.quietHoursEnabled)
        // A window that certainly contains "now", written so it never spans midnight.
        UserDefaults.standard.set(0, forKey: SettingsKey.quietHoursStart)
        UserDefaults.standard.set(min(now + 1, 24 * 60), forKey: SettingsKey.quietHoursEnd)

        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, [])
    }

    func testUnknownEventNameProducesNoSound() {
        SoundManager.shared.handleEvent("SomethingElse")
        XCTAssertEqual(played, [])
    }

    // MARK: - Helpers

    private func makePermissionEvent(sessionId: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": ["command": "echo hi"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}

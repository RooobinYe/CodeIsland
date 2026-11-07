import XCTest
@testable import CodeIslandCore

final class BackgroundCompactionTests: XCTestCase {
    private let sessionId = "452f068b-2c7a-44ab-b293-eaf2548c659f"

    /// Claude Desktop compacting a session an hour after its last turn ended:
    /// PreCompact (auto), then the summarizer's SubagentStop, and no Stop.
    func testAutoCompactionOfAnIdleSessionLeavesItIdle() throws {
        var finished = SessionSnapshot()
        finished.status = .idle
        finished.lastAssistantMessage = "Done."
        var sessions = [sessionId: finished]

        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "PreCompact",
            "session_id": sessionId,
            "trigger": "auto",
            "custom_instructions": NSNull(),
        ]), maxHistory: 10)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        XCTAssertNil(sessions[sessionId]?.toolDescription)

        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "SubagentStop",
            "session_id": sessionId,
            "agent_id": "aa39254381063f8a1",
            "agent_type": "",
            "last_assistant_message": "<analysis>summary</analysis>",
        ]), maxHistory: 10)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        XCTAssertEqual(sessions[sessionId]?.lastAssistantMessage, "Done.")
    }

    func testAutoCompactionDuringATurnStillShowsCompacting() throws {
        var working = SessionSnapshot()
        working.status = .running
        var sessions = [sessionId: working]

        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "PreCompact",
            "session_id": sessionId,
            "trigger": "auto",
        ]), maxHistory: 10)
        XCTAssertEqual(sessions[sessionId]?.status, .processing)
        XCTAssertEqual(sessions[sessionId]?.toolDescription, "Compacting context\u{2026}")
    }

    /// `/compact` typed while idle: the user asked for it, and the
    /// SessionStart (`source: compact`) that follows settles the card.
    func testManualCompactionOfAnIdleSessionShowsCompacting() throws {
        var sessions = [sessionId: SessionSnapshot()]

        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "PreCompact",
            "session_id": sessionId,
            "trigger": "manual",
        ]), maxHistory: 10)
        XCTAssertEqual(sessions[sessionId]?.status, .processing)
    }

    func testOnlyHousekeepingIsKeptFromMintingACard() throws {
        XCTAssertTrue(BackgroundCompaction.isHousekeepingWithoutCard(try decode([
            "hook_event_name": "PreCompact", "session_id": sessionId, "trigger": "auto",
        ])))
        XCTAssertTrue(BackgroundCompaction.isHousekeepingWithoutCard(try decode([
            "hook_event_name": "SubagentStop", "session_id": sessionId, "agent_id": "a1",
        ])))
        XCTAssertFalse(BackgroundCompaction.isHousekeepingWithoutCard(try decode([
            "hook_event_name": "PreCompact", "session_id": sessionId, "trigger": "manual",
        ])))
        for name in ["UserPromptSubmit", "PreToolUse", "Stop", "SessionStart"] {
            XCTAssertFalse(BackgroundCompaction.isHousekeepingWithoutCard(try decode([
                "hook_event_name": name, "session_id": sessionId,
            ])), name)
        }
    }

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "BackgroundCompactionTests", code: 1)
        }
        return event
    }
}

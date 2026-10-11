import XCTest
@testable import CodeIslandCore

/// The transcript-derived model label: parsing, the byte-probe gate, and how
/// snapshots absorb it.
final class SessionTranscriptMetadataTests: XCTestCase {

    // MARK: - Fixtures (shapes copied from real CLI 2.1.26x transcripts)

    private func systemLine(subtype: String) -> String {
        #"{"parentUuid":"p1","isSidechain":false,"type":"system","subtype":"\#(subtype)","durationMs":1234,"timestamp":"2026-09-12T03:30:00.000Z","uuid":"u2","isMeta":false}"#
    }

    private func userLine(_ text: String) -> String {
        #"{"parentUuid":"p1","isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u3","timestamp":"2026-09-12T03:40:00.000Z"}"#
    }

    private func assistantLine(
        model: String,
        effort: String? = nil,
        perTurnEffort: String? = nil,
        sidechain: Bool = false,
        text: String = "done"
    ) -> String {
        var tail = ""
        if let effort { tail += #","effort":"\#(effort)""# }
        if let perTurnEffort { tail += #","perTurnEffort":"\#(perTurnEffort)""# }
        return #"{"parentUuid":"p1","isSidechain":\#(sidechain),"message":{"model":"\#(model)","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}]},"type":"assistant","uuid":"u4"\#(tail)}"#
    }

    private func turnContextLine(model: String, effort: String) -> String {
        #"{"timestamp":"2026-09-24T09:05:19.777Z","ordinal":130,"type":"turn_context","payload":{"turn_id":"t1","cwd":"/repo","approval_policy":"never","model":"\#(model)","collaboration_mode":{"mode":"default","settings":{"model":"\#(model)","reasoning_effort":"\#(effort)"}},"effort":"\#(effort)","summary":"auto"}}"#
    }

    private func scan(_ lines: [String]) -> JSONLTailer.ScanResult.Delta {
        JSONLTailer.scanLines(Data((lines.joined(separator: "\n") + "\n").utf8)).delta
    }

    // MARK: - Byte probe

    func testProbeSkipsSystemRows() {
        for subtype in ["away_summary", "turn_duration", "stop_hook_summary", "compact_boundary", "local_command"] {
            XCTAssertEqual(
                JSONLTailer.quickTypeProbe(lineBytes: Data(systemLine(subtype: subtype).utf8)),
                .irrelevant,
                subtype
            )
        }
    }

    func testProbeLetsCodexTurnContextThrough() {
        XCTAssertEqual(
            JSONLTailer.quickTypeProbe(lineBytes: Data(turnContextLine(model: "gpt-5.6-sol", effort: "max").utf8)),
            .codexTurnContext
        )
    }

    // MARK: - scanLines: slash commands

    // Slash-command rows as CLI 2.1.2xx writes them: plain user rows, isMeta false.
    private let modelCommandLine = #"{"parentUuid":"p1","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args></command-args>"},"uuid":"u5","timestamp":"2026-09-12T03:41:00.000Z"}"#
    private let modelOutputLine = #"{"parentUuid":"u5","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to `Opus 5 (1M context) (default)` and saved as your default for new sessions</local-command-stdout>"},"uuid":"u6","timestamp":"2026-09-12T03:41:00.100Z"}"#
    private let skillCommandLine = #"{"parentUuid":"p1","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-message>design</command-message>\n<command-name>/design</command-name>\n<command-args>tidy the settings layout</command-args>"},"uuid":"u7","timestamp":"2026-09-12T03:42:00.000Z"}"#

    func testLocalSlashCommandsDoNotBecomeThePrompt() {
        let delta = scan([modelCommandLine, modelOutputLine])
        XCTAssertNil(delta.lastUserPrompt)
    }

    func testAPromptCommandStartsATurnAndReadsAsTyped() {
        let delta = scan([skillCommandLine])
        XCTAssertEqual(delta.lastUserPrompt, "/design tidy the settings layout")
    }

    func testCommandEchoClassification() {
        XCTAssertEqual(JSONLTailer.claudeCommandEcho("<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args>high</command-args>"), .local)
        XCTAssertEqual(JSONLTailer.claudeCommandEcho("<local-command-stderr>Error: nope</local-command-stderr>"), .local)
        XCTAssertEqual(JSONLTailer.claudeCommandEcho("<command-message>review</command-message>\n<command-name>review</command-name>"), .prompt("/review"))
        XCTAssertNil(JSONLTailer.claudeCommandEcho("<pasted_content id=\"1\">x</pasted_content> what is this?"))
        XCTAssertNil(JSONLTailer.claudeCommandEcho("fix the <command-name> parser"))
    }

    // MARK: - scanLines: model observation

    func testClaudeAssistantLineYieldsModelAndEffort() {
        let delta = scan([assistantLine(model: "claude-opus-5-5", effort: "xhigh")])
        XCTAssertEqual(delta.modelObservation, ModelObservation(model: "claude-opus-5-5", effort: "xhigh"))
    }

    func testPerTurnEffortWinsOverSessionEffort() {
        let delta = scan([assistantLine(model: "claude-opus-5-5", effort: "xhigh", perTurnEffort: "max")])
        XCTAssertEqual(delta.modelObservation?.effort, "max")
    }

    func testNewestAssistantLineWinsAndClearsStaleEffort() {
        let delta = scan([
            assistantLine(model: "claude-opus-5-5", effort: "xhigh"),
            assistantLine(model: "claude-haiku-4-5-20251001"),
        ])
        XCTAssertEqual(delta.modelObservation, ModelObservation(model: "claude-haiku-4-5-20251001", effort: nil))
    }

    func testSidechainAndSyntheticLinesDoNotRelabelTheSession() {
        let delta = scan([
            assistantLine(model: "claude-opus-5-5", effort: "xhigh"),
            assistantLine(model: "claude-haiku-4-5-20251001", effort: "low", sidechain: true),
            assistantLine(model: "<synthetic>", text: "API Error"),
        ])
        XCTAssertEqual(delta.modelObservation, ModelObservation(model: "claude-opus-5-5", effort: "xhigh"))
    }

    func testCodexTurnContextYieldsModelAndEffort() {
        let delta = scan([turnContextLine(model: "gpt-5.6-sol", effort: "max")])
        XCTAssertEqual(delta.modelObservation, ModelObservation(model: "gpt-5.6-sol", effort: "max"))
        XCTAssertFalse(delta.hasActivity)
        XCTAssertNil(delta.turnStatus)
    }

    func testCodexTurnContextFallsBackToCollaborationSettings() {
        let line = #"{"timestamp":"t","type":"turn_context","payload":{"cwd":"/r","collaboration_mode":{"mode":"default","settings":{"model":"gpt-6-astra","reasoning_effort":"high"}}}}"#
        XCTAssertEqual(scan([line]).modelObservation, ModelObservation(model: "gpt-6-astra", effort: "high"))
    }

    // MARK: - Snapshot: live tail semantics

    private func delta(model: ModelObservation? = nil) -> ConversationTailDelta {
        ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            modelObservation: model
        )
    }

    func testLiveModelIsAdoptedWithoutTouchingLastActivity() {
        let lastActivity = Date(timeIntervalSince1970: 1_000)
        var session = SessionSnapshot()
        session.lastActivity = lastActivity
        let model = ModelObservation(model: "claude-opus-5-5", effort: "xhigh")

        XCTAssertTrue(session.applyTranscriptMetadata(from: delta(model: model)))
        XCTAssertEqual(session.lastActivity, lastActivity)
        XCTAssertFalse(session.applyTranscriptMetadata(from: delta(model: model)), "unchanged model is a no-op")
        XCTAssertFalse(session.applyTranscriptMetadata(from: delta(model: nil)))
    }

    func testLiveModelKeepsTheContextVariantAndTracksEffort() {
        var session = SessionSnapshot()
        session.model = "claude-opus-5-5[1m]"
        XCTAssertTrue(session.applyTranscriptMetadata(
            from: delta(model: ModelObservation(model: "claude-opus-5-5", effort: "xhigh"))
        ))
        XCTAssertEqual(session.model, "claude-opus-5-5[1m]")
        XCTAssertEqual(session.reasoningEffort, "xhigh")
        XCTAssertEqual(session.modelLabel, "Opus 5.5 1M · xhigh")

        XCTAssertTrue(session.applyTranscriptMetadata(
            from: delta(model: ModelObservation(model: "claude-sonnet-5", effort: nil))
        ))
        XCTAssertEqual(session.model, "claude-sonnet-5")
        XCTAssertNil(session.reasoningEffort, "a model without effort must not inherit the old one")
    }

    // MARK: - Snapshot: attach-time backfill

    private func timedAssistantLine(model: String, effort: String, at timestamp: String) -> String {
        #"{"parentUuid":"p1","isSidechain":false,"message":{"model":"\#(model)","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}]},"type":"assistant","uuid":"u4","timestamp":"\#(timestamp)","effort":"\#(effort)"}"#
    }

    func testBackfillKeepsAModelAHookReportedAfterTheScannedLines() throws {
        // `claude --resume --model sonnet` over a transcript that ran on Opus:
        // SessionStart reported the new model before the attach scan.
        var session = SessionSnapshot()
        session.model = "claude-sonnet-5"
        session.modelReportedAt = try XCTUnwrap(TranscriptTimestamp.parse("2026-09-12T04:00:00.000Z"))

        let older = scan([timedAssistantLine(model: "claude-opus-5-5", effort: "xhigh", at: "2026-09-12T03:59:00.000Z")])
        XCTAssertFalse(session.applyTranscriptBackfill(older))
        XCTAssertEqual(session.model, "claude-sonnet-5")
        XCTAssertNil(session.reasoningEffort, "Opus's effort does not describe Sonnet")

        // An older line on the same model still lends its effort.
        let sameModel = scan([timedAssistantLine(model: "claude-sonnet-5", effort: "high", at: "2026-09-12T03:58:00.000Z")])
        XCTAssertTrue(session.applyTranscriptBackfill(sameModel))
        XCTAssertEqual(session.modelLabel, "Sonnet 5 · high")

        // A line written after the report is newer than it.
        let newer = scan([timedAssistantLine(model: "claude-opus-5-5", effort: "max", at: "2026-09-12T04:01:00.000Z")])
        XCTAssertTrue(session.applyTranscriptBackfill(newer))
        XCTAssertEqual(session.modelLabel, "Opus 5.5 · max")
    }

    func testBackfillOfARestoredSessionTakesTheTranscriptModel() {
        // Persisted model, no hook report since the relaunch: /model may have
        // switched while CodeIsland wasn't running.
        var session = SessionSnapshot()
        session.model = "claude-sonnet-5"
        let delta = scan([timedAssistantLine(model: "claude-opus-5-5", effort: "xhigh", at: "2026-09-12T03:59:00.000Z")])
        XCTAssertTrue(session.applyTranscriptBackfill(delta))
        XCTAssertEqual(session.modelLabel, "Opus 5.5 · xhigh")
    }

    func testSessionStartHookRecordsWhenItReportedTheModel() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let before = Date()
        _ = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "SessionStart", "session_id": "s1", "source": "resume",
            "model": "claude-sonnet-5", "cwd": "/repo",
        ]), maxHistory: 10)
        XCTAssertEqual(sessions["s1"]?.model, "claude-sonnet-5")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sessions["s1"]?.modelReportedAt), before)
    }

    func testModelSwitchOutputSetsThe1MVariant() {
        let on = scan([assistantLine(model: "claude-opus-5-5", effort: "xhigh"), modelCommandLine, modelOutputLine])
        XCTAssertEqual(on.configuredLongContext, true)
        XCTAssertNil(on.modelObservation, "a model seen before the switch is out of date")

        let offOutput = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to \u001b[1mOpus 5.5\u001b[22m and saved as your default for new sessions</local-command-stdout>"}}"#
        XCTAssertEqual(scan([offOutput]).configuredLongContext, false, "ANSI bold is not a [1m] tag")
        XCTAssertNil(scan([#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set effort level to high</local-command-stdout>"}}"#]).configuredLongContext)
    }

    func testSwitchingToAndFromThe1MVariantRelabelsTheSession() {
        var session = SessionSnapshot()
        session.model = "claude-opus-5-5"
        func live(longContext: Bool? = nil, model: String? = nil) -> ConversationTailDelta {
            ConversationTailDelta(
                sessionId: "s1", lastUserPrompt: nil, lastAssistantMessage: nil,
                modelObservation: model.map { ModelObservation(model: $0, effort: "xhigh") },
                configuredLongContext: longContext
            )
        }
        XCTAssertTrue(session.applyTranscriptMetadata(from: live(longContext: true)))
        XCTAssertEqual(session.modelLabel, "Opus 5.5 1M")
        _ = session.applyTranscriptMetadata(from: live(model: "claude-opus-5-5"))
        XCTAssertEqual(session.modelLabel, "Opus 5.5 1M · xhigh", "the bare API id keeps the 1M variant")

        XCTAssertTrue(session.applyTranscriptMetadata(from: live(longContext: false)))
        XCTAssertEqual(session.modelLabel, "Opus 5.5 · xhigh")
        _ = session.applyTranscriptMetadata(from: live(model: "claude-opus-5-5"))
        XCTAssertEqual(session.modelLabel, "Opus 5.5 · xhigh", "and loses it once switched off")

        // Switching model and variant at once: the next line names the model.
        session.model = "claude-sonnet-5"
        _ = session.applyTranscriptMetadata(from: live(longContext: true))
        _ = session.applyTranscriptMetadata(from: live(model: "claude-opus-5"))
        XCTAssertEqual(session.model, "claude-opus-5[1m]")
    }

    // MARK: - Reducer

    private func hookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    // MARK: - Subagent models

    func testCodexChildKeepsItsOwnModelAndNeverTheParents() throws {
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.model = "gpt-5.6-sol"
        var sessions = ["parent": parent]

        _ = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "SessionStart", "session_id": "parent", "_source": "codex",
            "agent_id": "child", "agent_type": "worker", "model": "gpt-5.4-mini",
        ]), maxHistory: 10)
        XCTAssertEqual(sessions["parent"]?.subagents["child"]?.model, "gpt-5.4-mini")
        XCTAssertEqual(sessions["parent"]?.model, "gpt-5.6-sol")

        // Later child hooks without a model leave it alone.
        _ = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "PreToolUse", "session_id": "parent", "_source": "codex",
            "agent_id": "child", "tool_name": "Bash", "tool_input": ["command": "ls"],
        ]), maxHistory: 10)
        XCTAssertEqual(sessions["parent"]?.subagents["child"]?.model, "gpt-5.4-mini")
    }

    func testClaudeSubagentWithoutModelStaysUnlabeled() throws {
        var parent = SessionSnapshot()
        parent.model = "claude-opus-5-5"
        parent.reasoningEffort = "xhigh"
        var sessions = ["parent": parent]

        _ = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "SubagentStart", "session_id": "parent",
            "agent_id": "a1", "agent_type": "Explore",
        ]), maxHistory: 10)
        XCTAssertNil(sessions["parent"]?.subagents["a1"]?.model)
        XCTAssertNil(sessions["parent"]?.subagents["a1"]?.modelLabel)
    }

    func testClaudeSubagentTranscriptPathDerivation() {
        XCTAssertEqual(
            SubagentState.claudeTranscriptPath(
                parentTranscriptPath: "/u/.claude/projects/-repo/3fdc50ad.jsonl",
                agentId: "a6914a36aae8b67eb"
            ),
            "/u/.claude/projects/-repo/3fdc50ad/subagents/agent-a6914a36aae8b67eb.jsonl"
        )
        XCTAssertNil(SubagentState.claudeTranscriptPath(parentTranscriptPath: "/u/x.json", agentId: "a1"))
        XCTAssertNil(SubagentState.claudeTranscriptPath(parentTranscriptPath: "/u/x.jsonl", agentId: "../a1"))
        XCTAssertNil(SubagentState.claudeTranscriptPath(parentTranscriptPath: "/u/x.jsonl", agentId: ""))
    }
}

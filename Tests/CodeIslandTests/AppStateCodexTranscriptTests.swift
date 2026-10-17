import XCTest
@testable import CodeIsland
import CodeIslandCore
import SQLite3

@MainActor
final class AppStateCodexTranscriptTests: XCTestCase {
    func testCodexBackfillReadsPublicOutputButNotReasoning() throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-public-output-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }

        let lines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Inspect the parser"}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Checking public rollout fields"}],"content":[{"type":"text","text":"hidden chain of thought"}],"encrypted_content":"secret"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The parser is ready."}]}}"#
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcript, atomically: true, encoding: .utf8)

        let messages = AppState.readRecentFromCodexTranscript(path: transcript.path).1

        XCTAssertEqual(messages.map(\.text), [
            "Inspect the parser",
            "The parser is ready."
        ])
        XCTAssertFalse(messages.contains { $0.text.contains("hidden chain") })
    }

    func testTaskStartedClearsPreviousCodexLiveOutputWithoutDeletingHistory() {
        let appState = AppState()
        let sessionId = "codex-live-output"
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .processing
        session.liveCodexOutput = "Previous turn"
        session.recentMessages = [ChatMessage(isUser: false, text: "Previous turn")]
        appState.sessions[sessionId] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            turnStatus: .processing,
            hasActivity: true
        ))

        XCTAssertNil(appState.sessions[sessionId]?.liveCodexOutput)
        XCTAssertEqual(appState.sessions[sessionId]?.recentMessages.map(\.text), ["Previous turn"])
    }

    func testCodexHookEnrichmentUpdatesTransientLiveOutput() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let data = Data(#"{"session_id":"remote-turn","hook_event_name":"PostToolUse","_source":"codex","last_assistant_message":" Inspecting the failing test. "}"#.utf8)
        let event = try XCTUnwrap(HookEvent(from: data))

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 5)

        XCTAssertEqual(sessions["remote-turn"]?.liveCodexOutput, "Inspecting the failing test.")
    }

    func testDelayedDeltaFromDetachedGenerationCannotMutateRecreatedSession() throws {
        let appState = AppState()
        let sessionId = "codexapp:reused-thread"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-generation-\(UUID().uuidString)")
        let oldTranscript = directory.appendingPathComponent("old.jsonl")
        let newTranscript = directory.appendingPathComponent("new.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: oldTranscript)
        try Data().write(to: newTranscript)
        defer {
            appState.detachTranscriptTailer(sessionId: sessionId)
            try? FileManager.default.removeItem(at: directory)
        }

        var oldSession = SessionSnapshot()
        oldSession.source = "codex"
        oldSession.termBundleId = AppState.codexAppBundleId
        oldSession.transcriptPath = oldTranscript.path
        oldSession.status = .processing
        appState.sessions[sessionId] = oldSession
        appState.attachTranscriptTailerIfNeeded(sessionId: sessionId)
        let oldToken = try XCTUnwrap(appState.attachedTranscriptTokens[sessionId])

        // Model a delta that has left JSONLTailer's serial queue but whose
        // MainActor hop is delayed until after close + same-id recreation.
        let delayedOldDelta = ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: "stale reply",
            turnStatus: .idle,
            hasActivity: true,
            attachmentToken: oldToken,
            filePath: oldTranscript.path
        )

        appState.removeSession(sessionId)
        XCTAssertNil(appState.attachedTranscriptTokens[sessionId])

        var recreated = SessionSnapshot()
        recreated.source = "codex"
        recreated.termBundleId = AppState.codexAppBundleId
        recreated.transcriptPath = newTranscript.path
        recreated.status = .processing
        recreated.lastAssistantMessage = "fresh reply"
        appState.sessions[sessionId] = recreated
        appState.attachTranscriptTailerIfNeeded(sessionId: sessionId)
        let newToken = try XCTUnwrap(appState.attachedTranscriptTokens[sessionId])
        XCTAssertNotEqual(newToken, oldToken)

        appState.applyTranscriptDelta(delayedOldDelta)

        XCTAssertEqual(appState.sessions[sessionId]?.status, .processing)
        XCTAssertEqual(appState.sessions[sessionId]?.lastAssistantMessage, "fresh reply")
        XCTAssertEqual(appState.attachedTranscriptPaths[sessionId], newTranscript.path)
        XCTAssertEqual(appState.attachedTranscriptTokens[sessionId], newToken)
    }

    func testReverseLifecycleScanSkipsOversizedUnterminatedTailLine() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-oversized-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data(
            (#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n").utf8
        )
        data.append(Data(repeating: 0x78, count: 512 * 1024))
        try data.write(to: file)

        XCTAssertEqual(
            AppState.latestCodexTurnStatus(
                path: file.path,
                chunkSize: 16 * 1024,
                maxBytesToScan: 1024 * 1024,
                maxLineBytes: 64 * 1024
            ),
            .processing
        )
    }

    func testReverseLifecycleScanHonorsExplicitTotalByteBudget() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-scan-budget-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data(
            (#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n").utf8
        )
        data.append(Data(repeating: 0x78, count: 256 * 1024))
        try data.write(to: file)

        XCTAssertNil(AppState.latestCodexTurnStatus(
            path: file.path,
            chunkSize: 16 * 1024,
            maxBytesToScan: 64 * 1024,
            maxLineBytes: 32 * 1024
        ))
    }

    func testCodexDesktopProcessDiscoversNoSessions() throws {
        // Desktop cards come from hooks. Opening a past thread rewrites its
        // rollout and state-DB row without a turn, so neither is read.
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-desktop-none-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rawSessionId = "11111111-2222-4333-8444-555555555555"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        let rollout = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/desktop/repo",
            now: now,
            originator: "Codex Desktop",
            source: "vscode"
        )

        let statePath = tempDir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let sql = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                model TEXT,
                archived INTEGER NOT NULL,
                source TEXT NOT NULL
            );
            INSERT INTO threads VALUES (
                '\(rawSessionId)', '\(rollout.path)', '/desktop/repo',
                \(Int64(now.timeIntervalSince1970)), 'gpt-test', 0, 'vscode'
            );
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let discovered = AppState.discoverCodexSessions(
            processes: [CodexProcessDiscoveryCandidate(
                pid: 123,
                cwd: "/",
                startTime: now.addingTimeInterval(-60),
                isDesktop: true
            )],
            sessionsBase: sessionsBase.path,
            statePath: statePath,
            now: now,
            fileManager: fm
        )

        XCTAssertTrue(discovered.isEmpty)
    }

    func testSameRawThreadOpenInDesktopAndCLIIsDiscoveredOnlyForCLI() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-dual-mode-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rawSessionId = "12345678-1234-4234-8234-123456789abc"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        _ = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/shared/repo",
            now: now,
            originator: "Codex Desktop",
            source: "vscode",
            filenameTimestamp: "2000-01-01T00-00-00"
        )
        _ = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/shared/repo",
            now: now,
            originator: "Codex CLI",
            source: "cli",
            filenameTimestamp: "2000-01-01T00-00-01"
        )

        let discovered = AppState.discoverCodexSessions(
            processes: [
                CodexProcessDiscoveryCandidate(
                    pid: 100,
                    cwd: "/",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: true
                ),
                CodexProcessDiscoveryCandidate(
                    pid: 101,
                    cwd: "/shared/repo",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: false
                ),
            ],
            sessionsBase: sessionsBase.path,
            statePath: tempDir.appendingPathComponent("missing.sqlite").path,
            now: now,
            fileManager: fm
        )

        // The Desktop copy is left to its hooks; the CLI one is still found.
        XCTAssertEqual(discovered.map(\.sessionId), [rawSessionId])
        XCTAssertEqual(discovered.first?.pid, 101)
        XCTAssertNil(discovered.first?.termBundleId)
    }

    func testUnknownOriginRolloutIsClaimedByTheCLIProcess() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-unknown-mode-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rawSessionId = "99999999-8888-4777-8666-555555555555"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        _ = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/shared/repo",
            now: now,
            originator: "future-surface",
            source: "future-source"
        )

        let discovered = AppState.discoverCodexSessions(
            processes: [
                CodexProcessDiscoveryCandidate(
                    pid: 100,
                    cwd: "/",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: true
                ),
                CodexProcessDiscoveryCandidate(
                    pid: 101,
                    cwd: "/shared/repo",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: false
                ),
            ],
            sessionsBase: sessionsBase.path,
            statePath: tempDir.appendingPathComponent("missing.sqlite").path,
            now: now,
            fileManager: fm
        )

        XCTAssertEqual(discovered.map(\.sessionId), [rawSessionId])
        XCTAssertEqual(discovered.first?.pid, 101)
    }

    func testOtherAppServerClientRolloutStaysWithItsOwnProcess() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-client-mode-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rawSessionId = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        let rollout = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/shared/repo",
            now: now,
            originator: "Claude Code",
            source: "vscode"
        )

        let statePath = tempDir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let sql = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                model TEXT,
                archived INTEGER NOT NULL,
                source TEXT NOT NULL
            );
            INSERT INTO threads VALUES (
                '\(rawSessionId)', '\(rollout.path)', '/shared/repo',
                \(Int64(now.timeIntervalSince1970)), 'gpt-test', 0, 'vscode'
            );
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let discovered = AppState.discoverCodexSessions(
            processes: [
                CodexProcessDiscoveryCandidate(
                    pid: 100,
                    cwd: "/",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: true
                ),
                CodexProcessDiscoveryCandidate(
                    pid: 101,
                    cwd: "/shared/repo",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: false
                ),
            ],
            sessionsBase: sessionsBase.path,
            statePath: statePath,
            now: now,
            fileManager: fm
        )

        XCTAssertEqual(discovered.map(\.sessionId), [rawSessionId])
        XCTAssertEqual(discovered.first?.pid, 101)
        XCTAssertNil(discovered.first?.termBundleId)
    }

    func testOtherAppServerClientSubagentRolloutStaysInItsParentNamespace() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-client-child-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let childSessionId = "cccccccc-dddd-4eee-8fff-000000000000"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        // A spawned thread keeps its parent's originator under an object source.
        _ = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: childSessionId,
            cwd: "/shared/repo",
            now: now,
            originator: "Claude Code",
            source: ["subagent": ["thread_spawn": ["parent_thread_id": "parent-thread"]]]
        )

        let discovered = AppState.discoverCodexSessions(
            processes: [
                CodexProcessDiscoveryCandidate(
                    pid: 100,
                    cwd: "/",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: true
                ),
                CodexProcessDiscoveryCandidate(
                    pid: 101,
                    cwd: "/shared/repo",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: false
                ),
            ],
            sessionsBase: sessionsBase.path,
            statePath: tempDir.appendingPathComponent("missing.sqlite").path,
            now: now,
            fileManager: fm
        )

        XCTAssertEqual(discovered.map(\.sessionId), [childSessionId])
        XCTAssertEqual(discovered.first?.parentSessionId, "parent-thread")
        XCTAssertNil(discovered.first?.termBundleId)
    }

    func testCodexLatestTerminalTurnTimestampPrefersNewestTerminalEvent() throws {
        let transcript = [
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-04-09T03:17:18.000Z","type":"event_msg","payload":{"type":"agent_message","message":"still working"}}"#,
            #"{"timestamp":"2026-04-09T03:17:20.500Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codexLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:17:20.500Z"))
    }

    func testCodexLatestTerminalTurnTimestampTreatsAbortedAndFailedTurnsAsTerminal() throws {
        let transcript = [
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-04-09T03:17:21Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
            #"{"timestamp":"2026-04-09T03:17:19.000Z","type":"event_msg","payload":{"type":"turn_failed","reason":"tool_error"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codexLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:17:21Z"))
    }

    func testCodexLatestTerminalTurnTimestampIgnoresMalformedAndNonTerminalEvents() {
        let transcript = [
            "not-json",
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
            #"{"timestamp":"2026-04-09T03:17:17.000Z","type":"response_item","payload":{"type":"message"}}"#
        ].joined(separator: "\n")

        XCTAssertNil(AppState.codexLatestTerminalTurnTimestamp(in: transcript))
    }

    func testQoderLatestTerminalTurnTimestampPrefersExplicitStopEvent() throws {
        let transcript = [
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:31.309452Z","message":{"role":"assistant","content":[{"text":"hello","type":"text"}]}}"#,
            #"{"type":"progress","timestamp":"2026-04-09T03:59:31.332585Z","data":{"hookEvent":"Stop","hookName":"Stop","type":"hook_progress"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.qoderLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:59:31.332585Z"))
    }

    func testQoderLatestTerminalTurnTimestampFallsBackToAssistantTextWhenStopMissing() throws {
        let transcript = [
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:30.000000Z","message":{"role":"assistant","content":[{"thinking":"let me think","type":"thinking"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:31.309452Z","message":{"role":"assistant","content":[{"text":"hello","type":"text"}]}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.qoderLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:59:31.309452Z"))
    }

    func testCodeBuddyLatestTerminalTurnTimestampUsesCompletedAssistantMessage() throws {
        let transcript = [
            #"{"timestamp":1775408759547,"type":"function_call","status":"completed","role":"assistant","content":[{"type":"output_text","text":"tool"}]}"#,
            #"{"timestamp":1775408774216,"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"final"}]}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codeBuddyLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, Date(timeIntervalSince1970: 1775408774.216))
    }

    func testCodeBuddyLatestTerminalTurnTimestampIgnoresNonCompletedAssistantEntries() {
        let transcript = [
            #"{"timestamp":1775408759547,"type":"message","role":"assistant","status":"streaming","content":[{"type":"output_text","text":"partial"}]}"#,
            #"{"timestamp":1775408774216,"type":"message","role":"user","status":"completed","content":[{"type":"input_text","text":"next"}]}"#
        ].joined(separator: "\n")

        XCTAssertNil(AppState.codeBuddyLatestTerminalTurnTimestamp(in: transcript))
    }

    private func timestampFrom(_ raw: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let timestamp = fractional.date(from: raw) {
            return timestamp
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(plain.date(from: raw))
    }

    private func makeCodexRollout(
        sessionsBase: URL,
        sessionId: String,
        cwd: String?,
        now: Date,
        originator: String = "Codex Desktop",
        source: Any = "vscode",
        filenameTimestamp: String = "2000-01-01T00-00-00"
    ) throws -> URL {
        let calendar = Calendar.current
        let dayDirectory = sessionsBase
            .appendingPathComponent(String(format: "%04d", calendar.component(.year, from: now)))
            .appendingPathComponent(String(format: "%02d", calendar.component(.month, from: now)))
            .appendingPathComponent(String(format: "%02d", calendar.component(.day, from: now)))
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        var payload: [String: Any] = [
            "id": sessionId,
            "originator": originator,
            "source": source,
        ]
        if let cwd {
            payload["cwd"] = cwd
        }
        let sessionMeta = try JSONSerialization.data(withJSONObject: [
            "type": "session_meta",
            "payload": payload,
        ])
        let started = Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8)
        var contents = sessionMeta
        contents.append(0x0A)
        contents.append(started)
        contents.append(0x0A)

        let rollout = dayDirectory
            .appendingPathComponent("rollout-\(filenameTimestamp)-\(sessionId).jsonl")
        try contents.write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: rollout.path
        )
        return rollout
    }
}

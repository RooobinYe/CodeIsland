import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Blocking hooks (PermissionRequest, AskUserQuestion, question
/// Notifications) are display-only: the session shows as blocked, the agent
/// asks in its own UI, and the island never holds or answers the request.
@MainActor
final class AppStatePermissionFlowTests: XCTestCase {
    private var savedCodexHome: String?
    private var savedSmartSuppress: Any?

    override func setUp() {
        super.setUp()
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
    }

    override func tearDown() {
        if let savedCodexHome {
            setenv("CODEX_HOME", savedCodexHome, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        if let savedSmartSuppress {
            UserDefaults.standard.set(savedSmartSuppress, forKey: SettingsKey.smartSuppress)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.smartSuppress)
        }
        super.tearDown()
    }

    func testPermissionRequestMarksTheSessionBlockedWithoutOpeningAnything() throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(sessionId: "s-blocked", toolName: "Bash")

        appState.handleBlockingRequest(event, status: .waitingApproval)

        XCTAssertEqual(appState.sessions["s-blocked"]?.status, .waitingApproval)
        XCTAssertEqual(appState.sessions["s-blocked"]?.currentTool, "Bash")
        XCTAssertEqual(appState.status, .waitingApproval)
        XCTAssertEqual(appState.surface, .collapsed, "the island never opens a card for a request")
        XCTAssertEqual(appState.displayOnlyWaitKind(forSession: "s-blocked"), .approval)
    }

    func testAskUserQuestionMarksTheSessionWaitingOnAQuestion() throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-ask",
            toolName: "AskUserQuestion",
            toolInput: ["questions": [["question": "Which DB?", "header": "DB", "options": [["label": "Postgres"], ["label": "SQLite"]]]]]
        )

        appState.handleBlockingRequest(event, status: .waitingQuestion)

        XCTAssertEqual(appState.sessions["s-ask"]?.status, .waitingQuestion)
        XCTAssertEqual(appState.displayOnlyWaitKind(forSession: "s-ask"), .question)
        XCTAssertEqual(
            AppState.blockingRequestAsk(event, status: .waitingQuestion, cwd: nil),
            .question(items: [PushQuestionItem(question: "Which DB?", options: ["Postgres", "SQLite"], header: "DB")], isSecret: false)
        )
    }

    func testActivityAfterThePromptClearsTheBlockedState() throws {
        let appState = AppState()
        appState.handleBlockingRequest(try makePermissionRequestEvent(sessionId: "s-answered", toolName: "Bash"), status: .waitingApproval)

        let post = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PostToolUse",
            "session_id": "s-answered",
            "tool_name": "Bash",
        ])))
        appState.handleEvent(post)

        XCTAssertNotEqual(appState.sessions["s-answered"]?.status, .waitingApproval)
        XCTAssertNil(appState.displayOnlyWaitKind(forSession: "s-answered"))
    }

    func testANotificationKeepsTheSessionBlocked() throws {
        let appState = AppState()
        appState.handleBlockingRequest(try makePermissionRequestEvent(sessionId: "s-notify", toolName: "Bash"), status: .waitingApproval)

        let notification = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "session_id": "s-notify",
            "notification_type": "permission_prompt",
            "message": "Claude needs your permission to use Bash",
        ])))
        appState.handleEvent(notification)

        XCTAssertEqual(appState.sessions["s-notify"]?.status, .waitingApproval)
    }

    func testPermissionRequestRoutesToTheBlockingHandler() throws {
        let event = try makePermissionRequestEvent(sessionId: "s-route", toolName: "Bash")
        XCTAssertEqual(HookServer.routeKind(for: event), .permission)
    }

    func testSmartSuppressKeepsPendingSurfaceCollapsedWhenTerminalIsFrontmost() {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        appState.sessions["s-smart"] = session

        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: "s-smart") { _ in true })
        XCTAssertTrue(appState.shouldAutoOpenPendingSurface(for: "s-smart") { _ in false })
    }

    func testPendingSurfaceAutoOpensWhenSmartSuppressIsOff() {
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        appState.sessions["s-smart-off"] = session

        XCTAssertTrue(appState.shouldAutoOpenPendingSurface(for: "s-smart-off") { _ in true })
    }

    func testConfigDeclaresMCPServerTransportRecognisesURLAndRejectsToolsOnlyTable() {
        let contents = """
        [mcp_servers.remote]
        url = "https://example.com/mcp"

        [mcp_servers.codex_app.tools.send_message_to_thread]
        approval_mode = "approve"
        """

        XCTAssertTrue(CodexPermissionRules.configDeclaresMCPServerTransport(contents, serverID: "remote"))
        XCTAssertFalse(CodexPermissionRules.configDeclaresMCPServerTransport(contents, serverID: "codex_app"))
        XCTAssertFalse(CodexPermissionRules.configDeclaresMCPServerTransport(contents, serverID: "absent"))
    }

    // MARK: - #316 repair of already-broken configs

    func testRepairRepointsAnOrphanedApprovalAtTheDeclaredServer() throws {
        let contents = """
        [mcp_servers.davinci-resolve]
        command = "/opt/venv/bin/python"

        \(CodexPermissionRules.mcpToolApprovalComment)
        [mcp_servers.davinci_resolve.tools.project_manager]
        approval_mode = "approve"
        """

        let repaired = try XCTUnwrap(CodexPermissionRules.repairingOrphanedMCPToolTables(contents))
        XCTAssertTrue(repaired.contains("[mcp_servers.davinci-resolve.tools.project_manager]"))
        XCTAssertFalse(repaired.contains("[mcp_servers.davinci_resolve"))
        XCTAssertTrue(repaired.contains(#"approval_mode = "approve""#),
                      "re-pointing must keep the approval the user actually granted")
        XCTAssertTrue(repaired.contains(#"command = "/opt/venv/bin/python""#))
    }

    func testRepairDropsAnApprovalWithNoServerToRepointAt() throws {
        let contents = """
        [mcp_servers.github]
        command = "github-mcp-server"

        \(CodexPermissionRules.mcpToolApprovalComment)
        [mcp_servers.codex_app.tools.send_message_to_thread]
        approval_mode = "approve"
        """

        let repaired = try XCTUnwrap(CodexPermissionRules.repairingOrphanedMCPToolTables(contents))
        XCTAssertFalse(repaired.contains("codex_app"))
        XCTAssertFalse(repaired.contains(CodexPermissionRules.mcpToolApprovalComment),
                       "the stamp must go with the table it introduced")
        XCTAssertTrue(repaired.contains("[mcp_servers.github]"))
        XCTAssertTrue(repaired.contains(#"command = "github-mcp-server""#))
    }

    /// An approval the user typed themselves is theirs, however it is spelled.
    func testRepairLeavesUnstampedTablesAlone() {
        let contents = """
        [mcp_servers.codex_app.tools.send_message_to_thread]
        approval_mode = "approve"
        """

        XCTAssertNil(CodexPermissionRules.repairingOrphanedMCPToolTables(contents))
    }

    func testRepairLeavesAHealthyConfigUntouched() {
        let contents = """
        [mcp_servers.github]
        command = "github-mcp-server"

        \(CodexPermissionRules.mcpToolApprovalComment)
        [mcp_servers.github.tools.get_me]
        approval_mode = "approve"

        """

        XCTAssertNil(CodexPermissionRules.repairingOrphanedMCPToolTables(contents),
                     "a healthy file must never be rewritten")
    }

    func testCodexAutoReviewConfigDefersPermissionRequestToCodex() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try #"approvals_reviewer = "auto_review""#
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-auto-review",
            toolName: "Bash",
            source: "codex"
        )

        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testCodexAutoReviewConfigDoesNotDeferAskUserQuestion() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try #"approvals_reviewer = "guardian_subagent""#
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-question",
            toolName: "AskUserQuestion",
            toolInput: ["question": "Continue?", "options": ["Yes", "No"]],
            source: "codex"
        )

        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testCodexProfileAutoReviewConfigIsDetected() throws {
        let config = """
        profile = "work"
        approvals_reviewer = "user"

        [profiles.work]
        approvals_reviewer = "auto_review"
        """

        XCTAssertTrue(CodexPermissionRules.configEnablesAutoReview(config))
    }

    func testCodexUserReviewerConfigDoesNotDefer() throws {
        let config = """
        approvals_reviewer = "user"

        [profiles.work]
        approvals_reviewer = "auto_review"
        """

        XCTAssertFalse(CodexPermissionRules.configEnablesAutoReview(config))
    }

    // MARK: - Helpers

    private func makeTemporaryCodexHome() -> URL {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        setenv("CODEX_HOME", codexHome.path, 1)
        return codexHome
    }

    @discardableResult
    private func writeCodexConfig(_ contents: String, in codexHome: URL) throws -> URL {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let configURL = codexHome.appendingPathComponent("config.toml")
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private func makePermissionRequestEvent(
        sessionId: String,
        toolName: String,
        toolInput: [String: Any] = ["command": "echo test"],
        source: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": toolName,
            "tool_input": toolInput
        ]
        if let source {
            payload["_source"] = source
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStatePermissionFlowTests", code: 1)
        }
        return event
    }

}

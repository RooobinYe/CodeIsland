import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Codex runs in two places at once: the CLI in a terminal tab, and the desktop
/// app (ChatGPT.app, bundle `com.openai.codex`). Each click must land on its own
/// surface — the CLI's tab, or the app's exact thread.
final class CodexActivationRoutingTests: XCTestCase {

    private func desktopThread(_ threadId: String) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = AppState.codexAppBundleId
        session.providerSessionId = threadId
        return session
    }

    private func ghosttyCLI() -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.mitchellh.ghostty"
        session.termApp = "ghostty"
        session.ttyPath = "/dev/ttys004"
        return session
    }

    func testDesktopThreadOpensItsOwnThreadLink() {
        XCTAssertEqual(
            TerminalActivator.codexDesktopThreadURL(
                for: desktopThread("01a12924-2d82-71b1-b74b-ea0d13e085e5"),
                sessionId: "codexapp:01a12924-2d82-71b1-b74b-ea0d13e085e5",
                spawnedByDesktopApp: true
            )?.absoluteString,
            "codex://threads/01a12924-2d82-71b1-b74b-ea0d13e085e5"
        )
    }

    func testDesktopThreadFallsBackToThePrefixedSessionId() {
        var session = desktopThread("x")
        session.providerSessionId = nil
        XCTAssertEqual(
            TerminalActivator.codexDesktopThreadURL(
                for: session, sessionId: "codexapp:thread-b", spawnedByDesktopApp: true
            )?.absoluteString,
            "codex://threads/thread-b"
        )
    }

    func testTwoDesktopThreadsGetDistinctLinks() {
        let a = TerminalActivator.codexDesktopThreadURL(for: desktopThread("thread-a"), sessionId: nil, spawnedByDesktopApp: true)
        let b = TerminalActivator.codexDesktopThreadURL(for: desktopThread("thread-b"), sessionId: nil, spawnedByDesktopApp: true)
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
    }

    func testCLISessionsNeverGetAThreadLink() {
        XCTAssertNil(TerminalActivator.codexDesktopThreadURL(
            for: ghosttyCLI(), sessionId: "raw-cli-id", spawnedByDesktopApp: false
        ))

        // Codex CLI inside the app's own terminal pane inherits the app's bundle id.
        var inAppTerminal = desktopThread("cli-thread")
        inAppTerminal.ttyPath = "/dev/ttys009"
        XCTAssertNil(TerminalActivator.codexDesktopThreadURL(
            for: inAppTerminal, sessionId: nil, spawnedByDesktopApp: true
        ))
    }

    func testDesktopThreadWithoutBundleIdStillGetsItsLink() {
        // ChatGPT 26.x drops __CFBundleIdentifier from its app-server's env: the
        // session has no termBundleId and a raw id, only the process tree tells.
        var session = SessionSnapshot()
        session.source = "codex"
        session.providerSessionId = "01a126a6-e4b5-79b1-9a2b-bbcde65e7901"
        XCTAssertEqual(
            TerminalActivator.codexDesktopThreadURL(
                for: session, sessionId: "01a126a6-e4b5-79b1-9a2b-bbcde65e7901", spawnedByDesktopApp: true
            )?.absoluteString,
            "codex://threads/01a126a6-e4b5-79b1-9a2b-bbcde65e7901"
        )
    }

    func testTerminalSessionsAreRecognisedSoTheDesktopAppCannotStealThem() {
        XCTAssertTrue(TerminalActivator.hasTerminal(ghosttyCLI()))

        var tmux = SessionSnapshot()
        tmux.tmuxPane = "%3"
        XCTAssertTrue(TerminalActivator.hasTerminal(tmux))

        XCTAssertFalse(TerminalActivator.hasTerminal(desktopThread("t")))
    }

    func testOnlyALaunchdOwnedCodexServerCountsAsTheCLIDaemon() {
        // The test runner is a child of its launcher, not of launchd.
        var session = SessionSnapshot()
        session.source = "codex"
        session.cliPid = getpid()
        XCTAssertFalse(TerminalActivator.runsOnCodexDaemon(session))

        session.source = "claude"
        XCTAssertFalse(TerminalActivator.runsOnCodexDaemon(session))

        XCTAssertFalse(TerminalActivator.runsOnCodexDaemon(SessionSnapshot()))
    }
}

import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Ghostty is driven by matching `tty of terminal`, so the tty picked for a
/// session must be the one Ghostty itself holds.
final class GhosttyTtyTests: XCTestCase {

    func testTmuxUsesTheAttachedClientsTtyNotTheInnerPane() {
        var session = SessionSnapshot()
        session.tmuxPane = "%3"
        session.ttyPath = "/dev/ttys020"        // inner tmux pty — unknown to Ghostty
        session.tmuxClientTty = "/dev/ttys004"
        XCTAssertEqual(TerminalActivator.ghosttyTty(for: session), "/dev/ttys004")
    }

    func testDetachedTmuxHasNoGhosttyTty() {
        var session = SessionSnapshot()
        session.tmuxPane = "%3"
        session.ttyPath = "/dev/ttys020"
        XCTAssertNil(TerminalActivator.ghosttyTty(for: session))
    }

    func testFallsBackToTheCapturedTtyWithoutALiveProcess() {
        var session = SessionSnapshot()
        session.ttyPath = "/dev/ttys007"
        XCTAssertEqual(TerminalActivator.ghosttyTty(for: session), "/dev/ttys007")
    }

    func testReadsTheLiveProcessTtyFirst() throws {
        // The test runner may have no controlling tty (CI), so only assert when it does.
        let own = getpid()
        guard let live = ProcessRunner.ttyForPid(own) else { throw XCTSkip("no controlling tty") }
        var session = SessionSnapshot()
        session.cliPid = own
        session.ttyPath = "/dev/ttys999"
        XCTAssertEqual(TerminalActivator.ghosttyTty(for: session), live)
    }

    func testNothingKnownMeansNoTty() {
        XCTAssertNil(TerminalActivator.ghosttyTty(for: SessionSnapshot()))
    }
}

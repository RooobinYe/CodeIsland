import XCTest
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// The expanded panel's chrome: the header (grouping tabs, Quit that asks
/// once) and the session list's usage footer.
@MainActor
final class PanelChromeTests: XCTestCase {

    // MARK: - Quit asks once

    /// A clock and a timer the test moves by hand; `quit` only counts.
    private final class Harness {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var quits = 0
        var pending: [(fireAt: Date, fire: @MainActor () -> Void, cancelled: Bool)] = []
        var cancels = 0

        @MainActor
        func make() -> QuitConfirmation {
            QuitConfirmation(
                quit: { [unowned self] in self.quits += 1 },
                now: { [unowned self] in self.now },
                schedule: { [unowned self] delay, fire in
                    let index = self.pending.count
                    self.pending.append((self.now.addingTimeInterval(delay), fire, false))
                    return { [unowned self] in
                        if !self.pending[index].cancelled { self.cancels += 1 }
                        self.pending[index].cancelled = true
                    }
                }
            )
        }

        /// Moves the clock and runs every timer now due.
        @MainActor
        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            for i in pending.indices where !pending[i].cancelled && pending[i].fireAt <= now {
                pending[i].cancelled = true
                pending[i].fire()
            }
        }
    }

    func testFirstClickOnlyArmsTheButton() {
        let h = Harness()
        let confirm = h.make()
        XCTAssertFalse(confirm.isArmed)
        XCTAssertFalse(confirm.press())
        XCTAssertTrue(confirm.isArmed)
        XCTAssertEqual(h.quits, 0)
    }

    func testSecondClickWithinTheWindowQuitsOnce() {
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        h.advance(QuitConfirmation.window - 0.1)
        XCTAssertTrue(confirm.isArmed)
        XCTAssertTrue(confirm.press())
        XCTAssertEqual(h.quits, 1)
        XCTAssertFalse(confirm.isArmed)
        // The timeout is cancelled, not left to fire later.
        XCTAssertTrue(h.pending.allSatisfy(\.cancelled))
    }

    func testTheArmLapsesAfterTheWindow() {
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        h.advance(QuitConfirmation.window)
        XCTAssertFalse(confirm.isArmed, "the pill reverts on its own")
        // The next click starts over: it arms, it doesn't quit.
        XCTAssertFalse(confirm.press())
        XCTAssertTrue(confirm.isArmed)
        XCTAssertEqual(h.quits, 0)
    }

    func testALateClickBeforeTheTimeoutRanStillDoesNotQuit() {
        // A busy main thread can run the revert late; the window is measured
        // on the clock, not by whether the timer got to run.
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        h.now = h.now.addingTimeInterval(QuitConfirmation.window + 0.5)
        XCTAssertTrue(confirm.isArmed)
        XCTAssertFalse(confirm.press())
        XCTAssertTrue(confirm.isArmed, "re-armed for a fresh window")
        XCTAssertEqual(h.quits, 0)
        XCTAssertTrue(confirm.press())
        XCTAssertEqual(h.quits, 1)
    }

    func testMovingAwayRevertsWithoutQuitting() {
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        confirm.cancel()
        XCTAssertFalse(confirm.isArmed)
        XCTAssertEqual(h.cancels, 1, "its timeout goes with it")
        XCTAssertFalse(confirm.press(), "coming back takes two clicks again")
        XCTAssertEqual(h.quits, 0)
    }

    func testAStaleTimeoutDoesNotRevertANewerArm() {
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        // The revert is late; the next click re-arms for a fresh window…
        h.now = h.now.addingTimeInterval(QuitConfirmation.window + 0.5)
        confirm.press()
        // …and the first arm's timeout, running now, must not cut it short.
        h.advance(0)
        XCTAssertTrue(confirm.isArmed)
        XCTAssertTrue(confirm.press())
        XCTAssertEqual(h.quits, 1)
    }

    func testCancelWhileIdleIsHarmless() {
        let h = Harness()
        let confirm = h.make()
        confirm.cancel()
        XCTAssertFalse(confirm.isArmed)
        XCTAssertEqual(h.quits, 0)
        XCTAssertEqual(h.cancels, 0)
    }

    func testQuitPillFitsBesideTheNotchInEveryLanguage() {
        // Expanded header, narrowest panel, 185pt notch: the right wing holds
        // two 24pt buttons, the pill, 4pt gaps and 6pt trailing padding.
        let headerRoom = (580 - 185) / 2 - 6 - 2 * NotchIconButton.hitSize - 2 * 4 - 4
        for (lang, table) in L10n.strings {
            let text = table["quit_confirm"] ?? ""
            XCTAssertFalse(text.isEmpty, "\(lang) has no quit_confirm")
            let width = QuitConfirmButton.pillWidth(for: text)
            XCTAssertLessThanOrEqual(width, headerRoom, "\(lang) \"\(text)\" crowds the header")
            // The hovered idle bar (no sessions) sizes itself to the pill too.
            let idleRoom = IdleIndicatorLayout.hoveredWidth(quitText: text)
                - IdleIndicatorLayout.trailingPadding - 2 * NotchIconButton.hitSize - 2 * IdleIndicatorLayout.buttonSpacing
            XCTAssertLessThanOrEqual(width, idleRoom, "\(lang) \"\(text)\" runs past the idle bar")
            XCTAssertFalse((table["quit_confirm_hint"] ?? "").isEmpty, "\(lang) has no quit_confirm_hint")
        }
    }

    func testHoveredIdleBarFitsAllThreeButtons() {
        // Count, its gap, three buttons, their gaps, trailing padding: the
        // sound button was clipped when the wing was a fixed 40pt wider.
        let minimum = 8 + IdleIndicatorLayout.countSpacing + 3 * NotchIconButton.hitSize
            + 2 * IdleIndicatorLayout.buttonSpacing + IdleIndicatorLayout.trailingPadding
        XCTAssertGreaterThanOrEqual(IdleIndicatorLayout.hoveredWidth(quitText: "QUIT?"), minimum)
    }

    func testHeaderHitTargetsFitTheMenuBar() {
        XCTAssertGreaterThanOrEqual(NotchIconButton.hitSize, 24)
        // Still inside the shortest header (a 25pt menu bar).
        XCTAssertLessThanOrEqual(NotchIconButton.hitSize, 25)
    }

    // MARK: - Strings

    func testEveryLanguageHasTheNewChromeStrings() {
        let keys = ["quit_confirm", "quit_confirm_hint"]
        func placeholders(_ s: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(\\d\\$)?@")
            return regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        let english = L10n.strings["en"]!
        for (lang, table) in L10n.strings {
            for key in keys {
                let value = table[key] ?? ""
                XCTAssertFalse(value.isEmpty, "\(lang) has no \(key)")
                XCTAssertEqual(placeholders(value), placeholders(english[key]!), "\(lang) \(key): \(value)")
            }
        }
    }
}

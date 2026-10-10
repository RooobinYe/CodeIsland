import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The expanded list's status words, its needs-you-first order, the order
/// held while the pointer is on the list, and the Compact density setting.
@MainActor
final class SessionListOrderingTests: XCTestCase {

    // MARK: - Status words

    func testEveryStatusHasItsOwnWord() {
        XCTAssertEqual(SessionCardStatus(session(.waitingApproval)), .needsYou)
        XCTAssertEqual(SessionCardStatus(session(.waitingQuestion)), .needsYou)
        XCTAssertEqual(SessionCardStatus(session(.running)), .working)
        XCTAssertEqual(SessionCardStatus(session(.processing)), .thinking)
        XCTAssertEqual(SessionCardStatus(session(.idle)), .idle, "nothing has happened yet")
        XCTAssertEqual(SessionCardStatus(session(.idle, prompt: "Fix it")), .done)

        var stopped = session(.idle, prompt: "Fix it")
        stopped.interrupted = true
        XCTAssertEqual(SessionCardStatus(stopped), .stopped)

        var failed = stopped
        failed.lastTurnFailed = true
        XCTAssertEqual(SessionCardStatus(failed), .error, "a failed turn outranks the interrupt")

        failed.status = .running
        XCTAssertEqual(SessionCardStatus(failed), .working, "the flags only describe an idle session")
    }

    func testStatusWordsAreSpelledOutInEveryLanguage() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }
        for language in ["en", "de", "zh", "zh-Hant", "ja", "ko", "tr"] {
            L10n.shared.language = language
            let words = SessionCardStatus.allCases.map(\.label)
            XCTAssertEqual(Set(words).count, words.count, "\(language): two statuses share a word")
            for (status, word) in zip(SessionCardStatus.allCases, words) {
                XCTAssertNotEqual(word, status.labelKey, "\(language): \(status) has no word")
            }
        }
    }

    func testStatusIsNeverHueAlone() {
        // Working and thinking share a colour; their words tell them apart.
        XCTAssertNotEqual(SessionCardStatus.working.labelKey, SessionCardStatus.thinking.labelKey)
        XCTAssertEqual(SessionCardStatus.needsYou.tier, 0)
        XCTAssertEqual(SessionCardStatus.working.tier, 1)
        XCTAssertEqual(SessionCardStatus.thinking.tier, 1)
        for status in [SessionCardStatus.done, .idle, .stopped, .error] {
            XCTAssertEqual(status.tier, 2, "\(status)")
        }
    }

    // MARK: - Ordering

    func testNeedsYouFirstThenWorkingThenTheRestByRecentActivity() {
        let now = Date()
        let sessions: [String: SessionSnapshot] = [
            "a-idle-old": session(.idle, prompt: "p", activity: now.addingTimeInterval(-600)),
            "b-running": session(.running, started: now.addingTimeInterval(-300)),
            "c-question": session(.waitingQuestion, activity: now.addingTimeInterval(-5)),
            "d-idle-new": session(.idle, prompt: "p", activity: now.addingTimeInterval(-10)),
            "e-thinking": session(.processing, started: now.addingTimeInterval(-60)),
            "z-approval": session(.waitingApproval, activity: now.addingTimeInterval(-500)),
            "g-stopped": stoppedSession(activity: now.addingTimeInterval(-100)),
        ]
        XCTAssertEqual(SessionListOrdering.order(sessions), [
            "c-question", "z-approval",      // needs you, most recent activity first
            "e-thinking", "b-running",       // working, newest session first
            "d-idle-new", "g-stopped", "a-idle-old", // the rest, most recent activity first
        ])
    }

    func testAWorkingSessionsActivityDoesNotReshuffleTheList() {
        let now = Date()
        var sessions: [String: SessionSnapshot] = [
            "old": session(.running, started: now.addingTimeInterval(-900)),
            "new": session(.running, started: now.addingTimeInterval(-60)),
        ]
        let before = SessionListOrdering.order(sessions)
        sessions["old"]?.lastActivity = now.addingTimeInterval(5)
        XCTAssertEqual(SessionListOrdering.order(sessions), before, "every tool call would move the cards")
        XCTAssertEqual(before, ["new", "old"])
    }

    func testOrderIsStableForEqualKeys() {
        let date = Date()
        let sessions = Dictionary(uniqueKeysWithValues: ["c", "a", "b"].map {
            ($0, session(.idle, prompt: "p", activity: date, started: date))
        })
        XCTAssertEqual(SessionListOrdering.order(sessions), ["a", "b", "c"])
    }

    // MARK: - Held order

    func testOrderIsHeldWhileThePointerIsOverTheList() {
        var freeze = SessionOrderFreeze()
        XCTAssertEqual(freeze.apply(["a", "b", "c"]), ["a", "b", "c"], "live until the pointer enters")

        freeze.freeze(["a", "b", "c"])
        XCTAssertTrue(freeze.isFrozen)
        // "c" now needs you and would sort first.
        XCTAssertEqual(freeze.apply(["c", "a", "b"]), ["a", "b", "c"], "a card moved under the pointer")
        // A session that ends drops out; one that starts joins at the end.
        XCTAssertEqual(freeze.apply(["d", "c", "a"]), ["a", "c", "d"])

        freeze.thaw()
        XCTAssertFalse(freeze.isFrozen)
        XCTAssertEqual(freeze.apply(["c", "a", "b"]), ["c", "a", "b"], "re-sorts once the pointer leaves")
    }

    func testReenteringKeepsTheFirstHeldOrder() {
        var freeze = SessionOrderFreeze()
        freeze.freeze(["a", "b"])
        freeze.freeze(["b", "a"])
        XCTAssertEqual(freeze.apply(["b", "a"]), ["a", "b"])
    }

    func testCompactTooltipCutsALongReply() {
        XCTAssertEqual(CompactSessionRowMetrics.tooltip(name: "web-app", latest: nil), "web-app")
        XCTAssertEqual(CompactSessionRowMetrics.tooltip(name: "web-app", latest: "  Done.  "), "web-app\nDone.")
        let long = CompactSessionRowMetrics.tooltip(name: "web-app", latest: String(repeating: "word ", count: 400))
        XCTAssertLessThanOrEqual(long.count, "web-app\n".count + CompactSessionRowMetrics.tooltipCharacters + 1)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testCoworkTurnsSetAndClearError() {
        var audit = CoworkAuditState()
        audit.apply(.userPrompt(text: "go", isSynthetic: false))
        audit.apply(.turnEnded(isError: true, resultText: "Overloaded", interrupted: false))
        var snapshot = session(.processing, prompt: "go")
        AppState.applyCoworkAuditState(&snapshot, state: audit)
        XCTAssertEqual(SessionCardStatus(snapshot), .error)

        // A later turn stopped with the Stop button reads STOPPED, not ERROR:
        // Cowork has no prompt hook and a stopped turn skips the completion.
        audit.apply(.userPrompt(text: "again", isSynthetic: false))
        audit.apply(.turnEnded(isError: false, resultText: nil, interrupted: true))
        AppState.applyCoworkAuditState(&snapshot, state: audit)
        XCTAssertEqual(SessionCardStatus(snapshot), .stopped)
    }

    // MARK: - ERROR after a failed turn

    func testAFailedTurnReadsErrorUntilTheNextPrompt() throws {
        let state = AppState()
        state.handleEvent(try hook(["hook_event_name": "UserPromptSubmit", "session_id": "err", "prompt": "go"]))
        state.handleEvent(try hook(["hook_event_name": "StopFailure", "session_id": "err", "error_type": "rate_limit"]))
        let failed = try XCTUnwrap(state.sessions["err"])
        XCTAssertTrue(failed.lastTurnFailed)
        XCTAssertEqual(SessionCardStatus(failed), .error)

        state.handleEvent(try hook(["hook_event_name": "UserPromptSubmit", "session_id": "err", "prompt": "again"]))
        XCTAssertEqual(state.sessions["err"]?.lastTurnFailed, false)
        XCTAssertEqual(state.sessions["err"].map(SessionCardStatus.init), .thinking)

        state.handleEvent(try hook(["hook_event_name": "Stop", "session_id": "err"]))
        XCTAssertEqual(state.sessions["err"].map(SessionCardStatus.init), .done)
    }

    // MARK: - Density setting

    func testDensityDefaultsToComfortableAndPersists() {
        let sandbox = DefaultsSandbox(keys: [SettingsKey.sessionListDensity])
        defer { sandbox.restore() }
        XCTAssertEqual(SettingsDefaults.sessionListDensity, "comfortable")
        XCTAssertEqual(SettingsManager.shared.sessionListDensity, .comfortable)

        SettingsManager.shared.sessionListDensity = .compact
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKey.sessionListDensity), "compact")
        XCTAssertEqual(SettingsManager.shared.sessionListDensity, .compact)

        UserDefaults.standard.set("dense", forKey: SettingsKey.sessionListDensity)
        XCTAssertEqual(SettingsManager.shared.sessionListDensity, .comfortable, "an unknown value reads as the default")
        XCTAssertEqual(SessionListDensity(storedValue: nil), .comfortable)
    }

    func testDensityIsLocalizedInEveryLanguage() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }
        let keys = ["session_list_density", "session_list_density_desc", "max_visible_sessions_desc_compact",
                    "session_a11y_prompt", "session_a11y_reply",
                    "session_a11y_running_tool"] + SessionListDensity.allCases.map(\.titleKey)
        for language in ["en", "de", "zh", "zh-Hant", "ja", "ko", "tr"] {
            L10n.shared.language = language
            for key in keys {
                XCTAssertNotEqual(L10n.shared[key], key, "\(language) lacks \(key)")
            }
            XCTAssertTrue(L10n.shared["session_a11y_running_tool"].contains("%@"), language)
        }
    }

    func testCompactRowsScrollByHeightOnly() {
        // Eight one-line rows fit the room budgeted for five cards.
        XCTAssertFalse(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 8, contentHeight: 310,
                                                      maxVisibleSessions: 5, density: .compact))
        XCTAssertTrue(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 8, contentHeight: 310,
                                                     maxVisibleSessions: 5, density: .comfortable))
        XCTAssertTrue(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 20, contentHeight: 760,
                                                     maxVisibleSessions: 5, density: .compact))
    }

    func testCompactColumnsFitTheirWords() {
        let status = CompactSessionRowMetrics.statusColumnWidth(fontSize: 9)
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        for word in SessionCardStatus.allCases.map(\.label) {
            XCTAssertLessThanOrEqual((word as NSString).size(withAttributes: [.font: font]).width, status, word)
        }
        let cap = CompactSessionRowMetrics.projectColumnCap(fontSize: 11)
        XCTAssertEqual(CompactSessionRowMetrics.projectColumnWidth(names: [String(repeating: "x", count: 60)], fontSize: 11, cap: cap), cap)
        XCTAssertLessThan(CompactSessionRowMetrics.projectColumnWidth(names: ["api"], fontSize: 11, cap: cap), cap)
        XCTAssertLessThanOrEqual(CompactSessionRowMetrics.projectColumnCap(fontSize: 16), 180)
    }

    // MARK: - Fixtures

    private func session(
        _ status: AgentStatus,
        prompt: String? = nil,
        activity: Date = Date(),
        started: Date = Date()
    ) -> SessionSnapshot {
        var s = SessionSnapshot(startTime: started)
        s.source = "claude"
        s.status = status
        s.lastUserPrompt = prompt
        s.lastActivity = activity
        return s
    }

    private func stoppedSession(activity: Date) -> SessionSnapshot {
        var s = session(.idle, prompt: "p", activity: activity)
        s.interrupted = true
        return s
    }

    private func hook(_ payload: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
    }
}

/// Compact rows on the real panel: eight sessions in the window a 14"
/// MacBook gives the panel, without scrolling, at the default and the
/// largest text size.
@MainActor
final class CompactSessionListLayoutTests: XCTestCase {
    private var sandbox: DefaultsSandbox?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        UserDefaults.standard.set(SessionListDensity.compact.rawValue, forKey: SettingsKey.sessionListDensity)
    }

    override func tearDown() {
        sandbox?.restore()
        super.tearDown()
    }

    func testEightCompactSessionsFitWithoutScrolling() throws {
        let four = try panelHeight(sessions: 4)
        let eight = try panelHeight(sessions: 8)
        // Every row adds one 34pt line (+3pt gap): a list that scrolled would
        // stop growing at the scroll budget instead.
        XCTAssertEqual((eight - four) / 4, CompactSessionRowMetrics.rowHeight + CompactSessionRowMetrics.spacing, accuracy: 1.5)
        XCTAssertLessThan(eight, SessionListMetrics.scrollHeight(maxVisibleSessions: SettingsDefaults.maxVisibleSessions))
    }

    func testCompactRowsStayInsideTheWindowAtTheLargestText() throws {
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        let eight = try panelHeight(sessions: 8)
        XCTAssertLessThan(eight, PanelHeightMetrics.desiredHeight(maxVisibleSessions: SettingsDefaults.maxVisibleSessions))
    }

    func testComfortableIsStillTheDefaultCard() throws {
        UserDefaults.standard.removeObject(forKey: SettingsKey.sessionListDensity)
        let comfortable = try panelHeight(sessions: 2)
        UserDefaults.standard.set(SessionListDensity.compact.rawValue, forKey: SettingsKey.sessionListDensity)
        let compact = try panelHeight(sessions: 2)
        XCTAssertGreaterThan(comfortable - compact, 2 * 20, "Compact rows should be much shorter than cards")
    }

    /// Height of the panel (notch bar + list) for `count` working sessions.
    private func panelHeight(sessions count: Int) throws -> CGFloat {
        let state = AppState()
        for index in 0..<count {
            var s = SessionSnapshot(startTime: Date().addingTimeInterval(-Double(index) * 60 - 60))
            s.source = "claude"
            s.cwd = "/Users/dev/code/project-\(index)"
            s.gitBranch = "feat/branch-\(index)"
            s.status = index.isMultiple(of: 2) ? .running : .idle
            s.currentTool = index.isMultiple(of: 2) ? "Edit" : nil
            s.toolDescription = index.isMultiple(of: 2) ? "src/components/Dashboard.tsx" : nil
            s.lastUserPrompt = "Add filters to the dashboard page"
            s.addRecentMessage(ChatMessage(isUser: true, text: "Add filters to the dashboard page"))
            s.addRecentMessage(ChatMessage(isUser: false, text: "Adding a date-range and status filter bar."))
            state.sessions["s\(index)"] = s
        }
        state.activeSessionId = "s0"
        state.refreshDerivedState()
        state.surface = .sessionList
        let panel = try PanelHost(state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        let gap = try panel.gapUnderPanel()
        XCTAssertGreaterThan(gap, 0, "the list runs off the bottom of the window")
        return panel.height - gap
    }
}

/// The session list's scroll view keeps its thin overlay scroller. AppKit
/// put the system's legacy style back on its own schedule, and the 13pt
/// scroller it then drew took that much off every card's width.
@MainActor
final class SessionListScrollWidthTests: XCTestCase {
    func testTheScrollingListKeepsItsFullWidth() async throws {
        _ = NSApplication.shared
        let sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        defer {
            sandbox.restore()
        }
        let demo = try await GalleryDemo.list(count: 8, lang: .en)
        defer { demo.release() }
        let panel = try PanelHost(demo.state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()

        let scroll = try XCTUnwrap(Self.scrollView(in: panel.host), "eight cards should scroll")
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertEqual(scroll.contentView.frame.width, scroll.frame.width, accuracy: 0.5,
                       "a legacy scroller is narrowing the cards")
        scroll.scrollerStyle = .legacy
        XCTAssertEqual(scroll.scrollerStyle, .overlay, "the system's style came back")
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }
}

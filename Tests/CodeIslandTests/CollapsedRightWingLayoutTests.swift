import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The collapsed bar hangs off the notch's right, on notched and notchless
/// screens alike. Its right wing — quiet-hours moon, completion dot, question
/// badge, session count — must stay clear of the notch: a waiting question's
/// badge once slid under it, and the completion dot beside it disappeared
/// behind it altogether. A question the user dismissed (#352) keeps that badge
/// up until it is answered in the terminal.
@MainActor
final class CollapsedRightWingLayoutTests: XCTestCase {
    private let suiteName = "CollapsedRightWingLayoutTests"
    private var suite: UserDefaults!
    private var saved: [String: Any?] = [:]
    private let standardKeys = [
        SettingsKey.smartSuppress, SettingsKey.followUpReminderMinutes,
    ]
    private let notch: CGFloat = 185

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        for key in standardKeys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set(0, forKey: SettingsKey.followUpReminderMinutes)
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        for key in standardKeys {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await super.tearDown()
    }

    func testRightWingRoomIsItsContentOrTheMinimum() {
        // A count and one badge fit the minimum with notch clearance.
        XCTAssertEqual(CompactRightWingLayout.room(contentWidth: 46, minimum: 51), 51)
        // Badge + dot + count: 66 + 4 clearance.
        XCTAssertEqual(CompactRightWingLayout.room(contentWidth: 66, minimum: 51), 70, accuracy: 0.001)
        // Not measured yet.
        XCTAssertEqual(CompactRightWingLayout.room(contentWidth: 0, minimum: 40), 40)
    }

    func testQuestionBadgeAndCompletionDotStayClearOfTheNotch() async throws {
        for glance in [false, true] {
            let state = try await collapsedState(glance: glance)
            let g = try renderedGeometry(state)
            let name = "glance=\(glance)"
            XCTAssertNil(g.intrusion, "\(name): the right wing draws under the notch at \(g.intrusion ?? 0)pt")
            XCTAssertLessThanOrEqual(g.barRight, 620, "\(name): the bar runs past the panel window")
            // However wide the wing grows, the left end stays a lip past the notch.
            XCTAssertEqual(g.barLeft, notchLeft - CompactRightWingLayout.leadingLip + 1, accuracy: 1, name)
        }
    }

    func testCollapsedBarHangsOffTheNotchRightOnEveryScreen() async throws {
        for hasNotch in [true, false] {
            let state = AppState()
            var session = SessionSnapshot()
            session.source = "claude"
            state.sessions = ["s1": session]
            state.refreshDerivedState()
            let g = try renderedGeometry(state, hasNotch: hasNotch)
            let name = "hasNotch=\(hasNotch)"
            // Lip left of the notch; the minimum wing (min(27, 32 − 6) + 14) right of it.
            // The panel shape is drawn about a point inside its frame.
            XCTAssertEqual(g.barLeft, notchLeft - CompactRightWingLayout.leadingLip + 1, accuracy: 1, name)
            XCTAssertEqual(g.barRight, notchRight + 40 - 1, accuracy: 1, name)
        }
    }

    // MARK: - Fixture

    private var notchLeft: CGFloat { (620 - notch) / 2 }
    private var notchRight: CGFloat { (620 + notch) / 2 }

    private func collapsedState(glance: Bool) async throws -> AppState {
        let state = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/code/web-app"
        var other = SessionSnapshot()
        other.source = "codex"
        other.cwd = "/Users/dev/code/api"
        state.sessions = ["s1": session, "s2": other]
        state.activeSessionId = "s1"
        state.refreshDerivedState()
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [[
                "question": "Deploy?", "header": "Pick",
                "options": [["label": "Yes", "description": ""], ["label": "No", "description": ""]],
            ]]],
        ]
        let event = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
        state.handleBlockingRequest(event, status: .waitingQuestion)
        XCTAssertEqual(state.status, .waitingQuestion, "the wait should show as the collapsed bar's bell")
        state.glanceCompletionActive = glance
        return state
    }


    // MARK: - Rendering

    /// The real panel on a red backdrop: the bar's ends, and the first column
    /// under the physical notch where anything but the bar's black is drawn.
    private func renderedGeometry(_ state: AppState, hasNotch: Bool = true) throws -> (barLeft: CGFloat, barRight: CGFloat, intrusion: CGFloat?) {
        let windowWidth: CGFloat = 620, height: CGFloat = 64, notchHeight: CGFloat = 32
        let view = NotchPanelView(appState: state, hasNotch: hasNotch, notchHeight: notchHeight, notchW: notch, screenWidth: 1512)
            .defaultAppStorage(suite)
            .background(Color(red: 1, green: 0, blue: 0))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: windowWidth, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        // Measured widths feed back into the bar on the next pass.
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let w = image.width, h = image.height
        let scale = CGFloat(w) / windowWidth
        let context = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = px + (y * w + x) * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        func isBackdrop(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 60 && c.2 < 60 }
        func isBlack(_ c: (Int, Int, Int)) -> Bool { c.0 < 12 && c.1 < 12 && c.2 < 12 }
        let barRows = 0..<Int(notchHeight * scale)
        let mid = Int(notchHeight / 2 * scale)
        let left = try XCTUnwrap((0..<w).first { !isBackdrop(rgb($0, mid)) }, "no bar rendered")
        let right = try XCTUnwrap((0..<w).reversed().first { !isBackdrop(rgb($0, mid)) })
        let notchLeft = Int((windowWidth - notch) / 2 * scale), notchRight = Int((windowWidth + notch) / 2 * scale)
        let intrusion = (notchLeft..<notchRight).first { x in
            barRows.contains { y in let c = rgb(x, y); return !isBlack(c) && !isBackdrop(c) }
        }
        return (CGFloat(left) / scale, CGFloat(right + 1) / scale, intrusion.map { CGFloat($0) / scale })
    }
}

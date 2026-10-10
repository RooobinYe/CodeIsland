import XCTest

// Waiting primitives for async tests. Every wait here is bounded: when the
// thing a test waits for never happens, the test fails by name within
// seconds instead of hanging the whole `swift test` run.
//
// None of them use XCTest expectations. `await fulfillment(of:timeout:)`
// inside a @MainActor async test waits through XCTWaiter while XCTest's own
// XCTWaiter is already spinning the main run loop for the async test itself.
// In full-suite runs (after earlier suites had driven the real
// terminal-visibility probe) that combination repeatedly left the main queue
// undrained: main-actor jobs sat for ~2 s or forever, and XCTest logged
// "Run loop nesting count is negative (-1)". A test that only asserted a
// request stays pending could hang itself and the tests after it.

/// Upper bound for waits that normally finish in microseconds. Generous on
/// purpose: a loaded CI machine can deschedule the test process for seconds.
let asyncTestTimeout: TimeInterval = 5

/// Polls `condition` in the caller's isolation until it holds. Records a
/// failure and returns `false` once `timeout` passes.
@discardableResult
func waitUntil(
    timeout: TimeInterval = asyncTestTimeout,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail(timeoutDescription("Condition still false after \(timeout)s.", message()), file: file, line: line)
            return false
        }
        // A yield lets already-enqueued work run first; the short sleep keeps
        // a condition that needs another thread from busy-spinning the actor.
        await Task.yield()
        if condition() { break }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

private func timeoutDescription(_ what: String, _ context: String) -> String {
    context.isEmpty ? what : "\(what) \(context)"
}


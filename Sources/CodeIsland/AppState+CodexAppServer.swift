import Foundation
import AppKit
import SwiftUI
import CodeIslandCore

enum CodexAppServerExitStrategy: Equatable {
    case reconnectPreservingSessions
    case stopAndRemoveSessions
}

extension AppState {
    /// Session ID prefix applied to Codex threads surfaced via the app-server.
    /// Desktop app-server, rollout fallback, and state-DB discovery all use this
    /// prefix; Codex CLI keeps the raw UUID so the two modes remain distinct.
    nonisolated static let codexAppSessionPrefix = "codexapp:"
    // Plain `let` constants — nonisolated so NSWorkspace notification
    // handlers on background queues can read them without Swift 6
    // Sendable warnings.
    nonisolated static let codexAppBundleId = "com.openai.codex"

    // MARK: - Public lifecycle

    /// Start watching `com.openai.codex` in NSWorkspace and, whenever it's
    /// running, maintain a JSON-RPC client connected to `codex app-server`.
    /// Idempotent — safe to call multiple times.
    func startCodexAppServerWatcher() {
        if codexAppServerObservers != nil { return }

        var observers: [NSObjectProtocol] = []
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppState.codexAppBundleId else { return }
            Task { @MainActor in self?.startCodexAppServerClientIfPossible() }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppState.codexAppBundleId else { return }
            Task { @MainActor in self?.stopCodexAppServerClient() }
        })

        codexAppServerObservers = observers

        // Catch up with whatever state we booted into.
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == AppState.codexAppBundleId }) {
            startCodexAppServerClientIfPossible()
        }
    }

    func stopCodexAppServerWatcher() {
        codexAppServerReconnectTask?.cancel()
        codexAppServerReconnectTask = nil
        if let observers = codexAppServerObservers {
            let center = NSWorkspace.shared.notificationCenter
            for observer in observers { center.removeObserver(observer) }
            codexAppServerObservers = nil
        }
        stopCodexAppServerClient()
    }

    // MARK: - Client lifecycle

    private func startCodexAppServerClientIfPossible() {
        guard codexAppServerClient == nil else { return }
        guard let executable = Self.codexAppServerExecutableURL() else {
            scheduleCodexAppServerReconnect()
            return
        }

        let client = CodexAppServerClient(executableURL: executable)
        client.onMessage = { [weak self] message in
            Task { @MainActor in self?.handleCodexAppServerMessage(message) }
        }
        client.onExit = { [weak self, weak client] _ in
            Task { @MainActor in
                guard let self, let client,
                      self.codexAppServerClient === client else { return }
                self.handleCodexAppServerExit()
            }
        }

        do {
            try client.start()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            try client.initializeHandshake(clientName: "CodeIsland", clientVersion: version)
        } catch {
            client.stop()
            scheduleCodexAppServerReconnect()
            return
        }
        codexAppServerClient = client
    }

    nonisolated static func codexAppServerExitStrategy(
        hostRunning: Bool,
        watcherActive: Bool
    ) -> CodexAppServerExitStrategy {
        hostRunning && watcherActive
            ? .reconnectPreservingSessions
            : .stopAndRemoveSessions
    }

    private func handleCodexAppServerExit() {
        codexAppServerClient = nil
        let hostRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == AppState.codexAppBundleId
        }
        switch Self.codexAppServerExitStrategy(
            hostRunning: hostRunning,
            watcherActive: codexAppServerObservers != nil
        ) {
        case .reconnectPreservingSessions:
            // Preserve state-backed cards, refresh immediately, and restore the
            // live JSON-RPC channel with capped exponential backoff.
            requestCodexDesktopDiscoveryScan()
            scheduleCodexAppServerReconnect()
        case .stopAndRemoveSessions:
            codexAppServerReconnectTask?.cancel()
            codexAppServerReconnectTask = nil
            removeCodexAppServerSessions()
        }
    }

    private func scheduleCodexAppServerReconnect() {
        guard codexAppServerObservers != nil,
              codexAppServerReconnectTask == nil else { return }

        codexAppServerReconnectTask = Task { @MainActor [weak self] in
            var delay: UInt64 = 500_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                guard self.codexAppServerObservers != nil else {
                    self.codexAppServerReconnectTask = nil
                    return
                }
                guard NSWorkspace.shared.runningApplications.contains(where: {
                    $0.bundleIdentifier == AppState.codexAppBundleId
                }) else {
                    self.codexAppServerReconnectTask = nil
                    self.removeCodexAppServerSessions()
                    return
                }

                self.startCodexAppServerClientIfPossible()
                if self.codexAppServerClient != nil {
                    self.codexAppServerReconnectTask = nil
                    return
                }
                delay = min(delay * 2, 10_000_000_000)
            }
        }
    }

    static func codexAppServerExecutableURL(
        runningBundleURLs: [URL] = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier == AppState.codexAppBundleId ? app.bundleURL : nil
        },
        fallbackPaths: [String] = [
            CodexAppServerClient.defaultExecutablePath,
            NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex"
        ],
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [URL] = []
        for bundleURL in runningBundleURLs {
            candidates.append(bundleURL.appendingPathComponent("Contents/Resources/codex"))
        }
        candidates.append(contentsOf: fallbackPaths.map { URL(fileURLWithPath: $0) })

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return candidate
            }
        }
        return nil
    }

    private func stopCodexAppServerClient() {
        codexAppServerReconnectTask?.cancel()
        codexAppServerReconnectTask = nil
        let client = codexAppServerClient
        codexAppServerClient = nil
        client?.stop()
        removeCodexAppServerSessions()
    }

    private func removeCodexAppServerSessions() {
        let stale = sessions.keys.filter { $0.hasPrefix(AppState.codexAppSessionPrefix) }
        for id in stale {
            removeSession(id)
        }
    }

    // MARK: - Notification dispatch

    func handleCodexAppServerMessage(_ message: CodexJSONRPCMessage) {
        let params = message.raw["params"]?.asObject ?? [:]

        switch message.kind {
        case .notification(let method):
            switch method {
            case "thread/started":
                applyCodexThreadStartedNotification(params: params)
            case "thread/status/changed":
                applyCodexThreadStatusNotification(params: params)
            case "thread/closed":
                applyCodexThreadClosedNotification(params: params)
            default:
                break
            }
        case .request, .response, .error:
            // Server->client requests (plan-mode `requestUserInput`) are answered
            // in Codex itself; the thread status flag already shows the wait.
            break
        }
    }

    private func applyCodexThreadStartedNotification(params: [String: AnyCodableLike]) {
        guard let thread = params["thread"]?.asObject else { return }
        guard let threadId = thread["id"]?.asString else { return }
        let sessionId = AppState.codexAppSessionPrefix + threadId
        closedCodexAppThreads.removeValue(forKey: threadId)

        var snapshot = sessions[sessionId] ?? SessionSnapshot(startTime: Date())
        snapshot.source = "codex"
        snapshot.termBundleId = AppState.codexAppBundleId
        snapshot.providerSessionId = threadId
        if let cwd = thread["cwd"]?.asString, !cwd.isEmpty {
            snapshot.cwd = cwd
        }
        if let preview = thread["preview"]?.asString, !preview.isEmpty {
            snapshot.lastUserPrompt = preview
        }
        if let name = thread["name"]?.asString, !name.isEmpty {
            snapshot.sessionTitle = name
        }
        if let path = thread["path"]?.asString, !path.isEmpty {
            snapshot.transcriptPath = path
        }

        let waitBefore = displayOnlyWaitKind(forSession: sessionId)
        applyCodexThreadStatus(&snapshot, status: thread["status"]?.asObject)
        snapshot.lastActivity = Date()
        sessions[sessionId] = snapshot
        noteDisplayOnlyWait(sessionId: sessionId, was: waitBefore)
        attachTranscriptTailerIfNeeded(sessionId: sessionId)
        refreshDerivedState()
    }

    /// A `waitingOnApproval` / `waitingOnUserInput` flag is a display-only
    /// wait: the user answers in Codex, the island only shows and pushes it.
    private func applyCodexThreadStatusNotification(params: [String: AnyCodableLike]) {
        guard let threadId = params["threadId"]?.asString else { return }
        let sessionId = AppState.codexAppSessionPrefix + threadId
        guard var snapshot = sessions[sessionId] else { return }

        let waitBefore = displayOnlyWaitKind(forSession: sessionId)
        applyCodexThreadStatus(&snapshot, status: params["status"]?.asObject)
        snapshot.lastActivity = Date()
        sessions[sessionId] = snapshot
        noteDisplayOnlyWait(sessionId: sessionId, was: waitBefore, announce: true)
        refreshDerivedState()
    }

    private func applyCodexThreadClosedNotification(params: [String: AnyCodableLike]) {
        guard let threadId = params["threadId"]?.asString else { return }
        let sessionId = AppState.codexAppSessionPrefix + threadId
        closedCodexAppThreads[threadId] = Date()
        removeSession(sessionId)
    }

    /// Map a ThreadStatus union onto our flat AgentStatus enum. Shared between the
    /// initial `thread/started` payload (which embeds the status) and the incremental
    /// `thread/status/changed` notification.
    static func applyCodexThreadStatus(
        _ snapshot: inout SessionSnapshot,
        status: [String: AnyCodableLike]?
    ) {
        guard let typeLabel = status?["type"]?.asString else { return }
        switch typeLabel {
        case "active":
            let flags: [AnyCodableLike]
            if case .array(let a) = status?["activeFlags"] ?? .null { flags = a } else { flags = [] }
            let flagStrings = flags.compactMap { $0.asString }
            if flagStrings.contains("waitingOnApproval") {
                snapshot.status = .waitingApproval
            } else if flagStrings.contains("waitingOnUserInput") {
                snapshot.status = .waitingQuestion
            } else {
                snapshot.status = .running
                snapshot.currentTool = nil
                snapshot.toolDescription = nil
            }
        case "idle":
            snapshot.status = .idle
            snapshot.currentTool = nil
            snapshot.toolDescription = nil
        case "systemError", "notLoaded":
            snapshot.status = .idle
        default:
            break
        }
    }

    // Instance method kept for convenience on call sites that already have `self`.
    fileprivate func applyCodexThreadStatus(
        _ snapshot: inout SessionSnapshot,
        status: [String: AnyCodableLike]?
    ) {
        AppState.applyCodexThreadStatus(&snapshot, status: status)
    }
}

import Foundation
import CodeIslandCore

/// Push notifications, fed from the same places that drive the island:
/// display-only waits and the completion effect.
extension AppState {
    /// Who a session's pushes are about — the labels its card shows.
    func pushSubject(for sessionId: String) -> PushSubject {
        let session = sessions[sessionId]
        return PushSubject(
            sessionId: sessionId,
            agent: session?.sourceLabel ?? "Agent",
            project: session?.cwd == nil ? nil : session?.projectDisplayName,
            host: session?.remoteDisplayName
        )
    }

    // MARK: Request identity

    /// A display-only wait, identified by what it asks: the same wait asking
    /// something else (Claude Desktop's next card) is a new request.
    func pushRequest(forDisplayOnlyWait sessionId: String, asking content: PushContent) -> PushPendingRequest {
        let key = "wait:\(content.hashValue)"
        return PushPendingRequest(key: key) { [weak self] in
            guard let current = self?.displayOnlyWaitPushContent(forSession: sessionId),
                  "wait:\(current.hashValue)" == key else { return nil }
            return current
        }
    }

    /// Runs right after the reducer, before its side effects: a turn that
    /// ended on an API error pushes the error; any other turn end the
    /// reducer turned into a completion card pushes a completion.
    func pushAfterReduce(_ event: HookEvent, sessionId: String, effects: [SideEffect]) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        let session = sessions[sessionId]
        if let failure = PushEventClassifier.sessionError(eventName: event.eventName, raw: event.rawJSON) {
            notifier.notify(
                .error(type: failure.type, detail: failure.detail),
                subject: pushSubject(for: sessionId),
                smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId)
            )
            return
        }
        guard effects.contains(.enqueueCompletion(sessionId: sessionId)) else { return }
        notifier.notify(
            .completion(summary: Self.pushCompletionSummary(session)),
            subject: pushSubject(for: sessionId),
            smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId),
            isSubagent: PushEventClassifier.isSubagentCompletion(
                agentId: event.agentId,
                raw: event.rawJSON,
                sessionId: sessionId,
                session: session
            ),
            interrupted: session?.interrupted == true
        )
    }

    /// AiWork daemon turn boundary (its streams bypass the hook reducer).
    func pushAiWorkTurnEnded(_ eventName: String, sessionId: String, data: [String: AnyCodableLike]? = nil) {
        switch eventName {
        case "stream.completed": pushTurnEnded(sessionId: sessionId, failed: false)
        case "stream.failed":
            pushTurnEnded(sessionId: sessionId, failed: true, errorDetail: Self.aiworkFailureText(data))
        default: return  // stream.aborted: the user stopped it
        }
    }

    /// What a `stream.failed` event itself says went wrong, if anything.
    nonisolated static func aiworkFailureText(_ data: [String: AnyCodableLike]?) -> String? {
        guard let data else { return nil }
        let candidates = [
            data["error"]?.asString,
            data["error"]?.asObject?["message"]?.asString,
            data["error_message"]?.asString,
            data["terminal_notice"]?.asObject?["summary"]?.asString,
            data["reason"]?.asString,
        ]
        return candidates.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// A turn ended in a source that bypasses the hook reducer (AiWork,
    /// Claude Desktop Cowork): its completion, or its error when it failed.
    ///
    /// - `errorDetail`: the failure's own text, from the event that reported
    ///   it. Never the session's last reply — that can be the previous
    ///   turn's; with nothing better the push says only that it failed.
    func pushTurnEnded(sessionId: String, failed: Bool, errorDetail: String? = nil) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        let session = sessions[sessionId]
        let content: PushContent = failed
            ? .error(type: nil, detail: errorDetail)
            : .completion(summary: Self.pushCompletionSummary(session))
        notifier.notify(
            content,
            subject: pushSubject(for: sessionId),
            smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId)
        )
    }

    /// Subscribes the push channels to follow-up reminders. Called once at launch.
    func connectPushToFollowUps() {
        followUps.addReminderHandler { [weak self] reminder in
            self?.pushFollowUpReminder(reminder)
        }
    }

    /// A follow-up reminder came due. It carries the same command / question
    /// as the first push, plus how long it has been waiting.
    ///
    /// - `.deferred`: the Mac held its own reminder back (locked, screen
    ///   saver, quiet hours) — the moment a phone matters most.
    /// - `.onTime`: played on the Mac as well — unless `locallySuppressed`:
    ///   the island kept quiet because the user seemed to be in front of it
    ///   (the session's terminal tab in front, the card under the pointer).
    ///   That is Smart Suppress's call, and the gate honours it only while
    ///   someone is at the Mac. Away, the phone gets it; the controller then
    ///   counts it as an attempt (`remoteChannelDelivered`).
    /// - `.catchUp`: the local replay after the hold ended; the person is
    ///   back and the deferred one already went out.
    @discardableResult
    func pushFollowUpReminder(_ reminder: FollowUpReminder) -> PushDecision {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return .disabled }
        if reminder.delivery == .catchUp { return .skipped(.userPresent) }
        let sessionId = reminder.sessionId
        let pending: PushContent
        // Approvals and questions: what the wait asked, with where to answer it.
        switch reminder.kind {
        case .approval, .question:
            guard let waiting = displayOnlyWaitPushContent(forSession: sessionId, kind: reminder.kind) else {
                return .skipped(.nothingPending)
            }
            pending = waiting
        case .completion:
            // One nudge for a finished turn nobody looked at. If the turn's own
            // completion push reached the phone, the nudge would only repeat
            // it; if the turn failed, "finished" would be wrong. (Both are
            // decided just before the reminder's clock starts, hence the slack.)
            if notifier.shouldSkipCompletionReminder(sessionId: sessionId, since: reminder.waitingSince.addingTimeInterval(-5)) {
                return .skipped(.duplicate)
            }
            pending = .completion(summary: Self.pushCompletionSummary(sessions[sessionId]))
        }
        let decision = notifier.notify(
            .reminder(pending: pending, waitingSince: reminder.waitingSince),
            subject: pushSubject(for: sessionId),
            smartSuppressed: reminder.locallySuppressed
        )
        if case .sent = decision {
            followUps.remoteChannelDelivered(reminder)
        }
        return decision
    }

    // MARK: Content

    nonisolated static func pushContent(forPermission event: HookEvent, cwd: String?) -> PushContent {
        .permission(
            tool: event.toolName,
            detail: PushDetailSummarizer.permissionDetail(
                toolInput: event.toolInput,
                fallback: event.toolDescription,
                cwd: cwd
            )
        )
    }

    /// The reply the completion card shows: this turn's last assistant
    /// message. `lastAssistantMessage` alone can still hold the previous
    /// turn's text when a Stop arrived without one, and the "Reply complete"
    /// placeholder says nothing a phone needs.
    static func pushCompletionSummary(_ session: SessionSnapshot?) -> String? {
        guard let session else { return nil }
        if let last = session.recentMessages.last {
            guard !last.isUser else { return nil }
            let placeholders = Set(L10n.strings.values.compactMap { $0["reply_complete_placeholder"] })
            return placeholders.contains(last.text) ? nil : last.text
        }
        return session.lastAssistantMessage
    }
}

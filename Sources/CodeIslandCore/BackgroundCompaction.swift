import Foundation

/// A context compaction the CLI runs on its own while no turn is running.
///
/// Claude Desktop compacts a Code-tab session that has sat idle: the hook
/// fires `PreCompact` (`trigger: "auto"`) and then `SubagentStop` for the
/// summarizer, but no prompt starts and no `Stop` follows. Read as the start
/// of work, it left a finished session "thinking" for good.
public enum BackgroundCompaction {
    /// Whether this hook is an automatic compaction. A compaction during a
    /// turn has the same shape; the session's status tells the two apart.
    public static func isAutomaticCompaction(_ event: HookEvent) -> Bool {
        let name = EventNormalizer.normalize(event.eventName)
        guard name == "PreCompact" || name == "PostCompact" else { return false }
        return (event.rawJSON["trigger"] as? String)?.lowercased() == "auto"
    }

    /// Whether this hook, for a session with no card, should leave it without
    /// one: an automatic compaction, or a subagent stopping, is the CLI
    /// tidying up, not the user starting work.
    public static func isHousekeepingWithoutCard(_ event: HookEvent) -> Bool {
        if isAutomaticCompaction(event) { return true }
        return EventNormalizer.normalize(event.eventName) == "SubagentStop"
    }
}

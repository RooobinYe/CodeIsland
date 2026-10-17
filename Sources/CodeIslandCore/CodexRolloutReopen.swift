import Foundation

/// Opening a past thread in Codex Desktop is not activity, but it looks like
/// it: Codex appends an `event_msg` / `thread_settings_applied` line to the
/// thread's rollout and bumps its `updated_at` in state_5.sqlite, so both the
/// rollout's mtime and the database say the thread was just touched. The
/// first prompt is what should bring the card, as for Claude Desktop.
public enum CodexRolloutReopen {
    /// `event_msg` payload types Codex writes when a thread is opened without
    /// a new turn.
    static let reopenEventTypes: Set<String> = ["thread_settings_applied"]

    /// When the rollout ends with lines written only by opening the thread,
    /// the time of the last real activity line before them; nil when the
    /// rollout ends with real activity, or when that time can't be read, so
    /// the caller keeps the times it has.
    public static func lastActivityBeforeReopen(path: String, maxBytes: Int = 256 * 1024) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return nil }
        return lastActivityBeforeReopen(inTail: data, startsMidLine: start > 0)
    }

    /// The same, over the last bytes of a rollout. `startsMidLine` drops the
    /// first line, which a tail read may have cut.
    public static func lastActivityBeforeReopen(inTail data: Data, startsMidLine: Bool = false) -> Date? {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }

        var sawReopen = false
        for line in lines.reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                // A line still being written: whatever it is, it is newer.
                return nil
            }
            let payload = json["payload"] as? [String: Any]
            if json["type"] as? String == "event_msg",
               let payloadType = payload?["type"] as? String,
               reopenEventTypes.contains(payloadType) {
                sawReopen = true
                continue
            }
            guard sawReopen else { return nil }
            return (json["timestamp"] as? String).flatMap(TranscriptTimestamp.parse)
        }
        return nil
    }
}

import Foundation

/// Transcript line timestamps ("2026-09-12T03:35:41.545Z"), with or without
/// fractional seconds.
public enum TranscriptTimestamp {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    public static func parse(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}

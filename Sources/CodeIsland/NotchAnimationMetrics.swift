import Foundation

/// Speed multiplier for the island's open and close animations.
/// Higher values shorten the spring response while preserving its damping.
enum NotchAnimationSpeed {
    static let minimum = 0.5
    static let maximum = 2.0
    static let step = 0.1
    static let normal = 1.0

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return normal }
        return min(max(value, minimum), maximum)
    }

    static func response(base: TimeInterval, speed: Double) -> TimeInterval {
        base / clamped(speed)
    }
}

enum NotchAnimationMetrics {
    /// Unscaled spring responses at 1.0x speed.
    static let baseOpenResponse: TimeInterval = 0.42
    static let baseCloseResponse: TimeInterval = 0.38
    static let basePopResponse: TimeInterval = 0.36

    /// The expanded content fades in a beat behind the island's shape, and
    /// out well ahead of it, so it never rides the shape's edge.
    static let baseContentFadeIn: TimeInterval = 0.22
    static let baseContentFadeInDelay: TimeInterval = 0.05
    static let baseContentFadeOut: TimeInterval = 0.1

    static var openResponse: TimeInterval { scaled(baseOpenResponse) }
    static var closeResponse: TimeInterval { scaled(baseCloseResponse) }
    static var popResponse: TimeInterval { scaled(basePopResponse) }

    /// A base duration at the user's animation speed.
    static func scaled(_ base: TimeInterval) -> TimeInterval {
        NotchAnimationSpeed.response(base: base, speed: storedSpeed)
    }

    private static var storedSpeed: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKey.notchAnimationSpeed) != nil else {
            return NotchAnimationSpeed.normal
        }
        return NotchAnimationSpeed.clamped(defaults.double(forKey: SettingsKey.notchAnimationSpeed))
    }
}

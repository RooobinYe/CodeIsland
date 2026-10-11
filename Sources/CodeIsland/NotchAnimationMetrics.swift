import Foundation

enum NotchAnimationMetrics {
    /// Spring responses for the island's open, close and pop.
    static let openResponse: TimeInterval = 0.42
    static let closeResponse: TimeInterval = 0.38
    static let popResponse: TimeInterval = 0.36

    /// The expanded content fades in a beat behind the island's shape, and
    /// out well ahead of it, so it never rides the shape's edge.
    static let contentFadeIn: TimeInterval = 0.22
    static let contentFadeInDelay: TimeInterval = 0.05
    static let contentFadeOut: TimeInterval = 0.1
}

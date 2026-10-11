import SwiftUI

enum NotchAnimation {
    /// 展开面板：微弹，有少许回弹感
    static var open: Animation {
        .spring(response: NotchAnimationMetrics.openResponse, dampingFraction: 0.82)
    }
    /// 收起面板：临界阻尼，无过冲（防止 NotchPanelShape 底边露出刘海）
    static var close: Animation {
        .spring(response: NotchAnimationMetrics.closeResponse, dampingFraction: 1.0)
    }
    /// 通知弹出：比 open 更利落、带一点回弹，用于 completion/approval 自动展开
    static var pop: Animation {
        .spring(response: NotchAnimationMetrics.popResponse, dampingFraction: 0.74)
    }
    /// 微交互：hover 状态变化、按钮高亮等
    static let micro = Animation.easeOut(duration: 0.12)
}

// MARK: - Expanded content transition

extension AnyTransition {
    /// The expanded content stays put while the island's shape grows over it
    /// and fades in a beat behind the shape; on close it fades out before the
    /// shape has shrunk around it. Nothing slides: a list travelling its full
    /// height turned any frame the main thread missed into a visible jump.
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)).animation(
                .easeOut(duration: NotchAnimationMetrics.scaled(NotchAnimationMetrics.baseContentFadeIn))
                    .delay(NotchAnimationMetrics.scaled(NotchAnimationMetrics.baseContentFadeInDelay))
            ),
            removal: .opacity.animation(
                .easeOut(duration: NotchAnimationMetrics.scaled(NotchAnimationMetrics.baseContentFadeOut))
            )
        )
    }
}

// MARK: - MorphText — blur morph on text change

/// Text that briefly blurs when its content changes, creating a smooth "morph" effect.
///
/// Opt in with `streamsRapidly` for sources that push token-level deltas (AiWork /
/// Agentix `stream.text_delta` into the `$` row): those updates swap text
/// immediately instead of morphing, because each change would otherwise restart the
/// blur cycle and leave the label permanently unreadable. Every other caller keeps
/// the original morph behaviour — this is deliberately not a global change.
struct MorphText: View {
    let text: String
    var font: Font = .system(size: 12)
    var color: Color = .white
    var lineLimit: Int? = 1
    /// True only for sources in `SessionSnapshot.rapidStreamingSources`.
    var streamsRapidly: Bool = false

    @State private var displayed: String
    @State private var blur: CGFloat = 0
    @State private var generation = 0
    /// Monotonic (`systemUptime`), not wall-clock: an NTP correction or a
    /// sleep/wake that steps the clock backward would make the elapsed test
    /// negative and pin the label into no-morph mode.
    @State private var lastChangeAt: TimeInterval = -.greatestFiniteMagnitude

    /// Updates arriving within this window are treated as a stream, not a morph.
    private static let streamWindow: TimeInterval = 0.22

    init(
        text: String,
        font: Font = .system(size: 12),
        color: Color = .white,
        lineLimit: Int? = 1,
        streamsRapidly: Bool = false
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        self.streamsRapidly = streamsRapidly
        _displayed = State(initialValue: text)
    }

    var body: some View {
        Text(displayed)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .blur(radius: blur * 4)
            .opacity(1 - blur * 0.15)
            .compositingGroup()
            .onChange(of: text) { _, newText in
                guard newText != displayed else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let streaming = streamsRapidly
                    && (now - lastChangeAt < Self.streamWindow || blur > 0.01)
                lastChangeAt = now
                generation += 1
                let gen = generation

                if streaming {
                    // Keep the label sharp while content is still arriving.
                    displayed = newText
                    if blur != 0 {
                        withAnimation(.easeOut(duration: 0.12)) { blur = 0 }
                    }
                    return
                }

                withAnimation(.easeOut(duration: 0.1)) { blur = 1 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard gen == generation else { return }
                    displayed = newText
                    withAnimation(.easeOut(duration: 0.15)) { blur = 0 }
                }
            }
    }
}

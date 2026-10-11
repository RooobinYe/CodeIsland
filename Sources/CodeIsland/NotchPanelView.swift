import SwiftUI
import CodeIslandCore

/// Shared bounds for the collapsed-width scale setting — keeps the settings
/// slider and the width math in lockstep. Percent of the (simulated) notch width.
enum NotchWidthScale {
    static let min = 50
    static let max = 150
    static let step = 1
}

enum NotchWidthMetrics {
    /// Applies on notched displays too: below 100% the wings move in over the
    /// physical notch, so the visible island narrows.
    static func effectiveNotchWidth(notchW: CGFloat, collapsedWidthScale: Int) -> CGFloat {
        let clampedScale = Swift.max(NotchWidthScale.min, Swift.min(collapsedWidthScale, NotchWidthScale.max))
        return notchW * CGFloat(clampedScale) / 100.0
    }
}

// MARK: - Hover interaction state machine

/// Where the island is in its hover interaction. `prehover` is the immediate
/// lightweight acknowledgement (slight widen + scale) shown while the expand
/// delay is still running — a quick mouse pass-through only ever plays this
/// first stage and reverses, instead of popping the full panel open.
enum NotchHoverPhase {
    case collapsed
    case prehover
    case expanded
}

enum NotchHoverEvent {
    case mouseEntered
    case mouseExited
    case expandDelayElapsed
    case collapseDelayElapsed
}

enum NotchHoverInteraction {
    static let prehoverAnimationDuration: TimeInterval = 0.21
    static let expandDelay: TimeInterval = 0.5
    static let collapseDelay: TimeInterval = 0.5
    static let prehoverWidthDelta: CGFloat = 7
    static let prehoverScale: CGFloat = 1.004

    /// User-tunable range for `expandDelay` (Settings → Behavior). Below 0.1s
    /// every pass of the pointer toward the menu bar would pop the panel open;
    /// past 1s the island stops feeling like it responds to hover at all.
    static let expandDelayRange: ClosedRange<TimeInterval> = 0.1...1.0
    static let expandDelayStep: TimeInterval = 0.05

    /// The stored preference, clamped into `expandDelayRange`. A value written
    /// by hand (`defaults write`) or a corrupt one must never yield a zero or
    /// negative timer interval, so non-finite input falls back to the default.
    static func expandDelay(forSetting raw: Double) -> TimeInterval {
        guard raw.isFinite else { return expandDelay }
        return min(max(raw, expandDelayRange.lowerBound), expandDelayRange.upperBound)
    }

    static func nextPhase(from phase: NotchHoverPhase, event: NotchHoverEvent) -> NotchHoverPhase {
        switch (phase, event) {
        case (.collapsed, .mouseEntered):
            return .prehover
        case (.prehover, .mouseExited):
            return .collapsed
        case (.prehover, .expandDelayElapsed):
            return .expanded
        case (.expanded, .collapseDelayElapsed):
            return .collapsed
        default:
            return phase
        }
    }
}

enum ToolNameDisplay {
    static let compactMaxCharacters = 24

    static func compact(_ tool: String, maxCharacters: Int = compactMaxCharacters) -> String {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 3, trimmed.count > maxCharacters else { return trimmed }

        let components = trimmed.components(separatedBy: "__")
        let meaningfulSuffix: String?
        if components.count > 1, let last = components.last, !last.isEmpty {
            meaningfulSuffix = last
        } else {
            meaningfulSuffix = nil
        }
        let minimumPrefixCount = max(1, min(4, maxCharacters - 4))
        let suffixBudget = max(1, maxCharacters - minimumPrefixCount - 3)
        let suffixCount = meaningfulSuffix.map { min($0.count, suffixBudget) } ?? max(4, maxCharacters / 2)
        let prefixCount = max(1, maxCharacters - suffixCount - 3)
        return "\(trimmed.prefix(prefixCount))...\(trimmed.suffix(suffixCount))"
    }
}

struct NotchPanelView: View {
    var appState: AppState
    let hasNotch: Bool
    let notchHeight: CGFloat
    let notchW: CGFloat
    let screenWidth: CGFloat

    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.showAgentDetails) private var showAgentDetails = SettingsDefaults.showAgentDetails
    @AppStorage(SettingsKey.smartSuppress) private var smartSuppress = SettingsDefaults.smartSuppress
    @AppStorage(SettingsKey.hideWhenNoSession) private var hideWhenNoSession = SettingsDefaults.hideWhenNoSession
    @AppStorage(SettingsKey.collapsedWidthScale) private var collapsedWidthScale = SettingsDefaults.collapsedWidthScale
    @AppStorage(SettingsKey.hapticOnHover) private var hapticOnHover = SettingsDefaults.hapticOnHover
    @AppStorage(SettingsKey.hapticIntensity) private var hapticIntensity = SettingsDefaults.hapticIntensity
    @AppStorage(SettingsKey.showSessionRecap) private var showSessionRecap = SettingsDefaults.showSessionRecap
    @AppStorage(SettingsKey.hoverExpandDelay) private var hoverExpandDelay = SettingsDefaults.hoverExpandDelay
    @AppStorage(SettingsKey.showProjectName) private var showProjectName = SettingsDefaults.showProjectName

    /// Delayed hover: prevents accidental expansion when mouse passes through
    @State private var hoverTimer: Timer?
    @State private var isHovered = false
    @State private var idleHovered = false
    /// Three-stage hover: collapsed → prehover (immediate ack) → expanded (after delay)
    @State private var hoverPhase: NotchHoverPhase = .collapsed
    /// Window height and card chrome for the completion card's reply area.
    @State private var cardSpace = CompletionCardSpace()
    /// Measured width of the collapsed right wing (0 until first laid out).
    @State private var rightWingWidth: CGFloat = 0
    /// The session list's natural height, kept while the island is collapsed:
    /// the list is rebuilt on every open, and starting it from 0 laid it out
    /// unscrolled first, then again inside the scroll view a frame later —
    /// twice the work, and a target height that moved mid-animation.
    @State private var listContentHeight: CGFloat = 0

    private var isActive: Bool { !appState.sessions.isEmpty }
    /// First launch / no-session state should still render a visible marker so the app
    /// doesn't disappear completely behind the physical notch.
    private var showIdleIndicator: Bool {
        !isActive && !hideWhenNoSession
    }
    /// Whether the bar content should be visible (respects hideWhenNoSession)
    private var showBar: Bool {
        isActive && !appState.hidesCollapsedBar(hideWhenNoSession: hideWhenNoSession)
    }
    private var shouldShowExpanded: Bool {
        showBar && appState.surface.isExpanded
    }
    /// Neither bar nor idle indicator: the island is the notch itself — what a
    /// hidden island closes into before its window goes away.
    private var isNotchShell: Bool {
        !showBar && !showIdleIndicator
    }
    /// Prehover acknowledgement is only rendered on the collapsed active bar —
    /// once the surface expands (from hover or any other path) it disappears.
    private var shouldShowPrehover: Bool {
        showBar && !shouldShowExpanded && hoverPhase == .prehover
    }

    private var collapsedRecapTooltip: String {
        guard showSessionRecap, !shouldShowExpanded else { return "" }
        let sid = appState.rotatingSessionId ?? appState.activeSessionId ?? appState.sessions.keys.sorted().first
        return SessionMetadataStyle.collapsedRecapTooltip(
            for: sid.flatMap { appState.sessions[$0] },
            showProjectName: showProjectName
        )
    }

    /// Mascot size — fits within the menu bar height
    private var mascotSize: CGFloat { min(27, notchHeight - 6) }

    /// Minimum width of the collapsed bar's right wing
    private var compactWingWidth: CGFloat { mascotSize + 14 }

    /// Effective island width — the notch (physical or simulated) scaled by the setting.
    private var effectiveNotchW: CGFloat {
        NotchWidthMetrics.effectiveNotchWidth(
            notchW: notchW,
            collapsedWidthScale: collapsedWidthScale
        )
    }

    /// Total panel width — adapts based on state and screen geometry
    private var panelWidth: CGFloat {
        let nw = effectiveNotchW
        let lip = CompactRightWingLayout.leadingLip
        if showIdleIndicator { return lip + nw + (idleHovered ? compactWingWidth + 40 : compactWingWidth) }
        if isNotchShell { return notchW }
        if shouldShowExpanded { return min(max(nw + 200, 580), maxPanelWidth) }
        return lip + nw + collapsedRightRoom
    }

    /// The panel window's width (PanelWindowController.panelSize).
    private var maxPanelWidth: CGFloat { min(620, screenWidth - 40) }

    /// The collapsed bar's right wing: its content clear of the notch, never
    /// under the minimum wing (a little more while a session works).
    private var collapsedRightRoom: CGFloat {
        let working: CGFloat = appState.status == .idle ? 0 : 10
        // Immediate hover acknowledgement: a slight widen while the expand delay runs
        let prehoverExtra: CGFloat = shouldShowPrehover ? NotchHoverInteraction.prehoverWidthDelta : 0
        return CompactRightWingLayout.room(contentWidth: rightWingWidth, minimum: compactWingWidth + working)
            + prehoverExtra
    }

    /// Collapsed bars hang off the notch's right, so they shift right to keep
    /// the (physical or simulated) notch centred; expanded stays centred.
    private var barOffset: CGFloat {
        guard (showBar && !shouldShowExpanded) || showIdleIndicator else { return 0 }
        return (panelWidth - effectiveNotchW) / 2 - CompactRightWingLayout.leadingLip
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if showBar {
                    // Active: compact bar — wider version when expanded
                    HStack(spacing: 0) {
                        if shouldShowExpanded {
                            AppLogoView(size: 36, showBackground: false)
                                .padding(.leading, 6)
                        } else {
                            // Collapsed: nothing left of the notch but a lip.
                            Color.clear
                                .frame(width: CompactRightWingLayout.leadingLip + effectiveNotchW)
                        }
                        Spacer(minLength: 0)
                        CompactRightWing(appState: appState, expanded: shouldShowExpanded, hasNotch: hasNotch)
                    }
                    .frame(height: notchHeight)
                    // Recap on hover while collapsed — shows whenever hover
                    // doesn't expand the panel (smart suppress with the
                    // terminal frontmost); expanded cards show it inline.
                    .help(collapsedRecapTooltip)
                    // 0 while expanded (only the collapsed wing reports) — keep
                    // the last width for the next collapse.
                    .onPreferenceChange(CompactRightWingWidthKey.self) { if $0 > 0 { rightWingWidth = $0 } }
                } else if showIdleIndicator {
                    IdleIndicatorBar(
                        notchW: effectiveNotchW,
                        notchHeight: notchHeight,
                        hasNotch: hasNotch,
                        hovered: idleHovered
                    )
                } else {
                    // Idle: just the notch shell
                    Spacer()
                        .frame(height: notchHeight)
                }

                // Below-notch expanded content
                if shouldShowExpanded {
                    Line()
                        .stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                        .frame(height: 0.5)
                        .padding(.horizontal, 12)
                        .transition(.islandContent)

                    switch appState.surface {
                    case .completionCard:
                        // The card never scrolls: its height is not the list's.
                        SessionListView(appState: appState, onlySessionId: appState.justCompletedSessionId,
                                        contentHeight: .constant(0))
                            .transition(.islandContent)
                    case .sessionList:
                        SessionListView(appState: appState, onlySessionId: nil,
                                        contentHeight: $listContentHeight)
                            .transition(.islandContent)
                    case .collapsed:
                        EmptyView()
                    }
                }
            }
            .recordsCompletionCardChrome(in: cardSpace)
            // Explicit height whenever collapsed: a close then shrinks width and
            // height on one spring, instead of the height trailing the width
            // while the expanded content is still being removed.
            .frame(width: panelWidth, height: shouldShowExpanded ? nil : notchHeight, alignment: .top)
            .clipped()
            .background(
                NotchPanelShape(
                    topExtension: shouldShowExpanded ? 14 : (isNotchShell ? 0 : 3),
                    bottomRadius: shouldShowExpanded ? 24 : 12,
                    minHeight: notchHeight
                )
                .fill(.black)
            )
            .scaleEffect(shouldShowPrehover ? NotchHoverInteraction.prehoverScale : 1, anchor: .top)
            .contentShape(Rectangle())
            .onHover { hovering in
                // The pointer is on the island itself — what follow-up
                // reminders count as "reading this card" — whatever the
                // hover then does to the surface below.
                appState.followUps.pointerOverIsland = hovering
                // Idle indicator hover — delay un-hover to prevent oscillation when
                // the animated width change crosses the mouse position (#52).
                if showIdleIndicator {
                    if hovering {
                        hoverTimer?.invalidate()
                        hoverTimer = nil
                        withAnimation(NotchAnimation.micro) { idleHovered = true }
                    } else {
                        hoverTimer?.invalidate()
                        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                            Task { @MainActor in
                                withAnimation(NotchAnimation.micro) { idleHovered = false }
                            }
                        }
                    }
                    return
                }
                switch appState.surface {
                case .completionCard:
                    // Completion card: mark entered on hover-in, block collapse until entered
                    if hovering {
                        appState.completionHasBeenEntered = true
                    } else if appState.completionHasBeenEntered || appState.deferCollapseOnMouseLeave {
                        // Mouse entered then left — allow collapse (immediate or deferred)
                        hoverTimer?.invalidate()
                        hoverTimer = nil
                        appState.deferCollapseOnMouseLeave = false
                        appState.cancelCompletionQueue()
                        withAnimation(NotchAnimation.close) {
                            appState.surface = .collapsed
                        }
                    }
                    return
                default: break
                }
                // Respect collapseOnMouseLeave setting
                if !hovering && !SettingsManager.shared.collapseOnMouseLeave { return }
                // Smart suppress: don't auto-expand when active session's terminal is foreground
                if hovering && smartSuppress {
                    if let delegate = NSApp.delegate as? AppDelegate,
                       let pc = delegate.panelController,
                       pc.isActiveTerminalForeground() {
                        return
                    }
                }

                isHovered = hovering
                if hovering {
                    // Immediate lightweight acknowledgement; a quick pass-through
                    // only ever plays this first stage and reverses.
                    withAnimation(NotchAnimation.hoverPrehover) {
                        hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .mouseEntered)
                    }
                    // Delay full expansion to avoid accidental triggers
                    hoverTimer?.invalidate()
                    hoverTimer = Timer.scheduledTimer(
                        withTimeInterval: NotchHoverInteraction.expandDelay(forSetting: hoverExpandDelay),
                        repeats: false
                    ) { _ in
                        Task { @MainActor in
                            // Guard: mouse may have left during the delay
                            guard isHovered else { return }
                            if hapticOnHover {
                                let performer = NSHapticFeedbackManager.defaultPerformer
                                switch hapticIntensity {
                                case 3: // strong: two taps
                                    performer.perform(.levelChange, performanceTime: .now)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        performer.perform(.levelChange, performanceTime: .now)
                                    }
                                case 2: // medium
                                    performer.perform(.levelChange, performanceTime: .default)
                                default: // light
                                    performer.perform(.alignment, performanceTime: .default)
                                }
                            }
                            // One transaction: the prehover widen hands over to
                            // the open spring instead of snapping back first.
                            withAnimation(NotchAnimation.open) {
                                hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .expandDelayElapsed)
                                appState.surface = .sessionList
                                appState.cancelCompletionQueue()
                                if appState.activeSessionId == nil {
                                    appState.activeSessionId = appState.sessions.keys.sorted().first
                                }
                            }
                        }
                    }
                } else {
                    // Reverse the prehover acknowledgement right away…
                    withAnimation(NotchAnimation.hoverPrehover) {
                        hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .mouseExited)
                    }
                    // …and collapse an expanded panel after a grace delay so an
                    // accidental mouse-out doesn't flicker it shut.
                    hoverTimer?.invalidate()
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: NotchHoverInteraction.collapseDelay, repeats: false) { _ in
                        Task { @MainActor in
                            guard !isHovered else { return }
                            withAnimation(NotchAnimation.close) {
                                hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .collapseDelayElapsed)
                                appState.surface = .collapsed
                            }
                        }
                    }
                }
            }
            .onChange(of: appState.surface) { _, newSurface in
                // The surface can change from outside the hover flow (auto-expand
                // cards, click-to-close, …) — keep the phase from going stale.
                if newSurface == .collapsed && !isHovered {
                    hoverPhase = .collapsed
                } else if newSurface.isExpanded && hoverPhase != .expanded {
                    hoverPhase = .expanded
                }
            }
            // Outside onHover on purpose: the hover region moves with the bar.
            .offset(x: barOffset)

            Spacer()
                .allowsHitTesting(false)
        }
        // minHeight 0: the frame is the window's height even when the content
        // runs taller (without it the frame grows with its content), so the
        // measurement below is the window, and any overflow runs off the
        // bottom instead of pushing the notch bar off the top.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        // The hosting view fills the panel window, whose height is already
        // clamped to the screen.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardSpace.recordWindowHeight($0) }
        .environment(cardSpace)
        // No `.animation(_:value: surface)` here: an implicit animation wins
        // over `withAnimation`, which turned every close and every pop into
        // the open spring. Each change of surface brings its own.
    }
}

// MARK: - Compact Wings (notch-level, 32px height)

/// Right side: project name + session count (detailed) or just count (simple)
private struct CompactRightWing: View {
    var appState: AppState
    let expanded: Bool
    let hasNotch: Bool
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled
    @AppStorage(SettingsKey.quietHoursEnabled) private var quietHoursEnabled = SettingsDefaults.quietHoursEnabled
    @AppStorage(SettingsKey.quietHoursStart) private var quietHoursStart = SettingsDefaults.quietHoursStart
    @AppStorage(SettingsKey.quietHoursEnd) private var quietHoursEnd = SettingsDefaults.quietHoursEnd
    /// The waiting badges pulse forever; with Reduce Motion they hold still
    /// (a one-off follow-up bounce still marks a reminder).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Re-evaluated on every re-render; the compact bar redraws often enough
    /// that the moon appears/disappears close to the window edges.
    private var inQuietHours: Bool {
        guard soundEnabled, quietHoursEnabled else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return SoundManager.isInQuietHours(
            minutesSinceMidnight: (c.hour ?? 0) * 60 + (c.minute ?? 0),
            start: quietHoursStart,
            end: quietHoursEnd
        )
    }

    private var displaySessionId: String? {
        appState.rotatingSessionId ?? appState.activeSessionId ?? appState.sessions.keys.sorted().first
    }
    private var projectName: String? {
        guard let sid = displaySessionId, let cwd = appState.sessions[sid]?.cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            if expanded {
                ExpandedHeaderControls(soundEnabled: $soundEnabled)
            } else {
                // Quiet hours active — explains why event sounds are silent.
                if inQuietHours {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .help(l10n["quiet_hours"])
                }

                // Glance completion dot — an agent finished while collapsed;
                // cleared as soon as the panel expands.
                if appState.glanceCompletionActive {
                    Circle()
                        .fill(Color(red: 0.4, green: 1.0, blue: 0.5))
                        .frame(width: 7, height: 7)
                        .shadow(color: Color(red: 0.4, green: 1.0, blue: 0.5).opacity(0.7), radius: 3)
                }

                if appState.followUps.hintActive {
                    // Follow-up reminder fired while collapsed: badge the bell and
                    // bounce it on each reminder, until the island is opened or
                    // the item resolves.
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.7, blue: 0.28))
                        .symbolEffect(.bounce, value: appState.followUps.hintPulse)
                        .help(l10n["follow_up_hint"])
                } else if appState.status == .waitingApproval || appState.status == .waitingQuestion {
                    // A session is blocked on the user
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.7, blue: 0.28))
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                }

                // Session count: active / total
                HStack(spacing: 1) {
                    let active = appState.activeSessionCount
                    let total = appState.totalSessionCount
                    if active > 0 {
                        Text("\(active)")
                            .foregroundStyle(Color(red: 0.4, green: 1.0, blue: 0.5))
                        Text("/")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text("\(total)")
                        .foregroundStyle(.white.opacity(0.9))
                }
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
        }
        .padding(.trailing, 6)
        // Its natural width, reported so the collapsed bar can make room for
        // it clear of the notch (CompactRightWingLayout).
        .fixedSize(horizontal: true, vertical: false)
        .background(GeometryReader { geo in
            Color.clear.preference(key: CompactRightWingWidthKey.self, value: expanded ? 0 : geo.size.width)
        })
    }
}

struct NotchIconButton: View {
    let icon: String
    var tint: Color = .white
    var tooltip: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The drawn circle, and the hit target around it.
    static let circleSize: CGFloat = 22
    static let hitSize: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.opacity(hovering ? 1.0 : 0.85))
                .frame(width: Self.circleSize, height: Self.circleSize)
                .background(
                    Circle()
                        .fill(tint.opacity(hovering ? 0.2 : 0.08))
                )
                .scaleEffect(hovering && !reduceMotion ? 1.1 : 1.0)
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
        .help(tooltip ?? "")
        // Icon-only: VoiceOver would otherwise read the symbol name
        // ("gearshape"), in English, instead of what the button does.
        .accessibilityLabel(tooltip ?? icon)
    }
}

/// The expanded header's buttons: sound, Settings, and Quit, which asks once.
private struct ExpandedHeaderControls: View {
    @Binding var soundEnabled: Bool
    @StateObject private var quit = QuitConfirmation()
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 4pt between 24pt hit targets keeps the 6pt gap between the circles.
        HStack(spacing: 4) {
            NotchIconButton(icon: soundEnabled ? "speaker.wave.2" : "speaker.slash", tooltip: soundEnabled ? l10n["mute"] : l10n["enable_sound_tooltip"]) {
                soundEnabled.toggle()
            }
            NotchIconButton(icon: "gearshape", tooltip: l10n["settings"]) {
                SettingsWindowController.shared.show()
            }
            QuitConfirmButton(confirmation: quit)
        }
        // The pill is wider than the icon: the other buttons slide over to
        // make room, or with Reduce Motion simply move.
        .animation(reduceMotion ? nil : NotchAnimation.micro, value: quit.isArmed)
    }
}

/// The power button, which asks once (QuitConfirmation): the first click
/// turns it into a red "QUIT?" pill, a second click within three seconds
/// quits. The pill grows to the left, so the pointer that armed it stays on
/// it; leaving it reverts the button. The row it sits in owns the
/// confirmation, so it can animate (and make room for) the wider pill.
struct QuitConfirmButton: View {
    @ObservedObject var confirmation: QuitConfirmation
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    static let tint = Color(red: 1.0, green: 0.4, blue: 0.4)
    /// The pill's text: lighter than `tint`, for contrast on its red fill.
    static let pillText = Color(red: 1.0, green: 0.55, blue: 0.55)
    static let pillFontSize: CGFloat = 10
    static let pillPadding: CGFloat = 7

    /// The armed pill's width for its (localized) text — kept short enough
    /// to fit beside the notch (see PanelChromeTests).
    static func pillWidth(for text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: pillFontSize, weight: .bold)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + pillPadding * 2
    }

    init(confirmation: QuitConfirmation) {
        self.confirmation = confirmation
    }

    var body: some View {
        let armed = confirmation.isArmed
        Button {
            confirmation.press()
        } label: {
            ZStack(alignment: .trailing) {
                if armed {
                    Text(l10n["quit_confirm"])
                        .font(.system(size: Self.pillFontSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.pillText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Self.pillPadding)
                        .frame(height: NotchIconButton.circleSize)
                        .background(Capsule().fill(Self.tint.opacity(hovering ? 0.26 : 0.18)))
                        .transition(.opacity)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Self.tint.opacity(hovering ? 1.0 : 0.85))
                        .frame(width: NotchIconButton.circleSize, height: NotchIconButton.circleSize)
                        .background(Circle().fill(Self.tint.opacity(hovering ? 0.2 : 0.08)))
                        .scaleEffect(hovering && !reduceMotion ? 1.1 : 1.0)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: NotchIconButton.hitSize, minHeight: NotchIconButton.hitSize, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(NotchAnimation.micro) { hovering = h }
            if !h { confirmation.cancel() }
        }
        .onDisappear { confirmation.cancel() }
        .onChange(of: armed) { _, isArmed in
            // The label changes under VoiceOver's cursor without being read.
            if isArmed { AccessibilityNotification.Announcement(l10n["quit_confirm_hint"]).post() }
        }
        .help(armed ? l10n["quit_confirm_hint"] : l10n["quit"])
        .accessibilityLabel(armed ? l10n["quit_confirm_hint"] : l10n["quit"])
    }
}

// MARK: - Idle Indicator Bar

private struct IdleIndicatorBar: View {
    let notchW: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool
    let hovered: Bool
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled
    @StateObject private var quit = QuitConfirmation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: hasNotch ? CompactRightWingLayout.leadingLip + notchW : 0)

            // Right: expanded shows text + buttons, collapsed shows nothing
            if hovered {
                HStack(spacing: 8) {
                    // Gives way to the quit pill: the hovered bar is only a
                    // little wider than its buttons.
                    if !quit.isArmed {
                        Text("0")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    HStack(spacing: 4) {
                        NotchIconButton(icon: soundEnabled ? "speaker.wave.2" : "speaker.slash", tooltip: soundEnabled ? l10n["mute"] : l10n["enable_sound_tooltip"]) {
                            soundEnabled.toggle()
                        }
                        NotchIconButton(icon: "gearshape", tooltip: l10n["settings"]) {
                            SettingsWindowController.shared.show()
                        }
                        QuitConfirmButton(confirmation: quit)
                    }
                }
                .padding(.trailing, 6)
                .transition(.opacity)
            }
        }
        .frame(height: notchHeight)
        .animation(NotchAnimation.micro, value: hovered)
        // The buttons go with the hover, and an armed pill with them
        // (QuitConfirmButton cancels when it disappears).
        .animation(reduceMotion ? nil : NotchAnimation.micro, value: quit.isArmed)
    }
}

// MARK: - Session List

/// When the expanded session list scrolls, and how tall it may get.
enum SessionListMetrics {
    /// The window budgets this much per visible session
    /// (PanelHeightMetrics.desiredHeight).
    static let heightPerSession: CGFloat = 90

    static func scrollHeight(maxVisibleSessions: Int) -> CGFloat {
        CGFloat(maxVisibleSessions) * heightPerSession
    }

    /// Scroll once there are more sessions than the setting shows — or fewer,
    /// but taller than the room budgeted for them: cards with a task list, an
    /// approval row or a recap run well past 90pt each, and four of them used
    /// to push the list and its footer off the bottom of the window with no
    /// way to reach them.
    ///
    /// Compact rows go by height alone: the window is still sized for
    /// `maxVisibleSessions` cards, and one-line rows fill that room — eight
    /// fit where five cards did — before the list scrolls.
    static func needsScroll(
        isCompletionCard: Bool,
        sessionCount: Int,
        contentHeight: CGFloat,
        maxVisibleSessions: Int,
        density: SessionListDensity = .comfortable
    ) -> Bool {
        guard !isCompletionCard else { return false }
        let tooTall = contentHeight > scrollHeight(maxVisibleSessions: maxVisibleSessions) + 0.5
        switch density {
        case .comfortable: return sessionCount > maxVisibleSessions || tooTall
        case .compact: return tooTall
        }
    }
}

private struct SessionListView: View {
    var appState: AppState
    /// When set, only show this session (auto-expand on completion)
    var onlySessionId: String? = nil
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions
    @AppStorage(SettingsKey.sessionListDensity) private var densityRaw = SettingsDefaults.sessionListDensity
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.showProjectName) private var showProjectName = SettingsDefaults.showProjectName
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Natural height of the session cards, scrolling or not. Owned by the
    /// panel so the next open starts from the last measurement.
    @Binding var contentHeight: CGFloat
    /// The order on screen is held while the pointer is over the list.
    @State private var orderFreeze = SessionOrderFreeze()
    @State private var thawTask: Task<Void, Never>?

    private var density: SessionListDensity {
        // The completion card is one full card whatever the setting.
        onlySessionId == nil ? SessionListDensity(storedValue: densityRaw) : .comfortable
    }

    /// Needs-you first, then working, then the rest by recent activity —
    /// held in place while the pointer is over the list.
    private var orderedSessionIds: [String] {
        orderFreeze.apply(appState.sessionListOrder())
    }

    private var sessionIds: [String] {
        if let only = onlySessionId {
            // A card whose session is gone shows nothing (the AiWork
            // watchers drop sessions without moving the surface). Falling
            // through would render every session as a completion card, and
            // their replies size against each other without settling (#357).
            return appState.sessions[only] != nil ? [only] : []
        }
        return orderedSessionIds
    }

    var body: some View {
        // Compute once per render — sessionIds, needsScroll
        let ids = sessionIds
        let totalSessionCount = ids.count
        let density = self.density
        let needsScroll = SessionListMetrics.needsScroll(
            isCompletionCard: onlySessionId != nil,
            sessionCount: totalSessionCount,
            contentHeight: contentHeight,
            maxVisibleSessions: maxVisibleSessions,
            density: density
        )
        // Compact rows share their column widths so the status words line up.
        let fontSize = CGFloat(contentFontSize)
        let compactColumns: (project: CGFloat, status: CGFloat) = density == .compact
            ? (
                CompactSessionRowMetrics.projectColumnWidth(
                    names: ids.compactMap {
                        appState.sessions[$0]?.headline(showProjectName: showProjectName).text
                    },
                    fontSize: fontSize,
                    cap: CompactSessionRowMetrics.projectColumnCap(fontSize: fontSize)
                ),
                CompactSessionRowMetrics.statusColumnWidth(fontSize: CompactSessionRowMetrics.statusFontSize(fontSize))
            )
            : (0, 0)
        let content = VStack(spacing: density == .compact ? CompactSessionRowMetrics.spacing : 6) {
            ForEach(ids, id: \.self) { sessionId in
                if let session = appState.sessions[sessionId] {
                    SessionCard(
                        appState: appState,
                        sessionId: sessionId,
                        session: session,
                        isCompletion: onlySessionId != nil,
                        density: density,
                        compactProjectWidth: compactColumns.project,
                        compactStatusWidth: compactColumns.status
                    )
                }
            }

            // "Show all sessions" — hover with delay to expand
            if onlySessionId != nil && appState.sessions.count > 1 {
                SessionsExpandLink(count: appState.sessions.count) {
                    withAnimation(NotchAnimation.open) {
                        appState.surface = .sessionList
                        appState.cancelCompletionQueue()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        // The same in both branches: inside the scroll view the content still
        // lays out at its natural height, so switching never flips it back.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        // Cards needing you sort to the top — but not while the pointer is on
        // the list, where a card moving would put another under the cursor
        // just as it clicks. The list re-sorts once the pointer leaves. The
        // whole area counts (gaps between cards included), and a brief exit
        // past the edge doesn't release the hold.
        .contentShape(Rectangle())
        .onHover { inside in
            guard onlySessionId == nil else { return }
            thawTask?.cancel()
            thawTask = nil
            if inside {
                orderFreeze.freeze(appState.sessionListOrder())
            } else {
                thawTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: SessionOrderFreeze.releaseDelay)
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : NotchAnimation.micro) { orderFreeze.thaw() }
                }
            }
        }

        VStack(spacing: 0) {
            if needsScroll {
                ThinScrollView(maxHeight: SessionListMetrics.scrollHeight(maxVisibleSessions: maxVisibleSessions)) {
                    content
                }
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 20,
                        bottomTrailingRadius: 20, topTrailingRadius: 0,
                        style: .continuous
                    )
                )
            } else {
                content
            }
        }
    }
}

// MARK: - Collapsed right wing layout

/// The collapsed bar hangs off the notch's right: a lip on the left (so the
/// bar's rounded corner sits clear of the notch), the notch (physical or
/// simulated), then the right wing — quiet-hours moon, completion dot,
/// question badge, session count. The wing grows to fit its content clear of
/// the notch, so nothing slides under it.
enum CompactRightWingLayout {
    /// Bar visible left of the notch: the collapsed bottom corner radius.
    static let leadingLip: CGFloat = 12
    /// Clearance between the wing's content and the notch edge.
    static let notchGap: CGFloat = 4

    /// - Parameter contentWidth: the right wing's laid-out width, trailing
    ///   padding included; 0 until it has been measured.
    static func room(contentWidth: CGFloat, minimum: CGFloat) -> CGFloat {
        Swift.max(minimum, contentWidth + notchGap)
    }
}

/// Reports the collapsed right wing's laid-out width up to the bar.
struct CompactRightWingWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = Swift.max(value, nextValue())
    }
}

/// The session list's scroll area: hugs short content, scrolls past
/// `maxHeight`, with a thin overlay scrollbar whatever the system's
/// "Show scroll bars" preference.
///
/// A SwiftUI ScrollView, not an NSScrollView hosting the cards: the nested
/// NSHostingView was built inside the open animation's first frame — after
/// the animation's clock had started — and its 50–90ms showed as a stutter
/// every time a scrolling list opened.
private struct ThinScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content.background(OverlayScrollerStyle())
        }
        // Order matters (as in PanelFittedScrollArea): fixedSize proposes no
        // height, so the ScrollView reports its content's and the frame caps it.
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keeps the scroller of the NSScrollView behind a SwiftUI ScrollView a thin
/// light overlay. AppKit puts the system's preferred style back (legacy with
/// a mouse attached or "Show scroll bars: Always") on its own schedule, and a
/// legacy scroller took 13pt off every card. Without an NSScrollView to find,
/// the system's scroller simply stays.
private struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.apply() }

    final class Probe: NSView {
        private weak var styledScrollView: NSScrollView?
        private var styleObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            if styledScrollView !== scrollView {
                styledScrollView = scrollView
                // Whenever AppKit sets a style, set ours straight back.
                styleObservation = scrollView.observe(\.scrollerStyle) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if scrollView.verticalScroller?.controlSize != .mini { scrollView.verticalScroller?.controlSize = .mini }
            if scrollView.scrollerKnobStyle != .light { scrollView.scrollerKnobStyle = .light }
        }

        /// Never in the way of the cards it sits behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The card header's git branch next to a long project name.
enum BranchLabelMetrics {
    /// Characters a squeezed branch keeps. The project name outranks it,
    /// and with no floor a long name left the branch an icon and "…".
    static let minimumCharacters = 12

    /// The branch's full width when it is short, else room for
    /// `minimumCharacters` (middle-truncated).
    static func minimumWidth(for label: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let glyph = ("M" as NSString).size(withAttributes: [.font: font]).width
        let full = (label as NSString).size(withAttributes: [.font: font]).width
        return (min(full, glyph * CGFloat(minimumCharacters)) + 1).rounded(.up)
    }
}

private struct SessionIdentityLine: View {
    let session: SessionSnapshot
    let sessionId: String
    let projectFontSize: CGFloat
    let projectColor: Color
    let sessionFontSize: CGFloat
    let sessionColor: Color
    let dividerColor: Color
    @AppStorage(SettingsKey.showGitBranch) private var showGitBranch = SettingsDefaults.showGitBranch
    @AppStorage(SettingsKey.showProjectName) private var showProjectName = SettingsDefaults.showProjectName

    private var displaySessionId: String { session.displaySessionId(sessionId: sessionId) }

    var body: some View {
        // With the status chip beside it the row can run out of room at large
        // text sizes. The short id goes first then: a name read whole beats an
        // id. A name too long either way keeps the id and truncates, as before.
        ViewThatFits(in: .horizontal) {
            line(showsShortId: true)
            line(showsShortId: false)
            line(showsShortId: true)
        }
    }

    private func line(showsShortId: Bool) -> some View {
        let headline = session.headline(showProjectName: showProjectName)
        return HStack(spacing: 4) {
            if headline.kind == .project {
                ProjectNameLink(
                    name: headline.text,
                    cwd: session.cwd,
                    isInteractive: !session.isRemote,
                    fontSize: projectFontSize,
                    color: projectColor
                )
                .layoutPriority(2)
            } else {
                // Project name hidden: no folder link and no path tooltip either,
                // or hovering the card would still reveal it.
                Text(headline.text)
                    .font(.system(size: projectFontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(projectColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
            }

            if showGitBranch, let branch = session.gitBranch {
                let label = session.gitIsWorktree ? "\(branch) ⧉" : branch
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: max(sessionFontSize - 1, 8), weight: .semibold))
                    Text(label)
                        .font(.system(size: sessionFontSize, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: BranchLabelMetrics.minimumWidth(for: label, fontSize: sessionFontSize))
                }
                .help(label)
                .foregroundStyle(sessionColor.opacity(0.85))
                .layoutPriority(1)
            }

            if let sessionLabel = headline.trailingSessionLabel {
                Text("#\(sessionLabel)")
                    .font(.system(size: sessionFontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(sessionColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if showsShortId {
                    Text("·")
                        .font(.system(size: sessionFontSize, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dividerColor)

                    Text("#\(shortSessionId(displaySessionId))")
                        .font(.system(size: sessionFontSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(sessionColor.opacity(0.6))
                        .fixedSize()
                }
            } else if showsShortId {
                Text("#\(shortSessionId(displaySessionId))")
                    .font(.system(size: sessionFontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(sessionColor.opacity(0.6))
                    .fixedSize()
            }
        }
    }
}

private struct ProjectNameLink: View {
    let name: String
    let cwd: String?
    let isInteractive: Bool
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        Text(name)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .onTapGesture {
                if isInteractive, let cwd = cwd {
                    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                }
            }
            .help(isInteractive && cwd != nil ? "\(L10n.shared["open_path"]) \(cwd ?? "")" : "")
    }
}

private struct SessionsExpandLink: View {
    let count: Int
    let action: () -> Void
    @State private var hovering = false
    @State private var hoverTimer: Timer?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
                Text("\(count) \(L10n.shared["n_sessions"])")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(hovering ? 0.75 : 0.55))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.5 : 0.3))
                Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(NotchAnimation.micro) { hovering = h }
            hoverTimer?.invalidate()
            hoverTimer = nil
            if h {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                    Task { @MainActor in action() }
                }
            }
        }
    }
}

func shouldTriggerJumpFailureFeedback(_ jumpChecks: [Bool]) -> Bool {
    !jumpChecks.contains(true)
}

/// Namespace for the session card's jump animation utilities
enum JumpAnimationHelper {
    static let shakeSequence = [8, -8, 6, -6, 3, -3, 0]
    static let shakeStepDuration: UInt64 = 35_000_000

    @MainActor
    static func runShake(offset: Binding<CGFloat>) async {
        for value in shakeSequence {
            withAnimation(.easeInOut(duration: 0.035)) {
                offset.wrappedValue = CGFloat(value)
            }
            try? await Task.sleep(nanoseconds: shakeStepDuration)
        }
    }
}

enum JumpValidationOutcome: Equatable {
    case success
    case failed
    case cancelled
}

func evaluateJumpValidation(
    delays: [UInt64],
    isCancelled: () -> Bool = { Task.isCancelled },
    sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
    checkSucceeded: () async -> Bool
) async -> JumpValidationOutcome {
    for delay in delays {
        await sleep(delay)
        if isCancelled() { return .cancelled }
        if await checkSucceeded() { return .success }
    }

    return isCancelled() ? .cancelled : .failed
}

private struct SessionCard: View {
    var appState: AppState
    let sessionId: String
    let session: SessionSnapshot
    var isCompletion: Bool = false
    var density: SessionListDensity = .comfortable
    /// Compact rows: column widths every row shares, so the words line up.
    var compactProjectWidth: CGFloat = 150
    var compactStatusWidth: CGFloat = 64
    @State private var hovering = false
    @State private var failureShakeOffset: CGFloat = 0
    @State private var jumpValidationTask: Task<Void, Never>?
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.aiMessageLines) private var aiMessageLines = SettingsDefaults.aiMessageLines
    @AppStorage(SettingsKey.showAgentDetails) private var showAgentDetails = SettingsDefaults.showAgentDetails
    @AppStorage(SettingsKey.autoCollapseAfterSessionJump) private var autoCollapseAfterSessionJump = SettingsDefaults.autoCollapseAfterSessionJump
    @AppStorage(SettingsKey.showTaskProgress) private var showTaskProgress = SettingsDefaults.showTaskProgress
    @AppStorage(SettingsKey.showSessionRecap) private var showSessionRecap = SettingsDefaults.showSessionRecap
    @AppStorage(SettingsKey.showModelLabel) private var showModelLabel = SettingsDefaults.showModelLabel
    @AppStorage(SettingsKey.showProjectName) private var showProjectName = SettingsDefaults.showProjectName
    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    private var aiLineLimit: Int? { aiMessageLines > 0 ? aiMessageLines : nil }
    /// Cursor is blocked on a question answered inside its own UI (#265) —
    /// a display-only wait with no in-panel answer flow.
    private var showsExternalCursorQuestion: Bool {
        session.status == .waitingQuestion && session.cursorPendingQuestion != nil
    }
    private var cardStatus: SessionCardStatus { SessionCardStatus(session) }
    /// The completion card is a full card whatever the density.
    private var isCompactRow: Bool { density == .compact && !isCompletion }
    private var chipFontSize: CGFloat { SessionStatusChip.fontSize(content: fontSize) }
    private var buttonFontSize: CGFloat { max(10, fontSize) }

    /// What the card's live row shows: the running tool, or that the model is
    /// thinking. A card waiting on you shows its request instead, so only a
    /// tool that is not already on an approval row appears there.
    private enum LiveRow: Equatable {
        case tool(String)
        case thinking
    }

    private var liveRow: LiveRow? {
        switch cardStatus {
        case .working, .thinking:
            return session.currentTool.map(LiveRow.tool) ?? .thinking
        case .needsYou:
            guard !showsExternalCursorQuestion,
                  let tool = session.currentTool else { return nil }
            return .tool(tool)
        case .done, .idle, .stopped, .error:
            return nil
        }
    }

    var body: some View {
        Group {
            if isCompactRow {
                compactBody
            } else {
                comfortableBody
            }
        }
        .offset(x: failureShakeOffset)
        .contentShape(Rectangle())
        .onTapGesture { handleSessionClick() }
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
        .onDisappear {
            jumpValidationTask?.cancel()
            jumpValidationTask = nil
        }
    }

    // MARK: Comfortable card

    private var comfortableBody: some View {
        HStack(alignment: .top, spacing: 10) {
            mascotColumn

            VStack(alignment: .leading, spacing: 5) {
                comfortableHeader

                if showsExternalCursorQuestion {
                    cursorQuestionBlock
                }

                // Agent checklist progress (TaskCreate / TodoWrite / update_plan).
                if showTaskProgress && !session.agentTasks.isEmpty {
                    AgentTaskProgressView(tasks: session.agentTasks, fontSize: fontSize, agentIsIdle: session.status == .idle)
                }

                // Session title: first user prompt (hide when detailed mode shows chat history)
                if let prompt = session.lastUserPrompt, session.recentMessages.isEmpty {
                    SessionGlyphLine(kind: .prompt, text: prompt, fontSize: fontSize)
                }

                chatAndLiveRows

                // Claude Code's idle recap — the newest thing in an idle session,
                // so it sits under the chat rows. visibleRecap is nil while working.
                if showSessionRecap, let recap = session.visibleRecap {
                    SessionRecapRow(
                        text: recap.text,
                        fontSize: fontSize,
                        lineLimit: isCompletion
                            ? CompletionReplyMetrics.recapLineLimit
                            : aiLineLimit.map { max($0, 2) }
                    )
                    .equatable()
                    // On the completion card the reply's scroll area is sized
                    // around this row; squeezed to one line it would be measured
                    // short and never get its second line back.
                    .fixedSize(horizontal: false, vertical: isCompletion)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(cardBackground(cornerRadius: 10))
        .padding(.horizontal, 6)
    }

    /// Character + subagent icons.
    private var mascotColumn: some View {
        VStack(spacing: 3) {
            MascotView(source: session.mascotSource, size: 32)
            if showAgentDetails && !session.subagents.isEmpty {
                let sorted = session.subagents.values.sorted { $0.startTime < $1.startTime }
                // Grid: 4 per row, 8px icons
                let rows = stride(from: 0, to: sorted.count, by: 4).map {
                    Array(sorted[$0..<min($0 + 4, sorted.count)])
                }
                VStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 1) {
                            ForEach(row, id: \.agentId) { sub in
                                MiniAgentIcon(active: sub.status != .idle, size: 8)
                                    .help(subagentTooltipText(sub, showModel: showModelLabel))
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 36)
    }

    /// Status word, project name + optional session label + short ID, tags.
    private var comfortableHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            SessionStatusChip(status: cardStatus, fontSize: chipFontSize)
                .layoutPriority(3)
            SessionIdentityLine(
                session: session,
                sessionId: sessionId,
                projectFontSize: fontSize + 2,
                projectColor: .white.opacity(0.95),
                sessionFontSize: fontSize,
                sessionColor: .white.opacity(0.76),
                dividerColor: .white.opacity(0.28)
            )
            // The line itself fills the gap up to the tags: a Spacer here took
            // a share of the row and truncated a short name beside blank space.
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if let remote = session.remoteDisplayName {
                    SessionTag("@\(remote)", color: Color(red: 0.45, green: 0.72, blue: 1.0), maxWidth: 110)
                        .help("@\(remote)")
                }
                if !session.subagents.isEmpty {
                    SessionTag("+\(session.subagents.count) Sub", color: Color(red: 0.65, green: 0.55, blue: 0.95))
                }
                if session.isYoloMode == true {
                    SessionTag("YOLO", color: Color(red: 1.0, green: 0.35, blue: 0.35))
                }
                // Name only: the reasoning effort is still kept on the session
                // (tooltips, subagents), just not spelled out on the card.
                if showModelLabel, let modelName = ModelLabel.displayName(for: session.model) {
                    SessionTag(modelName, maxWidth: 120)
                        .help(session.model ?? modelName)
                }
                SessionTag(timeAgo(session.startTime))
                TerminalBadge(session: session)
            }
        }
    }

    /// Chat history + live status.
    @ViewBuilder
    private var chatAndLiveRows: some View {
        let live = liveRow
        if !session.recentMessages.isEmpty || live != nil {
            VStack(alignment: .leading, spacing: 3) {
                // Chat messages (detailed mode only)
                let visibleMessages = session.status != .idle
                    ? Array(session.recentMessages.suffix(2))
                    : session.recentMessages
                let fullReplyId = CompletionReplyMetrics.fullReplyId(in: visibleMessages, isCompletionCard: isCompletion)
                let olderReplyLimit = isCompletion
                    ? CompletionReplyMetrics.olderReplyLineLimit(aiLineLimit)
                    : aiLineLimit
                ForEach(visibleMessages) { msg in
                    // Extracted to separate view so SwiftUI skips re-rendering
                    // when only the parent's hover state changes (#52 perf).
                    ChatMessageRow(
                        text: msg.text,
                        isUser: msg.isUser,
                        fontSize: fontSize,
                        aiLineLimit: olderReplyLimit,
                        isCompletionReply: msg.id == fullReplyId,
                        pinsHeight: isCompletion
                    )
                }

                // What the agent is doing right now.
                if let live {
                    liveRowView(live)
                }
            }
        }
    }

    @ViewBuilder
    private func liveRowView(_ row: LiveRow) -> some View {
        switch row {
        case .tool(let tool):
            HStack(alignment: .center, spacing: 6) {
                SessionToolChip(tool: tool, color: cardStatus.color, fontSize: fontSize)
                if let detail = session.toolDescription, !detail.isEmpty {
                    MorphText(
                        text: detail,
                        font: .system(size: fontSize, design: .monospaced),
                        color: .white.opacity(0.75),
                        streamsRapidly: SessionSnapshot.rapidStreamingSources
                            .contains(session.source)
                    )
                    .truncationMode(.tail)
                }
            }
        case .thinking:
            TypingIndicator(fontSize: fontSize, label: L10n.shared["typing_thinking"])
        }
    }

    // MARK: Requests

    /// Cursor asked a question in its own UI (#265). There is no hook
    /// channel to answer from here, so show the question plus a hint
    /// instead of an endless "thinking" indicator.
    private var cursorQuestionBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let question = session.cursorPendingQuestion, !question.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Text("?")
                        .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(SessionCardStatus.needsYou.color)
                    Text(question)
                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Text(L10n.shared["cursor_question_answer_hint"])
                .font(.system(size: max(10, fontSize - 1), design: .monospaced))
                .foregroundStyle(SessionCardStatus.needsYou.color.opacity(0.85))
        }
    }

    // MARK: Compact row

    /// Opens up under the row only for a session that needs you, and only
    /// when there is something to show there.
    private var compactExpands: Bool {
        guard cardStatus == .needsYou else { return false }
        return showsExternalCursorQuestion || session.currentTool != nil
    }

    private var compactBody: some View {
        let status = cardStatus
        let expands = compactExpands
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                MascotView(source: session.mascotSource, size: 18)
                    .frame(width: 22)
                Text(session.headline(showProjectName: showProjectName).text)
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: compactProjectWidth, alignment: .leading)
                Text(status.label)
                    .font(.system(size: CompactSessionRowMetrics.statusFontSize(fontSize), weight: .bold, design: .monospaced))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
                    .frame(width: compactStatusWidth, alignment: .leading)
                compactActivity
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: CompactSessionRowMetrics.rowHeight)

            if expands {
                VStack(alignment: .leading, spacing: 5) {
                    compactRequest
                }
                // Under the project name, clear of the mascot column.
                .padding(.leading, 30)
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 10)
        .background(cardBackground(
            cornerRadius: 8,
            tint: expands ? SessionCardStatus.needsYou.color.opacity(0.08) : nil
        ))
        .help(compactTooltip)
        .padding(.horizontal, 6)
    }

    /// One line. A session that needs you shows its prompt here and its
    /// request below; a working one its tool; a resting one the newest of
    /// recap / reply / prompt.
    @ViewBuilder
    private var compactActivity: some View {
        if cardStatus == .needsYou {
            if let prompt = session.lastUserPrompt {
                SessionGlyphLine(kind: .prompt, text: prompt, fontSize: max(10, fontSize - 1))
            }
        } else if case .tool(let tool)? = liveRow {
            HStack(spacing: 6) {
                SessionToolChip(tool: tool, color: cardStatus.color, fontSize: fontSize)
                if let detail = session.toolDescription, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: max(10, fontSize - 1), design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        } else if cardStatus == .working || cardStatus == .thinking {
            if let prompt = session.lastUserPrompt {
                SessionGlyphLine(kind: .prompt, text: prompt, fontSize: max(10, fontSize - 1))
            } else if liveRow == .thinking {
                TypingIndicator(fontSize: max(10, fontSize - 1), label: L10n.shared["typing_thinking"])
            }
        } else if showSessionRecap, let recap = session.visibleRecap {
            // Written after the reply, as a summary of where things stand.
            SessionGlyphLine(kind: .recap, text: recap.text, fontSize: max(10, fontSize - 1))
        } else if let reply = session.lastAssistantMessage {
            SessionGlyphLine(kind: .reply, text: reply, fontSize: max(10, fontSize - 1))
        } else if let prompt = session.lastUserPrompt {
            SessionGlyphLine(kind: .prompt, text: prompt, fontSize: max(10, fontSize - 1))
        }
    }

    @ViewBuilder
    private var compactRequest: some View {
        if showsExternalCursorQuestion {
            cursorQuestionBlock
        } else if let tool = session.currentTool {
            HStack(spacing: 6) {
                SessionToolChip(tool: tool, color: SessionCardStatus.needsYou.color, fontSize: fontSize)
                if let detail = session.toolDescription, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// The row keeps one line; the hover shows who it is and the latest reply.
    private var compactTooltip: String {
        CompactSessionRowMetrics.tooltip(
            name: session.headline(showProjectName: showProjectName).text,
            latest: session.lastAssistantMessage.map(stripDirectives)
                ?? session.visibleRecap?.text
                ?? session.lastUserPrompt
        )
    }

    // MARK: Shared

    /// Card fill with the status rail down its leading edge.
    private func cardBackground(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return ZStack(alignment: .leading) {
            shape.fill(hovering ? Color.white.opacity(0.10) : Color.white.opacity(0.05))
            if let tint {
                shape.fill(tint)
            }
            Rectangle()
                .fill(cardStatus.railColor)
                .frame(width: 3)
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private func handleSessionClick() {
        TerminalActivator.activate(session: session, sessionId: sessionId)

        guard autoCollapseAfterSessionJump, session.canJumpFromNotch else { return }

        jumpValidationTask?.cancel()
        jumpValidationTask = Task {
            let delays: [UInt64] = [120_000_000, 320_000_000, 640_000_000]
            let outcome = await evaluateJumpValidation(
                delays: delays,
                checkSucceeded: { await checkJumpSucceeded() }
            )

            switch outcome {
            case .success:
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    switch appState.surface {
                    case .sessionList, .completionCard:
                        withAnimation(NotchAnimation.close) {
                            appState.surface = .collapsed
                        }
                    default:
                        break
                    }
                }
            case .failed:
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    SoundManager.shared.preview("8bit_error")
                }
                guard !Task.isCancelled else { return }
                await runJumpFailureShakeAnimation()
            case .cancelled:
                return
            }
        }
    }

    private func checkJumpSucceeded() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let succeeded = TerminalVisibilityDetector.isSessionTabVisible(session)
                    || TerminalVisibilityDetector.isTerminalFrontmostForSession(session)
                continuation.resume(returning: succeeded)
            }
        }
    }

    @MainActor
    private func runJumpFailureShakeAnimation() async {
        await JumpAnimationHelper.runShake(offset: $failureShakeOffset)
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

// MARK: - Session card parts

/// The card's status word: NEEDS YOU, WORKING, DONE … in its status colour.
/// Also drawn by the Appearance settings preview.
struct SessionStatusChip: View {
    let status: SessionCardStatus
    let fontSize: CGFloat

    /// The word stays small at large text sizes — the header row has the
    /// project, branch and tags to fit too.
    static func fontSize(content: CGFloat) -> CGFloat {
        min(10, max(9, content - 2))
    }

    var body: some View {
        Text(status.label)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(status.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(status.color.opacity(0.15))
            )
    }
}

/// `▸ Bash` — the running (or requested) tool, set apart from the chat lines.
struct SessionToolChip: View {
    let tool: String
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        Text("▸ \(ToolNameDisplay.compact(tool))")
            .font(.system(size: max(9, fontSize - 1), weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.12))
            )
            // VoiceOver would read the triangle's Unicode name.
            .accessibilityLabel(String(format: L10n.shared["session_a11y_running_tool"], ToolNameDisplay.compact(tool)))
    }
}

/// The glyphs that tell chat lines apart: `›` your prompt, `●` the agent's
/// reply, `↻` a recap. Each sits in a box one monospaced character wide, so
/// the text after it starts at the same x whatever the glyph.
enum SessionGlyph {
    static let prompt = "›"
    static let reply = "●"
    static let recap = "↻"
    static let promptColor = Color.white.opacity(0.5)
    static let replyColor = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// Your own words, a step quieter than the agent's.
    static let promptTextColor = Color.white.opacity(0.62)
    /// The dot is drawn smaller than a letter, but laid out at full size so
    /// it centres on the first line.
    static let replyScale: CGFloat = 0.72

    /// One monospaced character: the glyph column's width. `↻` has no glyph
    /// in SF Mono and falls back to a narrower font.
    static func columnWidth(_ fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        return ("M" as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// What VoiceOver says for each glyph instead of its Unicode name.
    static var promptSpoken: String { L10n.shared["session_a11y_prompt"] }
    static var replySpoken: String { L10n.shared["session_a11y_reply"] }
    static var recapSpoken: String { L10n.shared["session_recap"] }
}

/// One line led by a glyph — the prompt line on a full card, and the latest
/// activity on a compact row.
private struct SessionGlyphLine: View {
    enum Kind { case prompt, reply, recap }
    let kind: Kind
    let text: String
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            glyph
            switch kind {
            case .prompt:
                Text(ChatMessageTextFormatter.literalText(text))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(SessionGlyph.promptTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .reply:
                AssistantReplyText(text: stripDirectives(text), fontSize: fontSize, lineLimit: 1)
            case .recap:
                Text(text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var glyph: some View {
        let font = Font.system(size: fontSize, weight: .bold, design: .monospaced)
        return Group {
            switch kind {
            case .prompt:
                Text(SessionGlyph.prompt).font(font).foregroundStyle(SessionGlyph.promptColor)
                    .accessibilityLabel(SessionGlyph.promptSpoken)
            case .reply:
                Text(SessionGlyph.reply).font(font).foregroundStyle(SessionGlyph.replyColor)
                    .scaleEffect(SessionGlyph.replyScale)
                    .accessibilityLabel(SessionGlyph.replySpoken)
            case .recap:
                Text(SessionGlyph.recap).font(font).foregroundStyle(SessionMetadataStyle.recapAccent)
                    .accessibilityLabel(SessionGlyph.recapSpoken)
            }
        }
        .frame(width: SessionGlyph.columnWidth(fontSize))
    }
}

// MARK: - Claude Logo (official sunburst from simple-icons, viewBox 0 0 24 24)

private struct ClaudeLogo: View {
    var size: CGFloat = 22
    private static let color = Color(red: 0.85, green: 0.47, blue: 0.34) // #D97757

    // Official Claude logo SVG path (source: simple-icons)
    fileprivate static let svgPath = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

    var body: some View {
        ClaudeLogoShape()
            .fill(Self.color)
            .frame(width: size, height: size)
    }
}

private struct ClaudeLogoShape: Shape {
    private static let basePath: Path = ClaudeLogoShape.parseSVGPath(ClaudeLogo.svgPath)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return Self.basePath.applying(transform)
    }

    // Minimal SVG path parser for m/l/h/v/c/z commands
    private static func parseSVGPath(_ d: String) -> Path {
        var path = Path()
        var x: CGFloat = 0, y: CGFloat = 0
        var i = d.startIndex
        var cmd: Character = "m"

        func skipWS() {
            while i < d.endIndex && (d[i] == " " || d[i] == ",") { i = d.index(after: i) }
        }

        func peekNum() -> Bool {
            guard i < d.endIndex else { return false }
            let c = d[i]
            return c == "-" || c == "." || c.isNumber
        }

        func num() -> CGFloat {
            skipWS()
            var s = ""
            if i < d.endIndex && d[i] == "-" { s.append(d[i]); i = d.index(after: i) }
            var hasDot = false
            while i < d.endIndex {
                let c = d[i]
                if c == "." {
                    if hasDot { break }
                    hasDot = true; s.append(c); i = d.index(after: i)
                } else if c.isNumber {
                    s.append(c); i = d.index(after: i)
                } else { break }
            }
            return CGFloat(Double(s) ?? 0)
        }

        while i < d.endIndex {
            skipWS()
            guard i < d.endIndex else { break }
            let c = d[i]
            if c.isLetter {
                cmd = c; i = d.index(after: i)
            }

            switch cmd {
            case "m":
                let dx = num(), dy = num(); x += dx; y += dy
                path.move(to: CGPoint(x: x, y: y))
                cmd = "l" // subsequent coords are implicit lineTo
            case "M":
                x = num(); y = num()
                path.move(to: CGPoint(x: x, y: y))
                cmd = "L"
            case "l":
                let dx = num(), dy = num(); x += dx; y += dy
                path.addLine(to: CGPoint(x: x, y: y))
            case "L":
                x = num(); y = num()
                path.addLine(to: CGPoint(x: x, y: y))
            case "h":
                x += num(); path.addLine(to: CGPoint(x: x, y: y))
            case "H":
                x = num(); path.addLine(to: CGPoint(x: x, y: y))
            case "v":
                y += num(); path.addLine(to: CGPoint(x: x, y: y))
            case "V":
                y = num(); path.addLine(to: CGPoint(x: x, y: y))
            case "c":
                let dx1 = num(), dy1 = num(), dx2 = num(), dy2 = num(), dx = num(), dy = num()
                path.addCurve(to: CGPoint(x: x+dx, y: y+dy),
                              control1: CGPoint(x: x+dx1, y: y+dy1),
                              control2: CGPoint(x: x+dx2, y: y+dy2))
                x += dx; y += dy
            case "C":
                let x1 = num(), y1 = num(), x2 = num(), y2 = num()
                x = num(); y = num()
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: x1, y: y1),
                              control2: CGPoint(x: x2, y: y2))
            case "Z", "z":
                path.closeSubpath()
            default:
                i = d.index(after: i)
            }

            // Handle repeated implicit commands
            skipWS()
            if i < d.endIndex && peekNum() && "mlhvcMLHVC".contains(cmd) {
                continue
            }
        }
        return path
    }
}

// MARK: - Notch Panel Shape (inverse radius at top, regular radius at bottom)

private struct NotchPanelShape: Shape {
    var topExtension: CGFloat
    var bottomRadius: CGFloat
    /// Fixed minimum height — NOT animated, prevents spring overshoot from exposing the notch
    var minHeight: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topExtension, bottomRadius) }
        set {
            topExtension = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ext = topExtension
        let maxY = max(rect.maxY, rect.minY + minHeight)
        let br = min(bottomRadius, rect.width / 4, (maxY - rect.minY) / 2)
        // Smoothness factor for continuous-curvature corners (superellipse approximation).
        // 0.5523 = perfect circle; higher values tighten the curve for an Apple squircle feel.
        let k: CGFloat = 0.62

        var p = Path()
        // Top edge (extends into notch area via wings)
        p.move(to: CGPoint(x: rect.minX - ext, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + ext, y: rect.minY))
        // Right shoulder: cubic bezier tangent to top line (horizontal) and right side (vertical)
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + ext),
            control1: CGPoint(x: rect.maxX + ext * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + ext * 0.35)
        )
        // Right side down to bottom-right corner
        p.addLine(to: CGPoint(x: rect.maxX, y: maxY - br))
        // Bottom-right: cubic bezier for continuous-curvature corner
        p.addCurve(
            to: CGPoint(x: rect.maxX - br, y: maxY),
            control1: CGPoint(x: rect.maxX, y: maxY - br * (1 - k)),
            control2: CGPoint(x: rect.maxX - br * (1 - k), y: maxY)
        )
        // Bottom edge
        p.addLine(to: CGPoint(x: rect.minX + br, y: maxY))
        // Bottom-left: cubic bezier for continuous-curvature corner
        p.addCurve(
            to: CGPoint(x: rect.minX, y: maxY - br),
            control1: CGPoint(x: rect.minX + br * (1 - k), y: maxY),
            control2: CGPoint(x: rect.minX, y: maxY - br * (1 - k))
        )
        // Left side up to shoulder
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + ext))
        // Left shoulder: cubic bezier tangent to left side (vertical) and top line (horizontal)
        p.addCurve(
            to: CGPoint(x: rect.minX - ext, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + ext * 0.35),
            control2: CGPoint(x: rect.minX - ext * 0.35, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

/// Terminal icon + name badge (display only, not a button)
private struct TerminalBadge: View {
    let session: SessionSnapshot

    /// The card header keeps its tags at full size, so a long terminal or
    /// host name is cut here rather than squeezing the project name.
    static let labelMaxWidth: CGFloat = 96

    private static let sourceBundleIds: [String: String] = [
        "cursor": "com.todesktop.230313mzl4w4u92",
        "trae": "com.trae.app",
        "traecn": "cn.trae.app",
        "qoder": "com.qoder.ide",
        "droid": "com.factory.app",
        "codebuddy": "com.tencent.codebuddy",
        "codybuddycn": "com.tencent.codebuddy.cn",
        "stepfun": "com.stepfun.app",
        "codex": "com.openai.codex",
        "opencode": "ai.opencode.desktop",
        "aiwork": "com.alipay.dtcoder.ide",
        "aiwork-cli": "com.alipay.dtcoder.ide",
    ]
    private static var termIconCache: [String: NSImage] = [:]

    private var termIcon: NSImage? {
        // CLI hosted in a foreign IDE: show the agent icon, not the host IDE.
        if session.isCLIHostedInForeignApp,
           let src = SessionSnapshot.normalizedSupportedSource(session.source),
           let icon = cliIcon(source: src, size: 13) {
            return icon
        }
        let bid = session.termBundleId ?? Self.sourceBundleIds[session.mascotSource]
        guard let bid else { return nil }
        if let cached = Self.termIconCache[bid] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.termIconCache[bid] = icon
        return icon
    }

    private var badgeLabel: String? {
        session.terminalBadgeLabel
    }

    private let remoteColor = Color(red: 0.3, green: 0.75, blue: 0.5)

    /// Small chip naming the multiplexer the CLI sits in (tmux, zellij), shown
    /// next to — never instead of — the terminal it runs inside. Same chip
    /// vocabulary as the queue counter and the AskUserQuestion header.
    @ViewBuilder
    private func multiplexerChip(fg: Color, bg: Color) -> some View {
        if let mux = session.multiplexerLabel {
            Text(mux)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(fg)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    /// Same chip for the UI harness that spawned the CLI (T3 Code): the
    /// terminal badge still names where the harness server runs, the chip
    /// says the conversation itself lives in the harness (#321).
    @ViewBuilder
    private func hostHarnessChip(fg: Color, bg: Color) -> some View {
        if let harness = session.hostHarnessLabel {
            Text(harness)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(fg)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .help(String(format: L10n.shared["hosted_by_harness_hint"], harness))
        }
    }

    var body: some View {
        Group {
            if session.isRemote {
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(remoteColor)
                    if let term = session.terminalName {
                        Text(term)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(remoteColor)
                            .lineLimit(1)
                            .hugWidth(of: term, fontSize: 9.5, upTo: Self.labelMaxWidth)
                    }
                    multiplexerChip(fg: remoteColor, bg: remoteColor.opacity(0.16))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(remoteColor.opacity(0.08))
                )
            } else {
                HStack(spacing: 3) {
                    // Icon only; the name is in the tooltip. Spelled out only
                    // when there is no icon to show.
                    if let icon = termIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 13, height: 13)
                            .help(badgeLabel ?? "")
                            .accessibilityLabel(badgeLabel ?? "")
                    } else if let term = badgeLabel {
                        Text(term)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .hugWidth(of: term, fontSize: 9.5, upTo: Self.labelMaxWidth)
                    }
                    multiplexerChip(fg: .white.opacity(0.5), bg: .white.opacity(0.1))
                    hostHarnessChip(fg: .white.opacity(0.5), bg: .white.opacity(0.1))
                }
            }
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Shared Helpers

private let cliIconFiles: [String: String] = [
    "claude": "claude",
    "codex": "codex",
    "gemini": "gemini",
    "antigravity": "antigravity",
    "google-antigravity": "gemini",
    "cursor": "cursor",
    "cursor-cli": "cursor",
    "trae": "trae",
    "traecn": "trae",
    "traecli": "trae",
    "traecli-next": "trae",
    "copilot": "copilot",
    "qoder": "qoder",
    "qoder-cli": "qoder",
    "qoderwork": "qoder",
    "droid": "factory",
    "codebuddy": "codebuddy",
    "codybuddycn": "codebuddy",
    "stepfun": "stepfun",
    "workbuddy": "workbuddy",
    "hermes": "hermes",
    "grok": "grok",
    "qwen": "qwen",
    "kimi": "kimi",
    "pi": "pi",
    "omp": "pi",
    "opencode": "opencode",
    "cline": "cline",
    "dsh": "dsh",
    // AiWork (formerly DTCoder). GUI and CLI share one asset, as qoder/qoder-cli
    // and cursor/cursor-cli do; the NSWorkspace branch in cliIcon() prefers the
    // installed app's own icon and falls back to this when AiWork is absent.
    "aiwork": "aiwork",
    "aiwork-cli": "aiwork",
    // Rendered from the in-house pixel mascots via
    // MascotRenderHarness/testRenderCliIcons (MASCOT_ICON_DIR=…).
    "kiro": "kiro",
    "openclaw": "openclaw",
    "minimax": "minimax",
    "mimo": "mimo",
]

private var cliIconCache: [String: NSImage] = [:]

func cliIcon(source: String, size: CGFloat = 16) -> NSImage? {
    let key = "\(source)_\(Int(size))"
    if let cached = cliIconCache[key] { return cached }

    // AiWork (formerly DTCoder): prefer the installed app's own icon, falling
    // back to the bundled aiwork.png below when AiWork is not installed.
    if source == "aiwork" || source == "aiwork-cli",
       let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.alipay.dtcoder.ide") {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: size, height: size)
        cliIconCache[key] = icon
        return icon
    }

    guard let filename = cliIconFiles[source],
          let url = Bundle.appModule.url(forResource: filename, withExtension: "png", subdirectory: "Resources/cli-icons"),
          let image = NSImage(contentsOf: url)
    else {
        // No asset (new integrations, custom CLIs): draw a monogram tile so
        // every row in the settings CLI list still gets an icon.
        let fallback = monogramIcon(for: source, size: size)
        cliIconCache[key] = fallback
        return fallback
    }
    image.size = NSSize(width: size, height: size)
    cliIconCache[key] = image
    return image
}

/// Rounded tile with the source's first letter; hue derived from the source
/// name so distinct CLIs get stable, distinct colors.
private func monogramIcon(for source: String, size: CGFloat) -> NSImage {
    let letter = String(source.trimmingCharacters(in: CharacterSet(charactersIn: ".")).prefix(1)).uppercased()
    // Deterministic hash — Swift's hashValue is seeded per launch and would
    // repaint the tile a different color every run.
    let stableHash = source.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    let hue = Double(stableHash % 360) / 360.0
    let scale: CGFloat = 4  // draw at 4x so small sizes stay crisp
    let px = size * scale
    let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        let bg = NSColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1)
        NSBezierPath(roundedRect: rect.insetBy(dx: px * 0.02, dy: px * 0.02),
                     xRadius: px * 0.22, yRadius: px * 0.22).addClip()
        bg.setFill()
        rect.fill()
        let font = NSFont.systemFont(ofSize: px * 0.58, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: letter, attributes: attrs)
        let textSize = text.size()
        text.draw(at: NSPoint(x: (px - textSize.width) / 2, y: (px - textSize.height) / 2))
        return true
    }
    image.size = NSSize(width: size, height: size)
    return image
}

private struct SessionTag: View {
    let text: String
    var color: Color = .white.opacity(0.7)
    /// Widest the tag gets (host names, model labels); it still hugs a
    /// short text and gives way when the header runs out of room.
    var maxWidth: CGFloat?

    static let fontSize: CGFloat = 9.5

    init(_ text: String, color: Color = .white.opacity(0.7), maxWidth: CGFloat? = nil) {
        self.text = text
        self.color = color
        self.maxWidth = maxWidth
    }

    var body: some View {
        Text(text)
            .font(.system(size: Self.fontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .hugWidth(of: text, fontSize: Self.fontSize, upTo: maxWidth.map { $0 - 12 })
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(0.12))
            )
    }
}

private extension View {
    /// Monospaced label that hugs its text up to `cap` and truncates below
    /// that only when its row runs out of room. `.frame(maxWidth:)` alone
    /// would stretch a short label to the cap.
    @ViewBuilder
    func hugWidth(of text: String, fontSize: CGFloat, upTo cap: CGFloat?) -> some View {
        if let cap {
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
            let width = min(((text as NSString).size(withAttributes: [.font: font]).width + 1).rounded(.up), cap)
            frame(minWidth: 0, idealWidth: width, maxWidth: width, alignment: .leading)
        } else {
            self
        }
    }
}

// MARK: - Typing Indicator (three bouncing dots)

private struct TypingIndicator: View {
    let fontSize: CGFloat
    var label: String? = nil
    var bright: Bool = false
    var color: Color? = nil
    @State private var phase: CGFloat = -60
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let label {
            let baseColor: Color = color ?? .white
            let baseOpacity: Double = bright ? 0.6 : 0.35
            let peakOpacity: Double = bright ? 0.8 : 0.5
            let midOpacity: Double = bright ? 0.5 : 0.3
            let bandWidth: CGFloat = bright ? 80 : 60
            let duration: Double = 2.5
            let endPhase: CGFloat = bright ? 100 : 80
            let startPhase: CGFloat = bright ? -80 : -60

            Text(label)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(baseColor.opacity(baseOpacity))
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(midOpacity), location: bright ? 0.35 : 0.4),
                            .init(color: .white.opacity(peakOpacity), location: 0.5),
                            .init(color: .white.opacity(midOpacity), location: bright ? 0.65 : 0.6),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: phase)
                    .mask(
                        Text(label)
                            .font(.system(size: fontSize, design: .monospaced))
                    )
                )
                .onAppear {
                    phase = startPhase
                    // Reduce Motion: the label stays, the endless shimmer goes.
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: false)) {
                        phase = endPhase
                    }
                }
                .onDisappear { phase = startPhase }
        }
    }
}

// MARK: - Mini Agent Icon (8-bit robot head)

struct MiniAgentIcon: View {
    let active: Bool
    var size: CGFloat = 12

    // 0=empty, 1=body, 2=eye, 3=antenna tip, 4=highlight, 5=shadow
    private let grid: [[Int]] = [
        [0, 0, 0, 3, 0, 0, 0],  // antenna tip (glows)
        [0, 0, 0, 1, 0, 0, 0],  // antenna stem
        [0, 4, 1, 1, 1, 5, 0],  // head top
        [0, 1, 2, 1, 2, 1, 0],  // eyes
        [0, 1, 1, 1, 1, 1, 0],  // face
        [0, 5, 1, 0, 1, 5, 0],  // mouth
        [0, 0, 1, 0, 1, 0, 0],  // legs
    ]

    var body: some View {
        let base = active ? Color.green : Color.gray
        let bright = active ? Color(red: 0.5, green: 1.0, blue: 0.5) : Color(white: 0.7)
        let dark = active ? Color(red: 0.1, green: 0.5, blue: 0.15) : Color(white: 0.35)
        let eye = active ? Color.white : Color(white: 0.85)
        let glow = active ? Color(red: 0.4, green: 1.0, blue: 0.4) : Color(white: 0.6)

        Canvas { ctx, sz in
            let px = sz.width / 7
            for row in 0..<7 {
                for col in 0..<7 {
                    let v = grid[row][col]
                    guard v != 0 else { continue }
                    let color: Color = switch v {
                    case 2: eye
                    case 3: glow
                    case 4: bright
                    case 5: dark
                    default: base
                    }
                    ctx.fill(
                        Path(CGRect(x: CGFloat(col) * px, y: CGFloat(row) * px, width: px, height: px)),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: active ? .green.opacity(0.4) : .clear, radius: 2)
    }
}

// MARK: - Shared Helpers

/// Generate a short session ID with better disambiguation.
private func shortSessionId(_ id: String) -> String {
    let clean = id.replacingOccurrences(of: "-", with: "")
    if clean.count >= 8 {
        return String(clean.suffix(4))
    }
    return String(id.prefix(4))
}

/// Build the help-tooltip string for a subagent mini-icon. Lives outside
/// the SwiftUI ViewBuilder so the body stays trivial — complex inline
/// expressions in ForEach were measurably slowing the hover-expand
/// animation per #141 review.
private func subagentTooltipText(_ sub: SubagentState, showModel: Bool = false) -> String {
    var typeLabel = sub.agentType.isEmpty ? "Subagent" : sub.agentType
    // The subagent's own model — it often differs from the parent card's tag.
    if showModel, let model = sub.modelLabel {
        typeLabel += " · \(model)"
    }
    var detail = ""
    if let tool = sub.currentTool, !tool.isEmpty {
        detail = tool
        if let desc = sub.toolDescription, !desc.isEmpty {
            detail += " " + desc
        }
    }
    return detail.isEmpty ? typeLabel : "\(typeLabel) — \(detail)"
}

// MARK: - Session metadata (recap + model tag)

enum SessionMetadataStyle {
    /// Recap glyph tint — distinct from the green ">" user and orange "$"
    /// reply markers so a recap never reads as the agent speaking.
    static let recapAccent = Color(red: 0.6, green: 0.68, blue: 1.0)

    /// Tooltip for the collapsed bar: the displayed idle session's recap,
    /// headed like its card — so with "Show project name" off it names the
    /// session title (or the agent), never the folder.
    static func collapsedRecapTooltip(for session: SessionSnapshot?, showProjectName: Bool) -> String {
        guard let session, let recap = session.visibleRecap else { return "" }
        return "↻ \(session.headline(showProjectName: showProjectName).text)\n\(recap.text)"
    }
}

/// Claude Code's "while you were away" recap on an idle card: a ↻ marker and
/// secondary-colored text, set apart from the "●" reply rows.
private struct SessionRecapRow: View, Equatable {
    let text: String
    let fontSize: CGFloat
    let lineLimit: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text(SessionGlyph.recap)
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(SessionMetadataStyle.recapAccent)
                .frame(width: SessionGlyph.columnWidth(fontSize))
            Text(text)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
        .help(text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n.shared["session_recap"]): \(text)")
    }
}

/// Strip internal directives (::code-comment{}, ::git-*{}, etc.) from message text
/// so they don't leak into the UI preview.
// MARK: - Chat Message Row (extracted for render-skip optimization)

/// Separate view so SwiftUI skips body re-evaluation when only the parent's
/// hover state changes — avoids expensive text processing on every hover.
private struct ChatMessageRow: View, Equatable {
    let text: String
    let isUser: Bool
    let fontSize: CGFloat
    let aiLineLimit: Int?
    /// The finished reply on the completion card: rendered in full, ignoring
    /// aiLineLimit.
    var isCompletionReply = false
    /// Keep a capped reply at its full height (up to the cap) instead of
    /// letting a crowded card squeeze it — on the completion card, where the
    /// reply's scroll area is sized around these rows.
    var pinsHeight = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.isUser == rhs.isUser
        && lhs.fontSize == rhs.fontSize && lhs.aiLineLimit == rhs.aiLineLimit
        && lhs.isCompletionReply == rhs.isCompletionReply && lhs.pinsHeight == rhs.pinsHeight
    }

    var body: some View {
        // `›` your prompt, `●` the agent's reply — the running tool has its
        // own `▸` chip, so no glyph means two things any more.
        if isUser {
            HStack(alignment: .top, spacing: 5) {
                Text(SessionGlyph.prompt)
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(SessionGlyph.promptColor)
                    .frame(width: SessionGlyph.columnWidth(fontSize))
                    .accessibilityLabel(SessionGlyph.promptSpoken)
                Text(ChatMessageTextFormatter.literalText(text))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(SessionGlyph.promptTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            HStack(alignment: .top, spacing: 5) {
                Text(SessionGlyph.reply)
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(SessionGlyph.replyColor)
                    .scaleEffect(SessionGlyph.replyScale)
                    .frame(width: SessionGlyph.columnWidth(fontSize))
                    .accessibilityLabel(SessionGlyph.replySpoken)
                // Block Markdown when uncapped or on the completion card, a
                // marker-free preview under the reply-line cap
                // (MarkdownReplyView.swift).
                AssistantReplyText(
                    text: stripDirectives(text),
                    fontSize: fontSize,
                    lineLimit: aiLineLimit,
                    isCompletionReply: isCompletionReply
                )
                .fixedSize(horizontal: false, vertical: pinsHeight && !isCompletionReply)
            }
        }
    }
}

private func stripDirectives(_ text: String) -> String {
    // Match ::directive-name{...} patterns (may span multiple lines)
    // Use a simple approach: remove lines that start with ::word{ or are continuation of a directive
    var result: [String] = []
    var inDirective = false
    var braceDepth = 0

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if inDirective {
            for ch in line {
                if ch == "{" { braceDepth += 1 }
                if ch == "}" { braceDepth -= 1 }
            }
            if braceDepth <= 0 {
                inDirective = false
                braceDepth = 0
            }
            continue
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("::") && trimmed.contains("{") {
            // Count braces to handle single-line vs multi-line directives
            braceDepth = 0
            for ch in line {
                if ch == "{" { braceDepth += 1 }
                if ch == "}" { braceDepth -= 1 }
            }
            if braceDepth > 0 {
                inDirective = true
            }
            // Either way, skip this line
            continue
        }
        result.append(String(line))
    }

    let cleaned = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned
}

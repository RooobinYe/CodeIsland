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
    /// On notched displays the island can grow beyond the physical notch but never
    /// shrink under it — narrower would expose the bare hardware cutout (#268).
    static func effectiveNotchWidth(notchW: CGFloat, collapsedWidthScale: Int, hasNotch: Bool) -> CGFloat {
        let clampedScale = Swift.max(NotchWidthScale.min, Swift.min(collapsedWidthScale, NotchWidthScale.max))
        let scaled = notchW * CGFloat(clampedScale) / 100.0
        if hasNotch { return Swift.max(notchW, scaled) }
        return scaled
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
    static let compactMaxWidth: CGFloat = 120

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
    @AppStorage(SettingsKey.showToolStatus) private var showToolStatus = SettingsDefaults.showToolStatus
    @AppStorage(SettingsKey.collapsedWidthScale) private var collapsedWidthScale = SettingsDefaults.collapsedWidthScale
    @AppStorage(SettingsKey.showClaudeQuota) private var showClaudeQuota = SettingsDefaults.showClaudeQuota
    @AppStorage(SettingsKey.claudeQuotaChip) private var claudeQuotaChip = SettingsDefaults.claudeQuotaChip
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
    /// Curtain animation for tool status toggle
    @State private var curtainOffset: CGFloat = 0
    @State private var curtainOpacity: Double = 1
    @State private var displayedToolStatus: Bool = SettingsDefaults.showToolStatus
    /// Window height and card chrome for the completion card's reply area.
    @State private var cardSpace = CompletionCardSpace()
    /// Measured width of the plan-limit chip (0 until first laid out) — the
    /// bar reserves exactly this instead of guessing from the label length.
    @State private var quotaChipWidth: CGFloat = 0
    /// Measured width of the collapsed right wing (0 until first laid out).
    @State private var rightWingWidth: CGFloat = 0

    private var isActive: Bool { !appState.sessions.isEmpty }
    /// First launch / no-session state should still render a visible marker so the app
    /// doesn't disappear completely behind the physical notch.
    private var showIdleIndicator: Bool {
        !isActive && !hideWhenNoSession
    }
    /// Whether the bar content should be visible (respects hideWhenNoSession)
    private var showBar: Bool {
        isActive && !(hideWhenNoSession && appState.activeSessionCount == 0)
    }
    private var shouldShowExpanded: Bool {
        showBar && appState.surface.isExpanded
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

    /// Minimum wing width needed to display compact bar content
    private var compactWingWidth: CGFloat { mascotSize + 14 }

    /// Effective island width — on notched screens the scale can only widen past the notch.
    private var effectiveNotchW: CGFloat {
        NotchWidthMetrics.effectiveNotchWidth(
            notchW: notchW,
            collapsedWidthScale: collapsedWidthScale,
            hasNotch: hasNotch
        )
    }

    /// Total panel width — adapts based on state and screen geometry
    private var panelWidth: CGFloat {
        let nw = effectiveNotchW
        if showIdleIndicator { return idleHovered ? nw + compactWingWidth * 2 + 80 : nw + compactWingWidth * 2 }
        if !isActive { return hasNotch ? nw - 20 : nw }
        if shouldShowExpanded { return min(max(nw + 200, 580), maxPanelWidth) }
        return collapsedBarWidth + quotaReserve.extraWidth + rightWingReserve
    }

    /// Room the collapsed right wing lacks to clear the notch; 0 whenever it fits.
    private var rightWingReserve: CGFloat {
        guard showBar, !shouldShowExpanded else { return 0 }
        return CompactRightWingLayout.missing(
            contentWidth: rightWingWidth,
            wing: compactWingWidth,
            statusExtra: collapsedStatusExtra,
            hasNotch: hasNotch
        )
    }

    /// The panel window's width (PanelWindowController.panelSize).
    private var maxPanelWidth: CGFloat { min(620, screenWidth - 40) }

    /// The collapsed active bar, before any room for the plan-limit chip.
    private var collapsedBarWidth: CGFloat {
        // Immediate hover acknowledgement: a slight widen while the expand delay runs
        let prehoverExtra: CGFloat = shouldShowPrehover ? NotchHoverInteraction.prehoverWidthDelta : 0
        return effectiveNotchW + compactWingWidth * 2 + collapsedStatusExtra + prehoverExtra
    }

    /// Status and tool-status reserves, split evenly between the two wings.
    private var collapsedStatusExtra: CGFloat {
        let extra: CGFloat = appState.status == .idle ? 0 : 20
        // Reserve space for tool status — proportional to screen width
        let toolExtra: CGFloat = displayedToolStatus ? (hasNotch ? screenWidth * 0.03 : screenWidth * 0.04) : 0
        return extra + toolExtra
    }

    /// Room for the plan-limit chip in the collapsed bar; `.none` whenever the
    /// chip isn't shown, which leaves the bar exactly as it is without it.
    private var quotaReserve: QuotaChipLayout.Reserve {
        guard showBar, !shouldShowExpanded,
              let limit = QuotaChip.limit(appState: appState, enabled: showClaudeQuota, modeRaw: claudeQuotaChip)
        else { return .none }
        // Measured once laid out; the label-length estimate covers the first frame.
        let chipWidth = quotaChipWidth > 0 ? quotaChipWidth : QuotaChip.estimatedWidth(for: limit)
        return QuotaChipLayout.reserve(
            chipWidth: chipWidth,
            mascotSize: mascotSize,
            wing: compactWingWidth,
            statusExtra: collapsedStatusExtra,
            hasNotch: hasNotch,
            spareWidth: maxPanelWidth - collapsedBarWidth
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if showBar {
                    // Active: compact bar — wider version when expanded
                    HStack(spacing: 0) {
                        CompactLeftWing(appState: appState, expanded: shouldShowExpanded, mascotSize: mascotSize, hasNotch: hasNotch, showToolStatus: showToolStatus)
                        if hasNotch && !shouldShowExpanded {
                            Spacer(minLength: effectiveNotchW)
                        } else if !shouldShowExpanded && showToolStatus {
                            CompactToolStatus(appState: appState)
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                        }
                        CompactRightWing(appState: appState, expanded: shouldShowExpanded, hasNotch: hasNotch)
                    }
                    .frame(height: notchHeight)
                    // Recap on hover while collapsed — shows whenever hover
                    // doesn't expand the panel (smart suppress with the
                    // terminal frontmost); expanded cards show it inline.
                    .help(collapsedRecapTooltip)
                    // 0 means the chip isn't drawn right now (a tool name holds
                    // the slot) — keep the last width so the bar doesn't twitch.
                    .onPreferenceChange(QuotaChipWidthKey.self) { if $0 > 0 { quotaChipWidth = $0 } }
                    // 0 while expanded (only the collapsed wing reports) — keep
                    // the last width for the next collapse.
                    .onPreferenceChange(CompactRightWingWidthKey.self) { if $0 > 0 { rightWingWidth = $0 } }
                } else if showIdleIndicator {
                    IdleIndicatorBar(
                        compactWingWidth: compactWingWidth,
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

                    switch appState.surface {
                    case .completionCard:
                        SessionListView(appState: appState, onlySessionId: appState.justCompletedSessionId)
                            .transition(.blurFade.combined(with: .move(edge: .top)))
                    case .sessionList:
                        SessionListView(appState: appState, onlySessionId: nil)
                            .transition(.blurFade.combined(with: .move(edge: .top)))
                    case .collapsed:
                        EmptyView()
                    }
                }
            }
            .recordsCompletionCardChrome(in: cardSpace)
            .frame(width: panelWidth)
            .clipped()
            .background(
                NotchPanelShape(
                    topExtension: shouldShowExpanded ? 14 : 3,
                    bottomRadius: shouldShowExpanded ? 24 : 12,
                    minHeight: notchHeight
                )
                .fill(.black)
            )
            .offset(y: curtainOffset)
            .opacity(curtainOpacity)
            .onChange(of: showToolStatus) { _, newValue in
                // Phase 1: entire bar slides up and fades out
                withAnimation(.easeIn(duration: 0.2)) {
                    curtainOffset = -notchHeight
                    curtainOpacity = 0
                }
                // Phase 2: switch width while hidden
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    displayedToolStatus = newValue
                }
                // Phase 3: entire bar slides back down
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        curtainOffset = 0
                        curtainOpacity = 1
                    }
                }
            }
            .onAppear { displayedToolStatus = showToolStatus }
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
                            hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .expandDelayElapsed)
                            withAnimation(NotchAnimation.open) {
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
                            hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .collapseDelayElapsed)
                            withAnimation(NotchAnimation.close) {
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
            .offset(x: quotaReserve.shift + rightWingReserve / 2)

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
        // The expanded header's grouping tabs: the physical notch, not the
        // widened island, is what they must stay clear of.
        .environment(\.sessionGroupingTabsRoom, SessionGroupingTabsLayout.room(
            panelWidth: panelWidth, notchWidth: notchW, hasNotch: hasNotch
        ))
        .animation(NotchAnimation.open, value: appState.surface)
    }
}

// MARK: - Compact Wings (notch-level, 32px height)

/// Left side: pixel character + status info
private struct CompactLeftWing: View {
    var appState: AppState
    let expanded: Bool
    let mascotSize: CGFloat
    let hasNotch: Bool
    let showToolStatus: Bool
    @AppStorage(SettingsKey.sessionGroupingMode) private var groupingMode = SettingsDefaults.sessionGroupingMode
    @AppStorage(SettingsKey.showClaudeQuota) private var showClaudeQuota = SettingsDefaults.showClaudeQuota
    @AppStorage(SettingsKey.claudeQuotaChip) private var claudeQuotaChip = SettingsDefaults.claudeQuotaChip

    private var displaySession: SessionSnapshot? {
        let sid = appState.rotatingSessionId ?? appState.activeSessionId ?? appState.sessions.keys.sorted().first
        guard let sid else { return nil }
        return appState.sessions[sid]
    }
    private var liveTool: String? { displaySession?.currentTool }
    @State private var shownTool: String?
    @State private var lingerTimer: Timer?

    var body: some View {
        HStack(spacing: 6) {
            if expanded {
                AppLogoView(size: 36, showBackground: false)
                if appState.sessions.count > 1 {
                    SessionGroupingTabs(mode: $groupingMode)
                }
            } else {
                // On notch screens, show tool name only (no description, space is tight)
                if hasNotch, showToolStatus, let tool = shownTool {
                    Text(ToolNameDisplay.compact(tool))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(toolStatusColor(tool))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: ToolNameDisplay.compactMaxWidth, alignment: .leading)
                        .transition(.opacity)
                        .help(tool)
                } else if let limit = QuotaChip.limit(appState: appState, enabled: showClaudeQuota, modeRaw: claudeQuotaChip),
                          let snapshot = appState.claudeQuota.snapshot {
                    // Plan-limit chip takes the tool slot while no tool is
                    // running: window label + ring + percent, all windows in
                    // the tooltip.
                    QuotaChip(
                        limit: limit,
                        snapshot: snapshot,
                        stale: appState.claudeQuota.lastError != nil,
                        showsPace: QuotaChip.paceFits(mascotSize: mascotSize)
                    )
                        .fixedSize()
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: QuotaChipWidthKey.self, value: geo.size.width)
                        })
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, 6)
        .clipped()
        .onChange(of: liveTool) { _, newTool in
            lingerTimer?.invalidate()
            if let newTool {
                withAnimation(.easeInOut(duration: 0.2)) { shownTool = newTool }
            } else {
                lingerTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.3)) { shownTool = nil }
                    }
                }
            }
        }
        // Session rotation: immediately sync tool to avoid stale linger from previous session
        .onChange(of: appState.rotatingSessionId) { _, _ in
            lingerTimer?.invalidate()
            let newTool = liveTool
            withAnimation(.easeInOut(duration: 0.2)) { shownTool = newTool }
        }
    }
}

/// The expanded header's session grouping tabs.
struct SessionGroupingTab {
    /// SettingsKey.sessionGroupingMode value.
    let tag: String
    /// Drawn in the 5×7 pixel font, which has Latin capitals only — so the
    /// tabs read the same in every language; the tooltip names them.
    let pixelLabel: String
    /// For a header too narrow for the words (SessionGroupingTabsLayout).
    let shortPixelLabel: String
    /// L10n key of the spelled-out name (tooltip, VoiceOver).
    let nameKey: String

    static let all = [
        SessionGroupingTab(tag: "all", pixelLabel: "ALL", shortPixelLabel: "ALL", nameKey: "group_all"),
        SessionGroupingTab(tag: "status", pixelLabel: "STATUS", shortPixelLabel: "STA", nameKey: "group_status"),
        SessionGroupingTab(tag: "cli", pixelLabel: "AGENT", shortPixelLabel: "AGT", nameKey: "group_cli"),
    ]
}

/// Size of the grouping tabs, and when the header is too narrow for them.
///
/// The expanded header sits in the menu bar: on a notched screen its left
/// wing ends where the notch begins, and the spelled-out tabs (≈40pt wider
/// than the old ALL / STA / CLI) fit beside a notch of up to 200pt on the
/// narrowest (580pt) panel — MacBook notches are ≈185pt. Past that they fall
/// back to three-letter labels rather than run under the notch.
enum SessionGroupingTabsLayout {
    static let pixelSize: CGFloat = 1.3
    static let horizontalPadding: CGFloat = 5
    static let spacing: CGFloat = 1
    /// The drawn strip, and the taller hit target each tab gets around it.
    static let stripHeight: CGFloat = 17
    static let hitHeight: CGFloat = 24

    /// What the expanded header's left wing puts before the tabs: its leading
    /// padding, the 36pt logo and the spacing after it (CompactLeftWing).
    static let leadingChrome: CGFloat = 6 + 36 + 6
    /// Clearance kept between the tabs and the notch.
    static let notchGap: CGFloat = 4

    /// PixelText's width for `text`: 5 dots and a gap per glyph, no trailing gap.
    static func labelWidth(_ text: String, pixelSize: CGFloat = pixelSize) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return CGFloat(text.count) * 6 * pixelSize - pixelSize
    }

    /// Width of the whole tab strip.
    static func width(short: Bool) -> CGFloat {
        let tabs = SessionGroupingTab.all
        let labels = tabs.reduce(CGFloat(0)) { $0 + labelWidth(short ? $1.shortPixelLabel : $1.pixelLabel) }
        return labels + CGFloat(tabs.count) * horizontalPadding * 2 + CGFloat(tabs.count - 1) * spacing
    }

    /// Room the expanded header leaves the tabs. On a notched screen that is
    /// the wing beside the notch; elsewhere the left half of the panel (the
    /// right half holds the buttons).
    static func room(panelWidth: CGFloat, notchWidth: CGFloat, hasNotch: Bool) -> CGFloat {
        let wing = hasNotch ? (panelWidth - notchWidth) / 2 : panelWidth / 2
        return wing - leadingChrome - notchGap
    }

    static func usesShortLabels(room: CGFloat) -> Bool {
        width(short: false) > room
    }
}

private struct SessionGroupingTabsRoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    /// Width the expanded header leaves the grouping tabs
    /// (SessionGroupingTabsLayout.room), set by NotchPanelView.
    var sessionGroupingTabsRoom: CGFloat {
        get { self[SessionGroupingTabsRoomKey.self] }
        set { self[SessionGroupingTabsRoomKey.self] = newValue }
    }
}

/// Right side: project name + session count (detailed) or just count (simple)
private struct CompactRightWing: View {
    var appState: AppState
    let expanded: Bool
    let hasNotch: Bool
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled
    @AppStorage(SettingsKey.showToolStatus) private var showToolStatus = SettingsDefaults.showToolStatus
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

                if showToolStatus {
                    // Detailed mode: session count (project name is shown in center on non-notch)
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
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                } else {
                    // Simple mode: original session count only
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

// MARK: - Tool Status Helpers

/// Accent color for each tool category — shared between notch and non-notch views
private func toolStatusColor(_ tool: String) -> Color {
    switch tool.lowercased() {
    case "bash", "running command": return Color(red: 0.4, green: 1.0, blue: 0.5)
    case "edit", "write", "editing": return Color(red: 0.5, green: 0.7, blue: 1.0)
    case "read", "reading": return Color(red: 0.9, green: 0.8, blue: 0.4)
    case "grep", "glob", "searching", "calling mcp": return Color(red: 0.8, green: 0.6, blue: 1.0)
    case "agent", "delegating": return Color(red: 1.0, green: 0.6, blue: 0.4)
    case "compacting": return Color(red: 0.4, green: 0.85, blue: 0.9)
    default: return .white.opacity(0.7)
    }
}

enum SessionLiveOutputDisplay {
    static func summary(for session: SessionSnapshot?, maxCharacters: Int = 160) -> String? {
        guard maxCharacters > 0,
              let session,
              session.status != .idle,
              SessionSnapshot.normalizedSupportedSource(session.source) == "codex",
              let liveOutput = session.liveCodexOutput else { return nil }

        // Streamed replies are Markdown; flatten it so the one-line bar shows
        // words, not `##`, `**` or table pipes. Cached: the bar re-renders
        // far more often than the output changes.
        let flattened = ChatMessageTextFormatter.markdownPreview(liveOutput, singleLine: true)
        let normalized = String(flattened.characters)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maxCharacters else { return normalized }
        if maxCharacters == 1 { return "\u{2026}" }
        return String(normalized.prefix(maxCharacters - 1)) + "\u{2026}"
    }
}

// MARK: - Compact Tool Status (non-notch center area)

/// What the collapsed bar's centre leads with: the project folder, or the
/// session title when "Show project name" is off. Capped in width — an
/// AI-generated title runs to dozens of characters and would otherwise push
/// the tool and its description out of the bar. A short label still hugs its
/// text.
struct CompactContextLabel: View {
    let text: String

    static let fontSize: CGFloat = 11
    static let maxWidth: CGFloat = 120

    /// The label's widest extent: its text's width, up to `maxWidth`.
    static func width(for text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        // A point of slack: Text truncates a label measured to the exact width.
        let ideal = (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 1
        return min(ideal, maxWidth)
    }

    var body: some View {
        Text(text)
            .font(.system(size: Self.fontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .truncationMode(.tail)
            // minWidth 0 keeps it shrinkable when the bar is narrower still.
            .frame(minWidth: 0, maxWidth: Self.width(for: text), alignment: .leading)
    }
}

/// Shows the current tool activity in the center of the bar on non-notch screens.
/// Keeps the last tool visible for a short linger period to avoid flashing.
private struct CompactToolStatus: View {
    var appState: AppState

    /// Single source of truth: all fields derive from the same session.
    private var displaySessionId: String? {
        appState.rotatingSessionId ?? appState.activeSessionId ?? appState.sessions.keys.sorted().first
    }
    private var displaySession: SessionSnapshot? {
        guard let sid = displaySessionId else { return nil }
        return appState.sessions[sid]
    }
    private var liveTool: String? { displaySession?.currentTool }
    private var liveDesc: String? { displaySession?.toolDescription }
    private var liveOutput: String? { SessionLiveOutputDisplay.summary(for: displaySession) }
    private var displayStatus: AgentStatus { displaySession?.status ?? .idle }
    @AppStorage(SettingsKey.showProjectName) private var showProjectName = SettingsDefaults.showProjectName
    private var projectName: String? {
        let folder = displaySession?.cwd.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
        return SessionHeadline.contextLabel(
            projectName: folder,
            sessionLabel: displaySession?.sessionLabel,
            showProjectName: showProjectName
        )
    }

    @State private var shownTool: String?
    @State private var shownDesc: String?
    @State private var lingerTimer: Timer?

    /// Extract meaningful part of description — file paths show last component
    private func shortDesc(_ desc: String) -> String {
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            return (trimmed as NSString).lastPathComponent
        }
        return trimmed
    }

    /// Whether the current session is doing any work (not idle)
    private var isWorking: Bool { displayStatus != .idle }

    var body: some View {
        HStack(spacing: 5) {
            // Project name — shown whenever the session is not idle
            if isWorking, let project = projectName {
                CompactContextLabel(text: project)
                    .id("center-project-\(displaySessionId ?? "")")
                    .transition(.opacity)
            }

            // Tool status or thinking indicator
            if let tool = shownTool {
                TypingIndicator(fontSize: 11, label: ToolNameDisplay.compact(tool, maxCharacters: 32), bright: true, color: toolStatusColor(tool))
                    .id("tool-\(tool)-\(appState.rotatingSessionId ?? "")")
                    .help(tool)
                if let desc = shownDesc {
                    MorphText(
                        text: shortDesc(desc),
                        font: .system(size: 11, weight: .medium, design: .monospaced),
                        color: .white.opacity(0.7),
                        streamsRapidly: displaySession.map {
                            SessionSnapshot.rapidStreamingSources.contains($0.source)
                        } ?? false
                    )
                    .truncationMode(.tail)
                }
            } else if let liveOutput {
                Text("$")
                    .fontWeight(.bold)
                    .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                MorphText(
                    text: liveOutput,
                    font: .system(size: 11, weight: .medium, design: .monospaced),
                    color: .white.opacity(0.78)
                )
                .truncationMode(.tail)
                .help(liveOutput)
            } else if displayStatus == .processing {
                TypingIndicator(fontSize: 11, label: L10n.shared["typing_thinking"], bright: true)
                    .id("thinking-\(appState.rotatingSessionId ?? "")")
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .padding(.leading, 6)
        .animation(.easeInOut(duration: 0.25), value: shownTool)
        .animation(.easeInOut(duration: 0.15), value: shownDesc)
        .animation(.easeInOut(duration: 0.3), value: appState.rotatingSessionId)
        .onChange(of: liveTool) { _, newTool in
            lingerTimer?.invalidate()
            if let newTool {
                shownTool = newTool
                shownDesc = liveDesc
            } else {
                lingerTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.3)) {
                            shownTool = nil
                            shownDesc = nil
                        }
                    }
                }
            }
        }
        .onChange(of: liveDesc) { _, newDesc in
            if liveTool != nil { shownDesc = newDesc }
        }
        // Session rotation: immediately sync to avoid stale linger from previous session
        .onChange(of: appState.rotatingSessionId) { _, _ in
            lingerTimer?.invalidate()
            withAnimation(.easeInOut(duration: 0.2)) {
                shownTool = liveTool
                shownDesc = liveDesc
            }
        }
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

/// The grouping tabs in the 5×7 pixel font, spelled out (ALL · STATUS ·
/// AGENT) where the header has room for them.
private struct SessionGroupingTabs: View {
    @Binding var mode: String
    @Environment(\.sessionGroupingTabsRoom) private var room
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var l10n = L10n.shared
    @State private var hoveredTag: String?

    static let selectedColor = Color(red: 0.3, green: 0.85, blue: 0.4)
    /// ≈7:1 on black — the thin pixel strokes need more than the AA minimum.
    static let inactiveColor = Color.white.opacity(0.62)

    var body: some View {
        let layout = SessionGroupingTabsLayout.self
        let short = layout.usesShortLabels(room: room)
        HStack(spacing: layout.spacing) {
            ForEach(SessionGroupingTab.all, id: \.tag) { tab in
                let selected = mode == tab.tag
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { mode = tab.tag }
                } label: {
                    PixelText(
                        text: short ? tab.shortPixelLabel : tab.pixelLabel,
                        color: selected ? Self.selectedColor
                            : (hoveredTag == tab.tag ? .white.opacity(0.9) : Self.inactiveColor),
                        pixelSize: layout.pixelSize
                    )
                    .padding(.horizontal, layout.horizontalPadding)
                    .frame(height: layout.stripHeight)
                    .background(Rectangle().fill(selected ? .white.opacity(0.1) : .clear))
                    // Taller than the strip it draws: a 24pt target.
                    .frame(height: layout.hitHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredTag = $0 ? tab.tag : (hoveredTag == tab.tag ? nil : hoveredTag) }
                // The pixel glyphs are drawn, not text: without a label
                // VoiceOver reads nothing.
                .help(l10n[tab.nameKey])
                .accessibilityLabel(l10n[tab.nameKey])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(Rectangle().fill(.white.opacity(0.05)).frame(height: layout.stripHeight))
        .overlay(Rectangle().stroke(.white.opacity(0.1), lineWidth: 1).frame(height: layout.stripHeight))
    }
}

// MARK: - Idle Indicator Bar

private struct IdleIndicatorBar: View {
    let compactWingWidth: CGFloat
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
            Spacer(minLength: hasNotch ? notchW : 0)

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
    @AppStorage(SettingsKey.sessionGroupingMode) private var groupingMode = SettingsDefaults.sessionGroupingMode
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions
    @AppStorage(SettingsKey.showUsageStats) private var showUsageStats = SettingsDefaults.showUsageStats
    @AppStorage(SettingsKey.showClaudeQuota) private var showClaudeQuota = SettingsDefaults.showClaudeQuota
    @AppStorage(SettingsKey.sessionListDensity) private var densityRaw = SettingsDefaults.sessionListDensity
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.showProjectName) private var showProjectName = SettingsDefaults.showProjectName
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Natural height of the session cards, scrolling or not.
    @State private var contentHeight: CGFloat = 0
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

    private var groupedSessions: [(header: String, source: String?, ids: [String])] {
        if let only = onlySessionId {
            // A card whose session is gone shows nothing (the AiWork
            // watchers drop sessions without moving the surface). Falling
            // through would render every session as a completion card, and
            // their replies size against each other without settling (#357).
            return appState.sessions[only] != nil ? [("", nil, [only])] : []
        }

        let sorted = orderedSessionIds

        switch groupingMode {
        case "status":
            // What waits on you heads the list here too (SessionListGrouping);
            // while the order is held, so is each card's section.
            let freeze = orderFreeze
            let sessions = appState.sessions
            return SessionListGrouping.byStatus(sorted) { id in
                freeze.status(of: id, live: sessions[id]?.status)
            }.map { group in
                ("\(L10n.shared[group.labelKey]) (\(group.ids.count))", nil, group.ids)
            }

        case "cli":
            let cliOrder: [(source: String, name: String)] = [
                ("claude", "Claude"),
                ("codex", "Codex"),
                ("gemini", "Gemini"),
                ("antigravity", "AntiGravity"),
                ("google-antigravity", "Google Antigravity"),
                ("cursor", "Cursor"),
                ("trae", "Trae"),
                ("traecn", "Trae CN"),
                ("traecli", "Trae CLI"),
                ("copilot", "Copilot"),
                ("qoder", "Qoder"),
                ("qoderwork", "QoderWork"),
                ("droid", "Factory"),
                ("codebuddy", "CodeBuddy"),
                ("codybuddycn", "CodyBuddyCN"),
                ("stepfun", "StepFun"),
                ("workbuddy", "WorkBuddy"),
                ("hermes", "Hermes"),
                ("openclaw", "OpenClaw"),
                ("qwen", "Qwen Code"),
                ("kimi", "Kimi Code CLI"),
                ("opencode", "OpenCode"),
                ("mimo", "MiMo"),
                ("pi", "Pi"),
                ("kiro", "Kiro"),
                ("cline", "Cline"),
                ("zcode", "ZCode"),
                ("minimax", "MiniMax Code CLI"),
                ("aiwork", "AiWork"),
                ("aiwork-cli", "AiWork CLI"),
            ]
            var result: [(String, String?, [String])] = []
            var seen = Set<String>()
            for cli in cliOrder {
                let ids = sorted.filter { id in
                    guard let source = appState.sessions[id]?.source else { return false }
                    if source == cli.source { return true }
                    // Bundle promoted -cli variants with their IDE group (#248).
                    if cli.source == "cursor", source == "cursor-cli" { return true }
                    if cli.source == "qoder", source == "qoder-cli" { return true }
                    return false
                }
                ids.forEach { seen.insert($0) }
                if !ids.isEmpty {
                    result.append(("\(cli.name) (\(ids.count))", cli.source, ids))
                }
            }
            let remaining = sorted.filter { !seen.contains($0) }
            if !remaining.isEmpty {
                result.append(("\(L10n.shared["other"]) (\(remaining.count))", nil, remaining))
            }
            return result

        default: // "all"
            return [("", nil, sorted)]
        }
    }

    var body: some View {
        // Compute once per render — groupedSessions, totalCount, needsScroll
        let groups = groupedSessions
        let totalSessionCount = groups.reduce(0) { $0 + $1.ids.count }
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
                    names: groups.flatMap(\.ids).compactMap {
                        appState.sessions[$0]?.headline(showProjectName: showProjectName).text
                    },
                    fontSize: fontSize,
                    cap: CompactSessionRowMetrics.projectColumnCap(fontSize: fontSize)
                ),
                CompactSessionRowMetrics.statusColumnWidth(fontSize: CompactSessionRowMetrics.statusFontSize(fontSize))
            )
            : (0, 0)
        let content = VStack(spacing: density == .compact ? CompactSessionRowMetrics.spacing : 6) {
            ForEach(groups, id: \.header) { group in
                if !group.header.isEmpty {
                    HStack(spacing: 6) {
                        if let src = group.source, let icon = cliIcon(source: src) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 14, height: 14)
                        }
                        Text(group.header)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                }

                ForEach(group.ids, id: \.self) { sessionId in
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
                orderFreeze.freeze(
                    appState.sessionListOrder(),
                    statuses: appState.sessions.mapValues(\.status)
                )
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

            // Full session list only — the completion card stays focused on
            // the finished session.
            if onlySessionId == nil {
                SessionListFooter(appState: appState, showUsageStats: showUsageStats, showClaudeQuota: showClaudeQuota)
            }
        }
    }
}

// MARK: - Plan limits (Anthropic subscription windows)

private enum QuotaStyle {
    static let normal = Color.white.opacity(0.85)
    static let warning = Color(red: 1.0, green: 0.7, blue: 0.28)
    static let critical = Color(red: 1.0, green: 0.4, blue: 0.4)
    /// A weekly window in surplus — budget worth burning before it resets.
    static let surplus = Color(red: 0.42, green: 0.85, blue: 0.58)

    static func color(_ level: ClaudeQuotaLimit.Level) -> Color {
        switch level {
        case .normal: return normal
        case .warning: return warning
        case .critical: return critical
        }
    }

    /// Chip colour for the picked window: green for a weekly in surplus,
    /// otherwise the severity colour.
    static func color(_ limit: ClaudeQuotaLimit) -> Color {
        if limit.level == .normal, ClaudeQuotaSelector.isSurplus(limit) { return surplus }
        return color(limit.level)
    }

    /// Pace mark colour: amber when spending faster than even pace, green
    /// when behind it, dim within the neutral band.
    static func color(_ tone: ClaudeQuotaLimit.Pace.Tone) -> Color {
        switch tone {
        case .ahead: return warning
        case .behind: return surplus
        case .neutral: return .white.opacity(0.4)
        }
    }

    /// "32 pts ahead of pace (≈1h36m) · runs out in 47m at this rate".
    static func paceSentence(_ pace: ClaudeQuotaLimit.Pace, l10n: L10n) -> String {
        let points = "\(abs(Int(pace.points.rounded())))"
        let span = ClaudeQuotaFormat.duration(pace.duration)
        var parts: [String]
        switch pace.tone {
        case .ahead: parts = [String(format: l10n["quota_pace_ahead"], points, span)]
        case .behind: parts = [String(format: l10n["quota_pace_behind"], points, span)]
        case .neutral: parts = [l10n["quota_pace_even"]]
        }
        if let exhaustsIn = pace.exhaustsIn {
            parts.append(String(format: l10n["quota_pace_exhausts"], ClaudeQuotaFormat.duration(exhaustsIn)))
        } else {
            parts.append(String(format: l10n["quota_pace_projected"], ClaudeQuotaFormat.percent(pace.projectedPercent)))
        }
        return parts.joined(separator: " · ")
    }

    static func label(_ limit: ClaudeQuotaLimit, l10n: L10n) -> String {
        switch limit.kind {
        case .session: return "5h"
        case .weeklyAll: return l10n["quota_week"]
        case .weeklyScoped: return limit.scopeLabel ?? l10n["quota_week"]
        }
    }

    /// One line per window for tooltips: "5h 3% · resets in 1h20m".
    static func tooltip(_ snapshot: ClaudeQuotaSnapshot, stale: Bool, l10n: L10n, now: Date = Date()) -> String {
        var lines = snapshot.ordered.map { limit -> String in
            var line = "\(label(limit, l10n: l10n)) \(ClaudeQuotaFormat.percent(limit.percent))"
            if let resetsAt = limit.resetsAt, let cd = ClaudeQuotaFormat.countdown(until: resetsAt, now: now) {
                line += " · ↻ \(cd)"
            }
            if let pace = limit.pace(now: now) {
                line += " · " + paceSentence(pace, l10n: l10n)
            }
            return line
        }
        if stale { lines.append(l10n["quota_stale"]) }
        return lines.joined(separator: "\n")
    }
}

/// How the collapsed bar makes room for the plan-limit chip.
///
/// The bar is centred on the notch, so extra width added to it is split
/// evenly: the chip, which sits in the left wing, would only get half and
/// its tail would slide under the notch. On notched screens the bar instead
/// grows by exactly what the left wing lacks and shifts left by half of it,
/// so the right wing stays put and the gap between the wings still lands on
/// the notch. Nothing is spent on the right: menu-bar space on a MacBook is
/// too scarce to pad for symmetry.
enum QuotaChipLayout {
    struct Reserve: Equatable {
        /// Added to the collapsed bar's width.
        let extraWidth: CGFloat
        /// Horizontal offset of the whole bar (negative = left).
        let shift: CGFloat

        static let none = Reserve(extraWidth: 0, shift: 0)
    }

    /// Left wing padding before the mascot, and the spacing after it.
    static let wingLeading: CGFloat = 6
    static let wingSpacing: CGFloat = 6
    /// Clearance between the chip's tail and the notch edge.
    static let notchGap: CGFloat = 4

    /// - Parameters:
    ///   - wing: base width of each wing (`compactWingWidth`).
    ///   - statusExtra: the status / tool-status reserves the bar already
    ///     splits between both wings; half of it is left-wing room.
    ///   - spareWidth: how much wider the bar can get before it runs past
    ///     the panel window (window width minus the bar without the chip).
    static func reserve(
        chipWidth: CGFloat,
        mascotSize: CGFloat,
        wing: CGFloat,
        statusExtra: CGFloat,
        hasNotch: Bool,
        spareWidth: CGFloat = .infinity
    ) -> Reserve {
        // No notch to clear: the flexible row just needs the chip's width.
        // On a wide external display at a large width scale with tool status
        // on, that can run past the window; capped, the centre tool status
        // (or the spacer) gives up the difference instead.
        guard hasNotch else {
            return Reserve(extraWidth: Swift.min(chipWidth + wingSpacing, Swift.max(0, spareWidth)), shift: 0)
        }
        let needed = wingLeading + mascotSize + wingSpacing + chipWidth + notchGap
        let room = wing + statusExtra / 2
        let missing = Swift.max(0, needed - room)
        return Reserve(extraWidth: missing, shift: -missing / 2)
    }
}

/// Reports the collapsed chip's laid-out width up to the bar for its reserve.
struct QuotaChipWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = Swift.max(value, nextValue())
    }
}

/// How the collapsed bar makes room for its right wing on a notched screen.
///
/// The right wing (quiet-hours moon, completion dot, question badge, session
/// count) sits at the bar's right end, and whatever it is wider than its room
/// reaches back under the notch. Its room is a wing plus half the status
/// reserve — enough for the count and one badge. With tool status in simple
/// mode nothing else pads it, so a waiting question's badge slid under the
/// notch and the completion dot beside it vanished behind it. The bar grows by
/// what the wing lacks and shifts right by half of it, so the left end and the
/// gap over the notch stay put — the mirror of `QuotaChipLayout`.
enum CompactRightWingLayout {
    /// - Parameter contentWidth: the right wing's laid-out width, trailing
    ///   padding included; 0 until it has been measured.
    static func missing(contentWidth: CGFloat, wing: CGFloat, statusExtra: CGFloat, hasNotch: Bool) -> CGFloat {
        guard hasNotch, contentWidth > 0 else { return 0 }
        return Swift.max(0, contentWidth + QuotaChipLayout.notchGap - (wing + statusExtra / 2))
    }
}

/// Reports the collapsed right wing's laid-out width up to the bar.
struct CompactRightWingWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = Swift.max(value, nextValue())
    }
}

/// Signed pace points hung under a percent like a subscript: drawn as an
/// overlay so it never moves or widens what it annotates.
private struct QuotaPaceMark: ViewModifier {
    let pace: ClaudeQuotaLimit.Pace?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let pace {
                Text(ClaudeQuotaFormat.paceDelta(pace.points))
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(QuotaStyle.color(pace.tone))
                    .fixedSize()
                    // Bottom-aligned, then pushed down by about its own line
                    // height so it hangs just under the percent.
                    .offset(y: 7.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Collapsed-island chip: window label, a 9pt ring, and percent with its
/// pace mark hung underneath.
struct QuotaChip: View {
    let limit: ClaudeQuotaLimit
    let snapshot: ClaudeQuotaSnapshot
    let stale: Bool
    /// Whether the pace mark has room under the percent (see `paceFits`).
    let showsPace: Bool
    @ObservedObject private var l10n = L10n.shared

    /// Longest window label the chip shows. A model-scoped window is named by
    /// the server, and a long display name would push the bar past the panel
    /// window; the tooltip still shows it in full.
    static let maxLabelLength = 8

    /// The pace mark hangs under the percent, inside a wing as tall as the
    /// mascot. Below this mascot size (a menu-bar-height bar, ≈25pt) there is
    /// no room for it and it would be cut in half; the tooltip still has it.
    static func paceFits(mascotSize: CGFloat) -> Bool { mascotSize >= 24 }

    static func label(for limit: ClaudeQuotaLimit, l10n: L10n) -> String {
        let full = QuotaStyle.label(limit, l10n: l10n)
        guard full.count > maxLabelLength else { return full }
        return full.prefix(maxLabelLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// First-frame guess at the chip's width before it is measured: ring and
    /// percent plus the window label (10pt monospaced ≈ 6.2pt per glyph).
    static func estimatedWidth(for limit: ClaudeQuotaLimit) -> CGFloat {
        38 + CGFloat(label(for: limit, l10n: L10n.shared).count) * 6.2
    }

    init(limit: ClaudeQuotaLimit, snapshot: ClaudeQuotaSnapshot, stale: Bool, showsPace: Bool) {
        self.limit = limit
        self.snapshot = snapshot
        self.stale = stale
        self.showsPace = showsPace
    }

    /// Shared resolution for the chip's limit so the bar width and the wing
    /// agree on whether it is shown.
    static func limit(appState: AppState, enabled: Bool, modeRaw: String) -> ClaudeQuotaLimit? {
        guard enabled, let mode = ClaudeQuotaChipMode(rawValue: modeRaw), mode != .off,
              let snapshot = appState.claudeQuota.snapshot else { return nil }
        return ClaudeQuotaSelector.pick(from: snapshot, mode: mode)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            chip(now: context.date)
        }
    }

    private func chip(now: Date) -> some View {
        let color = QuotaStyle.color(limit)
        return HStack(spacing: 3) {
            // Which window this is: 5h / week / model name.
            Text(Self.label(for: limit, l10n: l10n))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: min(limit.percent / 100, 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 9, height: 9)
            Text(ClaudeQuotaFormat.percent(limit.percent))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .modifier(QuotaPaceMark(pace: showsPace ? limit.pace(now: now) : nil))
        }
        .opacity(stale ? 0.55 : 1)
        .help(QuotaStyle.tooltip(snapshot, stale: stale, l10n: l10n, now: now))
    }
}

// MARK: - Session list footer (plan limits, token usage)

/// Which lines the session list's footer shows.
struct SessionListFooterContent: Equatable {
    /// Plan limits on one line, the token totals in its tooltip.
    var limits = false
    /// The token totals in words, on a line of their own.
    var tokens = false
    /// "Plan limits: could not reach Anthropic" — limits on, nothing fetched.
    var quotaMessage = false

    /// With plan limits on and fetched, they lead and the tokens fold into
    /// their line; otherwise (setting off, first fetch pending or failed) the
    /// token line shows as before, with the fetch error under it.
    static func resolve(showClaudeQuota: Bool, hasSnapshot: Bool, hasError: Bool, hasUsage: Bool) -> Self {
        if showClaudeQuota && hasSnapshot { return Self(limits: true) }
        return Self(tokens: hasUsage, quotaMessage: showClaudeQuota && hasError)
    }
}

/// The footer's words: token totals ("last 5h: 422K in · 96K out") and the
/// plan-limit tooltip ("5h 64% · resets in 2h20m · …").
enum UsageFooterText {
    /// A model-scoped window is named by the server; past this many
    /// characters the line shows it cut, the tooltip in full.
    static let maxWindowLabelLength = 10

    /// Token usage worth a footer: the setting is on and there is some.
    static func shownUsage(_ usage: ClaudeUsageScanner.Snapshot?, enabled: Bool) -> ClaudeUsageScanner.Snapshot? {
        guard enabled, let usage, !(usage.last5h.isEmpty && usage.today.isEmpty) else { return nil }
        return usage
    }

    /// "422K in · 96K out". In is billed input: new input plus cache writes.
    static func inOut(_ totals: ClaudeUsageTotals, l10n: L10n) -> String {
        String(
            format: l10n["usage_in_out"],
            ClaudeUsageScanner.formatTokens(totals.inputTokens + totals.cacheCreationTokens),
            ClaudeUsageScanner.formatTokens(totals.outputTokens)
        )
    }

    /// "last 5h: 422K in · 96K out"
    static func last5h(_ usage: ClaudeUsageScanner.Snapshot, l10n: L10n) -> String {
        String(format: l10n["usage_span"], l10n["usage_last_5h"], inOut(usage.last5h, l10n: l10n))
    }

    /// "Today: 922K in · 233K out"
    static func today(_ usage: ClaudeUsageScanner.Snapshot, l10n: L10n) -> String {
        String(format: l10n["usage_span"], l10n["usage_today"], inOut(usage.today, l10n: l10n))
    }

    /// Capitalises a span that starts a line ("last 5h" → "Last 5h").
    static func leading(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Token totals for a tooltip: where they come from, then each window
    /// with what its "in" is made of.
    static func usageTooltip(_ usage: ClaudeUsageScanner.Snapshot, l10n: L10n) -> String {
        func breakdown(_ t: ClaudeUsageTotals) -> String {
            "  " + String(
                format: l10n["usage_tooltip_breakdown"],
                ClaudeUsageScanner.formatTokens(t.inputTokens),
                ClaudeUsageScanner.formatTokens(t.cacheCreationTokens),
                ClaudeUsageScanner.formatTokens(t.cacheReadTokens)
            )
        }
        return [
            l10n["usage_tooltip_title"],
            leading(last5h(usage, l10n: l10n)), breakdown(usage.last5h),
            today(usage, l10n: l10n), breakdown(usage.today),
        ].joined(separator: "\n")
    }

    /// The footer's name for a window: "5h", "Week", or the model's name, cut
    /// to `maxWindowLabelLength`.
    static func windowLabel(_ limit: ClaudeQuotaLimit, l10n: L10n) -> String {
        let full = QuotaStyle.label(limit, l10n: l10n)
        guard full.count > maxWindowLabelLength else { return full }
        return full.prefix(maxWindowLabelLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Colour level in the footer: the server's severity, raised to a warning
    /// near the cap (the alert threshold the chip's Auto mode uses) in case
    /// the server still calls it normal there.
    static func level(_ limit: ClaudeQuotaLimit) -> ClaudeQuotaLimit.Level {
        if limit.level == .normal, limit.percent >= ClaudeQuotaSelector.alertPercent { return .warning }
        return limit.level
    }

    /// "5h 64% · resets in 2h20m · 11 pts ahead of even pace (≈33m) · runs
    /// out in 1h40m at this rate".
    static func limitLine(_ limit: ClaudeQuotaLimit, l10n: L10n, now: Date) -> String {
        var parts = ["\(QuotaStyle.label(limit, l10n: l10n)) \(ClaudeQuotaFormat.percent(limit.percent))"]
        if let resetsAt = limit.resetsAt, let countdown = ClaudeQuotaFormat.countdown(until: resetsAt, now: now) {
            parts.append(String(format: l10n["quota_resets_in"], countdown))
        }
        if let pace = limit.pace(now: now) {
            parts.append(QuotaStyle.paceSentence(pace, l10n: l10n))
        }
        return parts.joined(separator: " · ")
    }

    /// The limit line's tooltip: every window with its reset and pace, a
    /// stale note, then the token totals the line no longer shows.
    static func limitsTooltip(
        _ snapshot: ClaudeQuotaSnapshot,
        stale: Bool,
        usage: ClaudeUsageScanner.Snapshot?,
        l10n: L10n,
        now: Date
    ) -> String {
        var lines = snapshot.ordered.map { limitLine($0, l10n: l10n, now: now) }
        if stale { lines.append(l10n["quota_stale"]) }
        if let usage { lines += ["", usageTooltip(usage, l10n: l10n)] }
        return lines.joined(separator: "\n")
    }
}

/// The session list's footer (SessionListFooterContent): plan limits first
/// when they're on, otherwise the token totals in words.
private struct SessionListFooter: View {
    var appState: AppState
    let showUsageStats: Bool
    let showClaudeQuota: Bool

    var body: some View {
        let usage = UsageFooterText.shownUsage(appState.claudeUsage, enabled: showUsageStats)
        let snapshot = appState.claudeQuota.snapshot
        let error = appState.claudeQuota.lastError
        let content = SessionListFooterContent.resolve(
            showClaudeQuota: showClaudeQuota,
            hasSnapshot: snapshot != nil,
            hasError: error != nil,
            hasUsage: usage != nil
        )
        if content.limits, let snapshot {
            QuotaFooterLine(snapshot: snapshot, error: error, usage: usage)
        }
        if content.tokens, let usage {
            UsageFooterLine(usage: usage)
        }
        if content.quotaMessage, let error {
            QuotaFooterMessage(error: error)
        }
    }
}

/// Plan limits on one line, what can stop you first: each window's bar,
/// percent (warning colours near the cap) and reset countdown, then the
/// token sparkline. Token totals and pace numbers are in the tooltip.
private struct QuotaFooterLine: View {
    let snapshot: ClaudeQuotaSnapshot
    let error: ClaudeQuotaClientError?
    let usage: ClaudeUsageScanner.Snapshot?
    @ObservedObject private var l10n = L10n.shared

    static let barWidth: CGFloat = 46

    var body: some View {
        // Countdowns tick once a minute; the panel is only open briefly.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let tooltip = UsageFooterText.limitsTooltip(
                snapshot, stale: error != nil, usage: usage, l10n: l10n, now: now
            )
            HStack(spacing: 8) {
                // Too narrow for every window with its countdown (long
                // model name, large text): the countdowns go first, to the
                // tooltip.
                ViewThatFits(in: .horizontal) {
                    windows(now: now, countdowns: true)
                    windows(now: now, countdowns: false)
                }
                Spacer(minLength: 0)
                if error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(QuotaStyle.warning)
                        .help(l10n["quota_stale"])
                }
                if let usage {
                    UsageSparkline(buckets: usage.hourlyOutputTokens)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 9)
            .contentShape(Rectangle())
            .help(tooltip)
            // The tooltip is the whole story, tokens included.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tooltip)
        }
    }

    private func windows(now: Date, countdowns: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(snapshot.ordered.enumerated()), id: \.offset) { _, limit in
                segment(limit, now: now, countdown: countdowns)
            }
        }
        .lineLimit(1)
    }

    private func segment(_ limit: ClaudeQuotaLimit, now: Date, countdown: Bool) -> some View {
        let color = QuotaStyle.color(UsageFooterText.level(limit))
        return HStack(spacing: 5) {
            Text(UsageFooterText.windowLabel(limit, l10n: l10n))
                .foregroundStyle(.white.opacity(0.6))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(color)
                    .frame(width: Self.barWidth * min(limit.percent / 100, 1))
                // Even-pace tick: where usage would be if spread evenly.
                if let elapsed = limit.elapsedFraction(now: now) {
                    Rectangle()
                        .fill(.white.opacity(0.6))
                        .frame(width: 1, height: 8)
                        .offset(x: Self.barWidth * elapsed - 0.5)
                }
            }
            .frame(width: Self.barWidth, height: 5)
            Text(ClaudeQuotaFormat.percent(limit.percent))
                .fontWeight(.semibold)
                .foregroundStyle(color)
            if countdown, let resetsAt = limit.resetsAt,
               let left = ClaudeQuotaFormat.countdown(until: resetsAt, now: now) {
                Text(left)
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .fixedSize()
    }
}

/// Footer fallback when there is no snapshot yet but the fetch failed.
private struct QuotaFooterMessage: View {
    let error: ClaudeQuotaClientError
    @ObservedObject private var l10n = L10n.shared

    private var text: String {
        switch error {
        case .unauthorized, .noCredential: return l10n["quota_login_needed"]
        default: return l10n["quota_unreachable"]
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 8)
        .help(text)
    }
}

/// Token totals from the local Claude transcripts, in words: "Claude · last
/// 5h: 422K in · 96K out   Today: 922K in · 233K out". "In" is billed input
/// (new input + cache writes); the tooltip breaks it down.
private struct UsageFooterLine: View {
    let usage: ClaudeUsageScanner.Snapshot
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let last5h = UsageFooterText.last5h(usage, l10n: l10n)
        let today = UsageFooterText.today(usage, l10n: l10n)
        let tooltip = UsageFooterText.usageTooltip(usage, l10n: l10n)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 9, weight: .semibold))
            // A long translation ("Eingabe" / "Ausgabe") sheds the "Claude ·"
            // lead, then takes a second line rather than cut a number off.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    span5h(last5h, brand: true)
                    Text(today)
                }
                .fixedSize()
                HStack(spacing: 14) {
                    span5h(last5h, brand: false)
                    Text(today)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 3) {
                    span5h(last5h, brand: true)
                    Text(today)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 8)
            UsageSparkline(buckets: usage.hourlyOutputTokens)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
    }

    /// "Claude · last 5h: 422K in · 96K out", or without the lead
    /// ("Last 5h: …").
    private func span5h(_ last5h: String, brand: Bool) -> some View {
        HStack(spacing: 5) {
            if brand {
                Text("Claude").fontWeight(.semibold)
                Text("·").foregroundStyle(.white.opacity(0.5))
                Text(last5h)
            } else {
                Text(UsageFooterText.leading(last5h))
            }
        }
    }
}

/// Trailing-hours output-token activity, one 2.5pt bar per hour (right = now).
private struct UsageSparkline: View {
    let buckets: [Int]

    var body: some View {
        let peak = max(buckets.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(.white.opacity(value == 0 ? 0.12 : 0.45))
                    .frame(width: 2.5, height: max(1.5, CGFloat(value) / CGFloat(peak) * 10))
            }
        }
        .frame(height: 10, alignment: .bottom)
        // Decorative: the tooltip and the line's label carry the numbers.
        .accessibilityHidden(true)
    }
}

/// Thin overlay scrollbar via NSScrollView — ignores system "show scrollbar" preference.
private struct ThinScrollView<Content: View>: NSViewRepresentable {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    /// AppKit puts the system's preferred style back (legacy with a mouse
    /// attached or "Show scroll bars: Always") on its own schedule; a legacy
    /// scroller took 13pt off the session list's width until the next update.
    private final class OverlayScrollView: NSScrollView {
        override var scrollerStyle: NSScroller.Style {
            get { super.scrollerStyle }
            set { super.scrollerStyle = .overlay }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = OverlayScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.drawsBackground = false
        scrollView.scrollerKnobStyle = .light

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight),
        ])

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let hosting = scrollView.documentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.controlSize = .mini
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
                if showModelLabel, let modelLabel = session.modelLabel {
                    SessionTag(modelLabel, color: SessionMetadataStyle.modelTagColor, maxWidth: 120)
                        .help(session.model ?? modelLabel)
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
                    if let icon = termIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 13, height: 13)
                    }
                    if let term = badgeLabel {
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

/// Collapsed single-line row for idle sessions >15 min
// MARK: - Pixel Text (5×7 dot matrix style)

struct PixelText: View {
    let text: String
    let color: Color
    var pixelSize: CGFloat = 2

    private static let W = 5  // glyph width
    private static let H = 7  // glyph height
    /// Rows any glyph draws in: the bottom two are always blank, and framing
    /// them too set the letters high in a centred strip.
    private static let inkRows = 5

    // 5×7 bitmaps — each row is 5 bits, 7 rows per glyph
    static let glyphs: [Character: [UInt8]] = [
        "0": [0,1,1,1,0, 1,0,0,1,1, 1,0,1,0,1, 1,1,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "1": [0,0,1,0,0, 0,1,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "2": [0,1,1,1,0, 1,0,0,0,1, 0,0,1,1,0, 0,1,0,0,0, 1,1,1,1,1, 0,0,0,0,0, 0,0,0,0,0],
        "3": [0,1,1,1,0, 1,0,0,0,1, 0,0,1,1,0, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "4": [0,0,0,1,0, 0,0,1,1,0, 0,1,0,1,0, 1,1,1,1,1, 0,0,0,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "5": [1,1,1,1,1, 1,0,0,0,0, 1,1,1,1,0, 0,0,0,0,1, 1,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "6": [0,1,1,1,0, 1,0,0,0,0, 1,1,1,1,0, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "7": [1,1,1,1,1, 0,0,0,0,1, 0,0,0,1,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "8": [0,1,1,1,0, 1,0,0,0,1, 0,1,1,1,0, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "9": [0,1,1,1,0, 1,0,0,0,1, 0,1,1,1,1, 0,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "A": [0,0,1,0,0, 0,1,0,1,0, 1,0,0,0,1, 1,1,1,1,1, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "B": [1,1,1,1,0, 1,0,0,0,1, 1,1,1,1,0, 1,0,0,0,1, 1,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "C": [0,1,1,1,0, 1,0,0,0,1, 1,0,0,0,0, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "D": [1,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 1,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "E": [1,1,1,1,1, 1,0,0,0,0, 1,1,1,1,0, 1,0,0,0,0, 1,1,1,1,1, 0,0,0,0,0, 0,0,0,0,0],
        "F": [1,1,1,1,1, 1,0,0,0,0, 1,1,1,1,0, 1,0,0,0,0, 1,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "G": [0,1,1,1,0, 1,0,0,0,0, 1,0,0,1,1, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "H": [1,0,0,0,1, 1,0,0,0,1, 1,1,1,1,1, 1,0,0,0,1, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "I": [0,1,1,1,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "K": [1,0,0,1,0, 1,0,1,0,0, 1,1,0,0,0, 1,0,1,0,0, 1,0,0,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "L": [1,0,0,0,0, 1,0,0,0,0, 1,0,0,0,0, 1,0,0,0,0, 1,1,1,1,1, 0,0,0,0,0, 0,0,0,0,0],
        "N": [1,0,0,0,1, 1,1,0,0,1, 1,0,1,0,1, 1,0,0,1,1, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "O": [0,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "P": [1,1,1,1,0, 1,0,0,0,1, 1,1,1,1,0, 1,0,0,0,0, 1,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "R": [1,1,1,1,0, 1,0,0,0,1, 1,1,1,1,0, 1,0,0,1,0, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "S": [0,1,1,1,1, 1,0,0,0,0, 0,1,1,1,0, 0,0,0,0,1, 1,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "T": [1,1,1,1,1, 0,0,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "U": [1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "W": [1,0,0,0,1, 1,0,0,0,1, 1,0,1,0,1, 1,0,1,0,1, 0,1,0,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "X": [1,0,0,0,1, 0,1,0,1,0, 0,0,1,0,0, 0,1,0,1,0, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "/": [0,0,0,0,1, 0,0,0,1,0, 0,0,1,0,0, 0,1,0,0,0, 1,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "-": [0,0,0,0,0, 0,0,0,0,0, 1,1,1,1,1, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
        " ": [0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
    ]

    var body: some View {
        let chars = Array(text.uppercased())
        let px = pixelSize
        let gap: CGFloat = px

        Canvas { ctx, size in
            var xOff: CGFloat = 0
            for ch in chars {
                guard let glyph = Self.glyphs[ch] else {
                    xOff += 3 * px
                    continue
                }
                for row in 0..<Self.H {
                    for col in 0..<Self.W {
                        if glyph[row * Self.W + col] == 1 {
                            let rect = CGRect(x: xOff + CGFloat(col) * px, y: CGFloat(row) * px, width: px, height: px)
                            ctx.fill(Path(rect), with: .color(color))
                        }
                    }
                }
                xOff += CGFloat(Self.W) * px + gap
            }
        }
        .frame(width: charWidth(chars.count), height: CGFloat(Self.inkRows) * pixelSize)
    }

    private func charWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let px = pixelSize
        return CGFloat(count) * (CGFloat(Self.W) * px + px) - px
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
    static let modelTagColor = Color(red: 0.55, green: 0.82, blue: 0.78)
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

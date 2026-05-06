import SwiftUI
import AVFoundation
import AppKit
import ApplicationServices
import EventKit

/// First-launch onboarding flow.
///
/// Visual approach:
///   • **Drifting background.** Subtle radial accents move slowly
///     in opposite directions on a 12s+ loop so the surface never
///     reads as a flat poster. Combined with a faint noise/grain
///     overlay, the background has presence — like Linear, Raycast,
///     or Apple's onboarding flows.
///   • **Staggered element entrance.** Title appears first, subtitle
///     follows ~120ms later, supporting elements ~240ms later, CTA
///     last. Each element has its own spring + fade, so the page
///     feels assembled rather than pasted on.
///   • **Spring page transitions.** Going next isn't a fade —
///     it's a layered slide where the new page enters from the
///     right with overshoot while the old page eases off to the
///     left. Spring physics are tuned tighter than SwiftUI defaults
///     (response: 0.42, damping: 0.82) for a "confident" feel.
///   • **Sliding pill dot indicator.** The active state isn't a
///     toggle — it's a capsule that physically slides from one dot
///     position to the next via matchedGeometryEffect, so the page
///     transition has a continuous visual link to the navigation
///     state.
///   • **Checkmark draw-in on the Ready page.** Path-trim animation
///     so the check actually draws itself, with a layered radial
///     glow that pulses in two phases. Feels more like a moment of
///     completion than a static icon.
///
/// Persistence: `UserDefaults.onboardingCompletedV1: Bool`. Bump
/// the V suffix when the flow changes substantively.
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentPage: Int = 0
    @State private var animateIn: Bool = false
    /// Tick used by the background animation. Increments every
    /// frame via TimelineView; we read it inside the radial-gradient
    /// modifier to drift the centers slowly. No state thrash for
    /// the rest of the view because the consumer is the background
    /// only.
    ///
    /// 2026-05-06: bumped from 3 to 6. The single-page SetupPage that
    /// crammed mic + accessibility + Whisper + API key onto one screen
    /// was replaced with one-permission-per-step cards. Rationale:
    /// users reported "all the permission [prompts] are coming in
    /// the background layer of the onboarding" — they didn't know
    /// what each system dialog was for because the explainer was
    /// buried two-rows-deep on a shared page. Now each TCC permission
    /// gets its own full-bleed page with a privacy explainer in
    /// plain English ("audio never leaves your Mac", "we don't
    /// store your calendar") so the system prompt that follows
    /// reads as a confirmation, not a surprise.
    private let totalPages: Int = 6

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                // Each page is in its own container with an explicit
                // .id so SwiftUI re-evaluates onAppear (which kicks
                // off staggered animations inside each page).
                //
                // Page order is intentional:
                //   0. Welcome — sets the tone
                //   1. Microphone — the only HARD requirement for
                //      dictation; everything else is enhancement
                //   2. Accessibility — needed for the Fn-key tap
                //      and paste-at-cursor; fail soft with ⌘⇧D
                //   3. Calendar — fully optional; pill is hidden
                //      unless the toggle is on
                //   4. Music — explainer only (Apple Events
                //      prompts can't be pre-fired; macOS asks the
                //      first time we contact Spotify/Music)
                //   5. Ready — recap + dismissal CTA
                Group {
                    switch currentPage {
                    case 0:
                        WelcomePage(onContinue: { goNext() })
                            .id("page-welcome")
                    case 1:
                        PermissionStepPage(
                            kind: .microphone,
                            onContinue: { goNext() }
                        ).id("page-mic")
                    case 2:
                        PermissionStepPage(
                            kind: .accessibility,
                            onContinue: { goNext() }
                        ).id("page-accessibility")
                    case 3:
                        PermissionStepPage(
                            kind: .calendar,
                            onContinue: { goNext() }
                        ).id("page-calendar")
                    case 4:
                        PermissionStepPage(
                            kind: .appleEvents,
                            onContinue: { goNext() }
                        ).id("page-music")
                    default:
                        ReadyPage(onComplete: onComplete)
                            .id("page-ready")
                    }
                }
                .transition(pageTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                progressDots
                    .padding(.bottom, 28)
            }
        }
        .frame(width: 720, height: 540)
        .opacity(animateIn ? 1 : 0)
        .scaleEffect(animateIn ? 1 : 0.96)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                animateIn = true
            }
        }
    }

    // MARK: Page transition

    /// Slide-and-fade with overshoot. New page comes in from the
    /// right with a tiny overshoot; old page slides off left while
    /// fading. Spring physics give it a confident snap rather than
    /// a generic crossfade.
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: PageTransitionModifier(progress: 0, direction: .insertion),
                identity: PageTransitionModifier(progress: 1, direction: .insertion)
            ),
            removal: .modifier(
                active: PageTransitionModifier(progress: 0, direction: .removal),
                identity: PageTransitionModifier(progress: 1, direction: .removal)
            )
        )
    }

    // MARK: Progress dots

    /// Three dots at the bottom — the active dot is a sliding pill
    /// that physically moves between positions via matchedGeometryEffect.
    /// Inactive dots are tiny low-opacity circles. The transition
    /// reads as one continuous gesture rather than three independent
    /// state changes.
    @Namespace private var dotNamespace

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(0..<totalPages, id: \.self) { i in
                ZStack {
                    if currentPage == i {
                        Capsule()
                            .fill(Color.white.opacity(0.90))
                            .matchedGeometryEffect(id: "dot", in: dotNamespace)
                            .frame(width: 24, height: 6)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.20))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 24, height: 6)  // reserve same slot so layout doesn't shift
            }
        }
    }

    // MARK: Drifting background

    private var backgroundLayer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Two slow sinusoids per axis at different frequencies
            // produce a wandering point that doesn't feel like a
            // simple loop. Ranges chosen so the centers stay inside
            // the visible canvas but visit different corners over
            // time.
            let t1x = 0.5 + 0.35 * sin(t * 0.13)
            let t1y = 0.3 + 0.25 * sin(t * 0.17 + 1.2)
            let t2x = 0.5 + 0.35 * cos(t * 0.11 + 2.3)
            let t2y = 0.7 + 0.25 * cos(t * 0.19)

            ZStack {
                // Deeper near-black base — Linear / Raycast aesthetic
                // rather than Apple-light-dark. RGB ≈ #050507. The
                // user feedback after the first polished pass was
                // "a little better, maybe a bit darker" — this hits
                // that target.
                Color(red: 0.025, green: 0.025, blue: 0.035)

                // Drifting radial accents — toned WAY down vs the
                // first pass (was .55/.40 opacity, now .26/.20).
                // They still shift the surface so it doesn't read
                // as flat poster-black, but stay deep and moody
                // rather than purple-glow.
                RadialGradient(
                    colors: [
                        Color(red: 0.28, green: 0.18, blue: 0.48).opacity(0.26),
                        Color.clear
                    ],
                    center: UnitPoint(x: t1x, y: t1y),
                    startRadius: 0,
                    endRadius: 380
                )
                .blendMode(.plusLighter)

                RadialGradient(
                    colors: [
                        Color(red: 0.10, green: 0.28, blue: 0.42).opacity(0.20),
                        Color.clear
                    ],
                    center: UnitPoint(x: t2x, y: t2y),
                    startRadius: 0,
                    endRadius: 420
                )
                .blendMode(.plusLighter)

                // Top hairline — subtler than before (10% → 6%) so
                // it doesn't compete with the dark surface.
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 28)
                    Spacer()
                }

                // Stronger vignette — corners read truly dark, the
                // content area in the middle gets the focus.
                RadialGradient(
                    colors: [Color.clear, Color.black.opacity(0.50)],
                    center: .center,
                    startRadius: 240,
                    endRadius: 520
                )
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    private func goNext() {
        withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
            currentPage = min(currentPage + 1, totalPages - 1)
        }
    }
}

// MARK: - Page transition modifier

private enum TransitionDirection { case insertion, removal }

/// Slide-and-fade with overshoot tied to the transition's progress.
/// When inserting, slides from the right (offset +60) to identity.
/// When removing, slides off to the left (offset -40). Combined
/// with opacity so the page reads as moving and dissolving at once.
private struct PageTransitionModifier: ViewModifier {
    let progress: CGFloat
    let direction: TransitionDirection

    func body(content: Content) -> some View {
        let xOffset: CGFloat = {
            switch direction {
            case .insertion:
                return (1 - progress) * 60
            case .removal:
                return (1 - progress) * -40
            }
        }()
        return content
            .opacity(Double(progress))
            .offset(x: xOffset)
            .scaleEffect(0.97 + 0.03 * progress)
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    let onContinue: () -> Void

    /// Per-element entrance flags — flipped via staggered delays
    /// in onAppear. Each binds to a separate `.opacity + .offset +
    /// .blur` so elements arrive with their own subtle motion.
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var chipsVisible = false
    @State private var ctaVisible = false

    var body: some View {
        // 2026-04-29 rewrite: short sentences, big visuals, plain
        // English. Anyone reading this should understand it even
        // if English is their second or third language. Short
        // words > clever phrasing. Pictures > paragraphs.
        VStack(alignment: .center, spacing: 0) {
            Spacer().frame(height: 56)

            // Brand strip — small, recedes to let the headline land
            HStack(spacing: 8) {
                sparkleIcon
                Text("nox")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .tracking(0.4)
            }
            .modifier(EntranceMotion(visible: titleVisible, delay: 0))

            Spacer().frame(height: 24)

            // Big headline — two short lines, no jargon
            VStack(spacing: 8) {
                Text("Welcome")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .modifier(EntranceMotion(visible: titleVisible, delay: 0.05))
                Text("Notes, music, and dictation,\nright from your notch.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(EntranceMotion(visible: subtitleVisible, delay: 0))
            }

            Spacer().frame(height: 44)

            // Big icon grid — visual-first feature preview.
            // 4 large SF Symbols + one-word labels. Reads in any
            // language because each icon is universal.
            HStack(spacing: 24) {
                ForEach(Array(featureChips.enumerated()), id: \.offset) { index, chip in
                    BigFeatureTile(icon: chip.icon, label: chip.label)
                        .modifier(EntranceMotion(
                            visible: chipsVisible,
                            delay: 0.07 * Double(index)
                        ))
                }
            }

            Spacer()

            PrimaryButton(title: "Get Started", action: onContinue)
                .modifier(EntranceMotion(visible: ctaVisible, delay: 0))
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity)
        .onAppear { runEntrance() }
    }

    /// Sparkle icon — uses `symbolEffect(.bounce)` on macOS 14+
    /// for a subtle attention pulse on entrance, falls back to a
    /// plain Image on macOS 13.
    @ViewBuilder
    private var sparkleIcon: some View {
        if #available(macOS 14.0, *) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 0.98))
                .symbolEffect(.bounce, value: titleVisible)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 0.98))
        }
    }

    private var featureChips: [(icon: String, label: String)] {
        // One-word labels. Universal SF Symbols. Works for any
        // user regardless of English fluency — the icons do the
        // heavy lifting, the label confirms.
        [
            ("mic.fill", "Speak"),
            ("music.note", "Music"),
            ("note.text", "Notes"),
            ("tray.full.fill", "Drop"),
        ]
    }

    private func runEntrance() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { titleVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { subtitleVisible = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { chipsVisible = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { ctaVisible = true }
        }
    }
}

/// Large, visual-first feature tile for the welcome screen.
/// Replaces the small text-heavy "FeatureChip" style with a
/// 64×64 frosted card + 26pt SF Symbol + small label. The icon
/// is the primary content; the label is a single word that
/// confirms what the icon means. Works without any English at
/// all — the icons are universal.
private struct BigFeatureTile: View {
    let icon: String
    let label: String

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.16 : 0.10),
                                Color.white.opacity(isHovered ? 0.08 : 0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.18 : 0.10), lineWidth: 0.5)
                    )
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .frame(width: 72, height: 72)
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .offset(y: isHovered ? -3 : 0)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
    }
}

private struct FeatureChip: View {
    let icon: String
    let label: String

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 0.98))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(Color.white.opacity(isHovered ? 0.10 : 0.06))
        )
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(isHovered ? 0.16 : 0.08), lineWidth: 0.5)
        )
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
    }
}

/// Reusable element-entrance modifier. Maps a `visible` Bool to
/// opacity (0→1), vertical offset (10pt → 0), and a tiny blur fade
/// (3pt → 0). The blur is what tips it from "fade in" to "drift
/// in" — it removes the snap of an opacity transition.
private struct EntranceMotion: ViewModifier {
    let visible: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 10)
            .blur(radius: visible ? 0 : 3)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.85).delay(delay),
                value: visible
            )
    }
}

// MARK: - Permission step pages (one per TCC permission)

/// Drives the four per-permission onboarding pages. Single struct
/// rather than four near-duplicate views: the layout is identical
/// (icon, title, subtitle, three privacy bullets, footer reassurance,
/// action buttons), only the copy + the system call behind the
/// "Allow" button differ.
///
/// Privacy posture: every page MUST end with the "stays on your Mac"
/// footer. The user explicitly asked for "we are not saving any of
/// their data and we are not accessing any of their data for our
/// personal use" — that promise is the load-bearing reason a privacy-
/// conscious user feels comfortable approving the system prompt that
/// follows. Don't remove the footer in any future tweak.
private enum PermissionKind {
    case microphone
    case accessibility
    case calendar
    case appleEvents

    var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "command.circle.fill"
        case .calendar: return "calendar"
        case .appleEvents: return "music.note"
        }
    }

    var headline: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .calendar: return "Calendar"
        case .appleEvents: return "Music & playback"
        }
    }

    var subtitle: String {
        switch self {
        case .microphone:
            return "So you can dictate offline."
        case .accessibility:
            return "So Fn-key dictation and paste-at-cursor work."
        case .calendar:
            return "So nox can show your next meeting on the notch."
        case .appleEvents:
            return "So nox can read what's playing for the music card."
        }
    }

    /// Three short bullet points. First is what the permission unlocks,
    /// second is the privacy posture (we DON'T do X), third is what
    /// happens if the user skips. Plain English, no jargon, written
    /// for someone whose first language isn't English.
    var bullets: [String] {
        switch self {
        case .microphone:
            return [
                "Hold Fn anywhere on your Mac. nox listens and turns your voice into text.",
                "Audio never leaves your Mac. Whisper transcribes locally — no servers, no cloud, no recordings saved.",
                "Skipping is fine — you can flip this on later in Settings → Permissions."
            ]
        case .accessibility:
            return [
                "Lets nox watch the Fn key for the dictation hotkey, and type the transcribed text at your cursor in any app.",
                "We do not log keystrokes, capture screenshots, or read other apps' contents. Only the Fn key is observed.",
                "Skip and you can still dictate via ⌘⇧D — we just won't be able to type at your cursor automatically."
            ]
        case .calendar:
            return [
                "When a meeting is about to start, the notch surfaces it with a one-tap join button.",
                "Read-only. We never add, edit, or delete events, and never store or transmit your calendar data.",
                "Fully optional — skip and the next-meeting pill stays off."
            ]
        case .appleEvents:
            return [
                "Reads what's playing in Spotify or Apple Music so the music card shows artwork, title, and transport buttons.",
                "Read-only — nox never changes your playback. We never store or transmit your listening history.",
                "macOS will ask you to allow this the first time you press play. You can also approve it now in System Settings → Privacy & Security → Automation."
            ]
        }
    }

    /// Footer line that appears at the bottom of EVERY permission
    /// step. Constant text by design — the repetition reinforces the
    /// privacy promise the way Signal's onboarding does.
    static var privacyFooter: String {
        "Your data stays on your Mac. nox never transmits or stores audio, calendar events, or media metadata."
    }
}

private struct PermissionStepPage: View {
    let kind: PermissionKind
    let onContinue: () -> Void

    @State private var headerVisible = false
    @State private var bodyVisible = false
    @State private var ctaVisible = false

    /// Live status mirrors so the Allow button can flip to a "Granted"
    /// confirmation chip the moment the user grants. Apple's TCC
    /// permission dialogs return synchronously enough that an in-page
    /// status flip on the same render cycle reads as the prompt
    /// resolving — no awkward "did my click register?" feeling.
    @State private var status: PermissionStatus = .notDetermined

    enum PermissionStatus {
        case notDetermined
        case granted
        case denied  // includes restricted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 56)

            // Icon + headline + subtitle stack.
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(iconBackgroundColor)
                    Image(systemName: kind.iconName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(iconForegroundColor)
                }
                .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 8) {
                    Text(kind.headline)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(kind.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .modifier(EntranceMotion(visible: headerVisible, delay: 0))

            Spacer().frame(height: 28)

            // Three privacy bullets — what it does, what we don't do,
            // what happens if you skip. No multi-line paragraphs;
            // keep each bullet to a single sentence so the page
            // reads quickly even on a 14" laptop.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(kind.bullets.enumerated()), id: \.offset) { idx, bullet in
                    BulletRow(text: bullet, accent: bulletAccent(forIndex: idx))
                        .modifier(EntranceMotion(visible: bodyVisible, delay: Double(idx) * 0.05))
                }
            }

            Spacer()

            // Footer + actions. Footer is constant across permissions
            // (privacy promise repeats so the user trusts it). Actions
            // adapt to the current permission status.
            VStack(alignment: .leading, spacing: 18) {
                Text(PermissionKind.privacyFooter)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(EntranceMotion(visible: ctaVisible, delay: 0))

                HStack(spacing: 12) {
                    if status == .granted {
                        // Granted state: big "Continue" CTA, no skip
                        // option (they already approved).
                        Spacer()
                        PrimaryButton(title: "Continue", action: onContinue)
                    } else {
                        Button(action: onContinue) {
                            Text(skipLabel)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        PrimaryButton(title: allowLabel, action: handleAllow)
                    }
                }
                .modifier(EntranceMotion(visible: ctaVisible, delay: 0))
            }
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 38)
        .onAppear {
            refreshStatus()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                headerVisible = true
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(0.10)) {
                bodyVisible = true
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(0.22)) {
                ctaVisible = true
            }
        }
    }

    // MARK: Visual styling

    private var iconBackgroundColor: Color {
        switch kind {
        case .microphone: return Color(red: 0.78, green: 0.62, blue: 0.98).opacity(0.18)
        case .accessibility: return Color(red: 0.42, green: 0.78, blue: 1.00).opacity(0.18)
        case .calendar: return Color(red: 1.00, green: 0.62, blue: 0.42).opacity(0.18)
        case .appleEvents: return Color(red: 0.42, green: 0.95, blue: 0.78).opacity(0.18)
        }
    }

    private var iconForegroundColor: Color {
        switch kind {
        case .microphone: return Color(red: 0.78, green: 0.62, blue: 0.98)
        case .accessibility: return Color(red: 0.42, green: 0.78, blue: 1.00)
        case .calendar: return Color(red: 1.00, green: 0.72, blue: 0.52)
        case .appleEvents: return Color(red: 0.55, green: 0.95, blue: 0.78)
        }
    }

    /// Per-bullet accent — use a check for "what it unlocks", a
    /// shield for "what we don't do", a question mark for "skip
    /// path". Visual cue lets a quick scanner pick out the privacy
    /// guarantee without reading.
    private func bulletAccent(forIndex index: Int) -> BulletRow.Accent {
        switch index {
        case 0: return .feature
        case 1: return .privacy
        default: return .skipNote
        }
    }

    // MARK: Action labels

    private var allowLabel: String {
        if kind == .appleEvents { return "Got it" }
        switch status {
        case .granted: return "Granted"
        case .denied: return "Open System Settings"
        case .notDetermined: return "Allow"
        }
    }

    private var skipLabel: String {
        switch kind {
        case .calendar, .appleEvents: return "Skip — I'll decide later"
        case .microphone: return "Skip"
        case .accessibility: return "Skip"
        }
    }

    // MARK: System calls

    private func handleAllow() {
        switch kind {
        case .microphone:
            requestMicrophone()
        case .accessibility:
            requestAccessibility()
        case .calendar:
            requestCalendar()
        case .appleEvents:
            // Can't pre-fire Apple Events prompts — macOS only
            // shows them when the app actually contacts a target
            // app. The user has been primed; advance.
            onContinue()
        }
    }

    private func requestMicrophone() {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        switch current {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) {
                        status = granted ? .granted : .denied
                    }
                    if granted {
                        // Auto-advance after the success state has had
                        // a beat to register visually.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            onContinue()
                        }
                    }
                }
            }
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .authorized:
            status = .granted
            onContinue()
        @unknown default:
            break
        }
    }

    private func requestAccessibility() {
        // Already trusted? Move on.
        if AXIsProcessTrusted() {
            status = .granted
            onContinue()
            return
        }
        // Pop the system prompt. Note: macOS only shows the prompt
        // ONCE per process; subsequent calls return false immediately
        // without re-prompting if denied. The Settings deep-link is
        // the recovery path for that case.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Poll for ~6s — the user has to drag nox into the
        // Accessibility list manually, so we wait a beat then refresh
        // status. If they grant, flip the state and advance; if not,
        // they can hit Skip.
        var attempts = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { t in
            attempts += 1
            DispatchQueue.main.async {
                let trusted = AXIsProcessTrusted()
                if trusted {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) {
                        status = .granted
                    }
                    t.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        onContinue()
                    }
                } else if attempts >= 12 {
                    // Stop polling after ~6s. User can still tap Skip
                    // or open Settings via the action button.
                    t.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func requestCalendar() {
        let store = EKEventStore()
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) {
                        status = granted ? .granted : .denied
                    }
                    if granted {
                        UserDefaults.standard.set(true, forKey: "showNextMeetingPill")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            onContinue()
                        }
                    }
                }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) {
                        status = granted ? .granted : .denied
                    }
                    if granted {
                        UserDefaults.standard.set(true, forKey: "showNextMeetingPill")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            onContinue()
                        }
                    }
                }
            }
        }
    }

    private func refreshStatus() {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: status = .granted
            case .denied, .restricted: status = .denied
            case .notDetermined: status = .notDetermined
            @unknown default: status = .notDetermined
            }
        case .accessibility:
            status = AXIsProcessTrusted() ? .granted : .notDetermined
        case .calendar:
            let s = EKEventStore.authorizationStatus(for: .event)
            if #available(macOS 14, *) {
                if s == .fullAccess || s == .writeOnly || s == .authorized {
                    status = .granted
                } else if s == .denied || s == .restricted {
                    status = .denied
                } else {
                    status = .notDetermined
                }
            } else {
                status = (s == .authorized) ? .granted : (s == .denied || s == .restricted ? .denied : .notDetermined)
            }
        case .appleEvents:
            // No way to read Automation status without sending an
            // Apple Event (which would itself trigger the prompt).
            // Always show the explainer.
            status = .notDetermined
        }
    }
}

/// One row inside a permission step's body — a tiny accent dot, then
/// a single short sentence. Three of these per page (feature, privacy,
/// skip-note) covers the user's question of "what does this unlock,
/// what does it NOT do, and what if I say no?"
private struct BulletRow: View {
    enum Accent {
        case feature   // teal — "what this enables"
        case privacy   // green — "what we don't do"
        case skipNote  // muted gray — "if you skip"

        var color: Color {
            switch self {
            case .feature: return Color(red: 0.42, green: 0.85, blue: 0.95)
            case .privacy: return Color(red: 0.42, green: 0.92, blue: 0.55)
            case .skipNote: return Color.white.opacity(0.40)
            }
        }

        var iconName: String {
            switch self {
            case .feature: return "sparkles"
            case .privacy: return "lock.shield.fill"
            case .skipNote: return "questionmark.circle"
            }
        }
    }

    let text: String
    let accent: Accent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: accent.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent.color)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(accent == .skipNote ? 0.55 : 0.78))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }
}

// MARK: - Page 2: Setup

private struct SetupPage: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    // Keychain-backed (was @AppStorage). Loaded on appear, written
    // back on every change. See SecureKeyStore for the security audit
    // rationale.
    @State private var apiKey: String = ""

    @State private var micGranted: Bool = false
    /// Track the full AVAuthorizationStatus so the button can
    /// distinguish first-time `.notDetermined` (fire system prompt)
    /// from `.denied` (the system has already refused once and only
    /// System Settings can re-enable). Without this distinction the
    /// "Allow" button silently does nothing for denied users — same
    /// regression that triggered the "I can't give the permission
    /// for some reason" report.
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var axGranted: Bool = false
    @State private var keyValidating: Bool = false
    @State private var keyValid: Bool? = nil

    @State private var headerVisible = false
    @State private var rowsVisible = false
    @State private var ctaVisible = false

    var body: some View {
        // 2026-04-29 rewrite. Now that local Whisper is the
        // default, the only HARD requirement is the microphone
        // permission. Accessibility is for the global Fn hotkey
        // and for typing the transcript at the cursor — useful
        // but not required (clipboard copy works without it).
        // Groq API key is now PURELY OPTIONAL (it polishes raw
        // Whisper output; without it we paste raw text).
        //
        // Each section uses a colored badge + 1-line plain
        // English ("for your voice", "for global hotkey",
        // "skip if not sure") so a user with limited English
        // can still understand what each toggle does. Grant
        // status uses ✓ / · symbols, no English needed.
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 50)
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick setup")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Two simple steps. Both optional but recommended.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .modifier(EntranceMotion(visible: headerVisible, delay: 0))

            Spacer().frame(height: 28)

            VStack(alignment: .leading, spacing: 14) {
                SetupRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: micRowSubtitle,
                    status: micGranted ? .granted : .pending,
                    actionLabel: micActionLabel,
                    action: requestMic
                )
                .modifier(EntranceMotion(visible: rowsVisible, delay: 0))

                SetupRow(
                    icon: "command.circle.fill",
                    title: "Accessibility",
                    subtitle: "Lets dictation type at your cursor in any app.",
                    status: axGranted ? .granted : .pending,
                    actionLabel: axGranted ? "Done" : "Open Settings",
                    action: requestAccessibility
                )
                .modifier(EntranceMotion(visible: rowsVisible, delay: 0.06))

                Divider().background(Color.white.opacity(0.08))
                    .padding(.vertical, 6)

                // Local-Whisper "you don't have to do anything"
                // status row — explains why there's no mandatory
                // API key step here.
                LocalWhisperStatusRow()
                    .modifier(EntranceMotion(visible: rowsVisible, delay: 0.10))

                // OPTIONAL Groq key — clearly labeled as optional
                // with a "skip" hint so non-technical users know
                // they can ignore this and dictation still works.
                APIKeyRow(
                    apiKey: $apiKey,
                    keyValidating: $keyValidating,
                    keyValid: $keyValid
                )
                .modifier(EntranceMotion(visible: rowsVisible, delay: 0.14))
            }

            Spacer()

            HStack {
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)

                Spacer()

                PrimaryButton(title: "Continue", action: onContinue)
            }
            .modifier(EntranceMotion(visible: ctaVisible, delay: 0))
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 60)
        .onAppear {
            apiKey = SecureKeyStore.shared.load(.dictationApiKey) ?? ""
            refreshPermissions()
            runEntrance()
        }
        .onChange(of: apiKey) { newValue in
            // Keychain write on every keystroke (cheap; SecItemUpdate is
            // a single XPC round-trip). Empty input → delete the
            // record so we don't keep a zero-length entry around.
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                SecureKeyStore.shared.delete(.dictationApiKey)
            } else {
                SecureKeyStore.shared.save(.dictationApiKey, value: trimmed)
            }
        }
    }

    private func runEntrance() {
        withAnimation { headerVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation { rowsVisible = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation { ctaVisible = true }
        }
    }

    /// Subtitle that adapts to current mic state. The `.denied` case
    /// is the one that previously fooled users — the row said
    /// "Lets nox hear your voice…" with an "Allow" button that did
    /// nothing on click. New copy spells out exactly where to go.
    private var micRowSubtitle: String {
        switch micStatus {
        case .authorized: return "Granted — nox can hear your voice."
        case .denied, .restricted:
            return "Denied earlier. Open Settings → Privacy → Microphone to enable nox."
        case .notDetermined: return "Lets nox hear your voice when you dictate."
        @unknown default: return "Lets nox hear your voice when you dictate."
        }
    }

    /// Button label that mirrors `micRowSubtitle` so the user
    /// always knows what they'll get from a tap.
    private var micActionLabel: String {
        switch micStatus {
        case .authorized: return "Done"
        case .denied, .restricted: return "Open Settings"
        case .notDetermined: return "Allow"
        @unknown default: return "Allow"
        }
    }

    private func refreshPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micGranted = micStatus == .authorized
        axGranted = AXIsProcessTrusted()
    }

    private func requestMic() {
        // macOS only fires the system permission prompt ONCE per app
        // identity. After the user denies (or after .denied is read
        // via TCC for any reason), `AVCaptureDevice.requestAccess`
        // returns `false` immediately without re-prompting — the
        // "Allow" button looks broken because nothing happens. The
        // ONLY recovery path is System Settings.
        //
        // Branch on current status:
        //   .notDetermined → fire the system prompt (one shot).
        //   .denied/.restricted → deep-link to Privacy → Microphone
        //     so the user can flip the nox toggle. Same fallback
        //     SettingsWindow uses on the Permissions row.
        //   .authorized → already granted; nothing to do (button
        //     should be hidden, but guard anyway).
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        micGranted = granted
                    }
                }
            }
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .authorized:
            micGranted = true
        @unknown default:
            break
        }
    }

    private func requestAccessibility() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                refreshPermissions()
            }
        }
    }
}

/// Reassuring "speech model is set up automatically" row that
/// sits between the permissions and the optional API key.
/// Shows a green check + plain-English copy so non-technical
/// users understand they don't have to do anything for
/// dictation to work — the model installs itself in the
/// background.
private struct LocalWhisperStatusRow: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.45))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech model")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Downloads once, then runs on your Mac. No internet needed after.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.60))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Green check — universal "ready" signal, no English.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

private struct SetupRow: View {
    enum Status { case pending, granted }

    let icon: String
    let title: String
    let subtitle: String
    let status: Status
    let actionLabel: String
    let action: () -> Void

    @State private var iconBouncing = false

    /// Status icon — `symbolEffect(.bounce)` on macOS 14+ when the
    /// permission flips from pending → granted. Plain image on
    /// macOS 13.
    @ViewBuilder
    private var statusIcon: some View {
        if #available(macOS 14.0, *) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(status == .granted
                    ? Color(red: 0.55, green: 0.92, blue: 0.68)
                    : Color(red: 0.78, green: 0.62, blue: 0.98))
                .symbolEffect(.bounce, value: iconBouncing)
        } else {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(status == .granted
                    ? Color(red: 0.55, green: 0.92, blue: 0.68)
                    : Color(red: 0.78, green: 0.62, blue: 0.98))
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(status == .granted
                        ? Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.18)
                        : Color.white.opacity(0.08))
                statusIcon
            }
            .frame(width: 36, height: 36)
            .onChange(of: status) { newStatus in
                if newStatus == .granted {
                    iconBouncing.toggle()
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            StatusButton(status: status, label: actionLabel, action: action)
        }
    }
}

private struct StatusButton: View {
    let status: SetupRow.Status
    let label: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if status == .granted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(status == .granted ? Color(red: 0.55, green: 0.92, blue: 0.68) : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(status == .granted
                    ? Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.16)
                    : Color.white.opacity(isHovered ? 0.16 : 0.10))
            )
            .overlay(
                Capsule().strokeBorder(status == .granted
                    ? Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.32)
                    : Color.white.opacity(isHovered ? 0.20 : 0.12), lineWidth: 0.5)
            )
            .scaleEffect(isPressed ? 0.94 : (isHovered ? 1.02 : 1.0))
        }
        .buttonStyle(.plain)
        .disabled(status == .granted)
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.06)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.55)) {
                        isPressed = false
                    }
                }
        )
    }
}

private struct APIKeyRow: View {
    @Binding var apiKey: String
    @Binding var keyValidating: Bool
    @Binding var keyValid: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(keyValid == true
                        ? Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.18)
                        : Color.white.opacity(0.08))
                Image(systemName: "key.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(keyValid == true
                        ? Color(red: 0.55, green: 0.92, blue: 0.68)
                        : Color(red: 0.78, green: 0.62, blue: 0.98))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Polish (optional)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    // Tiny "Optional" badge so non-English readers
                    // see the visual cue: skipping is fine.
                    Text("OPTIONAL")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                        )
                    Spacer()
                    Button {
                        if let url = URL(string: "https://console.groq.com/keys") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("Get free key")
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 0.98))
                    }
                    .buttonStyle(.plain)
                }

                Text("Removes ums and ahs. Free key from Groq, no credit card. Skip if not sure.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    SecureField("paste your key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        .onChange(of: apiKey) { _ in keyValid = nil }

                    Group {
                        if keyValidating {
                            ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
                        } else if keyValid == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(red: 0.40, green: 0.92, blue: 0.55))
                                .transition(.scale.combined(with: .opacity))
                        } else if keyValid == false {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.32, dampingFraction: 0.65), value: keyValid)

                    Button("Test") {
                        Task { await validate() }
                    }
                    .disabled(apiKey.isEmpty || keyValidating)
                }
            }
        }
    }

    private func validate() async {
        await MainActor.run { keyValidating = true }
        let groqURL = URL(string: "https://api.groq.com/openai/v1")!
        let isValid = await DictationService.validateAPIKey(apiKey, baseURL: groqURL)
        await MainActor.run {
            keyValid = isValid
            keyValidating = false
        }
    }
}

// MARK: - Page 3: Ready

private struct ReadyPage: View {
    let onComplete: () -> Void

    @State private var checkProgress: CGFloat = 0
    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: Double = 0
    @State private var pulse: Double = 0
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var ctaVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            HStack {
                Spacer()
                VStack(spacing: 28) {
                    successOrnament

                    VStack(spacing: 14) {
                        Text("You're ready!")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .modifier(EntranceMotion(visible: titleVisible, delay: 0))

                        Text("Here's how to use it:")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.65))
                            .modifier(EntranceMotion(visible: subtitleVisible, delay: 0))
                    }
                    .frame(maxWidth: 440)

                    // Three visual cue cards. Each shows an icon
                    // + a tiny label so non-English readers can
                    // understand at a glance.
                    HStack(spacing: 18) {
                        UseCueCard(
                            icon: "cursorarrow.rays",
                            top: "Hover",
                            bottom: "the notch"
                        )
                        UseCueCard(
                            icon: "mic.fill",
                            top: "Hold Fn",
                            bottom: "to dictate"
                        )
                        UseCueCard(
                            icon: "note.text.badge.plus",
                            top: "⌘⇧N",
                            bottom: "for a note"
                        )
                    }
                    .modifier(EntranceMotion(visible: subtitleVisible, delay: 0.10))
                }
                Spacer()
            }

            Spacer()

            HStack {
                Spacer()
                PrimaryButton(title: "Open nox", action: onComplete)
                    .modifier(EntranceMotion(visible: ctaVisible, delay: 0))
                Spacer()
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 60)
        .onAppear { runEntrance() }
    }

    /// Success ornament — two-layer glow + actual path-traced
    /// checkmark that draws itself from start to finish.
    private var successOrnament: some View {
        ZStack {
            // Outer soft halo, slow breathing.
            Circle()
                .fill(Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.20))
                .frame(width: 130, height: 130)
                .blur(radius: 18)
                .scaleEffect(ringScale + CGFloat(pulse) * 0.06)
                .opacity(ringOpacity * 0.85)

            // Mid ring, brighter.
            Circle()
                .fill(Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.30))
                .frame(width: 96, height: 96)
                .blur(radius: 6)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            // Inner solid disk.
            Circle()
                .fill(Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.32))
                .frame(width: 64, height: 64)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            // The actual checkmark — path with .trim drawing
            // animated from 0 → 1.
            CheckmarkShape()
                .trim(from: 0, to: checkProgress)
                .stroke(
                    Color(red: 0.65, green: 0.97, blue: 0.75),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 30, height: 22)
                .opacity(ringOpacity)
        }
    }

    private func runEntrance() {
        // 1. Ring fades in + scales up.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
            ringScale = 1.0
            ringOpacity = 1.0
        }
        // 2. Check draws in shortly after the ring lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.easeOut(duration: 0.42)) {
                checkProgress = 1.0
            }
        }
        // 3. Title and subtitle stagger in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            withAnimation { titleVisible = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation { subtitleVisible = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            withAnimation { ctaVisible = true }
        }
        // 4. Slow breathing on the halo for ambient life.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
    }
}

/// Checkmark path. Two strokes — a short down-right hook from
/// upper-left, then a long diagonal up-right. Drawn at 30×22pt
/// with stroke-only rendering so `.trim(from:to:)` animates the
/// draw-in cleanly.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Coordinates expressed as fractions of the bounding box
        // for resolution independence.
        let p1 = CGPoint(x: rect.minX + rect.width * 0.10,
                         y: rect.minY + rect.height * 0.55)
        let p2 = CGPoint(x: rect.minX + rect.width * 0.40,
                         y: rect.minY + rect.height * 0.85)
        let p3 = CGPoint(x: rect.minX + rect.width * 0.92,
                         y: rect.minY + rect.height * 0.18)
        path.move(to: p1)
        path.addLine(to: p2)
        path.addLine(to: p3)
        return path
    }
}

// MARK: - Shared button style

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.62, green: 0.46, blue: 0.96),
                            Color(red: 0.46, green: 0.32, blue: 0.86),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Capsule())
                .overlay(
                    // Inner highlight — gives the gradient surface
                    // a subtle "lit from above" feel rather than
                    // looking flat-painted.
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    )
                )
                .shadow(color: Color(red: 0.45, green: 0.32, blue: 0.85).opacity(isHovered ? 0.50 : 0.28),
                        radius: isHovered ? 16 : 9, y: isHovered ? 7 : 4)
                .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.025 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.06)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.55)) {
                        isPressed = false
                    }
                }
        )
    }
}


/// Three-card "how to use it" cue grid on the Ready page.
/// Icon-first design — the SF Symbol is the primary content,
/// labels are short and use universal cues (key combos, the
/// word "Hover"). Works without English: the icons + key
/// labels (⌘⇧N, Fn) are universal across keyboards.
private struct UseCueCard: View {
    let icon: String
    let top: String
    let bottom: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 2) {
                Text(top)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(bottom)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

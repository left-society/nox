import SwiftUI
import AppKit
import AVFoundation
import EventKit

/// Premium onboarding — 3 pages, single visual language.
///
/// Visual reference (user-saved 2026-05-08): the SuperIsland onboarding
/// captures (`~/Library/Application Support/nox/images/ED14F179…` and
/// siblings). Key takeaways from those frames:
///   • Left-aligned big title + light subtitle on each step page.
///   • A SINGLE grouped card holds all permission/summary rows,
///     separated by hairline dividers — not 3 individual hover-cards.
///   • A subtle ‹ Back chevron sits at top-left for the middle steps.
///   • The "All set" page swaps the brand logo for a small green
///     checkmark circle + "Open Settings instead" ghost link below
///     the primary CTA.
///   • The brand purple (#C5A3FF) is the lone accent — green is used
///     ONLY for the granted state.
///
/// Page flow:
///   1. Welcome      — brand intro, "Get started" CTA
///   2. Permissions  — back chevron, grouped permission card, Continue
///   3. All set      — green check, summary card, "Open nox" + ghost
///                     "Open Settings instead" link
///
/// Persistence: `UserDefaults.onboardingCompletedV2: Bool`. Bump the V
/// suffix when the flow changes substantively.
struct CleanOnboardingView: View {
    let onComplete: () -> Void

    @State private var page: Int = 0
    @State private var enter: Bool = false

    private let totalPages: Int = 3

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                Group {
                    switch page {
                    case 0:
                        WelcomePage(onContinue: { advance() })
                    case 1:
                        PermissionsPage(
                            onBack: { goBack() },
                            onContinue: { advance() }
                        )
                    default:
                        ReadyPage(
                            onComplete: onComplete,
                            onOpenSettings: openSettings
                        )
                    }
                }
                .id("clean-onboarding-page-\(page)")
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24, y: 0)),
                        removal:   .opacity.combined(with: .offset(x: -24, y: 0))
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                progressIndicator
                    .padding(.bottom, 28)
            }
        }
        .frame(width: 720, height: 540)
        .opacity(enter ? 1 : 0)
        .scaleEffect(enter ? 1 : 0.96)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) {
                enter = true
            }
        }
    }

    private func advance() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            page = min(page + 1, totalPages - 1)
        }
    }

    private func goBack() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            page = max(page - 1, 0)
        }
    }

    /// Routed when the user taps "Open Settings instead" on the All
    /// Set page. The onboarding window closes (mark complete) and the
    /// existing AppDelegate flow surfaces Settings via the menu-bar.
    private func openSettings() {
        onComplete()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("nox.openSettings"),
                object: nil
            )
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            Color.black
            // Brand-purple corona at the top — matches the nox icon's
            // innerCorona gradient. Subtle so the page reads as deep
            // black with a quiet glow, not a colored panel.
            RadialGradient(
                colors: [
                    NoxBrand.purple.opacity(0.10),
                    NoxBrand.purple.opacity(0.04),
                    .clear
                ],
                center: .init(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 380
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: - Progress dots

    @Namespace private var dotNamespace

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalPages, id: \.self) { i in
                ZStack {
                    if page == i {
                        Capsule()
                            .fill(NoxBrand.purple)
                            .frame(width: 22, height: 5)
                            .matchedGeometryEffect(id: "active", in: dotNamespace)
                    } else {
                        Circle()
                            .fill(.white.opacity(0.18))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(width: 22, height: 6)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: page)
    }
}

// MARK: - Brand tokens

private enum NoxBrand {
    /// Lavender from the nox icon's ringFill / innerCorona stops.
    static let purple = Color(red: 0.773, green: 0.640, blue: 1.000)
    static let purpleDeep = Color(red: 0.502, green: 0.392, blue: 0.784)
    /// Soft mint used for "Granted" chip + the All Set page check
    /// badge. Muted enough to coexist with the brand purple without
    /// feeling like a separate theme.
    static let granted = Color(red: 0.42, green: 0.86, blue: 0.55)
}

// MARK: - Logo

/// Recreates the nox icon as SwiftUI: deep-black squircle with a
/// purple gradient ring + notch cutout. Sized via `.frame`.
private struct NoxLogo: View {
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            // Squircle background with depth gradient.
            RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.039, green: 0.024, blue: 0.071),
                            Color(red: 0.016, green: 0.004, blue: 0.031),
                            .black
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.55
                    )
                )

            // Inner corona — barely-there purple wash.
            RadialGradient(
                colors: [
                    NoxBrand.purple.opacity(0.10),
                    NoxBrand.purple.opacity(0.04),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: size * 0.36
            )
            .blendMode(.plusLighter)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.224,
                                        style: .continuous))

            // Outer halo — soft glow under the ring (shadow).
            Circle()
                .stroke(NoxBrand.purple.opacity(0.42), lineWidth: size * 0.045)
                .blur(radius: size * 0.022)
                .frame(width: size * 0.566, height: size * 0.566)

            // Hard ring with the brand gradient.
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.937, green: 0.871, blue: 1.000),
                            Color(red: 0.851, green: 0.737, blue: 1.000),
                            NoxBrand.purple,
                            Color(red: 0.651, green: 0.533, blue: 0.910),
                            NoxBrand.purpleDeep
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: size * 0.0195
                )
                .frame(width: size * 0.566, height: size * 0.566)

            // Notch cutout — small black rect at the top centre,
            // overlaying the ring exactly where the SVG `notchMask`
            // does. Sells the "nox" identity.
            Rectangle()
                .fill(.black)
                .frame(width: size * 0.0547, height: size * 0.0352)
                .offset(y: -size * 0.305)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Page 1: Welcome
//
// Pure-typography hero — recreates Apple's macOS welcome "hello"
// (the hand-drawn cursive that ships in Big Sur+ and the Sonoma
// screensaver). NOT a system font — the actual path was extracted
// from macOS Sonoma's vector asset.
//
// Source: https://github.com/mtynior/AppleHello (MIT licensed),
// generated with svg-to-swiftui.quassum.com from the official SVG.
// Same path is used by every recreation in the wild because it
// IS the genuine Apple lettering — earlier attempts to use
// Snell Roundhand or Apple Chancery as a stand-in produced
// formal calligraphy that didn't read as the hand-drawn marker
// stroke Apple actually uses.
//
// Animation: `Path.trim(from:to:)` drives a stroke-on draw
// effect — the cursive writes itself in over ~2.4s with an
// ease-in-out curve, matching the cadence of Apple's animation.
// Linear stroke style with round caps + joins gives the soft
// felt-tip pen feel.

private struct WelcomePage: View {
    let onContinue: () -> Void
    @State private var helloProgress: CGFloat = 0
    @State private var captionVisible = false
    @State private var ctaVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Apple's "hello" — drawn by stroke-trim over ~2.8s
            // for the genuine "writing on" reveal. The Shape exposes
            // `progress` via `animatableData` so SwiftUI interpolates
            // it frame-by-frame; using `.trim(from:to:)` as a modifier
            // can silently fail to animate when wrapped in `.stroke()`
            // because the resulting view doesn't surface animatable
            // data through the stroke pipeline.
            AppleHelloShape(progress: helloProgress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: 4.5,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                // Aspect ratio of the official asset is roughly
                // 1.55:1 — give the shape its own canvas at that
                // aspect so the letterforms don't squash.
                .frame(width: 460, height: 296)
                // Whisper of brand purple under the strokes — ties
                // the page to the flow's accent without overpowering
                // the white pen-on-black read.
                .shadow(color: NoxBrand.purple.opacity(0.18),
                        radius: 24, x: 0, y: 4)

            Spacer().frame(height: 6)

            Text("Welcome to nox")
                .font(.system(size: 14, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.50))
                .opacity(captionVisible ? 1 : 0)

            Spacer()

            PrimaryCTA(title: "Get started", action: onContinue)
                .opacity(ctaVisible ? 1 : 0)
                .offset(y: ctaVisible ? 0 : 10)
                .padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            // Reset progress in case the page is re-shown after a
            // back-from-permissions navigation — without this, the
            // hello would already be at 1.0 and the writing reveal
            // would be skipped on the second visit.
            helloProgress = 0
            captionVisible = false
            ctaVisible = false

            // Stroke-on starts ~250ms after the page lands so the
            // page entrance and the writing read as separate moments.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeInOut(duration: 2.8)) {
                    helloProgress = 1.0
                }
            }
            // Caption fades in just before the writing finishes
            // (~2.4s), CTA right at completion (~3.0s) — Apple's
            // own welcome cadence.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.40) {
                withAnimation(.easeOut(duration: 0.50)) {
                    captionVisible = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.00) {
                withAnimation(.easeOut(duration: 0.45)) {
                    ctaVisible = true
                }
            }
        }
    }
}

// MARK: - Apple "hello" shape
//
// Verbatim path data extracted from the macOS Sonoma "hello"
// screensaver/welcome asset. Path is normalized to the unit
// rect — multiply x by `width`, y by `height` so the shape
// scales to whatever frame you give it.
//
// Attribution: https://github.com/mtynior/AppleHello (MIT) —
// generated via svg-to-swiftui.quassum.com from the official
// Apple SVG. We carry the path inline (rather than importing
// the package) to keep the dependency surface zero.
//
// `progress` (0…1) is exposed via `animatableData` so SwiftUI
// interpolates it frame-by-frame and `path(in:)` recomputes the
// trimmed segment each tick — that's what gives the genuine
// "writing on" reveal. Using `.trim(from:to:)` as a SwiftUI
// modifier and then `.stroke()` can silently NOT animate
// because the stroke pipeline doesn't propagate animatable data
// out of the trim modifier in every release. Driving trim at
// the Shape level via `Path.trimmedPath` is the canonical
// SwiftUI pattern (Apple's "Build animations in SwiftUI" WWDC
// session demonstrates this exact technique).

private struct AppleHelloShape: Shape {
    /// 0 → 1 fraction of the path that should be visible. At 0,
    /// the shape draws nothing; at 1, the full word "hello" is
    /// drawn. Anywhere in between produces the in-progress
    /// stroke-on reveal.
    var progress: CGFloat = 1.0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.size.width
        let height = rect.size.height
        path.move(to: CGPoint(x: 0.18942*width, y: 0.64916*height))
        path.addCurve(to: CGPoint(x: 0.27418*width, y: 0.51669*height),
                      control1: CGPoint(x: 0.27418*width, y: 0.51669*height),
                      control2: CGPoint(x: 0.23809*width, y: 0.59394*height))
        path.addCurve(to: CGPoint(x: 0.30536*width, y: 0.34281*height),
                      control1: CGPoint(x: 0.30196*width, y: 0.45722*height),
                      control2: CGPoint(x: 0.31651*width, y: 0.37724*height))
        path.addCurve(to: CGPoint(x: 0.24651*width, y: 0.67414*height),
                      control1: CGPoint(x: 0.26479*width, y: 0.21753*height),
                      control2: CGPoint(x: 0.24062*width, y: 0.67407*height))
        path.addCurve(to: CGPoint(x: 0.28192*width, y: 0.5111*height),
                      control1: CGPoint(x: 0.2524*width, y: 0.6742*height),
                      control2: CGPoint(x: 0.25206*width, y: 0.54125*height))
        path.addCurve(to: CGPoint(x: 0.32367*width, y: 0.53984*height),
                      control1: CGPoint(x: 0.31178*width, y: 0.48094*height),
                      control2: CGPoint(x: 0.3223*width, y: 0.52111*height))
        path.addCurve(to: CGPoint(x: 0.31839*width, y: 0.6355*height),
                      control1: CGPoint(x: 0.32589*width, y: 0.57011*height),
                      control2: CGPoint(x: 0.31687*width, y: 0.61804*height))
        path.addCurve(to: CGPoint(x: 0.43599*width, y: 0.55398*height),
                      control1: CGPoint(x: 0.32473*width, y: 0.70854*height),
                      control2: CGPoint(x: 0.42787*width, y: 0.63682*height))
        path.addCurve(to: CGPoint(x: 0.3834*width, y: 0.61147*height),
                      control1: CGPoint(x: 0.44471*width, y: 0.46492*height),
                      control2: CGPoint(x: 0.3683*width, y: 0.46917*height))
        path.addCurve(to: CGPoint(x: 0.4418*width, y: 0.66942*height),
                      control1: CGPoint(x: 0.38895*width, y: 0.66377*height),
                      control2: CGPoint(x: 0.42346*width, y: 0.67724*height))
        path.addCurve(to: CGPoint(x: 0.552*width, y: 0.38575*height),
                      control1: CGPoint(x: 0.50813*width, y: 0.64115*height),
                      control2: CGPoint(x: 0.55363*width, y: 0.49671*height))
        path.addCurve(to: CGPoint(x: 0.49571*width, y: 0.60864*height),
                      control1: CGPoint(x: 0.54988*width, y: 0.24203*height),
                      control2: CGPoint(x: 0.47856*width, y: 0.38729*height))
        path.addCurve(to: CGPoint(x: 0.57499*width, y: 0.64351*height),
                      control1: CGPoint(x: 0.50232*width, y: 0.69393*height),
                      control2: CGPoint(x: 0.55841*width, y: 0.66619*height))
        path.addCurve(to: CGPoint(x: 0.64978*width, y: 0.36314*height),
                      control1: CGPoint(x: 0.60564*width, y: 0.60157*height),
                      control2: CGPoint(x: 0.65966*width, y: 0.48059*height))
        path.addCurve(to: CGPoint(x: 0.59745*width, y: 0.62607*height),
                      control1: CGPoint(x: 0.63947*width, y: 0.24062*height),
                      control2: CGPoint(x: 0.56181*width, y: 0.44249*height))
        path.addCurve(to: CGPoint(x: 0.6548*width, y: 0.65717*height),
                      control1: CGPoint(x: 0.60934*width, y: 0.68733*height),
                      control2: CGPoint(x: 0.64502*width, y: 0.6666*height))
        path.addCurve(to: CGPoint(x: 0.70474*width, y: 0.51817*height),
                      control1: CGPoint(x: 0.67802*width, y: 0.6348*height),
                      control2: CGPoint(x: 0.6855*width, y: 0.5536*height))
        path.addCurve(to: CGPoint(x: 0.76896*width, y: 0.5601*height),
                      control1: CGPoint(x: 0.72906*width, y: 0.4734*height),
                      control2: CGPoint(x: 0.76738*width, y: 0.50686*height))
        path.addCurve(to: CGPoint(x: 0.70263*width, y: 0.65105*height),
                      control1: CGPoint(x: 0.77246*width, y: 0.67742*height),
                      control2: CGPoint(x: 0.72159*width, y: 0.67749*height))
        path.addCurve(to: CGPoint(x: 0.70448*width, y: 0.51817*height),
                      control1: CGPoint(x: 0.68627*width, y: 0.62823*height),
                      control2: CGPoint(x: 0.68244*width, y: 0.56022*height))
        path.addCurve(to: CGPoint(x: 0.7753*width, y: 0.52099*height),
                      control1: CGPoint(x: 0.71954*width, y: 0.48942*height),
                      control2: CGPoint(x: 0.74363*width, y: 0.48871*height))
        path.addCurve(to: CGPoint(x: 0.80807*width, y: 0.51063*height),
                      control1: CGPoint(x: 0.78825*width, y: 0.53419*height),
                      control2: CGPoint(x: 0.79935*width, y: 0.53183*height))
        // `trimmedPath` returns the sub-portion of the path between
        // 0 and `progress`, measured in arc length. SwiftUI calls
        // this method each animation tick with an interpolated
        // `progress`, so the stroke appears to draw itself on.
        // Clamp to [0, 1] just in case animation overshoots.
        return path.trimmedPath(from: 0, to: max(0, min(1, progress)))
    }
}

// MARK: - Page 2: Permissions

private struct PermissionsPage: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    @State private var visible = false
    /// Drives the "X of N granted" copy on the All Set page —
    /// observed by ancestor via DefaultsKey, so every PermissionRow
    /// posts to it. (Belt-and-braces: the All Set page also re-reads
    /// the live status on appear.)
    @State private var grantedCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back chevron (top-left) — matches the SuperIsland
            // reference. Using HStack with a Spacer so the chevron
            // sits inside the page's horizontal gutter without
            // shifting the title block below.
            HStack {
                BackChevron(action: onBack)
                Spacer(minLength: 0)
            }
            .padding(.top, 22)
            .padding(.horizontal, 26)
            .opacity(visible ? 1 : 0)

            Spacer().frame(height: 14)

            // Title block — left-aligned, big, with a light
            // subtitle. Larger left gutter so it lines up with the
            // grouped card below.
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                Text("nox needs a few permissions to work properly.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 56)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)

            Spacer().frame(height: 22)

            // Single grouped card. Children are flat rows; the card
            // surface + hairline dividers do the visual grouping
            // (vs. each row floating in its own surface).
            GroupedCard {
                PermissionRow(kind: .microphone)
                Hairline()
                PermissionRow(kind: .accessibility)
                Hairline()
                PermissionRow(kind: .calendar)
            }
            .padding(.horizontal, 56)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)

            Spacer()

            HStack {
                Spacer()
                PrimaryCTA(title: "Continue", action: onContinue)
                Spacer()
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            withAnimation(.spring(response: 0.50, dampingFraction: 0.84)) {
                visible = true
            }
        }
    }
}

private enum PermissionKind {
    case microphone, accessibility, calendar

    var iconName: String {
        switch self {
        case .microphone:    return "mic.fill"
        case .accessibility: return "accessibility"
        case .calendar:      return "calendar"
        }
    }

    var title: String {
        switch self {
        case .microphone:    return "Microphone"
        case .accessibility: return "Accessibility"
        case .calendar:      return "Calendar"
        }
    }

    var subtitle: String {
        switch self {
        case .microphone:
            return "Audio for dictation. Stays on-device."
        case .accessibility:
            return "Listen for the dictation hotkey, paste at cursor."
        case .calendar:
            return "Show your next meeting in the notch."
        }
    }

    /// Whether this permission is REQUIRED for nox to function in
    /// any meaningful way. Required permissions get a subtle
    /// "Required" pill next to the title (SuperIsland reference).
    /// Calendar is fully optional — meeting pill stays hidden if
    /// not granted, but everything else still works.
    var isRequired: Bool {
        switch self {
        case .microphone, .accessibility: return true
        case .calendar: return false
        }
    }
}

// MARK: - Permission row (flat, in grouped card)

private struct PermissionRow: View {
    let kind: PermissionKind
    @State private var status: PermissionStatus = .notDetermined
    @State private var hovered = false

    enum PermissionStatus { case notDetermined, granted, denied }

    var body: some View {
        HStack(spacing: 14) {
            // Icon tile.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(NoxBrand.purple.opacity(status == .granted ? 0.16 : 0.10))
                Image(systemName: kind.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        status == .granted ? NoxBrand.granted : NoxBrand.purple
                    )
            }
            .frame(width: 34, height: 34)

            // Text.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(kind.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    if kind.isRequired {
                        Text("Required")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.2)
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(.white.opacity(0.08))
                            )
                            .overlay(
                                Capsule().strokeBorder(.white.opacity(0.10),
                                                       lineWidth: 0.5)
                            )
                    }
                }
                Text(kind.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onAppear { refreshStatus() }
        .animation(.easeInOut(duration: 0.18), value: status)
    }

    @ViewBuilder
    private var actionButton: some View {
        if status == .granted {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                Text("Granted")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(NoxBrand.granted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(NoxBrand.granted.opacity(0.13)))
        } else {
            Button(action: handleAllow) {
                Text(status == .denied ? "Open Settings" : "Allow")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(NoxBrand.purple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(NoxBrand.purple.opacity(0.14)))
                    .overlay(
                        Capsule().strokeBorder(NoxBrand.purple.opacity(0.32),
                                               lineWidth: 0.6)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: System calls

    private func handleAllow() {
        switch kind {
        case .microphone:    requestMic()
        case .accessibility: requestAccessibility()
        case .calendar:      requestCalendar()
        }
    }

    private func requestMic() {
        let cur = AVCaptureDevice.authorizationStatus(for: .audio)
        switch cur {
        case .authorized:
            status = .granted
        case .denied, .restricted:
            openSettings("Privacy_Microphone")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    status = granted ? .granted : .denied
                }
            }
        @unknown default: break
        }
    }

    private func requestAccessibility() {
        if AXIsProcessTrusted() {
            status = .granted
            return
        }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // Poll briefly — the user has to drag nox into the list.
        var attempts = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { t in
            attempts += 1
            DispatchQueue.main.async {
                if AXIsProcessTrusted() {
                    status = .granted
                    t.invalidate()
                } else if attempts >= 12 {
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
                    status = granted ? .granted : .denied
                    if granted {
                        UserDefaults.standard.set(true, forKey: "showNextMeetingPill")
                    }
                }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async {
                    status = granted ? .granted : .denied
                    if granted {
                        UserDefaults.standard.set(true, forKey: "showNextMeetingPill")
                    }
                }
            }
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshStatus() {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: status = .granted
            case .denied, .restricted: status = .denied
            default: status = .notDetermined
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
                status = (s == .authorized) ? .granted
                       : (s == .denied || s == .restricted ? .denied : .notDetermined)
            }
        }
    }
}

// MARK: - Page 3: Ready

private struct ReadyPage: View {
    let onComplete: () -> Void
    let onOpenSettings: () -> Void
    @State private var visible = false
    @State private var grantedCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 80)

            // Green check circle — replaces the brand logo on this
            // page so the visual signals "you're done, not just
            // another step." The fill is a low-opacity mint tile;
            // the inset glyph is the brighter mint for contrast.
            ZStack {
                Circle()
                    .fill(NoxBrand.granted.opacity(0.18))
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(NoxBrand.granted)
            }
            .frame(width: 64, height: 64)
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.78)

            Spacer().frame(height: 22)

            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)

                Text("nox is ready in your menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)

            Spacer().frame(height: 28)

            // Summary card — same grouped surface as the
            // permissions list. Two rows: one for permissions
            // status (live count), one for the dictation hotkey.
            GroupedCard {
                SummaryRow(
                    icon: "checkmark.shield.fill",
                    iconTint: NoxBrand.granted,
                    title: "Permissions",
                    trailing: "\(grantedCount) of 3 granted"
                )
                Hairline()
                SummaryRow(
                    icon: "command",
                    iconTint: NoxBrand.purple,
                    title: "Dictation hotkey",
                    trailing: "⌘ ⇧ D"
                )
                Hairline()
                SummaryRow(
                    icon: "rectangle.dashed",
                    iconTint: NoxBrand.purple,
                    title: "The notch",
                    trailing: "Hover to expand"
                )
            }
            .padding(.horizontal, 56)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)

            Spacer()

            VStack(spacing: 10) {
                PrimaryCTA(title: "Open nox", action: onComplete)

                Button(action: onOpenSettings) {
                    Text("Open Settings instead")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    NSCursor.pointingHand.set()
                    if !hovering { NSCursor.arrow.set() }
                }
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            grantedCount = countGrantedPermissions()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) {
                visible = true
            }
        }
    }

    /// Re-checks live system status for each onboarded permission.
    /// Reading TCC at appear-time means the count reflects whatever
    /// the user did on the previous page (including taps that
    /// surfaced the system dialog and were accepted between pages).
    private func countGrantedPermissions() -> Int {
        var n = 0
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { n += 1 }
        if AXIsProcessTrusted() { n += 1 }
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) {
            if s == .fullAccess || s == .writeOnly || s == .authorized { n += 1 }
        } else {
            if s == .authorized { n += 1 }
        }
        return n
    }
}

// MARK: - Reusable bits

/// Top-left back affordance — chevron + "Back" label inside a soft
/// capsule. Hover slightly lifts the surface tone. Matches the
/// SuperIsland reference.
private struct BackChevron: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovered ? 0.85 : 0.62))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(.white.opacity(hovered ? 0.07 : 0.045))
            )
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.14), value: hovered)
    }
}

/// Single grouped card that hosts a stack of rows. Tones the
/// surface, adds a 0.5pt edge stroke, clips children to a 14pt
/// continuous rounded rect — that's the SuperIsland aesthetic for
/// permission/summary lists.
private struct GroupedCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
    }
}

/// Hairline divider between rows in a `GroupedCard`. Inset
/// horizontally so it doesn't reach the rounded corners.
private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 64)   // align past the icon tile
            .padding(.trailing, 16)
    }
}

/// One row inside the All Set summary card: leading icon tile,
/// title, trailing supplementary text (the value/state).
private struct SummaryRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    let trailing: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconTint.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            .frame(width: 34, height: 34)

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 12)

            Text(trailing)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Primary CTA button

private struct PrimaryCTA: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 220, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: hovered
                                    ? [NoxBrand.purple, NoxBrand.purple.opacity(0.92)]
                                    : [Color(red: 0.851, green: 0.737, blue: 1.000),
                                       NoxBrand.purple],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
                )
                .shadow(color: NoxBrand.purple.opacity(hovered ? 0.45 : 0.30),
                        radius: hovered ? 18 : 12, x: 0, y: 4)
                .scaleEffect(pressed ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .pressEvents { pressed = true } onRelease: { pressed = false }
        .animation(.easeInOut(duration: 0.16), value: hovered)
        .animation(.easeInOut(duration: 0.10), value: pressed)
    }
}

// MARK: - Press-and-hold support

private struct PressActionsModifier: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}

private extension View {
    func pressEvents(onPress: @escaping () -> Void,
                     onRelease: @escaping () -> Void) -> some View {
        modifier(PressActionsModifier(onPress: onPress, onRelease: onRelease))
    }
}

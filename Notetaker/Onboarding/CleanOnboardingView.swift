import SwiftUI
import AppKit
import AVFoundation
import EventKit

/// Premium onboarding — 3 pages, single visual language, Screen
/// Studio's clean dark aesthetic with the nox brand purple
/// (#C5A3FF) as the lone accent. Replaces the old multi-page wizard
/// (OnboardingView) which had 5 separate permission pages and a
/// busier visual treatment.
///
/// Page flow:
///   1. Welcome      — brand intro, "Get started" CTA
///   2. Permissions  — all three perms in one Screen Studio-style
///                     rowstack (live status, granular grant per row)
///   3. All set      — quick tips + "Open nox" CTA
///
/// Key design rules:
///   • One accent color (purple). No rainbow icons.
///   • No usage-data toggle — nox doesn't collect telemetry.
///   • Permission rows show "X enabled" green chip when granted,
///     full-width primary button when not.
///   • Backdrop = solid black with a barely-visible radial corona
///     of the brand purple at the top (matches the nox icon's
///     `innerCorona` gradient).
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
                    case 0: WelcomePage(onContinue: { advance() })
                    case 1: PermissionsPage(onContinue: { advance() })
                    default: ReadyPage(onComplete: onComplete)
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

private struct WelcomePage: View {
    let onContinue: () -> Void
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 76)

            NoxLogo(size: 96)
                .opacity(visible ? 1 : 0)
                .scaleEffect(visible ? 1 : 0.84)

            Spacer().frame(height: 32)

            VStack(spacing: 14) {
                Text("Welcome to nox")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 8)

                Text("Your notch, but useful.")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.62))
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 8)
            }

            Spacer()

            PrimaryCTA(title: "Get started", action: onContinue)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 12)
                .padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) {
                visible = true
            }
        }
    }
}

// MARK: - Page 2: Permissions

private struct PermissionsPage: View {
    let onContinue: () -> Void
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 64)

            NoxLogo(size: 56)
                .opacity(visible ? 1 : 0)
                .scaleEffect(visible ? 1 : 0.86)

            Spacer().frame(height: 22)

            VStack(spacing: 8) {
                Text("A few permissions")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                Text("All run locally on your Mac. nox never sends your data anywhere.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)

            Spacer().frame(height: 30)

            VStack(spacing: 10) {
                PermissionRow(kind: .microphone)
                PermissionRow(kind: .accessibility)
                PermissionRow(kind: .calendar)
            }
            .padding(.horizontal, 56)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)

            Spacer()

            PrimaryCTA(title: "Continue", action: onContinue)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 8)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
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
            return "Record your voice for dictation. Audio stays on-device."
        case .accessibility:
            return "Listen for the dictation hotkey and paste at the cursor."
        case .calendar:
            return "Show your next meeting in the notch — read-only."
        }
    }

    var allowLabel: String {
        switch self {
        case .microphone:    return "Allow Microphone"
        case .accessibility: return "Allow Accessibility"
        case .calendar:      return "Allow Calendar"
        }
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    @State private var status: PermissionStatus = .notDetermined
    @State private var hovered = false

    enum PermissionStatus { case notDetermined, granted, denied }

    var body: some View {
        HStack(spacing: 14) {
            // Icon tile.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(NoxBrand.purple.opacity(status == .granted ? 0.14 : 0.10))
                Image(systemName: kind.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        status == .granted ? Color(red: 0.42, green: 0.86, blue: 0.55)
                                           : NoxBrand.purple
                    )
            }
            .frame(width: 38, height: 38)

            // Text.
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(kind.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // Action / status.
            actionButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(hovered ? 0.05 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
        .onHover { hovered = $0 }
        .onAppear { refreshStatus() }
        .animation(.easeInOut(duration: 0.18), value: status)
        .animation(.easeInOut(duration: 0.18), value: hovered)
    }

    @ViewBuilder
    private var actionButton: some View {
        if status == .granted {
            // Granted chip — green check + label.
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                Text("Enabled")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color(red: 0.42, green: 0.86, blue: 0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color(red: 0.42, green: 0.86, blue: 0.55).opacity(0.13))
            )
        } else {
            Button(action: handleAllow) {
                Text(status == .denied ? "Open Settings" : "Allow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NoxBrand.purple)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(NoxBrand.purple.opacity(0.14))
                    )
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
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 70)

            NoxLogo(size: 86)
                .opacity(visible ? 1 : 0)
                .scaleEffect(visible ? 1 : 0.84)

            Spacer().frame(height: 26)

            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)

                Text("nox lives in your menu bar. Hover the notch to bring it down.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)

            Spacer().frame(height: 30)

            VStack(spacing: 12) {
                TipRow(icon: "rectangle.dashed",
                       text: "Hover the notch to expand the panel")
                TipRow(icon: "mic.fill",
                       text: "Press ⌘⇧D to start dictating anywhere")
                TipRow(icon: "gearshape.fill",
                       text: "Click the menu-bar icon for Settings")
            }
            .padding(.horizontal, 80)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)

            Spacer()

            PrimaryCTA(title: "Open nox", action: onComplete)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 8)
                .padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) {
                visible = true
            }
        }
    }
}

private struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NoxBrand.purple)
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.78))
            Spacer(minLength: 0)
        }
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

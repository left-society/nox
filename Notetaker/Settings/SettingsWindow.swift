import SwiftUI
import ServiceManagement
import AppKit
import AVFoundation
import ApplicationServices

// MARK: - Settings categories

/// One row in the sidebar nav. Order here = order in the sidebar.
/// Grouping is encoded by inserting `.divider` markers; the sidebar
/// view splits on those to render section headers like Alcove does
/// ("Notifications" / "Live Activities" / "Account").
enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case dictation
    case music
    case bluetooth
    case timer
    case calendar
    case notes
    case images
    case videos
    case charging
    case appearance
    case integrations
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .music: return "Music"
        case .bluetooth: return "Bluetooth"
        case .timer: return "Timer"
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        case .images: return "Images"
        case .videos: return "Videos"
        case .charging: return "Charging"
        case .appearance: return "Appearance"
        case .integrations: return "Integrations"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .music: return "music.note"
        case .bluetooth: return "headphones"
        case .timer: return "timer"
        case .calendar: return "calendar"
        case .notes: return "square.and.pencil"
        case .images: return "photo.on.rectangle"
        case .videos: return "play.rectangle.fill"
        case .charging: return "bolt.fill"
        case .appearance: return "paintbrush.fill"
        case .integrations: return "key.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// Tint color for the icon — matches Alcove's category-coded
    /// sidebar where each section icon has its own brand color.
    /// Picks a flat-Material palette so they read as labels, not
    /// like full-saturation accent buttons.
    var iconTint: Color {
        switch self {
        case .general: return Color(red: 0.55, green: 0.55, blue: 0.60)
        case .dictation: return Color(red: 0.99, green: 0.30, blue: 0.45)
        case .music: return Color(red: 0.95, green: 0.30, blue: 0.45)
        case .bluetooth: return Color(red: 0.20, green: 0.55, blue: 0.99)
        case .timer: return Color(red: 0.99, green: 0.45, blue: 0.30)
        case .calendar: return Color(red: 0.99, green: 0.45, blue: 0.30)
        case .notes: return Color(red: 0.99, green: 0.80, blue: 0.20)
        case .images: return Color(red: 0.30, green: 0.78, blue: 0.99)
        case .videos: return Color(red: 0.95, green: 0.20, blue: 0.20)
        case .charging: return Color(red: 0.30, green: 0.85, blue: 0.40)
        case .appearance: return Color(red: 0.60, green: 0.40, blue: 0.95)
        case .integrations: return Color(red: 0.99, green: 0.60, blue: 0.20)
        case .about: return Color(red: 0.45, green: 0.45, blue: 0.50)
        }
    }

    /// Sidebar group header that appears ABOVE this category. Nil
    /// means no header (continuation of the previous group).
    var groupHeader: String? {
        switch self {
        case .general: return nil
        case .dictation: return nil
        case .music: return "Activities"
        case .bluetooth: return nil
        case .timer: return nil
        case .calendar: return nil
        case .notes: return "Captures"
        case .images: return nil
        case .videos: return nil
        case .charging: return "System"
        case .appearance: return "Look"
        case .integrations: return "Account"
        case .about: return nil
        }
    }
}

// MARK: - Settings keys (single source of truth for @AppStorage)

/// Centralized so any other module that reads or writes a setting
/// uses the same key string. Avoids drift between SettingsView's
/// @AppStorage declarations and the consumer-side reads in
/// HoverActivator / AppDelegate / PanelRootView.
enum SettingsKey {
    // General
    static let launchAtLogin = "launchAtLogin"
    static let hideInFullscreen = "hideInFullscreen"
    static let hideFromScreenCapture = "hideFromScreenCapture"
    static let hoverDwellSeconds = "hoverDwellSeconds"
    static let hoverHotZoneWidth = "hoverHotZoneWidth"
    static let hapticsEnabled = "hapticsEnabled"
    static let defaultTabRaw = "defaultTabRaw"
    /// Auto-hide ambient pills while the user is in a system
    /// Focus or DND mode. Default true. The first time this is
    /// flipped on we trigger the system Focus authorization
    /// prompt (see `FocusStatusService.requestAuthorization`).
    static let respectFocusMode = "respectFocusMode"

    /// Per-pill "allow during Focus" exceptions. When the master
    /// `respectFocusMode` is on AND macOS Focus is active, ambient
    /// pills are normally suppressed; each of these allows ONE pill
    /// type to punch through. All default false (current behavior —
    /// full suppression — is preserved for users who don't visit the
    /// new indented rows). Routed through `FocusGatingPolicy.shouldShow`
    /// from `PanelPresenter.setPendingSystemEvent` (2026-05-17 sprint
    /// Session 4 — Alcove parity).
    static let allowChargingDuringFocus    = "allowChargingDuringFocus"
    static let allowAirDropDuringFocus     = "allowAirDropDuringFocus"
    static let allowBluetoothDuringFocus   = "allowBluetoothDuringFocus"
    static let allowScreenshotDuringFocus  = "allowScreenshotDuringFocus"

    /// nox's own "I'm locked in" Focus toggle, independent of
    /// macOS Focus. When ON, ambient pills (charger / screenshot
    /// / AirDrop / Bluetooth / track-change) get swallowed by
    /// the same suppression gate that handles macOS Focus — so
    /// the user gets a one-tap "I'm focused, stop interrupting"
    /// without depending on macOS Focus mode (which third-party
    /// apps can't toggle silently). Default false. Lives in the
    /// Live > Focus dashboard's primary toggle.
    ///
    /// Naming note (2026-05-08): originally `noxQuietMode`. User
    /// feedback: "It should be focus not quite — it should be
    /// for the person who is locked in." Renamed to make the
    /// feature's intent clearer ("focus / locked in" reads
    /// aspirationally vs. "quiet" reading passively).
    static let noxFocusMode = "noxFocusMode"

    /// Sibling to `noxFocusMode` — user's own "I'm in a study
    /// session" toggle. Same shape as Focus (resting pill widens to
    /// show a book glyph + live session timer; Live tab gets a
    /// matching status pill). Mutually exclusive with Focus: turning
    /// one on flips the other off, since both read as "deep work
    /// mode" and stacking them would be confusing.
    static let noxStudyMode = "noxStudyMode"

    /// User-chosen input device for dictation. Stored as
    /// `AVCaptureDevice.uniqueID`. Nil → use the system default
    /// (the device selected in System Settings → Sound → Input).
    /// Set when the user picks a mic from the post-failure prompt
    /// that fires after a silent recording — meaning the system
    /// default failed (typically a Bluetooth headset routed
    /// through HFP) and the user explicitly chose a fallback.
    /// Honored by `DictationRecorder.preferredInputDevice()`.
    static let dictationInputDeviceUID = "dictationInputDeviceUID"

    /// User's daily Focus minute goal. Drives the per-day rings on
    /// the Focus dashboard's hero card (each ring fills toward
    /// this value) and the "X of 7 goals completed" weekly framing.
    /// Default 60 — a reasonable single-pomodoro-plus session most
    /// users can hit on a working day. Tappable to change from the
    /// dashboard's "Daily goal" row.
    static let dailyFocusGoalMinutes = "dailyFocusGoalMinutes"

    /// User's daily Study minute goal. Sibling to the Focus goal;
    /// default 90 since study sessions tend to be longer-form
    /// (reading, problem sets, deep learning) than the
    /// fragmented-deep-work cadence Focus mode targets.
    static let dailyStudyGoalMinutes = "dailyStudyGoalMinutes"

    /// Carbon keyCode for the user's custom dictation hotkey when
    /// `dictationHotkeyMode == "custom_toggle"`. Captured by the
    /// KeyShortcutCapture component in Settings → Dictation → Hotkey.
    /// Stored as Int because Carbon expects UInt32 but
    /// UserDefaults' int storage is widest-fits-all. Default 0
    /// means "not yet captured" — orchestrator no-ops the
    /// registration in that state and the user falls back to
    /// the always-installed ⌘⇧D backup.
    static let dictationCustomKeyCode = "dictationCustomKeyCode"

    /// Carbon modifier flags (cmdKey | shiftKey | optionKey |
    /// controlKey, OR'd together) for the user's custom dictation
    /// hotkey. 0 = no modifiers. Captured alongside the keyCode.
    static let dictationCustomModifiers = "dictationCustomModifiers"

    /// Calendar source preference for the Live → calendar pane.
    /// String values: `"apple"` (default — show all events from
    /// EventKit, the same set Apple Calendar.app shows) or
    /// `"notion"` (show only events from Google-account calendars,
    /// since Notion Calendar is a Google Calendar frontend under
    /// the hood). Switching sources is a UI filter — both options
    /// flow through the same EventKit pipeline; "notion" mode just
    /// narrows the displayed set to Google sources.
    static let noxCalendarSource = "noxCalendarSource"

    /// Hide the notch HUD from screen recordings (`NSWindow.sharingType
    /// = .none`). Default false (visible). Inspired by SuperIsland.
    static let hideFromScreenRecordings = "hideFromScreenRecordings"

    /// Replace macOS's volume HUD (the white box) with nox's pill
    /// when the user presses F10/F11/F12. Requires Accessibility.
    /// Default false (opt-in). Inspired by SuperIsland.
    static let replaceSystemVolumeHUD = "replaceSystemVolumeHUD"

    // Music
    // showRestingPill removed 2026-05-08 (audit H3): the @AppStorage
    // toggle wrote this key but nothing in the project read it.
    static let sphereVisualizerEnabled = "sphereVisualizerEnabled"
    static let hideMusicWhileSourceFrontmost = "hideMusicWhileSourceFrontmost"
    static let musicAutoSwitchTab = "musicAutoSwitchTab"
    /// Horizontal swipe on the resting music pill = previous /
    /// next track. Read inline by `PanelRootView.pillSwipeEnabled`
    /// so a flip in Settings takes effect on the next gesture.
    static let pillSwipeToSkip = "pillSwipeToSkip"
    /// Natural swipe direction on the resting music pill. Default
    /// true: dragging LEFT skips forward, matching macOS "natural
    /// scroll" (content follows the finger). Flip to false for
    /// reading-order direction (RIGHT = next). Consumed by
    /// `SwipeGesturePolicy.decide` via the consumer in PanelRootView.
    /// 2026-05-17 sprint Session 2 — Alcove parity.
    static let naturalSwipeDirection = "naturalSwipeDirection"
    /// Tuning thresholds for the horizontal-swipe-to-skip gesture.
    /// Hidden from Settings UI in 1.9.21 — exposed via
    /// `SwipeGesturePolicy.defaultSuccessThreshold` /
    /// `defaultResetThreshold` and overridable by power users via
    /// `defaults write app.trynox` if they want a longer or shorter
    /// throw. Promoting to an "Advanced" panel is a v1.10 decision.
    static let horizontalSwipeSuccessThreshold = "horizontalSwipeSuccessThreshold"
    static let horizontalSwipeResetThreshold   = "horizontalSwipeResetThreshold"

    // Sound effects (1.9.21)
    /// Master kill-switch for the ambient-sound pack. Default true
    /// so the per-event toggles can opt in individually without a
    /// second hop through this gate. Modeled on the existing
    /// `hapticsEnabled` pattern.
    static let enableSoundEffects = "enableSoundEffects"
    /// Plays NSSound "Tink" the moment IOKit reports the charger
    /// plugged in (rising edge of `PowerState.isCharging`).
    /// Default false — opt-in.
    static let playSoundOnCharging = "playSoundOnCharging"
    /// Plays NSSound "Glass" on `BluetoothDeviceService.
    /// onDeviceConnected`. Default false — opt-in.
    static let playSoundOnBluetoothConnect = "playSoundOnBluetoothConnect"
    /// Plays NSSound "Funk" when LockScreenWatcher reports the
    /// screen has locked. Default false — opt-in.
    static let playSoundOnLock = "playSoundOnLock"
    /// Plays NSSound "Pop" when LockScreenWatcher reports the
    /// screen has unlocked. Default false — opt-in.
    static let playSoundOnUnlock = "playSoundOnUnlock"

    // Notes
    static let autoSaveCopiedText = "autoSaveCopiedText"
    static let retentionDays = "retentionDays"
    static let trashRetentionDays = "trashRetentionDays"

    // Images
    static let screenshotBurstThreshold = "screenshotBurstThreshold"
    static let screenshotBurstWindow = "screenshotBurstWindow"
    static let imageRetentionDays = "imageRetentionDays"

    // Videos
    static let videoQualityRaw = "videoQualityRaw"
    static let videoSaveLocation = "videoSaveLocation"

    // Bluetooth
    static let showBluetoothPill = "showBluetoothPill"
    static let hapticOnBluetoothChange = "hapticOnBluetoothChange"
    static let bluetoothShowAirPodsIcon = "bluetoothShowAirPodsIcon"

    // Timer
    static let timerHapticOnFinish = "timerHapticOnFinish"
    static let timerSoundOnFinish = "timerSoundOnFinish"
    static let timerDefaultPresetSeconds = "timerDefaultPresetSeconds"

    // Calendar
    static let showNextMeetingPill = "showNextMeetingPill"
    static let nextMeetingLeadMinutes = "nextMeetingLeadMinutes"

    // AirDrop
    static let showAirDropPill = "showAirDropPill"

    // Charging
    static let showChargingPill = "showChargingPill"
    static let chargingPillDuration = "chargingPillDuration"
    static let hapticOnChargingChange = "hapticOnChargingChange"

    // Appearance
    static let accentModeRaw = "accentModeRaw"
    static let shadowIntensityRaw = "shadowIntensityRaw"
    /// Style of the active-tab decoration. Stores a
    /// `TabIndicatorStyle` rawValue (Capsule / Capsule + marker /
    /// Marker only / None). Default `.capsule` (the shipped 1.9.20
    /// look). Read via `TabIndicatorStyle.current` from
    /// `ScribbleTabButton` so settings flips take effect on the
    /// next tab activation.
    /// 2026-05-17: superseded the short-lived boolean
    /// `tabMarkerUnderline` key — never shipped publicly, so no
    /// migration shim needed.
    static let tabIndicatorStyleRaw = "tabIndicatorStyleRaw"

    // Integrations
    static let geminiApiKey = GeminiOCRService.apiKeyDefaultsKey
}

enum DefaultTab: String, CaseIterable, Identifiable {
    case music, notes, images, videos, files, last
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: return "Music"
        case .notes: return "Notes"
        case .images: return "Images"
        case .videos: return "Videos"
        case .files: return "Files"
        case .last: return "Last used"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case sd720 = "720p"
    case hd1080 = "1080p"
    case best = "Best"
    var id: String { rawValue }
}

enum AccentMode: String, CaseIterable, Identifiable {
    case artwork = "Artwork-derived"
    case system = "System accent"
    var id: String { rawValue }

    /// Read the user's choice from UserDefaults. Defaults to
    /// `.artwork` (the original shipped behavior) so existing
    /// installs see no change after upgrade.
    static var current: AccentMode {
        AccentMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.accentModeRaw) ?? "")
            ?? .artwork
    }
}

enum ShadowIntensity: String, CaseIterable, Identifiable {
    case subtle = "Subtle"
    case medium = "Medium"
    case deep = "Deep"
    var id: String { rawValue }

    /// Multiplier applied to the panel layer's `shadowOpacity` target
    /// in `PanelWindowController.setShadowOpacity`. The base targets
    /// (0.65 full-open, 0.40 morph, 0.30 secondary) were tuned for
    /// `.medium`; scaling them lets users dial the slab's perceived
    /// depth without re-tuning every call site individually.
    ///   • `.subtle` (0.7×) — slab looks lighter, closer to the
    ///     desktop. Better on busy wallpapers where a deep shadow
    ///     muddies wallpaper detail.
    ///   • `.medium` (1.0×) — shipped default; matches every prior
    ///     release.
    ///   • `.deep`   (1.4×) — slab sits "into" the desktop more,
    ///     stronger contact-shadow feel. Best on flat/dark
    ///     wallpapers where depth doesn't fight art.
    /// Clamped inside the controller at 0..1 because Core Animation
    /// silently saturates above 1.0 anyway.
    var opacityScale: Float {
        switch self {
        case .subtle: return 0.7
        case .medium: return 1.0
        case .deep:   return 1.4
        }
    }

    /// Read the user's choice from UserDefaults. Defaults to
    /// `.medium` so existing installs see no change after upgrade.
    static var current: ShadowIntensity {
        ShadowIntensity(rawValue: UserDefaults.standard.string(forKey: SettingsKey.shadowIntensityRaw) ?? "")
            ?? .medium
    }
}

/// Style of the visual chrome around the active tab button.
/// Replaces the boolean `tabMarkerUnderline` key shipped briefly
/// pre-release in 1.9.21 dev builds — the four-way picker is the
/// real product surface (capsule + marker isn't binary, the
/// underline can stand alone or be removed entirely).
///
/// Consumed by `ScribbleTabButton` to decide whether to render
/// the capsule background / rim, the marker squiggle, or neither.
enum TabIndicatorStyle: String, CaseIterable, Identifiable {
    /// Capsule background + gradient rim only — the shipped 1.9.20
    /// look. No marker squiggle.
    case capsule = "Capsule"
    /// Both — capsule chrome AND the hand-drawn lavender marker
    /// squiggle. Maximum visual signal for "this tab is active."
    case capsuleMarker = "Capsule + marker"
    /// Marker squiggle only — drops the capsule entirely. Reads as
    /// the cleanest, most editorial gesture; closer to a pen
    /// drawing on paper than a UI control.
    case markerOnly = "Marker only"
    /// No chrome — just the bolder/semibold text color shift on
    /// the active tab. For users who want the rail itself to be
    /// the chrome, with tabs as pure typography.
    case none = "None"

    var id: String { rawValue }

    /// Read the user's choice from UserDefaults. Defaults to
    /// `.capsule` (the shipped 1.9.20 look) so existing installs
    /// see no visual change after upgrade.
    static var current: TabIndicatorStyle {
        TabIndicatorStyle(rawValue: UserDefaults.standard.string(forKey: SettingsKey.tabIndicatorStyleRaw) ?? "")
            ?? .capsule
    }

    /// Active-tab decoration includes the capsule background + rim.
    var showsCapsule: Bool {
        switch self {
        case .capsule, .capsuleMarker: return true
        case .markerOnly, .none:       return false
        }
    }

    /// Active-tab decoration includes the hand-drawn marker squiggle.
    var showsMarker: Bool {
        switch self {
        case .capsuleMarker, .markerOnly: return true
        case .capsule, .none:             return false
        }
    }
}

// MARK: - Root settings view

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var selection: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(SettingsTheme.sidebarBackground)
            // Hairline separator instead of the system Divider —
            // matches the onboarding's flat black aesthetic.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 0.5)
            ScrollView(showsIndicators: false) {
                detail
                    // 28/24 horizontal/vertical gives the new big
                    // page header room to breathe and stops cards
                    // from hugging the divider.
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(SettingsTheme.detailBackground)
        }
        .frame(minWidth: 800, idealWidth: 860, minHeight: 560, idealHeight: 620)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Inset header — mirrors macOS System Settings' branding band.
            // Uses the running app's bundle icon (Assets.xcassets/AppIcon)
            // so this stays in sync with whatever the user's seeing in
            // Finder, Dock, and the Cmd-Tab switcher. Earlier this was
            // Image(systemName: "scribble.variable") which read as
            // "settings has the wrong icon" — generic SF Symbol where
            // the actual brand mark belonged.
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                Text("nox")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsCategory.allCases) { category in
                        if let header = category.groupHeader {
                            Text(header.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.horizontal, 14)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        }
                        SidebarRow(
                            category: category,
                            isSelected: selection == category
                        )
                        .onTapGesture { selection = category }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettings(env: env)
        case .dictation: DictationSettings()
        case .music: MusicSettings()
        case .bluetooth: BluetoothSettings()
        case .timer: TimerSettings()
        case .calendar: CalendarSettings()
        case .notes: NotesSettings(env: env)
        case .images: ImagesSettings()
        case .videos: VideosSettings()
        case .charging: ChargingSettings()
        case .appearance: AppearanceSettings()
        case .integrations: IntegrationsSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: - Theme

/// Settings visual tokens. Aligned with the onboarding redesign
/// (CleanOnboardingView) so the two surfaces share one language:
/// near-black backgrounds, brand-purple as the lone accent, white
/// 0.04 grouped cards with white 0.07 hairline strokes. The rainbow
/// per-category sidebar tints are gone (Apple System Settings does
/// them, but they read as visual noise on top of the dark surface).
/// Brand purple matches `NoxBrand.purple` from CleanOnboardingView
/// (`#C5A3FF`) — kept literal here so we don't have to bridge two
/// private namespaces.
private enum SettingsTheme {
    static let sidebarBackground = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let detailBackground  = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let cardBackground    = Color.white.opacity(0.04)
    static let cardStroke        = Color.white.opacity(0.07)
    static let rowDivider        = Color.white.opacity(0.06)
    static let accent            = Color(red: 0.773, green: 0.640, blue: 1.000)
    static let accentSoft        = Color(red: 0.773, green: 0.640, blue: 1.000).opacity(0.16)
}

// MARK: - Sidebar row

/// Sidebar nav row. Mono SF-Symbol icon (no rainbow tile), with
/// the brand purple reserved for the SELECTED state — both the
/// background fill and the icon tint switch on. Hover gets a
/// quiet white-tint lift. Matches the SuperIsland reference.
private struct SidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isSelected
                        ? SettingsTheme.accent
                        : .white.opacity(0.55)
                )
                .frame(width: 20, height: 20)

            Text(category.title)
                .font(.system(size: 13,
                              weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.72))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isSelected
                        ? SettingsTheme.accentSoft
                        : (isHovered ? Color.white.opacity(0.04) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isSelected ? SettingsTheme.accent.opacity(0.22) : .clear,
                    lineWidth: 0.6
                )
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.14), value: isSelected)
        .animation(.easeInOut(duration: 0.14), value: isHovered)
    }
}

// MARK: - Section building blocks

/// Big page header at the top of each settings detail view.
///
/// 2026-05-08 redesign: dropped the saturated rainbow-tile icon
/// in favor of a clean text-only h1. The user already knows what
/// section they're in from the sidebar — duplicating the icon
/// here was visual noise that crowded the page above the cards.
/// Matches the SuperIsland onboarding's left-aligned title +
/// subtitle pattern.
///
/// The legacy `init(icon:tint:title:)` is kept so the 13 existing
/// call sites compile unchanged — icon and tint are simply
/// ignored. The new `init(title:subtitle:)` is the one to use
/// when adding new pages.
private struct SectionHeader: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    /// Back-compat shim — old call sites pass icon+tint, we
    /// silently drop them (the new design is text-only).
    init(icon: String, tint: Color, title: String) {
        self.title = title
        self.subtitle = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }
}

/// Grouped card surface for a stack of `SettingsRow`s. Matches the
/// onboarding's `GroupedCard`: 14pt continuous corners, white-0.04
/// fill, white-0.07 hairline stroke, 16pt bottom margin between
/// stacked cards.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SettingsTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SettingsTheme.cardStroke, lineWidth: 0.6)
            )
            .padding(.bottom, 16)
    }
}

/// One row inside a `SettingsCard`. Title + optional subtitle on
/// the leading edge, control on the trailing edge, hairline
/// divider between rows (suppressed on the last row via
/// `divider: false`). Matches the onboarding's permission-row
/// rhythm.
private struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var control: Control
    var divider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.50))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            if divider {
                Rectangle()
                    .fill(SettingsTheme.rowDivider)
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
        }
    }
}

/// Sub-section label that sits between two `SettingsCard`s within
/// a single page (e.g. "Hover" / "Behaviour" inside General).
/// Tiny uppercased small-caps, dimmed white — same treatment as
/// the sidebar group headers for visual consistency.
private struct GroupTitle: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(0.42))
            .padding(.top, 6)
            .padding(.bottom, 10)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.launchAtLogin) private var launchAtLogin: Bool = true
    @AppStorage(SettingsKey.hideFromScreenRecordings) private var hideFromScreenRecordings: Bool = false
    @AppStorage(SettingsKey.replaceSystemVolumeHUD) private var replaceSystemVolumeHUD: Bool = false
    // Per BUG-119 fix: removed `hideInFullscreen` and
    // `hideFromScreenCapture` @AppStorage bindings. The UI rows
    // are gone, no consumer ever read these keys. SettingsKey
    // constants are kept in the parent enum for now in case
    // we wire them properly in a later iteration.
    @AppStorage(SettingsKey.hoverDwellSeconds) private var hoverDwellSeconds: Double = 0.18
    @AppStorage(SettingsKey.hoverHotZoneWidth) private var hoverHotZoneWidth: Double = 300
    @AppStorage(SettingsKey.hapticsEnabled) private var hapticsEnabled: Bool = true
    @AppStorage(SettingsKey.defaultTabRaw) private var defaultTabRaw: String = DefaultTab.last.rawValue
    @AppStorage(SettingsKey.respectFocusMode) private var respectFocusMode: Bool = true
    @AppStorage(SettingsKey.showAirDropPill) private var showAirDropPill: Bool = true
    // 2026-05-17 sprint Session 4 — per-pill Focus exceptions.
    // Default false (full suppression) preserves the current
    // behavior for upgrading users; each flip lets one pill type
    // punch through `respectFocusMode` while Focus is active.
    @AppStorage(SettingsKey.allowChargingDuringFocus)   private var allowChargingDuringFocus:   Bool = false
    @AppStorage(SettingsKey.allowAirDropDuringFocus)    private var allowAirDropDuringFocus:    Bool = false
    @AppStorage(SettingsKey.allowBluetoothDuringFocus)  private var allowBluetoothDuringFocus:  Bool = false
    @AppStorage(SettingsKey.allowScreenshotDuringFocus) private var allowScreenshotDuringFocus: Bool = false
    // 2026-05-17 sprint Session 3 — ambient sound pack. Master
    // toggle ships on so a user who flips one per-event toggle
    // doesn't have to flip two; per-event toggles default OFF so
    // upgrading users get zero new sounds without explicit opt-in.
    @AppStorage(SettingsKey.enableSoundEffects)         private var enableSoundEffects:         Bool = true
    @AppStorage(SettingsKey.playSoundOnCharging)        private var playSoundOnCharging:        Bool = false
    @AppStorage(SettingsKey.playSoundOnBluetoothConnect) private var playSoundOnBluetoothConnect: Bool = false
    @AppStorage(SettingsKey.playSoundOnLock)            private var playSoundOnLock:            Bool = false
    @AppStorage(SettingsKey.playSoundOnUnlock)          private var playSoundOnUnlock:          Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.general.icon,
                          tint: SettingsCategory.general.iconTint,
                          title: "General")

            SettingsCard {
                SettingsRow(title: "Launch at login",
                            subtitle: nil,
                            divider: true) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                        .onChange(of: launchAtLogin) { setLaunchAtLogin($0) }
                }
                // 2026-05-08 audit H15: a user who closes the
                // first-launch onboarding window via the red traffic-
                // light gets `onboardingCompletedV2` set to true
                // anyway (in OnboardingWindow.windowWillClose) so
                // we don't pester them on every launch — but until
                // now there was no way back to the onboarding flow.
                // This button calls the previously-orphan
                // AppDelegate.presentOnboarding() to give one.
                SettingsRow(title: "Show onboarding again",
                            subtitle: "Re-open the welcome flow that ran on first launch.",
                            divider: true) {
                    Button("Show…") {
                        AppDelegate.shared?.presentOnboarding()
                    }
                    .buttonStyle(.bordered)
                }
                // 1.9.9 (idea borrowed from SuperIsland): toggle
                // `NSWindow.sharingType = .none` on every nox window
                // so the notch HUD is invisible to screen recorders,
                // OBS, ScreenCaptureKit feeds, etc. The user still
                // sees the HUD normally — it just doesn't appear in
                // the captured frame. Default false (current macOS
                // behavior). Streamers / demo-recorders LOVE this.
                SettingsRow(title: "Hide from screen recordings",
                            subtitle: "Make the notch HUD invisible to screen recorders, OBS, and screencast tools. Doesn't affect what you see.",
                            divider: true) {
                    Toggle("", isOn: $hideFromScreenRecordings).labelsHidden()
                        .onChange(of: hideFromScreenRecordings) { _ in
                            ScreenSharingPolicy.refreshAll()
                        }
                }
                // 1.9.9 (idea borrowed from SuperIsland): when on,
                // CGEventTap intercepts F10/F11/F12 (volume mute/
                // down/up) BEFORE macOS routes them to OSDUIHelper,
                // mutates volume directly via CoreAudio, and shows
                // nox's pill instead of Apple's white box.
                // Requires Accessibility.
                SettingsRow(title: "Replace system volume HUD",
                            subtitle: "Show nox's pill when you press the volume keys, instead of macOS's overlay. Requires Accessibility permission.",
                            divider: false) {
                    Toggle("", isOn: $replaceSystemVolumeHUD).labelsHidden()
                        .onChange(of: replaceSystemVolumeHUD) { newValue in
                            if newValue {
                                MediaKeyInterceptor.shared.start()
                            } else {
                                MediaKeyInterceptor.shared.stop()
                            }
                        }
                }
                // Per BUG-119 fix: removed "Hide in fullscreen" and
                // "Hide from screen capture" rows. Both wrote to
                // UserDefaults but no consumer ever read them —
                // toggling did nothing. Implementation requires
                // non-trivial work (NSWindowOcclusionState
                // observation, NSScreen.canRecordScreenContents,
                // etc.) and isn't on the near-term roadmap.
                // Removing the toggles is a trust-preserving move:
                // no setting in the app should lie about taking
                // effect.
            }

            GroupTitle(title: "Hover")
            SettingsCard {
                SettingsRow(title: "Open delay",
                            subtitle: "How long to dwell on the notch before the panel commits") {
                    HStack {
                        Slider(value: $hoverDwellSeconds, in: 0.1...0.6, step: 0.01)
                            .frame(width: 180)
                        Text(String(format: "%.2fs", hoverDwellSeconds))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                SettingsRow(title: "Hot-zone width",
                            subtitle: "Cursor area around the notch that triggers open",
                            divider: false) {
                    HStack {
                        Slider(value: $hoverHotZoneWidth, in: 200...420, step: 5)
                            .frame(width: 180)
                        Text("\(Int(hoverHotZoneWidth))pt")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            GroupTitle(title: "Behaviour")
            SettingsCard {
                SettingsRow(title: "Haptic feedback",
                            subtitle: "Trackpad bump on open, charging, copy, and seek") {
                    Toggle("", isOn: $hapticsEnabled).labelsHidden()
                }
                SettingsRow(title: "Auto-hide pills during Focus",
                            subtitle: "Suppress charging, screenshot, and Bluetooth pills while a Focus or DND mode is active") {
                    Toggle("", isOn: $respectFocusMode)
                        .labelsHidden()
                        .onChange(of: respectFocusMode) { newValue in
                            if newValue {
                                AppDelegate.shared?.focusStatusService?
                                    .requestAuthorization()
                            }
                        }
                }
                // 2026-05-17 sprint Session 4 — per-pill Focus
                // exceptions. Indented child toggles read as
                // children of the master "Auto-hide pills during
                // Focus" row above; four-space title prefix is the
                // cheap indent trick that stays inside the existing
                // SettingsRow without a new indented-row variant.
                // Each row's effect: only matters when master toggle
                // is ON and macOS Focus is currently active.
                SettingsRow(title: "    Charging",
                            subtitle: "Show charging pill even while a Focus mode is active.") {
                    Toggle("", isOn: $allowChargingDuringFocus).labelsHidden()
                        .disabled(!respectFocusMode)
                }
                SettingsRow(title: "    AirDrop",
                            subtitle: "Show AirDrop arrival pill even while a Focus mode is active.") {
                    Toggle("", isOn: $allowAirDropDuringFocus).labelsHidden()
                        .disabled(!respectFocusMode)
                }
                SettingsRow(title: "    Bluetooth",
                            subtitle: "Show Bluetooth connect / disconnect pill even while a Focus mode is active.") {
                    Toggle("", isOn: $allowBluetoothDuringFocus).labelsHidden()
                        .disabled(!respectFocusMode)
                }
                SettingsRow(title: "    Screenshot",
                            subtitle: "Show screenshot-saved pill even while a Focus mode is active.") {
                    Toggle("", isOn: $allowScreenshotDuringFocus).labelsHidden()
                        .disabled(!respectFocusMode)
                }
                SettingsRow(title: "AirDrop arrival pill",
                            subtitle: "Pill flashes when a file lands via AirDrop. Tap to reveal in Finder.") {
                    Toggle("", isOn: $showAirDropPill).labelsHidden()
                }
                SettingsRow(title: "Default tab",
                            subtitle: "Which tab opens by default when you summon the panel",
                            divider: false) {
                    Picker("", selection: $defaultTabRaw) {
                        ForEach(DefaultTab.allCases) { tab in
                            Text(tab.title).tag(tab.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            // 2026-05-17 sprint Session 3 — ambient sound pack.
            // Master toggle gates a set of per-event opt-ins.
            // All event toggles default OFF so upgrading users
            // get zero new audible feedback without explicit
            // opt-in (NSSound built-ins via SoundEffectsService).
            GroupTitle(title: "Sound")
            SettingsCard {
                SettingsRow(title: "Play sound effects",
                            subtitle: "Master switch for the ambient sound pack. Off here means none of the per-event toggles fire.") {
                    Toggle("", isOn: $enableSoundEffects).labelsHidden()
                }
                SettingsRow(title: "Charging",
                            subtitle: "NSSound \"Tink\" when you plug in.") {
                    Toggle("", isOn: $playSoundOnCharging).labelsHidden()
                        .disabled(!enableSoundEffects)
                }
                SettingsRow(title: "Bluetooth connect",
                            subtitle: "NSSound \"Glass\" when AirPods (or any BT audio device) connect.") {
                    Toggle("", isOn: $playSoundOnBluetoothConnect).labelsHidden()
                        .disabled(!enableSoundEffects)
                }
                SettingsRow(title: "Lock",
                            subtitle: "NSSound \"Funk\" when the screen locks.") {
                    Toggle("", isOn: $playSoundOnLock).labelsHidden()
                        .disabled(!enableSoundEffects)
                }
                SettingsRow(title: "Unlock",
                            subtitle: "NSSound \"Pop\" when you wake from lock.",
                            divider: false) {
                    Toggle("", isOn: $playSoundOnUnlock).labelsHidden()
                        .disabled(!enableSoundEffects)
                }
            }
        }
    }

    /// Roll back the toggle's stored UserDefaults value if SMAppService
    /// rejects the registration. Without this the toggle stays "on"
    /// even though the OS won't actually launch the app at login —
    /// the same class of "settings UI lies on failure" bug fixed in
    /// BUG-119. Audit H2.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Login item toggle failed: \(error)")
            // Bounce the toggle back to its previous state on the
            // next runloop tick — doing it inline would land
            // mid-onChange and SwiftUI ignores re-entrant writes
            // to the same @AppStorage var.
            DispatchQueue.main.async { [self] in
                launchAtLogin = !on
                let alert = NSAlert()
                alert.messageText = "Couldn't change Launch at Login"
                alert.informativeText = "macOS rejected the request. \(error.localizedDescription)\n\nIf this keeps happening, try removing nox from System Settings → General → Login Items, then toggle this setting again."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}

// MARK: - Music

private struct MusicSettings: View {
    @AppStorage(SettingsKey.sphereVisualizerEnabled) private var sphereVisualizerEnabled: Bool = true
    // Per BUG-119 fix: removed `hideMusicWhileSourceFrontmost`
    // and `musicAutoSwitchTab` — both were dead settings (UI
    // toggle wrote UserDefaults; nothing read it back).
    // 2026-05-08 audit H3: same fate for `showRestingPill` —
    // its toggle wrote `"showRestingPill"` to UserDefaults but
    // no code in the project read the key back, so flipping
    // it had no observable effect. Implementing a real on/off
    // would require gating PanelPresenter's resting-pill mode
    // on the setting; out of scope for this audit pass. The
    // resting pill always shows when music is playing, which
    // is the more common preference.
    @AppStorage(SettingsKey.pillSwipeToSkip) private var pillSwipeToSkip: Bool = true
    @AppStorage(SettingsKey.naturalSwipeDirection) private var naturalSwipeDirection: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.music.icon,
                          tint: SettingsCategory.music.iconTint,
                          title: "Music")

            SettingsCard {
                SettingsRow(title: "Sphere visualizer",
                            subtitle: "Rotating particle sphere on the music card") {
                    Toggle("", isOn: $sphereVisualizerEnabled).labelsHidden()
                }
                // Removed: "Hide while source app is frontmost" and
                // "Auto-switch to Music tab" — both were dead
                // toggles per BUG-119. Wiring them requires non-
                // trivial app-state observation; out of scope here.
                SettingsRow(title: "Swipe to skip",
                            subtitle: "Drag the resting pill left or right to skip tracks") {
                    Toggle("", isOn: $pillSwipeToSkip).labelsHidden()
                }
                // 2026-05-17 sprint Session 2 — Alcove parity. Pairs
                // with `SwipeGesturePolicy.decide(naturalMovement:)`:
                // ON  → left swipe = next (macOS natural-scroll model)
                // OFF → right swipe = next (reading-order model)
                SettingsRow(title: "Natural swipe direction",
                            subtitle: "Swipe left for next track. Off = reverse.",
                            divider: false) {
                    Toggle("", isOn: $naturalSwipeDirection).labelsHidden()
                }
                .disabled(!pillSwipeToSkip)
            }
        }
    }
}

// MARK: - Bluetooth

private struct BluetoothSettings: View {
    @AppStorage(SettingsKey.showBluetoothPill) private var showBluetoothPill: Bool = true
    @AppStorage(SettingsKey.hapticOnBluetoothChange) private var hapticOnBluetoothChange: Bool = true
    @AppStorage(SettingsKey.bluetoothShowAirPodsIcon) private var bluetoothShowAirPodsIcon: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.bluetooth.icon,
                          tint: SettingsCategory.bluetooth.iconTint,
                          title: "Bluetooth")

            SettingsCard {
                SettingsRow(title: "Show connect/disconnect pill",
                            subtitle: "Pill briefly shows the device name on pairing changes") {
                    Toggle("", isOn: $showBluetoothPill).labelsHidden()
                }
                SettingsRow(title: "Haptic on change",
                            subtitle: "Trackpad bump when a device connects or disconnects") {
                    Toggle("", isOn: $hapticOnBluetoothChange).labelsHidden()
                }
                SettingsRow(title: "Distinguish AirPods icon",
                            subtitle: "Use a dedicated AirPods glyph instead of the generic headphones",
                            divider: false) {
                    Toggle("", isOn: $bluetoothShowAirPodsIcon).labelsHidden()
                }
            }
        }
    }
}

// MARK: - Timer

private struct TimerSettings: View {
    @AppStorage(SettingsKey.timerHapticOnFinish) private var timerHapticOnFinish: Bool = true
    @AppStorage(SettingsKey.timerSoundOnFinish) private var timerSoundOnFinish: Bool = true
    // Per BUG-119 fix: removed `timerDefaultPresetSeconds` —
    // the picker subtitle promised "Used when starting a timer
    // from a hotkey" but no timer-start hotkey exists in
    // HotkeyService. The setting was aspirational. Wiring it
    // requires a new hotkey + handler chain (product work,
    // not bug work). Dropped the row to honor the
    // "no setting should lie" rule.

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.timer.icon,
                          tint: SettingsCategory.timer.iconTint,
                          title: "Timer")

            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set timers from the menu-bar icon (right-click). The pill counts down in MM:SS while the timer runs.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }

            GroupTitle(title: "When time's up")
            SettingsCard {
                SettingsRow(title: "Haptic feedback",
                            subtitle: "Trackpad bump when the timer hits zero") {
                    Toggle("", isOn: $timerHapticOnFinish).labelsHidden()
                }
                SettingsRow(title: "Play sound",
                            subtitle: "System chime when the timer ends",
                            divider: false) {
                    Toggle("", isOn: $timerSoundOnFinish).labelsHidden()
                }
            }

            // "Defaults" section removed (BUG-119) — see init
            // for rationale.
        }
    }
}

// MARK: - Calendar

private struct CalendarSettings: View {
    @AppStorage(SettingsKey.showNextMeetingPill) private var showNextMeetingPill: Bool = false
    @AppStorage(SettingsKey.nextMeetingLeadMinutes) private var nextMeetingLeadMinutes: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.calendar.icon,
                          tint: SettingsCategory.calendar.iconTint,
                          title: "Calendar")

            SettingsCard {
                SettingsRow(title: "Show next meeting pill",
                            subtitle: "Pill shows your next meeting and its join link as it approaches") {
                    Toggle("", isOn: $showNextMeetingPill)
                        .labelsHidden()
                        .onChange(of: showNextMeetingPill) { newValue in
                            // First-time auth on opt-in. We don't
                            // pop the dialog at launch — only when
                            // the user explicitly turns this on.
                            if newValue {
                                AppDelegate.shared?.calendarMonitor?
                                    .requestAuthorization { _ in
                                        AppDelegate.shared?.calendarMonitor?.refresh()
                                    }
                            }
                        }
                }
                SettingsRow(title: "Show pill before",
                            subtitle: "How early to surface the meeting (lead time)",
                            divider: false) {
                    Picker("", selection: $nextMeetingLeadMinutes) {
                        Text("1 minute").tag(1)
                        Text("3 minutes").tag(3)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("15 minutes").tag(15)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: nextMeetingLeadMinutes) { mins in
                        AppDelegate.shared?.calendarMonitor?.leadTime = TimeInterval(mins) * 60
                        AppDelegate.shared?.calendarMonitor?.refresh()
                    }
                }
            }

            GroupTitle(title: "Tip")
            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tap the pill to open the meeting link from the event. Zoom, Google Meet, Teams, and Webex are auto-detected.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }
}

// MARK: - Notes

private struct NotesSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.autoSaveCopiedText) private var autoSaveCopiedText: Bool = true
    @AppStorage(SettingsKey.retentionDays) private var retentionDays: Int = 2
    @AppStorage(SettingsKey.trashRetentionDays) private var trashRetentionDays: Int = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.notes.icon,
                          tint: SettingsCategory.notes.iconTint,
                          title: "Notes")

            SettingsCard {
                SettingsRow(title: "Auto-save copied text",
                            subtitle: "Plain-text clipboard items become notes automatically",
                            divider: false) {
                    Toggle("", isOn: $autoSaveCopiedText).labelsHidden()
                }
            }

            GroupTitle(title: "Retention")
            SettingsCard {
                SettingsRow(title: "Active for",
                            subtitle: "How long notes stay in the active list") {
                    Picker("", selection: $retentionDays) {
                        Text("1 day").tag(1)
                        Text("2 days").tag(2)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("Forever").tag(-1)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: retentionDays) { new in
                        env.retentionService.retentionSeconds = new < 0 ? .infinity : Double(new) * 86400
                    }
                }
                SettingsRow(title: "Trash kept for",
                            subtitle: "Trashed notes are recoverable for this long",
                            divider: false) {
                    Picker("", selection: $trashRetentionDays) {
                        Text("Delete now").tag(0)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: trashRetentionDays) { new in
                        env.retentionService.trashRetentionSeconds = Double(new) * 86400
                    }
                }
            }
        }
    }
}

// MARK: - Images

private struct ImagesSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @AppStorage(SettingsKey.screenshotBurstWindow) private var screenshotBurstWindow: Double = 3.0
    @AppStorage(SettingsKey.imageRetentionDays) private var imageRetentionDays: Int = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.images.icon,
                          tint: SettingsCategory.images.iconTint,
                          title: "Images")

            SettingsCard {
                SettingsRow(title: "Burst window",
                            subtitle: "Screenshots within this window count as a burst. The pill shows the running total.",
                            divider: false) {
                    HStack {
                        Slider(value: $screenshotBurstWindow, in: 1.0...10.0, step: 0.5)
                            .frame(width: 180)
                        Text(String(format: "%.1fs", screenshotBurstWindow))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            GroupTitle(title: "Retention")
            SettingsCard {
                SettingsRow(title: "Keep for",
                            subtitle: "Auto-delete after this period",
                            divider: false) {
                    Picker("", selection: $imageRetentionDays) {
                        Text("Forever").tag(-1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: imageRetentionDays) { new in
                        // Per BUG-119 fix: this picker now actually
                        // does something. Was previously just writing
                        // to UserDefaults that no consumer ever read.
                        env.retentionService.imageRetentionSeconds =
                            new < 0 ? .infinity : Double(new) * 86400
                    }
                }
            }
        }
    }
}

// MARK: - Videos

private struct VideosSettings: View {
    @AppStorage(SettingsKey.videoQualityRaw) private var videoQualityRaw: String = VideoQuality.hd1080.rawValue
    @AppStorage(SettingsKey.videoSaveLocation) private var videoSaveLocation: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.videos.icon,
                          tint: SettingsCategory.videos.iconTint,
                          title: "Videos")

            SettingsCard {
                SettingsRow(title: "Default quality",
                            subtitle: "Used by yt-dlp when downloading from YouTube/TikTok/etc.") {
                    Picker("", selection: $videoQualityRaw) {
                        ForEach(VideoQuality.allCases) { q in
                            Text(q.rawValue).tag(q.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                SettingsRow(title: "Save location",
                            subtitle: videoSaveLocation.isEmpty ? "App-managed (default)" : videoSaveLocation,
                            divider: false) {
                    Button("Choose…") { chooseSaveLocation() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            videoSaveLocation = url.path
        }
    }
}

// MARK: - Charging

private struct ChargingSettings: View {
    @AppStorage(SettingsKey.showChargingPill) private var showChargingPill: Bool = true
    @AppStorage(SettingsKey.chargingPillDuration) private var chargingPillDuration: Double = 3.5
    @AppStorage(SettingsKey.hapticOnChargingChange) private var hapticOnChargingChange: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.charging.icon,
                          tint: SettingsCategory.charging.iconTint,
                          title: "Charging")

            SettingsCard {
                SettingsRow(title: "Show charging pill",
                            subtitle: "Pill morphs to a charging indicator on plug/unplug") {
                    Toggle("", isOn: $showChargingPill).labelsHidden()
                }
                SettingsRow(title: "Visible for",
                            subtitle: "How long the charging indicator stays before reverting") {
                    HStack {
                        Slider(value: $chargingPillDuration, in: 1.5...8.0, step: 0.5)
                            .frame(width: 180)
                        Text(String(format: "%.1fs", chargingPillDuration))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                SettingsRow(title: "Haptic on plug/unplug",
                            subtitle: "Trackpad bump when the cable state changes",
                            divider: false) {
                    Toggle("", isOn: $hapticOnChargingChange).labelsHidden()
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    // 2026-05-17: rebuilt as a real preference surface after a long
    // stretch of being a placeholder card. Wires three knobs that
    // had been half-built in code (TabIndicatorStyle, AccentMode,
    // ShadowIntensity) into the panel's actual render paths.
    //
    // All three default to the shipped 1.9.20 behavior, so an
    // upgrading user sees no change until they touch a picker.
    @AppStorage(SettingsKey.tabIndicatorStyleRaw) private var tabIndicatorStyleRaw: String = TabIndicatorStyle.capsule.rawValue
    @AppStorage(SettingsKey.accentModeRaw) private var accentModeRaw: String = AccentMode.artwork.rawValue
    @AppStorage(SettingsKey.shadowIntensityRaw) private var shadowIntensityRaw: String = ShadowIntensity.medium.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.appearance.icon,
                          tint: SettingsCategory.appearance.iconTint,
                          title: "Appearance")

            SettingsCard {
                SettingsRow(title: "Active tab indicator",
                            subtitle: "Capsule = shipped look. Add the hand-drawn marker squiggle, run marker-only for a cleaner pen feel, or strip both for pure typography.") {
                    Picker("", selection: $tabIndicatorStyleRaw) {
                        ForEach(TabIndicatorStyle.allCases) { style in
                            Text(style.rawValue).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRow(title: "Accent color",
                            subtitle: "Artwork-derived pulls the dominant tone from the now-playing art and falls back to lavender. System accent honors your macOS accent color (System Settings → Appearance).") {
                    Picker("", selection: $accentModeRaw) {
                        ForEach(AccentMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRow(title: "Shadow intensity",
                            subtitle: "How heavily the slab casts a shadow on the desktop. Subtle is best on busy wallpapers, Deep on flat/dark ones.",
                            divider: false) {
                    Picker("", selection: $shadowIntensityRaw) {
                        ForEach(ShadowIntensity.allCases) { intensity in
                            Text(intensity.rawValue).tag(intensity.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: shadowIntensityRaw) { _ in
                        // Push the new multiplier to the live panel
                        // immediately. Without this, the slab keeps
                        // the previous opacity until the next
                        // show/morph re-fires setShadowOpacity.
                        AppDelegate.shared?.panelController?.refreshShadowIntensity()
                    }
                }
            }
        }
    }
}

// MARK: - Integrations

private struct IntegrationsSettings: View {
    // Keychain-backed key (was @AppStorage, which serialized into a
    // plaintext .plist). Loaded once on appear, written back to the
    // Keychain on every edit. The view binds to the @State directly so
    // SwiftUI's SecureField behaviour stays the same.
    @State private var geminiApiKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.integrations.icon,
                          tint: SettingsCategory.integrations.iconTint,
                          title: "Integrations")

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gemini")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Used to extract text from chat screenshots (right-click any image → Extract Messages). Get a key at aistudio.google.com.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("", text: $geminiApiKey, prompt: Text("Paste API key…").foregroundColor(.white.opacity(0.35)))
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.3))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                        .foregroundStyle(.white)
                }
                .padding(14)
            }
        }
        .onAppear {
            geminiApiKey = SecureKeyStore.shared.load(.geminiApiKey) ?? ""
        }
        .onChange(of: geminiApiKey) { newValue in
            // Save on every keystroke. Keychain writes are cheap
            // (single XPC round-trip) and this guarantees the user
            // doesn't lose the key if they close Settings without
            // an explicit "Save" action — there isn't one.
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                SecureKeyStore.shared.delete(.geminiApiKey)
            } else {
                SecureKeyStore.shared.save(.geminiApiKey, value: trimmed)
            }
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.about.icon,
                          tint: SettingsCategory.about.iconTint,
                          title: "About")

            SettingsCard {
                SettingsRow(title: "Version", subtitle: nil, divider: true) {
                    Text(version)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                SettingsRow(title: "Send feedback",
                            subtitle: "Bug reports, feature requests, kind words",
                            divider: false) {
                    Button("Email") {
                        if let url = URL(string: "mailto:feedback@trynox.app?subject=nox%20Feedback") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Dictation

private struct DictationSettings: View {
    // Keychain-backed (was @AppStorage). See SecureKeyStore for the
    // security audit rationale — UserDefaults plist on disk is
    // plaintext + readable by any process running as the user.
    @State private var apiKey: String = ""
    @AppStorage("dictationProvider") private var provider: String = "groq"
    @AppStorage("dictationCustomURL") private var customURL: String = ""
    @AppStorage("dictationCustomModel") private var customModel: String = ""
    @AppStorage("dictationCustomCleanupModel") private var customCleanupModel: String = ""
    @AppStorage("dictationCleanupEnabled") private var cleanupEnabled: Bool = true
    // Default MUST match `AppDelegate.savedMode ?? .fnHold` — earlier the
    // settings panel defaulted to `"fn_toggle"` while the app started in
    // `.fnHold`. The first time the user opened Settings → Dictation the
    // @AppStorage default materialised `"fn_toggle"` into UserDefaults,
    // and the next launch loaded toggle mode silently — so "hold to talk"
    // stopped working with no visible cause.
    @AppStorage("dictationHotkeyMode") private var hotkeyModeRaw: String = "fn_hold"
    @AppStorage(SettingsKey.dictationCustomKeyCode) private var customKeyCode: Int = 0
    @AppStorage(SettingsKey.dictationCustomModifiers) private var customModifiers: Int = 0
    @AppStorage("dictationCustomVocabulary") private var customVocabulary: String = ""

    // 2026-05-11 — voice engine + model + mic device pickers (user
    // request: "voice detection user should be able to have what
    // they want"). The infrastructure was already wired through
    // the rest of the codebase (see `loadDictationConfig`,
    // `LocalWhisperService.preferredModel`, `DictationRecorder
    // .preferredInputDevice`); these bindings just expose it as
    // proper UI instead of leaving the choices as hidden defaults.
    //
    // Default `useLocalWhisper = true` for fresh installs — privacy
    // wins, no API key needed, works offline. Cloud Groq stays one
    // toggle away for users who want max accuracy on accents or
    // long-form recording.
    @AppStorage("dictationUseLocalWhisper") private var useLocalWhisper: Bool = true
    @AppStorage("Notetaker.localWhisperModel") private var localWhisperModelRaw: String =
        LocalWhisperService.ModelSize.small.rawValue
    @AppStorage("dictationInputDeviceUID") private var inputDeviceUID: String = ""

    /// Snapshot of currently-discoverable mic devices. Refreshed on
    /// appear; static enough thereafter (the user isn't going to be
    /// hot-swapping mics inside the Settings window).
    @State private var availableInputDevices: [AVCaptureDevice] = []

    @State private var keyValidationStatus: ValidationStatus = .untested
    @State private var validateTask: Task<Void, Never>?

    enum ValidationStatus {
        case untested
        case validating
        case valid
        case invalid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                icon: SettingsCategory.dictation.icon,
                tint: SettingsCategory.dictation.iconTint,
                title: SettingsCategory.dictation.title
            )
            Text("Press your dictation hotkey to record voice and paste a cleaned-up transcript at the cursor in any app. Music auto-pauses while recording.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            // ENGINE — local (on-device WhisperKit) vs cloud (Groq/
            // OpenAI/Custom). Local is private, free, works offline;
            // cloud is faster and slightly more accurate on accented
            // speech. When local is picked, the model picker below
            // chooses the size/speed tradeoff. When cloud is picked,
            // the provider card further down handles endpoint + key.
            SettingsCard {
                GroupTitle(title: "Voice engine")
                SettingsRow(title: "Engine",
                            subtitle: useLocalWhisper
                                ? "On-device. Private, free, works offline. Slower on the bigger models but no audio leaves your Mac."
                                : "Cloud. Sends audio to your provider. Faster, slightly more accurate, needs an API key.") {
                    Picker("", selection: $useLocalWhisper) {
                        Text("On-device (private)").tag(true)
                        Text("Cloud (faster)").tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: useLocalWhisper) { _ in reapply() }
                }
                if useLocalWhisper {
                    Divider().background(SettingsTheme.rowDivider)
                    SettingsRow(title: "Whisper model",
                                subtitle: "Bigger = more accurate, more disk + RAM. Tiny / Base run instantly even on M1; Medium is best for accents but takes ~1.4 GB and ~2× the inference time.") {
                        Picker("", selection: $localWhisperModelRaw) {
                            ForEach(LocalWhisperService.ModelSize.allCases, id: \.rawValue) { size in
                                Text(size.displayName).tag(size.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: localWhisperModelRaw) { _ in
                            // Pipeline holds the previous model in
                            // memory; invalidate so the next dictation
                            // re-prepares with the new selection.
                            // Disk-cached models reload in ~1-2s.
                            Task { await LocalWhisperService.shared.invalidate() }
                            reapply()
                        }
                    }
                }
            }

            // MICROPHONE — explicit input-device picker. Common
            // failure mode: user has Bluetooth headphones connected,
            // macOS routes audio through HFP (telephony-grade,
            // sometimes silent), Whisper returns empty. Picking
            // built-in mic here fixes it for every future recording.
            // Empty UID = "system default" — what the recorder uses
            // when nothing is saved.
            SettingsCard {
                GroupTitle(title: "Microphone")
                SettingsRow(title: "Input device",
                            subtitle: "Pick the mic nox should record from. \"System default\" follows whatever macOS Sound settings is using right now.") {
                    Picker("", selection: $inputDeviceUID) {
                        Text("System default").tag("")
                        ForEach(availableInputDevices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
            .onAppear { refreshAvailableInputDevices() }

            // PROVIDER + API KEY — drives the cloud engine when
            // selected, AND drives the cleanup LLM (which runs for
            // BOTH engines — Whisper-on-device + LLM-cleanup-in-cloud
            // is a common combo for users who want privacy-preserving
            // transcription but still want polished output). Subtitle
            // reflects which role it's playing.
            SettingsCard {
                GroupTitle(title: useLocalWhisper
                           ? "Cleanup provider (optional)"
                           : "Transcription provider")
                SettingsRow(title: "Provider",
                            subtitle: "Groq is free and fast. OpenAI requires a paid account. Custom lets you point at any OpenAI-compatible endpoint.") {
                    Picker("", selection: $provider) {
                        Text("Groq (free)").tag("groq")
                        Text("OpenAI").tag("openai")
                        Text("Custom").tag("custom")
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: provider) { _ in keyValidationStatus = .untested; reapply() }
                }

                Divider().background(SettingsTheme.rowDivider)

                SettingsRow(title: "API key",
                            subtitle: provider == "groq"
                                ? "Get a free key at console.groq.com/keys"
                                : "Paste your provider's API key.") {
                    HStack(spacing: 8) {
                        SecureField("paste your key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .onChange(of: apiKey) { _ in
                                keyValidationStatus = .untested
                                reapply()
                            }
                        statusBadge
                        Button("Test") { testKey() }
                            .disabled(apiKey.isEmpty || keyValidationStatus == .validating)
                    }
                }

                if provider == "custom" {
                    Divider().background(SettingsTheme.rowDivider)
                    SettingsRow(title: "Base URL",
                                subtitle: "OpenAI-compatible base URL, e.g. https://api.example.com/v1") {
                        TextField("https://...", text: $customURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                            .onChange(of: customURL) { _ in reapply() }
                    }
                    Divider().background(SettingsTheme.rowDivider)
                    SettingsRow(title: "Whisper model", subtitle: nil) {
                        TextField("whisper-large-v3-turbo", text: $customModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .onChange(of: customModel) { _ in reapply() }
                    }
                    Divider().background(SettingsTheme.rowDivider)
                    SettingsRow(title: "Cleanup LLM model",
                                subtitle: "Optional. Leave empty to disable cleanup pass.") {
                        TextField("e.g. llama-3.3-70b-versatile", text: $customCleanupModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                            .onChange(of: customCleanupModel) { _ in reapply() }
                    }
                }

                Divider().background(SettingsTheme.rowDivider)
                SettingsRow(title: "Clean up transcript",
                            subtitle: "Run the raw Whisper output through an LLM to remove filler words, fix grammar, and tidy punctuation before pasting.") {
                    Toggle("", isOn: $cleanupEnabled)
                        .labelsHidden()
                        .onChange(of: cleanupEnabled) { _ in reapply() }
                }
            }

            // HOTKEY
            SettingsCard {
                GroupTitle(title: "Hotkey")
                SettingsRow(title: "Trigger",
                            subtitle: "Hold-to-talk = press and hold to record, release to stop. Tap-to-toggle = press once to start, again to stop. Custom shortcut works for keyboards without an Fn key.") {
                    Picker("", selection: $hotkeyModeRaw) {
                        Text("Tap Fn (toggle)").tag("fn_toggle")
                        Text("Hold Fn").tag("fn_hold")
                        Text("Custom shortcut").tag("custom_toggle")
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: hotkeyModeRaw) { _ in reapplyHotkey() }
                }
                // Custom-shortcut binder — only visible when the user
                // picked the custom mode. Click to record any key
                // combo (any modifiers + any key, including F-keys for
                // people on non-Apple keyboards).
                if hotkeyModeRaw == "custom_toggle" {
                    Divider().background(SettingsTheme.rowDivider)
                    SettingsRow(title: "Shortcut",
                                subtitle: "Click to record any modifier + key combo. Works on any keyboard, no Fn key required.") {
                        KeyShortcutCapture(
                            keyCode: $customKeyCode,
                            modifiers: $customModifiers
                        )
                        .onChange(of: customKeyCode) { _ in reapplyHotkey() }
                        .onChange(of: customModifiers) { _ in reapplyHotkey() }
                    }
                }
            }

            // CUSTOM VOCABULARY — biases Whisper toward known
            // names / technical terms / proper nouns. The user
            // reported "sometimes it's mispronouncing some
            // special words"; this is exactly the field that
            // fixes it. Whisper accepts a `prompt` parameter
            // that's "text that looks like the start of the
            // transcript" — Whisper continues in the same style
            // and vocabulary, so anything listed here gets
            // recognized far more reliably (~90% reduction in
            // proper-noun errors per OpenAI's prompting guide).
            SettingsCard {
                GroupTitle(title: "Custom vocabulary")
                Text("Words you say often that get transcribed wrong. Names, technical terms, jargon. Whisper biases toward these.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                ZStack(alignment: .topLeading) {
                    if customVocabulary.isEmpty {
                        Text("e.g. nox, SwiftUI, Whisper, Groq")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $customVocabulary)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 70, maxHeight: 110)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .onChange(of: customVocabulary) { _ in reapply() }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            // PERMISSIONS — live status, not a static blob of text. Shows
            // the current Microphone + Accessibility state with a green
            // check or an amber dot, plus an action button per row that
            // does the right thing (proactively prompt for Mic when
            // status is .notDetermined; jump to System Settings when
            // already denied or for Accessibility which doesn't have a
            // programmatic prompt API).
            DictationPermissionsCard()
        }
        .onAppear {
            // 2026-05-08 audit M17: load the keychain value WITHOUT
            // tripping the .onChange handler below. Previously the
            // load wrote to @State, which counts as a change, which
            // reset keyValidationStatus to .untested every time the
            // user opened Settings. Net effect: the validation
            // badge disappeared whenever they came back to the
            // Integrations tab. The `didLoadFromKeychain` latch
            // makes the first onChange a no-op.
            didLoadFromKeychain = true
            apiKey = SecureKeyStore.shared.load(.dictationApiKey) ?? ""
        }
        .onChange(of: apiKey) { newValue in
            // First fire after onAppear's load isn't a real edit —
            // skip persistence and badge reset.
            if didLoadFromKeychain {
                didLoadFromKeychain = false
                return
            }
            // Persist on every keystroke so the user doesn't lose the
            // key by closing Settings without an explicit Save (there
            // isn't one). Reapply config so the orchestrator picks up
            // the new key without a relaunch.
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                SecureKeyStore.shared.delete(.dictationApiKey)
            } else {
                SecureKeyStore.shared.save(.dictationApiKey, value: trimmed)
            }
            keyValidationStatus = .untested
            reapply()
        }
    }

    /// Latch that suppresses the .onChange-fires-on-onAppear-load
    /// echo. Set true on the keychain load, cleared on the first
    /// onChange invocation after that. Audit M17.
    @State private var didLoadFromKeychain: Bool = false

    private var statusBadge: some View {
        Group {
            switch keyValidationStatus {
            case .untested:
                EmptyView()
            case .validating:
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("checking…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            case .valid:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("valid").font(.system(size: 11)).foregroundStyle(.green)
                }
            case .invalid:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text("invalid").font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
    }

    private func testKey() {
        validateTask?.cancel()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let baseURL: URL = {
            switch provider {
            case "openai": return URL(string: "https://api.openai.com/v1")!
            case "custom": return URL(string: customURL) ?? URL(string: "https://api.groq.com/openai/v1")!
            default: return URL(string: "https://api.groq.com/openai/v1")!
            }
        }()
        keyValidationStatus = .validating
        validateTask = Task {
            let ok = await DictationService.validateAPIKey(key, baseURL: baseURL)
            // Cooperative cancellation check after the network call
            // completes. Without this, the user clicks Test → changes
            // the key → clicks Test again, and Task1's stale result
            // would land and overwrite Task2's .validating /.valid /
            // .invalid badge — wrong key would show as validated.
            // Audit H1.
            if Task.isCancelled { return }
            await MainActor.run {
                // Belt-and-suspenders: re-check on main too, in case
                // cancellation happened between the await above and
                // the MainActor hop.
                guard !Task.isCancelled else { return }
                keyValidationStatus = ok ? .valid : .invalid
            }
        }
    }

    /// Re-apply the new dictation config to the orchestrator so
    /// changes take effect immediately without an app restart.
    private func reapply() {
        AppDelegate.shared?.dictationOrchestrator?.configure(
            serviceConfig: AppDelegate.loadDictationConfig()
        )
    }

    private func reapplyHotkey() {
        guard let mode = DictationOrchestrator.HotkeyMode(rawValue: hotkeyModeRaw) else { return }
        // For .customToggle, pass the saved keyCode + modifiers so the
        // Carbon registration uses the user's binding. For Fn modes,
        // the params are ignored (orchestrator branches on mode).
        AppDelegate.shared?.dictationOrchestrator?.setHotkeyMode(
            mode,
            customKeyCode: UInt32(customKeyCode),
            customModifiers: UInt32(customModifiers)
        )
    }

    /// Snapshot every microphone macOS currently exposes so the
    /// "Input device" picker has rows to render. Filters to audio
    /// inputs only (Aggregate / Loopback pseudo-devices show up in
    /// some discovery sessions but are usually outputs or virtual).
    /// Mirrors the same `discoverableMicTypes()` list used by
    /// `DictationRecorder.preferredInputDevice` so what the user
    /// picks here is exactly what the recorder can resolve later.
    private func refreshAvailableInputDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: DictationRecorder.discoverableMicTypes(),
            mediaType: .audio,
            position: .unspecified
        )
        availableInputDevices = session.devices
    }
}

// MARK: - Dictation permissions card

/// Live, interactive permissions panel for dictation. Replaces the
/// previous static text + two "Open …" buttons. Polls Microphone +
/// Accessibility status on appear, on window-focus return, and when the
/// orchestrator broadcasts `noxDictationAccessibilityMissing`. Each row
/// has a single action button that picks the right behavior:
///
/// - Microphone, `.notDetermined` → "Grant" → `AVCaptureDevice.requestAccess`
///   (proactive prompt; user doesn't have to trigger their first
///   recording to get the system dialog).
/// - Microphone, `.denied` / `.restricted` → "Open Settings" → jumps to
///   System Settings → Privacy → Microphone (only path once denied).
/// - Accessibility, missing → "Open Settings" + a toast explaining
///   they'll need to relaunch nox after toggling. Apple gives no
///   programmatic prompt for AX once the user has dismissed it once.
private struct DictationPermissionsCard: View {
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var axTrusted: Bool = false
    @State private var pollTimer: Timer?

    var body: some View {
        SettingsCard {
            GroupTitle(title: "Permissions")
            VStack(spacing: 8) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: micSubtitle,
                    status: micStatusIcon,
                    actionTitle: micActionTitle,
                    action: handleMicAction
                )
                permissionRow(
                    icon: "hand.tap.fill",
                    title: "Accessibility",
                    subtitle: axTrusted
                        ? "Granted — Fn-key hold-to-talk is active."
                        : "Required so nox can read the Fn-key and paste transcripts at your cursor.",
                    status: axTrusted ? .ok : .needed,
                    actionTitle: axTrusted ? nil : "Open Settings",
                    action: { openAccessibilitySettings() }
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .onAppear {
            refresh()
            // Poll lazily while the Settings window is visible. Cheap —
            // both calls are local to the process and don't hit XPC.
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .noxDictationAccessibilityMissing)) { _ in
            refresh()
        }
    }

    // MARK: Row + helpers

    private enum RowStatus { case ok, needed, pending }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        status: RowStatus,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(status == .ok
                          ? Color.green.opacity(0.18)
                          : Color.yellow.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(status == .ok
                        ? Color.green
                        : Color.yellow)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Image(systemName: status == .ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(status == .ok ? .green : .yellow)
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let actionTitle = actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: State derivation

    private var micStatusIcon: RowStatus {
        switch micStatus {
        case .authorized: return .ok
        case .notDetermined: return .pending
        default: return .needed
        }
    }

    private var micSubtitle: String {
        switch micStatus {
        case .authorized:
            return "Granted — nox can record your voice."
        case .notDetermined:
            return "Tap Grant to allow nox to record your voice when you hold Fn or press your custom shortcut."
        case .denied:
            return "Denied earlier. Re-enable nox in System Settings → Privacy → Microphone, then relaunch."
        case .restricted:
            return "Microphone access is restricted by system policy."
        @unknown default:
            return "Microphone status unknown."
        }
    }

    private var micActionTitle: String? {
        switch micStatus {
        case .authorized: return nil
        case .notDetermined: return "Grant"
        default: return "Open Settings"
        }
    }

    private func handleMicAction() {
        switch micStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in refresh() }
            }
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    private func openAccessibilitySettings() {
        // Trigger the native AX prompt one more time in case the user
        // never saw it (no-op if they've already responded). Then deep-
        // link to System Settings so they can flip the toggle if needed.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @MainActor
    private func refresh() {
        let priorAX = axTrusted
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        axTrusted = AXIsProcessTrusted()
        // When Accessibility transitions from denied → granted while the
        // app is already running, the Fn-key event tap installed at
        // launch is a no-op (it bailed early due to the missing trust).
        // Auto-retry: ask the orchestrator to re-establish its hotkey
        // listeners using the user's saved mode. This makes hold-to-talk
        // start working the moment the toggle flips in System Settings,
        // no app relaunch required.
        if !priorAX, axTrusted {
            let savedMode = UserDefaults.standard.string(forKey: "dictationHotkeyMode")
                .flatMap { DictationOrchestrator.HotkeyMode(rawValue: $0) }
                ?? .fnHold
            AppDelegate.shared?.dictationOrchestrator?.setHotkeyMode(savedMode)
        }
    }
}

// MARK: - Window entry point

enum SettingsWindow {
    /// Single, reliable entry point for showing Settings. Delegates to the
    /// AppDelegate, which owns the window directly via `NSHostingController`.
    @MainActor
    static func open() {
        NSLog("nox: SettingsWindow.open invoked, shared=\(AppDelegate.shared != nil) appDelegate=\(NSApp.delegate.map { String(describing: type(of: $0)) } ?? "nil")")
        if let app = AppDelegate.shared {
            app.openSettings()
            return
        }
        if let app = NSApp.delegate as? AppDelegate {
            app.openSettings()
            return
        }
        NSLog("nox: SettingsWindow.open could not reach AppDelegate")
    }
}

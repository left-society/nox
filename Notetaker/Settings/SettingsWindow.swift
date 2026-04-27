import SwiftUI
import ServiceManagement
import AppKit

// MARK: - Settings categories

/// One row in the sidebar nav. Order here = order in the sidebar.
/// Grouping is encoded by inserting `.divider` markers; the sidebar
/// view splits on those to render section headers like Alcove does
/// ("Notifications" / "Live Activities" / "Account").
enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general
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

    // Music
    static let showRestingPill = "showRestingPill"
    static let sphereVisualizerEnabled = "sphereVisualizerEnabled"
    static let hideMusicWhileSourceFrontmost = "hideMusicWhileSourceFrontmost"
    static let musicAutoSwitchTab = "musicAutoSwitchTab"
    /// Horizontal swipe on the resting music pill = previous /
    /// next track. Read inline by `PanelRootView.pillSwipeEnabled`
    /// so a flip in Settings takes effect on the next gesture.
    static let pillSwipeToSkip = "pillSwipeToSkip"

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
}

enum ShadowIntensity: String, CaseIterable, Identifiable {
    case subtle = "Subtle"
    case medium = "Medium"
    case deep = "Deep"
    var id: String { rawValue }

    /// Map to the (contact, halo) opacity pair used by PanelRootView's
    /// shadow stack. Subtle is what's currently shipping; Medium is
    /// closer to the previous "more depth" attempt; Deep is for very
    /// busy desktops.
    var opacities: (contact: Double, halo: Double) {
        switch self {
        case .subtle: return (0.42, 0.22)
        case .medium: return (0.55, 0.32)
        case .deep: return (0.65, 0.45)
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
            Divider()
            ScrollView(showsIndicators: false) {
                detail
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(SettingsTheme.detailBackground)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 600)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Inset header — mirrors macOS System Settings' branding band
            HStack(spacing: 8) {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Notetaker")
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

private enum SettingsTheme {
    static let sidebarBackground = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let detailBackground = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let cardBackground = Color.white.opacity(0.04)
    static let cardStroke = Color.white.opacity(0.06)
    static let rowDivider = Color.white.opacity(0.05)
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(category.iconTint.opacity(0.85))
                Image(systemName: category.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)

            Text(category.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.78))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.10)
                      : (isHovered ? Color.white.opacity(0.05) : Color.clear))
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Section building blocks

private struct SectionHeader: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.bottom, 16)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsTheme.cardStroke, lineWidth: 0.5)
            )
            .padding(.bottom, 16)
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var control: Control
    var divider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                control
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if divider {
                Rectangle()
                    .fill(SettingsTheme.rowDivider)
                    .frame(height: 0.5)
                    .padding(.leading, 14)
            }
        }
    }
}

private struct GroupTitle: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.bottom, 8)
            .padding(.top, 4)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.launchAtLogin) private var launchAtLogin: Bool = true
    @AppStorage(SettingsKey.hideInFullscreen) private var hideInFullscreen: Bool = false
    @AppStorage(SettingsKey.hideFromScreenCapture) private var hideFromScreenCapture: Bool = false
    @AppStorage(SettingsKey.hoverDwellSeconds) private var hoverDwellSeconds: Double = 0.27
    @AppStorage(SettingsKey.hoverHotZoneWidth) private var hoverHotZoneWidth: Double = 300
    @AppStorage(SettingsKey.hapticsEnabled) private var hapticsEnabled: Bool = true
    @AppStorage(SettingsKey.defaultTabRaw) private var defaultTabRaw: String = DefaultTab.last.rawValue
    @AppStorage(SettingsKey.respectFocusMode) private var respectFocusMode: Bool = true
    @AppStorage(SettingsKey.showAirDropPill) private var showAirDropPill: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.general.icon,
                          tint: SettingsCategory.general.iconTint,
                          title: "General")

            SettingsCard {
                SettingsRow(title: "Launch at login", subtitle: nil) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                        .onChange(of: launchAtLogin) { setLaunchAtLogin($0) }
                }
                SettingsRow(title: "Hide in fullscreen",
                            subtitle: "Pill stays out of the way during full-screen apps") {
                    Toggle("", isOn: $hideInFullscreen).labelsHidden()
                }
                SettingsRow(title: "Hide from screen capture",
                            subtitle: "Pill won't show up in screenshots or recordings",
                            divider: false) {
                    Toggle("", isOn: $hideFromScreenCapture).labelsHidden()
                }
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
                SettingsRow(title: "AirDrop arrival pill",
                            subtitle: "Pill flashes when a file lands via AirDrop — tap to reveal in Finder") {
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
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
    }
}

// MARK: - Music

private struct MusicSettings: View {
    @AppStorage(SettingsKey.showRestingPill) private var showRestingPill: Bool = true
    @AppStorage(SettingsKey.sphereVisualizerEnabled) private var sphereVisualizerEnabled: Bool = true
    @AppStorage(SettingsKey.hideMusicWhileSourceFrontmost) private var hideMusicWhileSourceFrontmost: Bool = false
    @AppStorage(SettingsKey.musicAutoSwitchTab) private var musicAutoSwitchTab: Bool = true
    @AppStorage(SettingsKey.pillSwipeToSkip) private var pillSwipeToSkip: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.music.icon,
                          tint: SettingsCategory.music.iconTint,
                          title: "Music")

            SettingsCard {
                SettingsRow(title: "Always-on resting pill",
                            subtitle: "Show the small pill near the notch whenever music is playing") {
                    Toggle("", isOn: $showRestingPill).labelsHidden()
                }
                SettingsRow(title: "Sphere visualizer",
                            subtitle: "Rotating particle sphere on the music card") {
                    Toggle("", isOn: $sphereVisualizerEnabled).labelsHidden()
                }
                SettingsRow(title: "Hide while source app is frontmost",
                            subtitle: "If you're already in Spotify, no need for the pill") {
                    Toggle("", isOn: $hideMusicWhileSourceFrontmost).labelsHidden()
                }
                SettingsRow(title: "Auto-switch to Music tab",
                            subtitle: "When playback starts, jump to the Music tab on next open") {
                    Toggle("", isOn: $musicAutoSwitchTab).labelsHidden()
                }
                SettingsRow(title: "Swipe to skip",
                            subtitle: "Drag the resting pill left for previous, right for next",
                            divider: false) {
                    Toggle("", isOn: $pillSwipeToSkip).labelsHidden()
                }
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
    @AppStorage(SettingsKey.timerDefaultPresetSeconds) private var timerDefaultPresetSeconds: Int = 25 * 60

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

            GroupTitle(title: "Defaults")
            SettingsCard {
                SettingsRow(title: "Default duration",
                            subtitle: "Used when starting a timer from a hotkey",
                            divider: false) {
                    Picker("", selection: $timerDefaultPresetSeconds) {
                        Text("5 minutes").tag(5 * 60)
                        Text("10 minutes").tag(10 * 60)
                        Text("15 minutes").tag(15 * 60)
                        Text("25 minutes").tag(25 * 60)
                        Text("45 minutes").tag(45 * 60)
                        Text("60 minutes").tag(60 * 60)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
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
                    Text("The pill is tappable — clicking it opens the join link from the event's location, notes, or URL field. Zoom, Google Meet, Teams, Webex are auto-detected.")
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
    @AppStorage(SettingsKey.screenshotBurstWindow) private var screenshotBurstWindow: Double = 3.0
    @AppStorage(SettingsKey.imageRetentionDays) private var imageRetentionDays: Int = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.images.icon,
                          tint: SettingsCategory.images.iconTint,
                          title: "Images")

            SettingsCard {
                SettingsRow(title: "Burst window",
                            subtitle: "Screenshots within this window count as a burst — the pill shows the running total",
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
    @AppStorage(SettingsKey.accentModeRaw) private var accentModeRaw: String = AccentMode.artwork.rawValue
    @AppStorage(SettingsKey.shadowIntensityRaw) private var shadowIntensityRaw: String = ShadowIntensity.subtle.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(icon: SettingsCategory.appearance.icon,
                          tint: SettingsCategory.appearance.iconTint,
                          title: "Appearance")

            SettingsCard {
                SettingsRow(title: "Accent color",
                            subtitle: "Used by progress bars, sphere, empty-state glows") {
                    Picker("", selection: $accentModeRaw) {
                        ForEach(AccentMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRow(title: "Shadow intensity",
                            subtitle: "Depth of the halo around the slab",
                            divider: false) {
                    Picker("", selection: $shadowIntensityRaw) {
                        ForEach(ShadowIntensity.allCases) { intensity in
                            Text(intensity.rawValue).tag(intensity.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
        }
    }
}

// MARK: - Integrations

private struct IntegrationsSettings: View {
    @AppStorage(SettingsKey.geminiApiKey) private var geminiApiKey: String = ""

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
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
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
                SettingsRow(title: "Made by",
                            subtitle: "Built in Swift + AppKit, with caffeine",
                            divider: true) {
                    Text("Aritra Debnath")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                SettingsRow(title: "Send feedback",
                            subtitle: "Bug reports, feature requests, kind words",
                            divider: false) {
                    Button("Email") {
                        if let url = URL(string: "mailto:aritra13.debnath@gmail.com?subject=Notetaker%20Feedback") {
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

// MARK: - Window entry point

enum SettingsWindow {
    /// Single, reliable entry point for showing Settings. Delegates to the
    /// AppDelegate, which owns the window directly via `NSHostingController`.
    @MainActor
    static func open() {
        NSLog("Notetaker: SettingsWindow.open invoked, shared=\(AppDelegate.shared != nil) appDelegate=\(NSApp.delegate.map { String(describing: type(of: $0)) } ?? "nil")")
        if let app = AppDelegate.shared {
            app.openSettings()
            return
        }
        if let app = NSApp.delegate as? AppDelegate {
            app.openSettings()
            return
        }
        NSLog("Notetaker: SettingsWindow.open could not reach AppDelegate")
    }
}

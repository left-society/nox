import SwiftUI
import EventKit
import AppKit

/// Calendar widget rendered alongside the music card in the
/// expanded music panel — the layout the user requested 2026-05-06
/// (split: music left, calendar right). Connects to the real Apple
/// Calendar via the existing `CalendarMonitorService`'s EventKit
/// pipeline.
///
/// Display contract:
///   • Header: short weekday + day number. Day number tints red on
///     today (matches Apple Calendar's date treatment).
///   • Body when authorized:
///       – non-empty events: list of up to 3 rows (calendar-color
///         dot + title + start time). Overflow indicator below.
///       – empty: "No events today / Your day is clear" — same
///         copy Alcove uses on its empty-day card.
///   • Body when NOT authorized:
///       – "Connect Calendar" affordance that triggers the
///         EventKit auth prompt, populates `todayEvents` on
///         success.
///
/// State source: the shared `CalendarMonitorService` instance
/// owned by AppDelegate. Looked up via `AppDelegate.shared` rather
/// than @EnvironmentObject because the service is optional (only
/// created when the user enables the meeting pill in Settings) —
/// pushing it through environment would require a fallback path
/// for the no-service case anyway, so direct lookup is simpler.
struct CalendarTodayPane: View {
    /// Optional service. Nil → calendar features are off in
    /// settings; show the "Enable in Settings" CTA. The widget
    /// itself doesn't flip the toggle (settings-as-source-of-truth).
    @ObservedObject var service: CalendarMonitorService

    /// Direct Google Calendar integration (no macOS Calendar.app
    /// in the middle). Used when the user picks "Google" as the
    /// source. Singleton so connection state survives panel
    /// open/close and is shared with future surfaces.
    @ObservedObject private var googleService = GoogleCalendarService.shared

    /// Calendar source preference. Three values:
    ///   • `"apple"` (default) — every event Apple Calendar.app
    ///     would surface, via EventKit.
    ///   • `"google"` — events from a Google account signed in
    ///     directly to nox via OAuth. **Notion Calendar users get
    ///     their meetings here** because Notion Calendar runs on
    ///     Google under the hood.
    ///   • `"notion"` — events from a Notion database (V2; Stage 2).
    @AppStorage(SettingsKey.noxCalendarSource) private var calendarSource: String = "apple"

    /// Cached "today" date used by the date header. Recomputed on
    /// onAppear and refreshed every minute by a Timer publisher
    /// so a midnight rollover updates the header without needing
    /// the user to reopen the panel.
    @State private var today: Date = Date()
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dateHeader
            Divider()
                .background(Color.white.opacity(0.06))
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            today = Date()
            // Kick a refresh on appear so the widget pulls the
            // current day's events even if the polling loop hasn't
            // fired since the panel was last open.
            service.refresh()
        }
        .onReceive(minuteTimer) { _ in
            today = Date()
        }
    }

    // MARK: - Header

    private var dateHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: -2) {
                Text(weekdayShort.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.27))
                    .tracking(0.6)
                Text(dayNumber)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            Spacer(minLength: 0)
            // Source picker chip — top-right corner. Always shown
            // because picking "Google" is itself a recovery path
            // (user can switch from Apple→Google to skip EventKit
            // entirely). Used to be hidden until EventKit was
            // authorized; that gated users from finding the
            // simpler Google path.
            sourcePickerChip
        }
    }

    /// Compact menu-button that lets the user flip between
    /// "Apple Calendar" (all EventKit events) and "Notion Calendar"
    /// (Google-account events only — Notion Calendar runs on
    /// Google under the hood). Writing to the @AppStorage triggers
    /// a UserDefaults change which the running service picks up
    /// on its next refresh tick. We also call `service.refresh()`
    /// directly so the change feels instant rather than waiting
    /// up to 30s for the next poll.
    private var sourcePickerChip: some View {
        Menu {
            Button {
                if calendarSource != "apple" {
                    calendarSource = "apple"
                    service.refresh()
                }
            } label: {
                HStack {
                    Text("Apple Calendar")
                    if calendarSource == "apple" {
                        Image(systemName: "checkmark")
                    }
                }
            }
            // Google source — direct OAuth, no EventKit. When users
            // pick this and aren't signed in yet, the content branch
            // shows the "Sign in with Google" CTA.
            Button {
                if calendarSource != "google" {
                    calendarSource = "google"
                    Task { await googleService.refresh() }
                }
            } label: {
                HStack {
                    Text("Google Calendar")
                    if calendarSource == "google" {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button {
                if calendarSource != "notion" {
                    calendarSource = "notion"
                    service.refresh()
                }
            } label: {
                HStack {
                    Text("Notion Calendar")
                    if calendarSource == "notion" {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sourceChipLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color.white.opacity(0.78))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.10),
                                          lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sourceChipLabel: String {
        switch calendarSource {
        case "google": return "Google"
        case "notion": return "Notion"
        default:       return "Apple"
        }
    }

    private var weekdayShort: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: today)
    }

    private var dayNumber: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: today)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        // Branch on calendar source FIRST. Google source bypasses
        // EventKit entirely — its connection state lives on
        // GoogleCalendarService.shared, so we don't need EventKit
        // authorization at all when source = "google".
        if calendarSource == "google" {
            googleSourceContent
        } else {
            // Apple / Notion sources both flow through EventKit
            // (Notion = "filter to Google-account calendars in
            // EventKit" — preserved for users who already added
            // Google in System Settings).
            switch authorizationState {
            case .authorized:
                if calendarSource == "notion" && !service.hasGoogleCalendar {
                    notionNoGoogleCTA
                } else if service.todayEvents.isEmpty {
                    emptyDay
                } else {
                    eventsList
                }
            case .needsAuthorization:
                authCTA
            case .denied:
                deniedState
            }
        }
    }

    /// Google-source content branches on `googleService.connectionState`.
    /// One-tap sign-in is the whole point — no System Settings, no
    /// EventKit, just a "Sign in with Google" button → web auth →
    /// events appear.
    @ViewBuilder
    private var googleSourceContent: some View {
        switch googleService.connectionState {
        case .signedOut:
            googleSignInCTA
        case .authorizing:
            googleAuthorizingState
        case .signedIn:
            if googleService.todayEvents.isEmpty {
                googleEmptyDay
            } else {
                googleEventsList
            }
        case .error(let message):
            googleErrorState(message: message)
        }
    }

    /// "Sign in with Google" CTA. The single most important button
    /// in this whole feature — it's what makes the "Notion Calendar
    /// users connect with one tap" promise work.
    private var googleSignInCTA: some View {
        Button {
            googleService.signIn()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in with Google")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Color.accent.opacity(0.85))
                    Text("Notion Calendar uses Google")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Color.accent.opacity(0.85))
                }
                Text("One tap. No System Settings.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    private var googleAuthorizingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
            Text("Opening Google sign-in…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
        }
    }

    private var googleEmptyDay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No events today")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Text("Your day is clear")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    /// Renders the Google service's events using the same row helper
    /// as the EventKit path. Both paths produce
    /// `CalendarMonitorService.TodayEvent` values, so layout is shared.
    private var googleEventsList: some View {
        let visible = Array(googleService.todayEvents.prefix(3))
        let overflow = max(0, googleService.todayEvents.count - visible.count)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(visible) { event in
                eventRow(event)
            }
            if overflow > 0 {
                Text("+ \(overflow) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(.leading, 12)
            }
        }
    }

    /// Recovery CTA when the Google integration hits an error
    /// (refresh token expired, network sustained-failure, etc.).
    /// Tapping kicks a fresh sign-in.
    private func googleErrorState(message: String) -> some View {
        Button {
            googleService.signIn()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(2)
                Text("Tap to reconnect")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Color.accent.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
    }

    /// CTA shown when "Notion Calendar" is selected as the source
    /// but the user hasn't added a Google account to macOS
    /// Calendar.app. Notion Calendar is a Google Calendar frontend
    /// — without a Google account in EventKit there's nothing for
    /// us to surface. The button drops them into System Settings →
    /// Internet Accounts so they can add Google in one tap.
    private var notionNoGoogleCTA: some View {
        Button {
            // x-apple.systempreferences scheme deep-links the right
            // pane across macOS versions. Internet Accounts is
            // where Google Calendar gets added.
            if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("No Google account")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text("Notion Calendar runs on Google. Tap to connect.")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Color.accent.opacity(0.85))
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }

    /// Three-state auth model the widget cares about. EventKit's
    /// raw enum has 5 cases; collapsing them to {authorized,
    /// needsAuthorization, denied} simplifies the UI branching.
    private enum AuthState { case authorized, needsAuthorization, denied }

    private var authorizationState: AuthState {
        switch service.authorizationStatus {
        case .notDetermined:
            return .needsAuthorization
        case .denied, .restricted:
            return .denied
        default:
            // .authorized (legacy), .fullAccess, .writeOnly all
            // surface enough events for the widget. .writeOnly
            // CAN'T actually read events but the system surfaces
            // the empty list, which falls through to the empty
            // state — acceptable.
            return .authorized
        }
    }

    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No events today")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Text("Your day is clear")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    /// Up to three rows + overflow chip ("+ N more") when the day
    /// has more events than fit. Three rows is the sweet spot for
    /// ~360pt panel height — enough to read while leaving the
    /// music transport row unobstructed.
    private var eventsList: some View {
        let visible = Array(service.todayEvents.prefix(3))
        let overflow = max(0, service.todayEvents.count - visible.count)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(visible) { event in
                eventRow(event)
            }
            if overflow > 0 {
                Text("+ \(overflow) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(.leading, 12)  // align under titles
            }
        }
    }

    private func eventRow(_ event: CalendarMonitorService.TodayEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(calendarColor(for: event))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timeLabel(for: event))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    private func calendarColor(for event: CalendarMonitorService.TodayEvent) -> Color {
        guard let rgb = event.calendarColorRGB else {
            return Color(red: 0.6, green: 0.6, blue: 0.6)
        }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue,
                     opacity: rgb.alpha)
    }

    private func timeLabel(for event: CalendarMonitorService.TodayEvent) -> String {
        if event.isAllDay { return "All day" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: event.startDate)
    }

    // MARK: - Auth states

    /// First-run state — the service has never been authorized.
    /// Tap → trigger EventKit's prompt; on grant the `@Published
    /// authorizationStatus` flips and SwiftUI re-renders into the
    /// authorized branch.
    ///
    /// **2026-05-09 DMG-build bug fix:** the previous version called
    /// `NSApp.activate(ignoringOtherApps: true)` before
    /// `requestAuthorization`. On non-activating `NSPanel` hosts
    /// that activate call doesn't reliably bring nox to the
    /// foreground in shipped (hardened-runtime, notarized) builds,
    /// which made the TCC dialog appear silently behind other apps
    /// — user reported tapping "Connect Calendar" did nothing on
    /// installed DMG copies even though it worked locally.
    ///
    /// Cleaner flow:
    ///   • Just call `requestAuthorization` directly. The TCC
    ///     dialog is hosted by `tccd`, not nox — it surfaces in
    ///     front of the user's current screen regardless of which
    ///     app is "active." Skipping the activate dance avoids
    ///     the panel-dismiss race entirely.
    ///   • If the call comes back with auth still `.denied` /
    ///     `.notDetermined` (system never popped, or user
    ///     dismissed without choosing), fall through to opening
    ///     System Settings → Privacy → Calendars so the user has
    ///     a manual recovery path.
    private var authCTA: some View {
        Button {
            service.requestAuthorization { granted in
                // If the system call came back with no grant AND
                // the auth state is still not authorized, route
                // the user to System Settings as a manual fallback.
                // Wrapped in a small delay so the @Published auth
                // state has time to refresh first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let status = EKEventStore.authorizationStatus(for: .event)
                    let resolved: Bool
                    if #available(macOS 14, *) {
                        resolved = (status == .fullAccess
                                    || status == .writeOnly
                                    || status == .authorized)
                    } else {
                        resolved = (status == .authorized)
                    }
                    if !granted && !resolved {
                        openCalendarPrivacySettings()
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect Calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text("See today's events")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    /// Tap-to-recover state for users who already denied permission
    /// (or revoked it in System Settings later). The button now
    /// drops them straight into the Calendar privacy pane so they
    /// can flip nox's switch back on without hunting through menus.
    private var deniedState: some View {
        Button {
            openCalendarPrivacySettings()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar access denied")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text("Tap to enable in System Settings")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Color.accent.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
    }

    /// Open System Settings → Privacy & Security → Calendars. The
    /// `x-apple.systempreferences:` URL scheme is the only stable
    /// way to deep-link a privacy pane — Apple changes the actual
    /// Settings nav structure between macOS versions.
    private func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

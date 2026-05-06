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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
        switch authorizationState {
        case .authorized:
            if service.todayEvents.isEmpty {
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
    private var authCTA: some View {
        Button {
            // The panel is .nonactivating, so by default we never
            // come to the foreground. The TCC dialog still appears
            // (it's owned by tccd, not us), but if the user clicks
            // away from the panel during the prompt the panel
            // dismisses and they lose context. Briefly activate so
            // the dialog feels owned by nox and the panel stays put
            // while it's on screen.
            NSApp.activate(ignoringOtherApps: true)
            service.requestAuthorization { _ in }
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

    private var deniedState: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Calendar denied")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
            Text("Enable in System Settings")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.4))
        }
    }
}

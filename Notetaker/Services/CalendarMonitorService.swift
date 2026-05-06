import Foundation
import EventKit
import AppKit

/// Polls EventKit for the next upcoming meeting and surfaces it
/// as a notch pill when the start is close (default: within 5
/// minutes). Click handling is split: the pill shows title + minutes
/// remaining, and the URL hidden in the event's `location` /
/// `notes` / `url` fields is exposed so the user can jump straight
/// to the Zoom/Meet/Teams link.
///
/// Authorization happens lazily — we don't request access until
/// the user has explicitly opted in via Settings → General →
/// "Show next meeting pill". The fail-open default is "no pill",
/// matching the FocusStatusService model.
///
/// We don't subscribe to `EKEventStoreChanged` because the event
/// stream we care about (about-to-start meetings) is dominated by
/// time passing, not edits. A 30-second poll is cheap, doesn't
/// require store-change observation, and gives us natural
/// "minutes remaining" updates without per-tick math.
@MainActor
final class CalendarMonitorService: ObservableObject {
    /// Window of "soon" — events starting within this many seconds
    /// from now trigger the pill. 5 minutes by default; user can
    /// tune via Settings → Calendar → "Show pill before".
    var leadTime: TimeInterval = 5 * 60

    /// Snapshot of the current upcoming event, if any. Nil means
    /// no event within `leadTime` (or auth not granted, or service
    /// not started). The published change is what AppDelegate
    /// hooks into to drive the pill.
    @Published private(set) var upcoming: UpcomingEvent?

    /// All of TODAY's calendar events (post-filter), sorted
    /// chronologically. Refreshed in the same poll as `upcoming`.
    /// Used by the music-panel calendar widget — separate from
    /// `upcoming` because the widget shows the full day's events
    /// regardless of `leadTime`, including all-day banners which
    /// the meeting pill explicitly excludes.
    @Published private(set) var todayEvents: [TodayEvent] = []

    /// Lightweight payload for the calendar widget. Carries only
    /// what the widget needs (title, time range, calendar color
    /// for the dot). Independent of `UpcomingEvent` because the
    /// surface area + filtering rules differ — UpcomingEvent is
    /// "join-meeting-now" pill data, TodayEvent is "what's on
    /// your day at a glance" widget data.
    struct TodayEvent: Identifiable, Equatable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        /// CGColor → SwiftUI Color via `Color(cgColor:)`. Used for
        /// the colored dot next to each row, matching Apple
        /// Calendar's per-calendar tint.
        let calendarColorRGB: (red: Double, green: Double, blue: Double, alpha: Double)?

        static func == (lhs: TodayEvent, rhs: TodayEvent) -> Bool {
            lhs.id == rhs.id
                && lhs.title == rhs.title
                && lhs.startDate == rhs.startDate
                && lhs.endDate == rhs.endDate
                && lhs.isAllDay == rhs.isAllDay
        }
    }

    /// Authorization state. Mirrors `EKEventStore.authorizationStatus`
    /// but published so SwiftUI views can react to flips.
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined

    /// Fired each time the upcoming event snapshot transitions
    /// (nil → present, present → nil, or different event id).
    /// Used by AppDelegate to push the right pill state.
    var onUpcomingChange: ((UpcomingEvent?) -> Void)?

    private let store = EKEventStore()
    private var pollTimer: Timer?

    /// Concrete payload pushed to consumers. Carries everything
    /// the pill needs without exposing the full EKEvent (which
    /// has a much wider surface area than we want callers to
    /// touch).
    struct UpcomingEvent: Equatable {
        let id: String
        let title: String
        let startDate: Date
        /// Minutes until start, rounded to integer. Negative if
        /// the event is already in progress (we still surface
        /// in-progress events for a few minutes — the user often
        /// joins a couple minutes late).
        let minutesUntilStart: Int
        /// First HTTPS URL discovered in `notes`/`location`/`url`.
        /// Prefers `meet.google.com`, `zoom.us`, `teams.microsoft.com`.
        let joinURL: URL?

        // Per BUG-026 fix: previously this only compared `id` and
        // `minutesUntilStart`. If the organizer renamed the meeting
        // or swapped the join URL (a real concern: a 9 AM standup
        // gets a fresh Zoom link from the host minutes before
        // start), our pill kept showing the stale title and tapped
        // the dead URL. Comparing all four fields means any
        // upstream change in EventKit triggers a fresh emission.
        static func == (lhs: UpcomingEvent, rhs: UpcomingEvent) -> Bool {
            lhs.id == rhs.id
                && lhs.title == rhs.title
                && lhs.minutesUntilStart == rhs.minutesUntilStart
                && lhs.joinURL == rhs.joinURL
        }
    }

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        // Per BUG-118 fix: seed leadTime from UserDefaults at
        // init. Was previously a hardcoded 5-minute default that
        // only got overridden via the Settings UI's .onChange
        // handler — fires only when the user touches the picker,
        // so a stored setting from a previous session reverted
        // until the user re-opened Settings.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "nextMeetingLeadMinutes") != nil {
            let minutes = defaults.integer(forKey: "nextMeetingLeadMinutes")
            // Defensive clamp: if a corrupt value somehow stored
            // 0 or negative, fall back to the 5-minute default
            // rather than disabling the pill entirely.
            if minutes > 0 {
                leadTime = TimeInterval(minutes) * 60
            }
        }
    }

    /// Begin polling. Idempotent — re-calling just refreshes the
    /// authorization status and reschedules the timer. Does NOT
    /// pop the system permission prompt.
    func start() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        // Always schedule the timer even when auth is .notDetermined
        // so flipping the toggle on later doesn't require a service
        // restart — the next tick will see the new auth state and
        // begin populating `upcoming`.
        if pollTimer == nil {
            // 30s poll. The pill displays minutes (not seconds), so
            // a 30s cadence means we update the displayed minutes
            // remaining with at most ~30s lag — well below human-
            // perceptible "this is stale."
            pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            // Run once now so the first pill (if any) lands without
            // waiting for the first tick.
            refresh()
        }
    }

    /// Stop polling. Called when the user toggles the feature off
    /// or the app terminates.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if upcoming != nil {
            upcoming = nil
            onUpcomingChange?(nil)
        }
    }

    /// Request EventKit authorization. Pops the system dialog the
    /// first time; subsequent calls reflect the existing decision.
    /// Wired from Settings → General → "Show next meeting pill"
    /// so the user only sees the prompt when explicitly opting in.
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    self?.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                    self?.refresh()
                    completion?(granted)
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    self?.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                    self?.refresh()
                    completion?(granted)
                }
            }
        }
    }

    /// Re-read upcoming events. Diffs against the last snapshot
    /// and only fires `onUpcomingChange` on actual transitions to
    /// keep AppDelegate's pill setter from spamming the same
    /// `.calendarUpcoming` event.
    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let hasAccess: Bool
        if #available(macOS 14, *) {
            hasAccess = (status == .fullAccess || status == .writeOnly || status == .authorized)
        } else {
            hasAccess = (status == .authorized)
        }
        guard hasAccess else {
            if upcoming != nil {
                upcoming = nil
                onUpcomingChange?(nil)
            }
            if !todayEvents.isEmpty { todayEvents = [] }
            return
        }

        // Populate today's events for the music-panel calendar
        // widget. Independent of the `leadTime` window — the widget
        // wants the FULL day, including all-day banners and events
        // earlier in the day that are already done (so the user can
        // glance and confirm "yeah, my day is over").
        refreshTodayEvents()

        let now = Date()
        // Look forward `leadTime` seconds plus a 60-second slop
        // for events already in progress (so users who are running
        // late still see the pill while they're scrambling to the
        // join link).
        let windowEnd = now.addingTimeInterval(leadTime)
        let windowStart = now.addingTimeInterval(-60)
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: calendars)
        let events = store.events(matching: predicate)
            // Skip all-day banners — they're not "meetings starting soon",
            // they're free/busy markers.
            .filter { !$0.isAllDay }
            // Skip declined events. EKEvent.attendees can be nil if the
            // user is the organizer, in which case we keep it.
            .filter { event in
                let me = event.attendees?.first(where: { $0.isCurrentUser })
                return (me?.participantStatus ?? .accepted) != .declined
            }
            // Closest-first by start date.
            .sorted { $0.startDate < $1.startDate }

        guard let next = events.first else {
            if upcoming != nil {
                upcoming = nil
                onUpcomingChange?(nil)
            }
            return
        }

        let minutes = Int((next.startDate.timeIntervalSince(now) / 60.0).rounded())
        let joinURL = Self.extractJoinURL(from: next)
        let snapshot = UpcomingEvent(
            id: next.eventIdentifier ?? "\(next.startDate.timeIntervalSince1970)-\(next.title ?? "")",
            title: next.title ?? "Meeting",
            startDate: next.startDate,
            minutesUntilStart: minutes,
            joinURL: joinURL
        )

        if upcoming != snapshot {
            upcoming = snapshot
            onUpcomingChange?(snapshot)
        }
    }

    /// Re-read today's events for the music-panel calendar widget.
    /// Pulls the WHOLE day (00:00:00 → 23:59:59), filters declined
    /// events but keeps all-day banners (the widget wants to show
    /// "Birthday: Aritra" type entries that the meeting pill drops).
    /// Sorted chronologically, with all-day events floated to the
    /// top — matches Apple Calendar's day-view ordering.
    private func refreshTodayEvents() {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
            todayEvents = []
            return
        }
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: calendars
        )
        let raw = store.events(matching: predicate)
            .filter { event in
                // Drop declined invites — same logic the meeting
                // pill uses. EKEvent.attendees is nil if the user
                // is the organizer; in that case `me` is nil and
                // we keep the event.
                let me = event.attendees?.first(where: { $0.isCurrentUser })
                return (me?.participantStatus ?? .accepted) != .declined
            }
            .sorted { a, b in
                // All-day events first, then chronological.
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }

        let mapped: [TodayEvent] = raw.map { event in
            let cgColor = event.calendar?.cgColor
            var rgba: (red: Double, green: Double, blue: Double, alpha: Double)?
            if let c = cgColor,
               let comps = c.components, comps.count >= 3 {
                let alpha = comps.count >= 4 ? Double(comps[3]) : 1.0
                rgba = (Double(comps[0]), Double(comps[1]), Double(comps[2]), alpha)
            }
            let id = event.eventIdentifier
                ?? "\(event.startDate.timeIntervalSince1970)-\(event.title ?? "")"
            return TodayEvent(
                id: id,
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarColorRGB: rgba
            )
        }

        if mapped != todayEvents {
            todayEvents = mapped
        }
    }

    /// Pull the most likely "join meeting" URL from an event's
    /// fields. We check `url` first (calendar UI exposes this for
    /// some sources), then `location`, then `notes`. Within each
    /// field we prefer known meeting hosts so a generic link in
    /// the notes doesn't beat the actual Zoom URL embedded in
    /// `location`.
    private static func extractJoinURL(from event: EKEvent) -> URL? {
        if let url = event.url, looksLikeMeetingURL(url) { return url }

        let candidates: [String] = [event.location, event.notes]
            .compactMap { $0 }
        for candidate in candidates {
            if let url = firstMeetingURL(in: candidate) { return url }
        }

        // Fall back to any URL we can find — at least a Calendar
        // event with "see attached link" is still actionable.
        if let url = event.url { return url }
        for candidate in candidates {
            if let url = firstURL(in: candidate) { return url }
        }
        return nil
    }

    private static let meetingHostFragments: [String] = [
        "zoom.us", "meet.google.com", "teams.microsoft.com",
        "teams.live.com", "webex.com", "gotomeeting.com",
        "whereby.com", "hangouts.google.com", "around.co",
        "around.lol", "tuple.app"
    ]

    private static func looksLikeMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return meetingHostFragments.contains(where: { host.contains($0) })
    }

    private static func firstMeetingURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector?.matches(in: text, options: [], range: range) ?? []
        for match in matches {
            if let url = match.url, looksLikeMeetingURL(url) { return url }
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, options: [], range: range)?.url
    }
}

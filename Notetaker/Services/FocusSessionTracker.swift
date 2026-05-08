import Foundation
import Combine

/// Tracks a single in-flight macOS Focus / Do-Not-Disturb session
/// for the Live Focus detail panel's dashboard view.
///
/// Scope: ONE session at a time, in-memory only. The moment
/// `presenter.isFocused` flips to false, the tracker resets to
/// `sessionStartDate = nil` and `mutedEvents = []`. There's no
/// cross-day datastore — the dashboard is a "what is Focus doing
/// for me right now" view, not a history report. Keeping it scoped
/// avoids the Core Data / persistence layer this feature would
/// otherwise need.
///
/// Wiring:
///   • `handleFocusChanged(isFocused:)` is called from AppDelegate's
///     existing FocusStatusService observer, on every transition.
///   • `recordMute(typeKey:)` is called from
///     `PanelPresenter.setPendingSystemEvent` when a transient pill
///     gets swallowed by the Focus early-return — that's the
///     authoritative "this got muted" signal.
///
/// All access is `@MainActor` — every consumer (PanelPresenter,
/// AppDelegate, SwiftUI views) is already on main, so no
/// queue-hopping is needed.
@MainActor
final class FocusSessionTracker: ObservableObject {
    static let shared = FocusSessionTracker()

    /// Wall-clock instant when the current Focus session started
    /// (i.e. the most recent rising edge of `presenter.isFocused`).
    /// Nil when no Focus session is active.
    @Published private(set) var sessionStartDate: Date? = nil

    /// Every nox pill that got suppressed during the active session.
    /// Newest first by virtue of `append`. Wiped on session end so
    /// the dashboard always reflects "this session" only.
    @Published private(set) var mutedEvents: [MutedEvent] = []

    /// Day-keyed minute totals for completed focus sessions —
    /// persisted in UserDefaults so "today" and "this week" survive
    /// app restarts. Same shape as `StudySessionTracker.minutesByDay`
    /// (yyyy-MM-dd → minutes). Loaded on init, written back on every
    /// session-end.
    @Published private(set) var minutesByDay: [String: Int] = [:]
    private static let minutesStorageKey = "noxFocusMinutesByDay"

    /// One mute observation. `typeKey` is the same short string the
    /// dashboard's breakdown chips render verbatim ("charger",
    /// "screenshot", "bluetooth", etc.) — keeping the key human-
    /// readable means the tracker doesn't need a separate display-
    /// label mapping table.
    struct MutedEvent: Equatable {
        let date: Date
        let typeKey: String
    }

    /// Width of one bucket in the 60-minute sparkline. Five minutes
    /// = 12 buckets of comfortable width on the ~150pt-wide stat
    /// tile, and matches the granularity the user can actually
    /// perceive (sub-minute changes would just read as noise).
    private static let sparkBucketSeconds: TimeInterval = 300

    /// How many 5-min buckets the sparkline shows. 12 × 5 min = 60 min.
    private static let sparkBucketCount: Int = 12

    /// Window we keep `mutedEvents` for (any older than this gets
    /// trimmed on every record so memory doesn't grow unbounded for
    /// users with very long sessions). 4 hours covers any plausible
    /// dashboard read while still being a hard ceiling.
    private static let retentionSeconds: TimeInterval = 4 * 3600

    /// ISO-day formatter (yyyy-MM-dd) shared across today/this-week
    /// math. Calendar/timezone is the user's current — "today" in
    /// their timezone is what they expect, not POSIX UTC.
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.minutesStorageKey)
            as? [String: Int] {
            self.minutesByDay = stored
        }
    }

    // MARK: - Lifecycle hooks

    /// Driven by AppDelegate. Receives the COMBINED quiet-state
    /// boolean — true if either nox's own quiet mode OR macOS
    /// Focus (with respect-Focus enabled) is active. Idempotent:
    /// repeated `true` calls without an intervening `false` don't
    /// reset the session (the rising edge is the start; subsequent
    /// "still active" pings are no-ops).
    func handleQuietStateChanged(active: Bool) {
        if active {
            if sessionStartDate == nil {
                sessionStartDate = Date()
                mutedEvents = []
            }
        } else {
            // Falling edge — persist the session's minutes to today's
            // day-bucket, then clear the in-memory session state. The
            // mute log is session-scoped so it wipes; the day-bucket
            // dictionary is multi-day so it accumulates.
            if let start = sessionStartDate {
                let now = Date()
                let minutes = Int(now.timeIntervalSince(start) / 60)
                if minutes > 0 {
                    let key = dayFormatter.string(from: now)
                    var updated = minutesByDay
                    updated[key, default: 0] += minutes
                    minutesByDay = updated
                    UserDefaults.standard.set(updated, forKey: Self.minutesStorageKey)
                }
            }
            sessionStartDate = nil
            mutedEvents = []
        }
    }

    /// Back-compat shim — earlier code path passed `isFocused` only.
    /// Now everything routes through `handleQuietStateChanged`, but
    /// keeping this around lets older call sites compile unchanged.
    @available(*, deprecated, message: "Use handleQuietStateChanged(active:) instead — quiet state can come from nox's own toggle, not just macOS Focus.")
    func handleFocusChanged(isFocused: Bool) {
        handleQuietStateChanged(active: isFocused)
    }

    /// Called from PanelPresenter's Focus-suppression early-return.
    /// No-op when there's no active session (defensive — shouldn't
    /// happen in practice because the early-return only fires when
    /// `isFocused == true`, but the guard keeps the contract clean).
    func recordMute(typeKey: String) {
        guard sessionStartDate != nil else { return }
        let now = Date()
        mutedEvents.append(MutedEvent(date: now, typeKey: typeKey))
        // Trim retention window. Linear scan is fine — typical
        // sessions accumulate <100 events; even a chatty 4-hour
        // session won't exceed a few hundred.
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        if let firstKept = mutedEvents.firstIndex(where: { $0.date >= cutoff }),
           firstKept > 0 {
            mutedEvents.removeSubrange(0..<firstKept)
        }
    }

    // MARK: - Computed views (read-only, called by the dashboard)

    /// Total count of pills muted in the current session. The
    /// dashboard renders this as the big number on the first stat
    /// tile.
    var pillsMutedCount: Int { mutedEvents.count }

    /// Pills muted in the LAST 60 minutes (regardless of session
    /// boundary; falls within this session because we wipe on
    /// session end). Powers the second stat tile's hero number.
    var mutedInLast60Min: Int {
        let cutoff = Date().addingTimeInterval(-3600)
        return mutedEvents.lazy.filter { $0.date >= cutoff }.count
    }

    /// Type → count, descending by count. The dashboard's first
    /// stat tile renders the top N entries as breakdown chips
    /// ("5 charger · 4 screenshot · …").
    var mutedByType: [(key: String, count: Int)] {
        Dictionary(grouping: mutedEvents, by: \.typeKey)
            .map { (key: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    /// Total minutes in Focus today — persisted bucket + active
    /// session's running minutes (if any). Mirror of
    /// `StudySessionTracker.totalMinutesToday`.
    func totalMinutesToday(now: Date = Date()) -> Int {
        let key = dayFormatter.string(from: now)
        let stored = minutesByDay[key] ?? 0
        let live = sessionStartDate.map { Int(now.timeIntervalSince($0) / 60) } ?? 0
        return stored + live
    }

    /// Total minutes across the last 7 calendar days (including
    /// today + active session). Mirror of
    /// `StudySessionTracker.totalMinutesThisWeek`.
    func totalMinutesThisWeek(now: Date = Date()) -> Int {
        let cal = Calendar.current
        var total = 0
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else {
                continue
            }
            let key = dayFormatter.string(from: day)
            total += minutesByDay[key] ?? 0
        }
        if let start = sessionStartDate {
            total += Int(now.timeIntervalSince(start) / 60)
        }
        return total
    }

    /// True if a focus session is active right now. Drives the
    /// "in progress" subtext on the today tile.
    var isSessionActive: Bool { sessionStartDate != nil }

    /// 7-element array, one bar per day. Index 0 = oldest (6 days
    /// ago), index 6 = today. Today's bucket includes the live
    /// session contribution so it grows in real time. Mirror of
    /// `StudySessionTracker.weekBuckets`.
    func weekBuckets(now: Date = Date()) -> [Int] {
        let cal = Calendar.current
        var out = Array(repeating: 0, count: 7)
        for i in 0..<7 {
            let offset = 6 - i
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else {
                continue
            }
            let key = dayFormatter.string(from: day)
            out[i] = minutesByDay[key] ?? 0
        }
        if let start = sessionStartDate {
            out[6] += Int(now.timeIntervalSince(start) / 60)
        }
        return out
    }

    /// 12-element array of 5-min bucket counts ending at "now".
    /// Index 0 = oldest (55–60 min ago); index 11 = newest (last
    /// 5 min, "current bucket"). The dashboard's sparkline maps
    /// directly: index 0 = leftmost bar, index 11 = rightmost +
    /// glow.
    func sparkBuckets() -> [Int] {
        let now = Date()
        var out = Array(repeating: 0, count: Self.sparkBucketCount)
        for event in mutedEvents {
            let secondsAgo = now.timeIntervalSince(event.date)
            // bucketIdx 0 = current 5-min slice; 11 = 55-60 min ago.
            let bucketIdx = Int(secondsAgo / Self.sparkBucketSeconds)
            guard bucketIdx >= 0, bucketIdx < Self.sparkBucketCount else { continue }
            // Display order is oldest-left (index 11 of bucketIdx
            // → index 0 of out) to newest-right (bucketIdx 0 →
            // out's last index).
            let displayIdx = Self.sparkBucketCount - 1 - bucketIdx
            out[displayIdx] += 1
        }
        return out
    }
}

extension PanelPresenter.SystemEvent {
    /// Stable, human-readable bucket key used by
    /// `FocusSessionTracker` to group muted events for the
    /// "X charger · Y screenshot · …" breakdown chips on the
    /// dashboard. Returns nil for events that aren't subject to
    /// the Focus early-return (timer, calendar, AirDrop, volume,
    /// trackChanged is included because it IS muted by Focus —
    /// see `PanelPresenter.isMutedByFocus`).
    var trackingTypeKey: String {
        switch self {
        case .charging:                                  return "charger"
        case .screenshotSaved:                           return "screenshot"
        case .downloadStarted, .downloadCompleted:       return "download"
        case .noteSaved:                                 return "note"
        case .bluetoothConnected, .bluetoothDisconnected: return "bluetooth"
        case .timerRunning, .timerFinished:              return "timer"
        case .calendarUpcoming:                          return "calendar"
        case .airDropReceived, .airDropSent, .airDropFailed: return "airdrop"
        case .trackChanged:                              return "track"
        case .volumeChanged:                             return "volume"
        }
    }
}

import Foundation
import Combine

/// Tracks study sessions for the Live → Study detail panel's stats
/// grid. Persistent: minutes-per-day are stored in UserDefaults so
/// "today" and "this week" survive app restarts.
///
/// Storage shape: `[String: Int]` keyed by ISO-style "yyyy-MM-dd"
/// day strings, value = total minutes studied that day. Plain
/// dictionary in UserDefaults — small enough (a few dozen days
/// before we'd want a real datastore), trivially backwards-
/// compatible (missing keys read as 0), survives app updates.
///
/// Wiring: AppDelegate's `recomputeQuietState()` calls
/// `handleStudyStateChanged(active:)` whenever `noxStudyMode` flips.
/// On the rising edge we capture `sessionStartDate`. On the falling
/// edge we compute duration and add it to today's bucket.
///
/// All access is `@MainActor`.
@MainActor
final class StudySessionTracker: ObservableObject {
    static let shared = StudySessionTracker()

    /// Wall-clock start of the active session, nil when no session
    /// is running. Same shape as `FocusSessionTracker` so SwiftUI
    /// can read either tracker via the same code path.
    @Published private(set) var sessionStartDate: Date? = nil

    /// Day-keyed minute totals for completed sessions. Loaded from
    /// UserDefaults on init, written back on every session-end.
    /// Stored as `[String: Int]` (day string → minutes); `@Published`
    /// so SwiftUI re-renders the stats grid the moment a session
    /// closes.
    @Published private(set) var minutesByDay: [String: Int] = [:]

    private static let storageKey = "noxStudyMinutesByDay"

    /// ISO-day formatter (yyyy-MM-dd) shared across all key/lookup
    /// calls so today/this-week math agrees on the boundary. Calendar
    /// is the user's current calendar, NOT POSIX — `today` in the
    /// user's timezone is what they intuitively expect.
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        // Load existing day-bucket dictionary from UserDefaults.
        // Defensive cast — if a future schema migration writes a
        // different shape, fall back to empty rather than crashing.
        if let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey)
            as? [String: Int] {
            self.minutesByDay = stored
        }
    }

    // MARK: - Lifecycle

    /// Idempotent — repeated `true` calls without an intervening
    /// `false` don't restart the session (rising edge starts; "still
    /// active" pings are no-ops). On falling edge: compute the
    /// session's duration and add it to today's day-bucket, then
    /// persist.
    func handleStudyStateChanged(active: Bool) {
        if active {
            if sessionStartDate == nil {
                sessionStartDate = Date()
            }
        } else if let start = sessionStartDate {
            let now = Date()
            let minutes = Int(now.timeIntervalSince(start) / 60)
            // Skip persisting sub-minute sessions — they're noise
            // (user toggled, immediately untoggled). Keeping the day
            // bucket clean for honest stats.
            if minutes > 0 {
                let key = dayFormatter.string(from: now)
                var updated = minutesByDay
                updated[key, default: 0] += minutes
                minutesByDay = updated
                UserDefaults.standard.set(updated, forKey: Self.storageKey)
            }
            sessionStartDate = nil
        }
    }

    // MARK: - Computed views

    /// Total minutes studied today — persisted bucket + the active
    /// session's running minutes (if any). Hero number on the first
    /// stat tile.
    func totalMinutesToday(now: Date = Date()) -> Int {
        let key = dayFormatter.string(from: now)
        let stored = minutesByDay[key] ?? 0
        let live = sessionStartDate.map { Int(now.timeIntervalSince($0) / 60) } ?? 0
        return stored + live
    }

    /// True if a session is active right now. Drives "1 session" /
    /// "N sessions" subtext when paired with a count, but for V1 we
    /// don't track count separately (each toggle-cycle is a session
    /// in the user's mind, but we only persist minutes — that's fine
    /// for the headline metric).
    var isSessionActive: Bool { sessionStartDate != nil }

    /// Total minutes studied across the last 7 calendar days
    /// (including today + active session). Hero number on the
    /// second stat tile.
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
        // Active session's running minutes count toward today's
        // bucket (which is already in the loop above), so add them
        // ONCE here without double-counting.
        if let start = sessionStartDate {
            total += Int(now.timeIntervalSince(start) / 60)
        }
        return total
    }

    /// Minutes for a specific day relative to `now`. `daysAgo == 0`
    /// is today (and includes the live session contribution if any),
    /// `daysAgo == 6` is six days back. Used by the redesigned hero
    /// card's per-day rings — each ring fills `dayMinutes / dailyGoal`.
    func dayMinutes(daysAgo: Int, now: Date = Date()) -> Int {
        let cal = Calendar.current
        guard let day = cal.date(byAdding: .day, value: -daysAgo, to: now) else {
            return 0
        }
        let key = dayFormatter.string(from: day)
        let stored = minutesByDay[key] ?? 0
        if daysAgo == 0, let start = sessionStartDate {
            return stored + Int(now.timeIntervalSince(start) / 60)
        }
        return stored
    }

    /// Count of days in the rolling 7-day window where the user hit
    /// (or exceeded) their daily goal. Drives the "4 of 7 goals
    /// completed (57%)" subtext on the redesigned hero card.
    func goalsCompletedThisWeek(goal: Int, now: Date = Date()) -> Int {
        guard goal > 0 else { return 0 }
        var hit = 0
        for offset in 0..<7 {
            if dayMinutes(daysAgo: offset, now: now) >= goal {
                hit += 1
            }
        }
        return hit
    }

    /// 7-element array, one bar per day. Index 0 = oldest (6 days
    /// ago), index 6 = today (rightmost bar). Today's bucket
    /// includes the live session contribution so the rightmost bar
    /// grows as the user studies.
    func weekBuckets(now: Date = Date()) -> [Int] {
        let cal = Calendar.current
        var out = Array(repeating: 0, count: 7)
        for i in 0..<7 {
            // Display index i = (6 - i) days ago. So i=0 is 6 days
            // back (leftmost), i=6 is today (rightmost).
            let offset = 6 - i
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else {
                continue
            }
            let key = dayFormatter.string(from: day)
            out[i] = minutesByDay[key] ?? 0
        }
        // Add live session minutes to today's (rightmost) bucket.
        if let start = sessionStartDate {
            out[6] += Int(now.timeIntervalSince(start) / 60)
        }
        return out
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MORPH ARCHITECTURE
//
// The pill-to-slab morph used to live in this file: SwiftUI animated
// `currentWidth` / `currentHeight` / `currentRadius` against the
// `presenter.isShown` flip via `.animation(.spring(...), value:)`, with
// a `contentReady` gate that delayed heavy children behind a 160ms
// `Task.sleep`. That morph was fundamentally CPU-bound — every spring
// tick triggered a full SwiftUI body re-evaluation + recursive layout
// pass through the whole view tree. The user reported it as "still
// super laggy" and "not even close to smooth" through multiple rounds
// of parameter tuning, which couldn't paper over the architectural
// cost.
//
// The morph now lives in `PanelWindowController.animateOpen` /
// `animateClose`: pure Core Animation, GPU-driven, via
// `panel.animator().setFrame(...)` inside `NSAnimationContext.runAnimationGroup`.
// SwiftUI inside the panel is STATIC during the morph — no internal
// frame morph, no internal cornerRadius morph, no spring on a state
// flag that's flipping mid-animation. Body re-evaluates only on
// discrete `presenter.isShown` flips (twice per show / hide pair),
// not per frame. The visible silhouette change (wide-pill bottom curve
// → tall slab with subtle rounding) comes for free: SwiftUI re-clips
// `Color.black` with a fixed-radius `UnevenRoundedRectangle` against
// the morphing NSHostingView bounds — no Path data being interpolated,
// no shape rebuild per frame. This pattern is from ComfyNotch's
// open-source notch HUD, which we benchmarked against.

enum PanelTab: String, CaseIterable, Identifiable {
    /// `.music` is special: it only appears in the segmented bar when
    /// `PanelPresenter.nowPlaying` is non-nil. It exists to give the
    /// panel a *very light* first-paint surface when the user opens
    /// while music is playing — the alternative (defaulting to .notes
    /// every open) pays the heavy NotesListView mount cost during the
    /// open animation, which the user reported as residual lag even
    /// after the always-mount + opacity-gate refactor. With Music as
    /// the auto-routed default during playback, the first frame the
    /// user sees is just album art + title + 3 buttons. The heavier
    /// tabs (Notes, Images, Videos, Files) lazy-mount only when the
    /// user explicitly switches to them — by which point the panel
    /// is already at rest and the mount hitch is far less perceptible.
    case music, notes, images, videos, files, script

    var id: String { rawValue }

    var title: String {
        switch self {
        // 2026-05-06: renamed Music → Live. The tab now shows
        // both what's playing AND today's calendar events, so the
        // music-only label was stale. "Live" captures the
        // "happening right now" character of both panes — a track
        // is playing live, and the day is unfolding live.
        case .music: return "Live"
        case .notes: return "Notes"
        case .images: return "Images"
        case .videos: return "Videos"
        case .files: return "Files"
        case .script: return "Script"
        }
    }

    /// SF Symbol for the dock-style tab bar. Per the user's
    /// 2026-04-29 redesign request ("instead of using text for
    /// image/video stuff just use Apple icons — transparent ones"),
    /// every tab is now icon-only. References: the Liquid-Glass
    /// floating dock pill that ships with macOS Tahoe / iOS 26 +
    /// the user's reference screenshot showing a frosted pill bar
    /// with 6-7 outlined circular icons.
    ///
    /// Picking guidelines (matched to Apple's canonical glyphs for
    /// each domain):
    ///   • Music — `music.note` (Music app's notch glyph)
    ///   • Notes — `note.text` (Notes.app dock + sidebar glyph)
    ///   • Images — `photo` (Photos.app, Markup, screenshot
    ///     stack — outlined variant for "transparent" feel)
    ///   • Videos — `play.rectangle` (QuickTime + Apple Music
    ///     videos tab use the rectangular play glyph)
    ///   • Files — `folder` (Finder's canonical glyph; outlined
    ///     SF Symbol matches the user's "transparent ones" cue
    ///     better than `tray.full`)
    var icon: String {
        switch self {
        case .music: return "music.note"
        case .notes: return "note.text"
        case .images: return "photo"
        case .videos: return "play.rectangle"
        case .files: return "folder"
        // Script — `text.alignleft` reads as "lines of text aligned
        // left" which fits both the editor surface AND the scrolling
        // teleprompter view. `doc.text` was the alternative but it
        // looks like "document" which is too note-adjacent and
        // dilutes the Notes tab's identity.
        case .script: return "text.alignleft"
        }
    }
}

struct PanelRootView: View {
    @EnvironmentObject var presenter: PanelPresenter

    /// Mirrors the dashboard's @AppStorage so the resting pill's
    /// `focusPillContent` switches in/out the moment the user
    /// flips Focus mode from the dashboard. Without this @AppStorage
    /// binding, the inline `pillContentOverlay` switch wouldn't see
    /// UserDefaults changes at SwiftUI invalidation time.
    @AppStorage(SettingsKey.noxFocusMode) private var noxFocusMode: Bool = false

    /// Sibling to `noxFocusMode` for the Study mode pill route.
    /// Study uses the same pill-content shape (single indicator
    /// + timer or alongside-music pair); only the icon and the
    /// timer source differ. Either flag fires the small-pill
    /// study-or-focus branch in `pillContentOverlay`.
    @AppStorage(SettingsKey.noxStudyMode) private var noxStudyMode: Bool = false

    /// User preference for the slab's accent color. Read inside
    /// `panelAccent` to decide between artwork-derived (default)
    /// and the macOS system accent. Bound via @AppStorage so a
    /// flip in Settings → Appearance triggers an immediate body
    /// re-evaluation — without the subscription, `panelAccent`
    /// would still read the new value via `AccentMode.current`
    /// but SwiftUI wouldn't know to invalidate the view that
    /// owns it.
    @AppStorage(SettingsKey.accentModeRaw) private var accentModeRaw: String = AccentMode.artwork.rawValue

    /// Drives `pillContentOverlay`'s focus-pill case. Active iff
    /// nox's own Focus mode is on (the only case where there's no
    /// other pill content already taking the slot — music always
    /// wins, and the macOS-Focus-only path doesn't have a session
    /// timer to display anyway since `FocusSessionTracker` resets
    /// when our own mode flips).
    @ObservedObject private var focusTracker = FocusSessionTracker.shared

    /// Sibling tracker for Study mode. Same shape as `focusTracker`
    /// (publishes `sessionStartDate` on rising edge, clears on
    /// falling edge) so the pill / dashboard timer can read either
    /// tracker via the same code path. Persistent — `minutesByDay`
    /// drives the Study dashboard's stats grid (today, this week,
    /// 7-day bar chart) and survives app restarts.
    @ObservedObject private var studyTracker = StudySessionTracker.shared

    /// Pomodoro-style countdown timer bound to the active Focus
    /// session. When `isActive`, the resting pill swaps the open-
    /// ended HH:MM:SS count-up for a MM:SS countdown so the user
    /// can glance at remaining time without opening the panel.
    /// Paused state shows the countdown frozen at the remaining
    /// value. Expired state falls through to the count-up label
    /// (the celebration card lives inside the dashboard).
    @ObservedObject private var focusTimer = SessionTimerService.focus

    /// Sibling timer for Study mode. Identical state machine and
    /// observation contract as `focusTimer` — driven by the Study
    /// dashboard's chip strip, persists separately in UserDefaults
    /// (`noxStudyTimerSnapshot`), fires its own `.studyTimerExpired`
    /// notification. The resting pill picks between the two based
    /// on `activePillMode` so a Study countdown shows up on the
    /// pill while Study mode is active.
    @ObservedObject private var studyTimer = SessionTimerService.study

    /// True when the resting pill should swap to the focus
    /// pill content (aura + timer). Fires for EITHER source:
    ///   • `noxFocusMode` — nox's own toggle
    ///   • `presenter.isFocused` — macOS Focus (auto-synced via
    ///     respectFocusMode default-true)
    /// Music takes priority — when `nowPlaying != nil`, the
    /// music pill keeps the slot. The tracker's `sessionStartDate`
    /// is NOT required here (timer falls back to a "Focus" label
    /// if it's briefly nil during a race) — without this fix,
    /// the small pill silently fell through to the old
    /// inline moon+timer block in `musicPillContent` whenever
    /// macOS Focus alone (without nox's own toggle) was the
    /// trigger.
    /// True when Focus mode is on AND no music is playing. In that
    /// case the dedicated focus pill (anime character + timer)
    /// replaces all other pill content. When music is also active,
    /// `combinedPillVisible` (below) takes over instead so both
    /// indicators are shown side-by-side in a wider pill.
    private var focusPillVisible: Bool {
        (noxFocusMode || noxStudyMode || presenter.isFocused)
            && presenter.nowPlaying == nil
    }

    /// True when BOTH Focus/Study AND music are active. Triggers
    /// the hybrid layout: artwork + waveform on the left, mode
    /// indicator + timer on the right. The pill's panel.frame
    /// also widens by `focusPillExtraWidth` (65pt) to fit both
    /// blocks (see PanelWindowController.closedPillFrame).
    /// 2026-05-09 user feedback: "when music and focus mode are
    /// togather let's get back the long pill like before." Study
    /// uses the same hybrid surface — different icon + timer,
    /// same width and layout.
    private var combinedPillVisible: Bool {
        (noxFocusMode || noxStudyMode || presenter.isFocused)
            && presenter.nowPlaying != nil
    }

    /// Which mode owns the active pill indicator. Drives the
    /// icon/timer pair across `focusPillContent` and
    /// `combinedPillContent` so the same surfaces render
    /// "Focus" vs. "Study" with one branch instead of duplicated
    /// view bodies.
    private enum ActivePillMode { case focus, study }
    private var activePillMode: ActivePillMode {
        // Study takes priority when both are on — it's the more
        // recently introduced explicit mode, so a user with both
        // toggled would have flipped study most recently.
        if noxStudyMode { return .study }
        return .focus
    }

    /// Cached on first appear so body re-evals don't poke
    /// NSScreen.main / safeAreaInsets every time. The morph itself
    /// no longer triggers per-frame body evals (see file-level note),
    /// so this is purely a defense-in-depth optimization for the
    /// content-fade transition.
    @State private var notchOverlap: CGFloat = PanelWindowController.notchOverlap(for: NSScreen.main)

    /// Height of the visible pill content area BELOW the menu bar.
    /// Matches `PanelWindowController.closedPillBump` (20pt — the
    /// locked Alcove-parity dimension). Pill body views render at
    /// this height in the visible drop-down zone, NOT at notchOverlap
    /// height in the menu-bar-overlap zone (which gets covered by
    /// physical notch hardware + menu-bar items).
    ///
    /// This is iPhone Dynamic Island's geometry: silhouette extends
    /// downward past the cutout, content lives in the visible area.
    private let pillContentHeight: CGFloat = PanelWindowController.closedPillBump

    /// Horizontal scale of the waveform inside `pillContentOverlay`.
    /// Held at 1.0 in steady state; pulses to 0.85 then springs back
    /// to 1.0 on every track change (see the `.onChange(of: trackKey)`
    /// in `pillContentOverlay`). Pairs with the artwork's vertical
    /// lift to give the pill a layered "the music moved forward"
    /// gesture that's distinct from Alcove's spin/flip on track change.
    @State private var waveformPulse: Double = 1.0

    /// Phase of the song-change vertical-lift animation on the
    /// pill artwork. 0 = at rest (anchor position, full alpha),
    /// negative = exiting upward (offset = phase * 4 → up to -4pt
    /// when phase = -1), positive = entering from below (offset =
    /// phase * 4 → down to +4pt when phase = +1). The artwork's
    /// blur and opacity follow `|phase|` (full blur + invisible at
    /// the extremes, sharp + opaque at 0). Driven by an explicit
    /// two-phase animation in `triggerSongChange` rather than
    /// SwiftUI's `.transition` because NSHostingView's animation
    /// context propagation through `.id()` boundaries is unreliable
    /// in this codebase — state-based phase control fires every time.
    @State private var trackSwapPhase: Double = 0

    /// Snapshot of the now-playing info that the pill artwork is
    /// currently DISPLAYING. Diverges briefly from `presenter.nowPlaying`
    /// during the song-change animation: while the old artwork is
    /// fading out, this still holds the OLD info so the fade-out
    /// shows the OLD image. After the fade-out completes, this is
    /// updated to the new info, and the fade-in shows the new image.
    /// Without this snapshot the fade-out would render the new image
    /// (since `presenter.nowPlaying` updates synchronously when the
    /// orchestrator forwards a new snapshot), defeating the
    /// "old → new" cross-fade entirely.
    @State private var displayedNowPlaying: NowPlayingInfo? = nil

    /// Mirrors `trackKey` but updated only after the song-change
    /// animation's fade-out completes — used as a sentinel so the
    /// `.onChange(of: trackKey)` handler can distinguish "first load"
    /// (no prior track) from "actual track change" (animate the swap).
    @State private var displayedTrackKey: String = ""

    /// Monotonically-increasing generation token for the song-change
    /// animation. Each call to `triggerSongChange` (or the music-ended
    /// branch) increments this and captures the new value into its
    /// asyncAfter closure; when the closure fires it bails out if the
    /// generation has been superseded by a later track change. Without
    /// this, rapid skips (A→B→C→D faster than the 0.58s animation)
    /// would let stale closures mutate `displayedNowPlaying` /
    /// `displayedTrackKey` / `trackSwapPhase` after the latest one has
    /// already settled, corrupting the visible state.
    @State private var trackSwapGeneration: Int = 0

    /// Sentinel for the "music has ever played in this session" state.
    /// Distinguishes a TRUE first-ever load (no animation — there's
    /// nothing to fade out from) from a music-restart-after-stop
    /// (should animate — conceptually a new track arriving). Without
    /// this, the music-ended branch's nil-out of `displayedNowPlaying`
    /// would route the next play through branch 2 (snap, no animation).
    @State private var hasEverDisplayedTrack: Bool = false

    /// Decoded NSImage for the currently-displayed artwork, looked
    /// up from `ArtworkCache`. nil when no artwork data is available
    /// yet (placeholder music.note shows in that case) or while a
    /// background decode is in flight. Refreshed whenever
    /// `displayedNowPlaying` changes — re-renders this state when
    /// the cache completes a decode.
    @State private var pillArtworkImage: NSImage? = nil

    /// 2026-05-04 (user feedback: "i can still see some lag when i am
    /// onto different tabs"): tab content was being re-mounted from
    /// scratch on every tab switch (because of the `.id(activeTab)`
    /// modifier on the content Group). Each tab is heavy — NotesListView
    /// has LazyVStack + ScrollView + composer; ImagesGridView has
    /// thumbnail loaders; VideosGridView has video previews. First
    /// instantiation on switch costs ~30-60ms which lands as visible
    /// jank.
    ///
    /// Solution: a "visited tabs" cache. The first time a tab becomes
    /// active, it gets added to this set. From then on, it stays mounted
    /// in a ZStack, hidden via opacity when inactive. Subsequent
    /// switches just fade between already-laid-out trees — instant.
    ///
    /// Memory tradeoff: each tab tree is ~few hundred KB of view state
    /// once mounted. A user who visits all 5 tabs holds all 5 alive
    /// for the lifetime of the panel. Negligible vs the user-facing
    /// smoothness gain.
    @State private var visitedTabs: Set<PanelTab> = [.notes]

    // (Motion-blur snapshot now lives on PanelPresenter, cached
    // by PanelWindowController after each settled state. Removed
    // the @State here — the previous attempt to re-render
    // `renderableContent` via ImageRenderer crashed because the
    // SwiftUI tree depends on @EnvironmentObject stack that
    // doesn't propagate into ImageRenderer's render context.)

    /// Live horizontal drag distance on the resting music pill,
    /// in points. Zero when no drag is in flight. Drives the
    /// artwork's `.offset(x:)` for visual feedback during a swipe
    /// and powers the "did the user actually intend a skip"
    /// threshold check on drag end. Capped to ±60pt so a drag
    /// far past the threshold doesn't feel like the artwork is
    /// going to slide off the pill — matches Alcove's haptic
    /// "tug" affordance.
    @State private var pillSwipeOffset: CGFloat = 0
    /// True once the in-flight drag has crossed the skip threshold,
    /// so the haptic only fires on the *first* threshold crossing
    /// of a single drag rather than every frame.
    @State private var pillSwipeArmedDirection: Int = 0   // -1 prev, 0 idle, +1 next

    /// Settings → Music → Swipe to skip. Read inline so a flip in
    /// Settings takes effect on the next gesture without any
    /// wiring. Default true — for users who haven't seen the
    /// setting, the gesture is the discoverable feature.
    private var pillSwipeEnabled: Bool {
        if UserDefaults.standard.object(forKey: "pillSwipeToSkip") == nil { return true }
        return UserDefaults.standard.bool(forKey: "pillSwipeToSkip")
    }

    /// Settings → Music → Natural swipe direction. Default true
    /// (left swipe = next track, matching macOS natural-scroll
    /// trackpad behavior). Read inline so flips in Settings take
    /// effect on the next gesture without re-mounting.
    /// 2026-05-17 sprint Session 2 — Alcove parity.
    private var naturalSwipeDirection: Bool {
        if UserDefaults.standard.object(forKey: SettingsKey.naturalSwipeDirection) == nil { return true }
        return UserDefaults.standard.bool(forKey: SettingsKey.naturalSwipeDirection)
    }

    /// Stable identity for the dictation pill content — used as
    /// `.id(...)` on the SwiftUI view so phase transitions trigger
    /// the bouncy `.pillPop` transition. Three discrete states map
    /// to three IDs; same-phase changes (audio level updates while
    /// `.recording`) keep the same ID and don't re-trigger the
    /// transition.
    private var dictationStateID: String {
        switch presenter.dictationPhase {
        case .idle: return "idle"
        case .recording: return "rec"
        case .transcribing: return "transcribing"
        case .error: return "err"
        }
    }

    /// Rubber-banded swipe offset for the resting pill. Maps the raw
    /// drag distance through a square-root-ish curve so that the
    /// pill follows the finger ~1:1 for the first ~10pt then tapers
    /// — past ~30pt it barely moves further. Caps at ±20pt absolute
    /// so the pill silhouette never visibly clears the notch
    /// rectangle. Earlier the offset was a direct `min(max(-20, dx), 20)`
    /// clamp, which felt rigid (the pill stops dead at the cap
    /// instead of resisting). Reads as Apple's standard rubber-band
    /// over-scroll behavior.
    private var rubberBandedSwipeOffset: CGFloat {
        let raw = pillSwipeOffset
        // Polynomial easing: out = sign(x) * (max * (1 - exp(-|x| / max)))
        // — a soft-clip toward `max` that never reaches it. Looks
        // smooth at all drag distances and bounded by `max`.
        let cap: CGFloat = 20
        let sign: CGFloat = raw >= 0 ? 1 : -1
        let magnitude = abs(raw)
        let eased = cap * (1 - exp(-magnitude / cap))
        return sign * eased
    }

    /// Two sides for the chevron overlay. Left chevron means
    /// "swiping left to commit previous"; right chevron means
    /// "swiping right to commit next."
    /// Format the duration since `start` as a tight pill-friendly
    /// label. Below an hour: `1m`, `12m`, `59m`. At/above an hour:
    /// `1h`, `1h 23m`, `12h 5m`. Ticks at minute granularity (driven
    /// by a 30s TimelineView so updates are at most ~30s late, which
    /// is fine for human-scale duration).
    ///
    /// `0m` for the first 60 seconds — shows `1m` only after the
    /// minute mark. Reads better than `0m` flickering for a half
    /// minute on first show.
    fileprivate func focusElapsedLabel(since start: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(start)))
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 1 {
            return "1m"
        }
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }

    private enum SwipeSide { case left, right }

    /// Chevron opacity ramps with how far the user has dragged
    /// past the 10pt minimum. Bright when armed (past threshold).
    /// Hidden completely when there's no drag in flight.
    private func swipeChevronOpacity(side: SwipeSide) -> Double {
        let dx = pillSwipeOffset
        // Right chevron only shows when dragging right (positive dx).
        // Left chevron only when dragging left (negative dx).
        let directional: Double
        switch side {
        case .left:  directional = dx < 0 ? Double(-dx) : 0
        case .right: directional = dx > 0 ? Double(dx) : 0
        }
        guard directional > 4 else { return 0 }   // dead-zone
        // Ramp from 0 → 0.5 over the 4–35pt drag range, then jump
        // to 1.0 once the threshold is crossed (signaled by the
        // armed direction matching this side).
        let armedSign = pillSwipeArmedDirection
        let isArmed = (armedSign == 1 && side == .right) ||
                      (armedSign == -1 && side == .left)
        if isArmed { return 1.0 }
        let ramp = min(0.5, (directional - 4) / 60.0)
        return ramp
    }

    /// Chevron scales up subtly when armed — same affordance as
    /// the macOS swipe-actions in Mail.
    private func swipeChevronScale(side: SwipeSide) -> Double {
        let armedSign = pillSwipeArmedDirection
        let isArmed = (armedSign == 1 && side == .right) ||
                      (armedSign == -1 && side == .left)
        return isArmed ? 1.18 : 1.0
    }

    /// Bottom-corner radius for the panel silhouette. 16pt when sitting
    /// at the resting closed-pill geometry (gives quarter-circle corners
    /// reading as a pill), 34pt when expanded into the slab (subtle
    /// squircle reading as a HUD card). SwiftUI animates this via the
    /// chained `.animation(.easeOut(duration: 0.18), value: presenter.isShown)`
    /// modifier on the parent — `UnevenRoundedRectangle` interpolates
    /// `RectangleCornerRadii` continuously, so the corners morph in
    /// lockstep with the panel-frame morph driven by Core Animation.
    /// During the ~450ms expand animation the SwiftUI radius animation
    /// (0.18s) lands first, but the corners are barely visible during
    /// the early part of the morph (panel still close to pill size, so
    /// the bottom edge fills the visible silhouette regardless of
    /// radius) — the visual handoff reads as one continuous shape change.
    private var panelBottomRadius: CGFloat {
        if presenter.isShown {
            return PanelWindowController.innerCornerRadius
        }
        // Track-change OR volume HUD banner: softer/more rounded
        // bottom corners (14pt) — measured against Alcove frames
        // 800/850 where the banner has a noticeably more
        // pronounced bottom curve than the resting music pill's
        // 8pt. Goes back to 8pt when the banner retracts (event
        // clears → falls through to the music-pill case below).
        // Volume HUD shares this character so both "live activity"
        // banners read as one family.
        if case .volumeChanged = presenter.pendingSystemEvent {
            return 14
        }
        // Music-playing state: 14pt bottom radius UNCONDITIONALLY.
        //
        // At rest the silhouette has `closedPillBump = 0` (no visible
        // portion below the menu bar), so the bottom corners are
        // entirely behind/at the menu-bar boundary — INVISIBLE.
        // Changing 8 → 14pt has no perceptible effect on the resting
        // pill (locked dimensions per user 2026-05-05).
        //
        // During the trackChanged announcement, the apron drops 30pt
        // below the menu bar, exposing the bottom corners — and this
        // is exactly when the user wants to see "more narrow" / more
        // pronounced bottom curve (Alcove parity, user feedback
        // 2026-05-07: "corners in down side is more narrow"). Because
        // the radius value is the same in both states, SwiftUI never
        // animates it — only the panel.frame morphs, no clip-shape
        // transition that could "cut" the previous pill's edges.
        if presenter.nowPlaying != nil {
            return 14
        }
        // No music: notch hardware character (6pt rounded bottom).
        return 6
    }

    /// Inverse-bow shoulder radius at the top corners — drives the
    /// concave "S-curve" where the slab tucks under the menu bar.
    ///
    /// User direction (multiple rounds): "we need the shape while
    /// closing exactly like apple macbook notch does have." The
    /// MacBook Pro notch hardware is a rectangle with SHARP 90° top
    /// corners (where it meets the screen edge bezel) — no flares,
    /// no shoulders. Any non-zero topR gives the silhouette an
    /// inverse-bow "shoulder" that DURING THE CLOSE morphs through
    /// intermediate values which read as triangular wedges as the
    /// rect shrinks (the inverse-bow eats a percentage of width that
    /// grows as width shrinks).
    ///
    /// Setting topR=0 EVERYWHERE — open slab and closed states alike
    /// — gives the entire app one consistent shape language: a
    /// rectangle with sharp 90° top corners and rounded bottom
    /// corners. Just like the actual notch hardware. The slab
    /// becomes "a giant notch shape" growing out of the actual notch.
    /// Close is just that same shape shrinking to actual-notch size.
    /// No interpolation through wedge geometry, ever.
    ///
    /// (Music pill is unchanged at 6pt for now — locked dimensions
    /// per user memory: "do not tweak the unified resting pill".)
    private var panelTopRadius: CGFloat {
        // Slab open: 22pt inverse-bow shoulder — restored 2026-05-05.
        // User noted the slab was rendering with sharp edges at the
        // top corners, missing the smooth shoulder curve that flows
        // into the menu bar. The 22pt inverse-bow gives the slab
        // its signature "tucks under the menu bar" look.
        if presenter.isShown {
            return 22
        }
        // Track-change banner: KEEP the resting music pill's top
        // radius unchanged (6pt). Same reasoning as panelBottomRadius
        // — animating the radius from 6 → 12 on a separate SwiftUI
        // clock while the panel.frame Core-Animation spring runs
        // produced a visible "edge cut" at the resting pill's top
        // corners. Falling through to the music-pill case keeps the
        // shoulder character consistent throughout the expansion.
        // Volume HUD keeps its own 12pt because its banner geometry
        // is still being tuned separately.
        if case .volumeChanged = presenter.pendingSystemEvent {
            return 12
        }
        // Music-playing resting state: 6pt subtle chamfer (locked
        // music pill character, do not tweak).
        if presenter.nowPlaying != nil {
            return 6
        }
        // No-music closed (notch-hidden): 4pt subtle shoulder.
        // 2026-05-06 measured against Alcove: their `NotchShape`
        // class uses dynamic corner radii on BOTH ends in the
        // empty state, giving a subtle pill character at rest
        // and through the tease morph. Previously this returned
        // 0 (sharp 90° corners) to match the hardware notch
        // exactly, but the resulting tease read as "a black
        // rectangle widening" instead of "a pill flexing" — user
        // feedback: "still getting wider instead of that gentle
        // eye view." The hardware-notch feel was a pyrrhic win:
        // perfect at rest, broken on hover.
        //
        // 4pt is subtler than the music pill's 6 (so the no-music
        // pill still reads as smaller / less prominent than music),
        // but enough that the tease grow from 185→200pt looks like
        // a soft pill flexing instead of a sharp-cornered widening.
        return 4
    }

    // MARK: - Body

    var body: some View {
        // Outer transparent halo + inner silhouette structure. The
        // NSPanel's frame is `(inner + 2×halo) × (inner + halo)` — the
        // SwiftUI tree here insets by `haloPadding` on left/right/bottom,
        // so the visible silhouette occupies the inner area and the
        // outer halo is transparent space for the shadow to bleed into.
        // Without that bleed area the SwiftUI `.shadow` modifier just
        // gets clipped by the rectangular NSPanel boundary and the panel
        // reads as a pasted-on rectangle — the user described this
        // exactly: "no dropshadow (liquid blur)".
        //
        // The earlier multi-stop gradient + plusLighter-blended notch
        // sheen looked too "lifted" — the user said the new design
        // looked worse and that "black was definitely the choice." The
        // fix is the Alcove vocabulary: solid pure black for the slab
        // (the premium-feeling surface they want), and the depth comes
        // from a quiet rim around the silhouette + a generous luminous
        // drop shadow that escapes into the haloPadding margin.
        //
        // Layer stack (bottom → top):
        //   1. `panelBackground`: solid `Color.black`
        //   2. `contentOverlay`: the actual UI (header/tabs/content)
        //   3. `borderStroke`: subtle 0.5pt rim around the silhouette
        //   4. `dropRingOverlay`: drag-and-drop accent ring (existing)
        // The two `.shadow` calls below stack: a TIGHT dark ground-shadow
        // (close, slightly offset down) for the contact tell, plus a
        // WIDE soft halo (large radius, lower opacity) for the floating
        // glow — same recipe Alcove uses to feel "set into the desktop"
        // rather than "stamped onto" it.
        panelBackground
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(panelSilhouette)
            // OPAQUE BLACK NOTCH BAND. ALWAYS-RENDERED (no
            // `if presenter.isShown` gate) so it doesn't fade
            // in during the open morph. Earlier the band was
            // gated and the `withAnimation(.easeInOut(0.45))`
            // wrapping `presenter.isShown = true` applied an
            // implicit insertion fade — for the first ~200ms
            // of the open, the band was at partial opacity and
            // the panel's vibrancy background let the desktop
            // wallpaper bleed the top with hue. User saw it
            // as "light coming from the notch for a few
            // milliseconds during the open."
            //
            // Always-rendered means: when the panel is in pill
            // state (isShown=false), the band is still here at
            // full opacity. The panelBackground is also pure
            // Color.black in that state, so the band is
            // visually a no-op (black on black). When the
            // panel grows to slab and panelBackground becomes
            // translucent (VisualEffectBlur + 65% black), the
            // band is ALREADY at full opacity from frame zero
            // — no crossfade window, no wallpaper leak.
            //
            // LinearGradient with hard black at top, soft fade
            // at the bottom edge so the band-to-content
            // transition reads as continuous gradient, not a
            // visible seam.
            //
            // Height = notchOverlap + 36pt covers the hardware
            // notch (~32-37pt safe-area-inset) plus a fade tail
            // that meets the artwork gradient cleanly.
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: Color.black, location: 0.0),
                        .init(color: Color.black, location: 0.55),
                        .init(color: Color.black.opacity(0.7), location: 0.75),
                        .init(color: Color.black.opacity(0.0), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: notchOverlap + 36)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
            // artworkTopGradient overlay REMOVED per user request:
            // "remove the gradient from the thing and make it deep
            // black. And gradient will be only in song timeline,
            // play button, next button and the audio visualizer."
            // The slab background is now solid black; the album-
            // color tint lives only on the interactive controls
            // (progress bar fill, transport button accents, and
            // the visualizer bars). Function `artworkTopGradient`
            // is kept defined below in case we want to reintroduce
            // ambient lighting later, but it's no longer wired in.
            .overlay(alignment: .top) {
                // Pill artwork+waveform overlay — ONLY rendered when
                // the slab is closed. With opacity-only hiding the
                // SwiftUI render still includes the (invisible)
                // overlay in the layout pass, and at certain
                // intermediate animation states the blur kernel
                // could leak a faint silhouette at the top of the
                // slab — what the user described as "see a little
                // blurred bump there?". Removing the view from the
                // tree entirely when the slab is open guarantees
                // zero leakage.
                //
                // Per "still feeling like a little gradient at the
                // top while opening for a millisecond" feedback:
                // when `isShown` flips true (wrapped in
                // `withAnimation(.easeInOut(0.45))`), this
                // conditional removal was being animated as a fade
                // — the small album-art tile + waveform stayed
                // visible at the top of the growing slab for the
                // first 200+ms of the morph, which read as a
                // brief color flash at the top. Use
                // `.transition(.identity)` + an explicit
                // `transaction { animation = nil }` wrapper so the
                // removal is INSTANT regardless of the parent
                // animation context. The pill content vanishes
                // the moment isShown flips true; the slab grows
                // over a clean black panel from frame zero.
                Group {
                    if !presenter.isShown {
                        pillContentOverlay
                            .transition(.identity)
                    }
                }
                .transaction { txn in txn.animation = nil }
            }
            .overlay(alignment: .top) {
                /*  Inner content blur during the close gesture.
                    Lives INSIDE the overlay (so it only blurs the UI
                    inside the silhouette, not the silhouette outline
                    itself) but the .scaleEffect on the panel root
                    below scales the silhouette + content + border
                    together as a unit.

                    Why blur is here, not on the panel root:
                    A blur applied to the WHOLE composition convolves
                    the silhouette's top edge with surrounding
                    transparent pixels, creating a soft halo that
                    bleeds AROUND the notch hardware (the hardware
                    masks crisp edges but not blurred halos). User
                    reported it as "the thing is detaching from the
                    top." Existing comment at the silhouette layer
                    documents the same pattern: "it's only the
                    CONTENT inside that blurs, not the silhouette
                    outline."

                    .interactiveSpring tracks live target value, no
                    one-shot; same params as the root scaleEffect so
                    blur and scale move on the same beat. */
                contentOverlay
                    .blur(radius: presenter.swipeProgress * 18)
                    .animation(
                        .interactiveSpring(
                            response: 0.32,
                            dampingFraction: 0.74,
                            blendDuration: 0.18
                        ),
                        value: presenter.swipeProgress
                    )
            }
            // Two-zone drop picker overlay — visible only while a
            // drag is hovering the panel. Splits the slab into Save
            // (left) and AirDrop (right) zones; the AppKit drop
            // layer (PanelDropContainer) flips
            // `dropPickerHoveredZone` based on cursor X-position so
            // this overlay highlights the hot zone in real time.
            // The zone-routing decision lives in
            // `PanelDropContainer.performDragOperation`.
            //
            // Padded to inset from the silhouette's curved corners
            // (notchOverlap on top to clear the menu bar zone,
            // panelTopRadius on the sides to match the slab body).
            .overlay {
                // 2026-05-04 ALWAYS-MOUNTED. The previous gated form
                // (`if presenter.dropPickerActive && presenter.isShown
                // { DropPickerView(...) }`) caused a fresh SwiftUI
                // mount on every single drag-enter event — confirmed
                // in /tmp/notetaker-dictation.log by recurring
                // `🎨 DropPickerView.onAppear` lines paired with
                // morph entries at avgDt=30ms (3× slower than the
                // 10ms baseline). Heavy SwiftUI tree reconciliation
                // + the panel.frame morph triggered by isDropTargeted
                // were colliding on the main thread, choking the
                // spring tick.
                //
                // Always-mounted moves the mount cost to app launch.
                // Drag enter/exit then becomes just an opacity +
                // scale flip animated by Core Animation — same trick
                // we used for contentOverlay and VisualEffectBlur.
                DropPickerView(
                    hoveredZone: presenter.dropPickerHoveredZone,
                    fileCount: presenter.dropPickerFileCount,
                    accent: panelAccent
                )
                    // Picker fills the ENTIRE silhouette edge-
                    // to-edge — no padding. The panelSilhouette
                    // clip catches the rounded corners and notch
                    // cutout so the picker's two halves inherit
                    // the panel's shape automatically.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(presenter.dropPickerActive && presenter.isShown ? 1 : 0)
                    .scaleEffect(presenter.dropPickerActive && presenter.isShown ? 1.0 : 0.97)
                    .allowsHitTesting(false)  // AppKit layer handles drops
                    .animation(.easeOut(duration: 0.18),
                               value: presenter.dropPickerActive && presenter.isShown)
            }
            .overlay { borderStroke }
            // Re-clip the entire stack (background + every overlay)
            // to the panel silhouette. Without this, scrollable
            // content like the Images grid paints over the rounded
            // bottom-corner regions, making the panel look like it
            // has a square bottom against the desktop. The background
            // alone is already clipped above; the second clip here
            // catches the overlays that ride on top of it.
            .clipShape(panelSilhouette)
            // Drop ring rendered AFTER the clip so the outer halo
            // (the most visually impactful layer) extends OUTSIDE
            // the silhouette and isn't chopped off. Without this
            // ordering the user just saw a faint "light in the
            // back" because only the inner edge of the stroke was
            // surviving the clip.
            .overlay { dropRingOverlay }
            // Whole-pill reaction. When a transient pill event
            // fires (screenshot, note saved, charging, download),
            // the silhouette itself briefly puffs ~3.5% larger
            // and gets a soft event-tinted glow. Reads as the
            // pill "responding" to the event, not just the inner
            // content rearranging. Only fires on event-CASE
            // changes (not associated-value changes) so a burst
            // screenshot count tick doesn't re-puff per shot.
            .modifier(PillSilhouetteReact(
                caseKey: pillEventCaseKey,
                glowColor: pillReactColor,
                // Suppress puff/glow for trackChanged AND
                // volumeChanged — the panel's grow-into-banner
                // geometry change IS the visual announcement; a
                // tinted glow on top would read as a notification
                // firing rather than the activity expanding. Volume
                // also re-fires on every key-press tick; a per-tick
                // puff would strobe.
                suppressReact: {
                    if case .trackChanged = presenter.pendingSystemEvent { return true }
                    if case .volumeChanged = presenter.pendingSystemEvent { return true }
                    return false
                }()
            ))
            // ── Two-finger trackpad close-swipe feedback (Alcove parity)
            //
            // SCALE applied to the WHOLE panel composition
            // (panelBackground + every overlay + borderStroke +
            // dropRingOverlay + the silhouette puff modifier above)
            // so the silhouette + border + content all retract
            // together as one unit. anchor: .top welds the top edge
            // to the notch hardware — bottom rises while top stays
            // fixed → reads as the pill retracting INTO the notch.
            //
            // BLUR is NOT applied here — it lives inside the
            // `.overlay { contentOverlay … }` block above so it only
            // blurs inner UI, not the silhouette outline. A blur on
            // the whole composition convolves the silhouette's top
            // edge with surrounding transparent pixels, producing a
            // soft halo that bleeds AROUND the notch hardware (the
            // hardware masks crisp edges but not blurred halos).
            // User reported that exact symptom: "the thing is
            // detaching from the top." The codebase already
            // documented this at the silhouette comment line:
            // "it's only the CONTENT inside that blurs, not the
            // silhouette outline."
            //
            // NO .offset(y:) on the panel composition either. An
            // earlier rev applied `.offset(y: -swipeOffsetY)` to the
            // root, which physically translated the silhouette
            // upward, lifting the top edge AWAY from the notch.
            // Alcove keeps the top welded — only the bottom recedes
            // upward, achieved through scale-from-top alone.
            //
            // Alcove's binary exposes `SlideBlurScaleModifier` and
            // `VerticalOffsetModifier` as separate ViewModifiers —
            // VerticalOffsetModifier is for things that DO translate
            // (spawn-from-notch, cycle-activity slide-out, etc.); the
            // close gesture uses the SlideBlurScaleModifier whose
            // "slide" component is the scale-from-top motion (top
            // edge fixed, height contracts upward → bottom slides
            // up). It is NOT a translation of the whole panel.
            //
            // ELASTIC FEEDBACK lives in the scale magnitude. Two
            // contributions sum:
            //   • swipeProgress × 0.04 — at-threshold pinch (4%)
            //   • clamped(swipeOffsetY / 100) × 0.05 — elastic pull
            //     factor; the more the user keeps pulling past the
            //     threshold, the more the silhouette pinches in.
            // Combined max ≈ 9% shrink at the rubber-band cap.
            //
            // .interactiveSpring tracks the live target value
            // continuously (not a one-shot animation) — when the
            // gesture handler updates the value tick-by-tick, the
            // spring re-targets without restarting, giving the
            // elastic finger-tracking feel. When the gesture ends and
            // the values reset to 0, the same spring carries them
            // home with natural ease-out smoothing in the decay tail.
            //
            //   response 0.32  ≈ 320ms settle (reactive but reads as
            //                    elastic, not snappy)
            //   damping  0.74  slight bounce, adds liveliness
            //   blendDur 0.18  smooths over discrete tick-to-tick
            //                    finger samples
            //
            // Placed BEFORE `.padding(.horizontal/.bottom, haloPadding)`
            // and `.ignoresSafeArea` so the panel window's halo region
            // stays fixed in place — only the visible silhouette
            // pinches inward toward the notch.
            .scaleEffect(
                1.0
                    - presenter.swipeProgress * 0.04
                    - min(presenter.swipeOffsetY / 100, 1.0) * 0.05,
                anchor: .top
            )
            .animation(
                .interactiveSpring(
                    response: 0.32,
                    dampingFraction: 0.74,
                    blendDuration: 0.18
                ),
                value: presenter.swipeProgress
            )
            .animation(
                .interactiveSpring(
                    response: 0.32,
                    dampingFraction: 0.74,
                    blendDuration: 0.18
                ),
                value: presenter.swipeOffsetY
            )
            .padding(.horizontal, PanelWindowController.haloPadding)
            .padding(.bottom, PanelWindowController.haloPadding)
            .ignoresSafeArea(.all, edges: .top)
            // Single-axis state animation: content opacity, shadow
            // params, AND the bottom-corner radius interpolation
            // (UnevenRoundedRectangle's `RectangleCornerRadii` is
            // animatable) all run on this one timeline. Frame morph
            // is driven separately at the NSPanel level via Core
            // Animation (see PanelWindowController.animateOpen).
            //
            // `.smooth` is SwiftUI's interpolating-spring preset —
            // settled landing, no overshoot. Same Animation value
            // Alcove uses (the literal `smooth` is in their binary
            // alongside damping/stiffness symbols), and it gives the
            // radius morph a calmer, more "premium hardware" feel
            // than a linear ease-out on the corner shape.
            // `.bouncy` gives the corner-radius interpolation a
            // slight overshoot — the bottom corners briefly round
            // Direction-aware animation. Numbers MUST mirror the
            // PanelWindowController NSPanel-frame springs so the
            // SwiftUI-side properties (corner radius, content opacity,
            // shadow params) finish on the same beat as the window
            // geometry. Mismatch = silhouette settles at one duration
            // while panel frame is still morphing → user sees
            // "endpoint not landing."
            //
            // SwiftUI radii animation — overdamped, matches the
            // frame spring's ~362ms duration without overshoot.
            //
            // Frame spring (in PanelWindowController) is 182/22
            // (ratio 0.815, ~1.2% overshoot — subtle bloom).
            // Radii spring (here) is 167/28 (ratio 1.083, no
            // overshoot, ~362ms settle). Both finish on the same
            // beat so the silhouette lands together with the frame.
            //
            // Why radii doesn't bounce even though frame does:
            // OutwardFlaredShape's path clamps `max(0, topR)` —
            // when the spring overshoots to negative, the rendered
            // value is clipped to 0 while bottomR still shows its
            // positive overshoot. That asymmetry was the "weird
            // shapes during bounce" the user reported earlier.
            // Keeping radii strictly overdamped avoids this.
            //
            //   FRAME: 182/22  ratio≈0.815  ~1.2% bloom  ~364ms
            //   RADII OPEN:  167/28  ratio≈1.10  clean   ~362ms
            //   RADII CLOSE: 100/22  ratio≈1.10  clean   ~440ms
            // Radii snap quickly to slab character on open (~120ms)
            // while frame grows slowly (~286ms). User 2026-05-05:
            // "when opening the big pill it's getting into another
            // shape first before going into full pill" — was caused
            // by radii animating from music-pill character (6, 8)
            // to slab character (22, 34) at the SAME RATE as the
            // frame, making mid-open shapes match neither icon.
            //
            // Now: radii reach slab character within ~120ms while
            // frame is still ~40% grown. Remaining ~166ms shows the
            // panel growing in slab character throughout — no more
            // transitional "wrong" shape phase.
            //
            //   OPEN radii:  1000/65 (overdamped, ~120ms settle)
            //   CLOSE radii: 158/25 (Apple .smooth(0.50), ~320ms)
            .animation(presenter.isShown
                       ? .interpolatingSpring(mass: 1.0, stiffness: 1000, damping: 65, initialVelocity: 0)
                       : .interpolatingSpring(mass: 1.0, stiffness: 158, damping: 25, initialVelocity: 0),
                       value: presenter.isShown)
            // ALSO animate the corner radii when pendingSystemEvent
            // changes (e.g. .volumeChanged → nil). Without this, the
            // radii pop INSTANTLY from banner character (14, 12) to
            // music pill character (8, 6) while the panel.frame is
            // still morphing — visible as an inside "glitch" during
            // the volume HUD dismiss. Using the SAME timingCurve as
            // the panel.frame morph so radii lerp in lockstep with
            // the frame interpolation.
            .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.40),
                       value: pillEventCaseKey)
            // 2026-05-04 (user feedback after Alcove SS audit:
            // "the dropshadow only comes when you open... but
            // doesn't last"): smooth the shadow radius transition
            // when isMorphing flips. Previously the radius jumped
            // 6/12 → 18/36 instantly at settle (no animation
            // modifier on this value), which read as "shadow pops
            // to a different size mid-frame" → user perceived as
            // "shadow disappears." Animating the change makes the
            // shadow GROW smoothly into its settled radius
            // matching how Alcove's shadow grows with the
            // silhouette throughout the open (visible in SS
            // frames 215-285 of their reference recording — the
            // shadow is continuously visible, never popping).
            // 0.22s easeOut tracks the panel.frame settle so the
            // shadow finishes "growing into" its full radius
            // about 200ms after the spring settles.
            // EXACT cubic-bezier match to the panel-frame morph
            // (0.32, 0.72, 0, 1) — same out-quint Apple uses.
            // Lockstep with silhouette + content swap, no curve
            // mismatch.
            .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.40),
                       value: presenter.isMorphing)
            .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
            // Inject the slab's dynamic accent into the SwiftUI
            // environment. Every descendant view (MusicPanelView,
            // ScriptsView, Focus/Study detail panels, etc.) can
            // read it via `@Environment(\.panelAccent)` to get the
            // music-driven color (with brand lavender fallback)
            // instead of the static `DS.Color.accent`. One inject
            // point, every accent across the slab follows.
            .environment(\.panelAccent, panelAccent)
            // PERF GATE: both shadows render only when isShown=true.
            // During the morph itself both radii are 0 — SwiftUI's
            // `.shadow` is a CPU-side gaussian convolution whose cost
            // grows with radius² × surface area, so radius 0 is
            // essentially free. The fade-in / fade-out is driven by
            // the `.animation` modifier above.
            //
            // Two-shadow stack: contact + halo. The contact shadow
            // (tight, dark, slightly offset) reads as the panel
            // pressing down toward the desktop. The halo (wide, dim)
            // is the "liquid blur" the user described — a soft
            // luminance bleed all around the silhouette, not just at
            // the bottom.
            // SUBTLE shadow stack — radii drop during morph to
            // shed CPU gaussian cost. SwiftUI `.shadow()` is a
            // CPU-side gaussian convolution whose cost scales
            // with surface area × radius²; on every spring tick
            // during the open morph, two big-radius shadows were
            // re-running and dropping frames. Shrinking them to
            // ~50% during the morph and snapping back when the
            // spring settles keeps the visual "lift" in steady
            // state without paying for it per frame.
            // Shadow values reverted to the original stacked
            // pair on 2026-04-29 user request ("don't touch the
            // shadow"). My optimization passes were not the
            // source of the visible 2-layer artifact, and the
            // single-shadow / smaller-radius experiments
            // changed the depth feel without fixing the bug.
            // Original values from the last known-good
            // production build, preserved:
            // 2026-05-04 KEEPER FIX: SwiftUI .shadow() REMOVED.
            // Shadow now drawn by panel.contentView's CALayer with
            // shadowPath set to the silhouette CGPath. The
            // diagnostic confirmed SwiftUI's .shadow() was the
            // residual lag cause — drops clustered at fraction
            // 0.85-1.00 disappeared when shadow was disabled.
            //
            // Implementation in PanelWindowController:
            //   • silhouetteCGPath() — mirrors OutwardFlaredShape
            //     in raw CGPath form for shadowPath
            //   • updateShadowPath() — rebuilds + assigns the path
            //     wrapped in a CATransaction with disabled actions
            //   • updateShadowAppearance() — animates shadowOpacity
            //     0 ⇄ 0.55 on isShown changes
            //   • shadowTickHandler on SpringFrameAnimator — fires
            //     updateShadowPath() each spring tick so the shadow
            //     follows the morphing panel.frame in real time
            //
            // Documented 50-80% perf gain per CALayer docs:
            // shadowPath skips the offscreen alpha-analysis pass
            // SwiftUI's .shadow() was forcing every frame.
    }

    // MARK: - Slab blur gating

    /// Whether the slab content's 4pt focus-pull blur should fire
    /// during the current morph. True only for the OPEN/CLOSE morphs
    /// that are about the slab itself (pill ↔ slab transition);
    /// false during pill-state morphs that are about other content
    /// (volume HUD expand/dismiss, track banner, etc.).
    ///
    /// The slab content is at opacity 0 during pill state, so the
    /// blur is invisible — but SwiftUI still renders the Metal
    /// gaussian, which competes with the panel-frame spring on the
    /// main thread. Skipping it for volume HUD specifically means
    /// the close animation stays clean and matches Alcove (no
    /// focus-pull during the volume HUD dismiss).
    private var shouldBlurSlabDuringMorph: Bool {
        if presenter.isShown { return false }
        if !presenter.isMorphing { return false }
        // Skip during volume HUD lifecycle — Alcove parity.
        if case .volumeChanged = presenter.pendingSystemEvent { return false }
        return true
    }

    // MARK: - Cascade animation curve

    /// Snappy spring with a defined endpoint — bounce in the motion
    /// phase, clean settle at the duration boundary, no sub-pixel
    /// tail. Used by the cascade modifiers in renderableContent and
    /// MusicPanelView. Apple's WWDC23 `.snappy` preset is designed
    /// exactly for this; fallback for macOS 13 uses an interpolating
    /// spring tuned to the same character (≈10% bounce, ~360ms).
    private var cascadeAnimation: Animation {
        if #available(macOS 14.0, *) {
            return .snappy(duration: 0.32, extraBounce: 0.15)
        } else {
            // ω_n=18.7, ratio=0.59 → ~10% overshoot, ~360ms settle
            return .interpolatingSpring(mass: 1.0, stiffness: 350, damping: 22)
        }
    }

    // MARK: - Content overlay (header / segmented / grid)

    @ViewBuilder
    private var contentOverlay: some View {
        // ALWAYS-MOUNTED. The previous gated form (`if presenter.isShown
        // { ... }`) made the heavy content tree (NotesListView + image/
        // video/file grids + composer + LazyVStack + ScrollView + drag-
        // and-drop wiring + @FocusState scaffolding) un-mount and re-
        // mount on every show / hide cycle. Even after we deferred the
        // mount until AFTER the panel morph finished (so the morph
        // itself ran cleanly over an empty Color.black slab), the
        // 30-50ms SwiftUI mount + initial layout still landed AS A
        // VISIBLE HITCH right after the recoil settled — the user
        // perceived the gap between "panel arrived" and "content
        // visible" as lag. Reported across multiple iterations as
        // "much better than before but still lagging."
        //
        // Always-mount amortizes the mount cost to app launch, where
        // there's no animation competing for main-thread time and the
        // user can't see it. show() / hide() then just toggles the
        // opacity, which Core Animation can render on a single
        // CALayer alpha update — essentially free.
        //
        // Trade-off: the content tree IS evaluated when the panel is
        // hidden (e.g. @Published changes still trigger body re-evals
        // in mounted children). That's why we use `.opacity(0)` rather
        // than `.hidden()`: opacity-0 keeps layout stable but the
        // SwiftUI render path skips painting transparent fragments
        // entirely. LazyVStack inside ScrollView is lazy by definition
        // and only materializes visible cells, so the hidden cost is
        // dominated by the wrapper views (header, segmented, divider,
        // active-tab content frame), all of which are cheap to keep
        // around. ImagesGridView's thumbnail loader gates work on
        // `presenter.isShown` upstream so it doesn't decode JPEGs in
        // the background.
        //
        // `.allowsHitTesting(presenter.isShown)` ensures the invisible
        // content can't intercept clicks. Without this, a click that
        // landed in the closed-pill region while the panel is hidden
        // could be eaten by an invisible search-bar TextField or
        // segmented-control button.
        renderableContent
        // Push UI below the menu-bar zone. The top `notchOverlap`
        // points of the panel are hidden behind the notch /
        // menu-bar strip; we offset visible widgets down by exactly
        // that amount so the header lands flush below the bar.
        .padding(.top, notchOverlap)
        // Inset content horizontally by `panelTopRadius` so it
        // fits inside the silhouette's body (which is itself
        // inset by `topR` from the rect on each side — see
        // OutwardFlaredShape). Without this padding, content
        // extends to the panel's full width and gets clipped
        // by the silhouette mask at the inverse-bow shoulder
        // curves on each top corner. User: "the contents inside
        // of it ... are out of the place." 22pt on each side
        // when the slab is open, 6pt when the pill is at rest;
        // the value tracks `panelTopRadius` so the inset
        // animates in lockstep with the silhouette morph.
        .padding(.horizontal, panelTopRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // CRITICAL: compositingGroup MUST come before blur so the
        // blur is applied to a flattened single layer instead of
        // to each subview independently.
        .compositingGroup()
        // Hide the regular slab content entirely while the two-zone
        // drop picker is active, so the picker is unambiguously the
        // only thing the user sees during drag. The black panel
        // background (panelBackground) stays underneath so the
        // silhouette is intact.
        .opacity(presenter.isShown ? (presenter.dropPickerActive ? 0 : 1.0) : 0)
        .animation(.easeOut(duration: 0.18), value: presenter.dropPickerActive)
        // REVERTED the asymmetric fade-with-delay attempt. The 0.15s
        // delay between "silhouette grows" and "content fades in"
        // was meant to mirror NotchNook's two-stage reveal, but in
        // practice the empty-silhouette window read as "panel is
        // broken" — the user caught it mid-open in a screenshot
        // and reported "what the fuck is this." Without the delay,
        // content fades alongside the panel's open spring (parent
        // withAnimation context), and the eye never sees a
        // visibly-empty slab. Preferable feel.
        // Progressive-blur materialization. When the panel is closed
        // (or morphing toward closed), the content tree is rendered
        // with a 10pt gaussian blur; as `presenter.isShown` flips true
        // the blur animates to 0 alongside the parent's `.smooth`
        // animation. The user sees the header / segmented bar / list
        // dissolve INTO focus rather than fade in flat — same
        // "progressive blur" effect Alcove ships (its binary contains
        // a `progressiveBlurTransitionTask` symbol). The 10pt radius
        // is heavy enough to feel like the content is materializing
        // (not just appearing), but light enough that mid-morph reads
        // are still legible — typography stays decipherable through
        // the blur, so the transition feels like a focus pull rather
        // than a fog-of-war reveal.
        //
        // SwiftUI's `.blur` runs as a Metal filter on the off-screen
        // The content fade is opacity-only now. The previous
        // `.blur(radius: 10 → 0)` ran a GPU gaussian blur over the
        // entire content overlay (notes/images/grids) for every
        // frame of the open morph — measured to be the dominant
        // cost in the per-frame budget once shadows + halo were
        // already deferred. Dropping it eliminates the per-frame
        // blur kernel entirely; we still get a soft focus-in
        // visually because the opacity 0→1 transition with
        // `compositingGroup` lets Core Animation handle the fade
        // as a single layer alpha, no SwiftUI re-rasterization.
        //
        // Elastic content scale tied to the panel's open spring.
        // Without this the transport row + source badge looked
        // "stiff plastic" while the panel walls were jelly-
        // bouncing around them. Scaling the entire content
        // overlay with a spring matched to the panel's frame
        // morph means everything inside breathes WITH the
        // panel: 0.86 compressed when closed → 1.0 with two
        // visible bounces when opening, matching the panel's
        // 11.4% / 1.30% rhythm.
        //
        // SwiftUI mapping for panel's stiffness 200 / damping 16
        // (ω_n = 14.14, period = 0.444s, ratio = 0.566):
        //   response = 0.44s (matches panel's natural period)
        //   dampingFraction = 0.566 (matches ratio)
        // Both springs share ω_n and ratio so they trace the
        // same elastic curve at the same rate — content and
        // walls settle in lockstep, no two-stage stop.
        // PROGRESSIVE BLUR on content materialization (re-added).
        // Per direct frame-by-frame audit of NotchNook's open
        // animation (Built-in Retina Display 0930→0940→0960):
        //   • frame 0930: silhouette growing, content invisible
        //   • frame 0940: silhouette at full width, CONTENT HEAVILY
        //     BLURRED (~10-12pt gaussian) — purple album-art blob,
        //     unreadable text, faint shapes
        //   • frame 0960: silhouette settled, content fully sharp
        //   • Same pattern in reverse on close (frame 1340).
        // This is the "gentle materialization" the user asked for —
        // content doesn't pop in flat, it comes into focus through
        // a soft gaussian dissolve.
        //
        // 40pt radius — heavily bumped per direct frame audit of
        // jackson-storm/DynamicNotch's BlurFadeModifier (ships
        // blur: 40 for the active/closed state) and the user's
        // repeated feedback that 12pt and 20pt "couldn't be felt."
        // 40pt produces a clearly visible "frosted glass / out of
        // focus" state — content is recognizable as colored shapes
        // but text and details are illegible until the spring
        // settles. Reads unambiguously as a focus-pull, not a
        // micro-smear.
        //
        // The blur transition uses a SLOW HIGH-DAMPING SPRING
        // (response: 0.52, dampingFraction: 0.8) — adopted from
        // jackson-storm's "balanced" preset. Why this matters:
        //   • easeInOut is symmetric — at t=0.5 of duration,
        //     blur is at radius 20 (perception threshold), so
        //     half the animation runs with imperceptible blur.
        //   • A high-damping spring concentrates ~70% of its
        //     visible time near the start, so blur stays HIGH
        //     for most of the duration and then snaps clear at
        //     the end — that's the "focus pulling" sensation.
        //
        // The compositingGroup() above flattens content first; the
        // blur radius then applies to a single layer (proper
        // gauzy soft-focus), not to each subview independently
        // (which read as pixelated).
        // 2026-05-04 (rev 8) — blur intensity dropped 40 → 18 and
        // animation switched from response 0.52 spring (~520ms) to
        // easeOut(0.20) (200ms). Earlier values were too strong and
        // too long: the content stayed visibly blurred for ~300ms
        // AFTER the panel finished its frame morph, which read as
        // "the blur is dragging on / can't focus." 18pt is enough
        // to read as a soft-focus pull without making content
        // unidentifiable, and 200ms easeOut tracks the panel's
        // 230-270ms frame morph so the blur clears as the panel
        // settles instead of trailing behind it.
        // 2026-05-07: Gated this blur on `isMorphing` AND skip
        // for volume HUD specifically. Previously the 4pt blur ran
        // during ANY pill-state morph (open, close, volume, track
        // banner, etc.) — for the volume HUD's morph back to pill,
        // that blur created a visible focus-pull artifact during
        // the close. User feedback: "closing kinda weird with all
        // that blur. Can we follow alcove please." Alcove has no
        // blur on the volume HUD close — silhouette just shrinks
        // cleanly.
        //
        // Skip when pendingSystemEvent is .volumeChanged (or was
        // recently — guarded by the morph itself being short).
        .blur(radius: shouldBlurSlabDuringMorph ? 4 : 0)
        // Direction-aware spring matching the panel's close timing
        // so content doesn't trail behind the panel.
        .animation(presenter.isShown
                   ? .interpolatingSpring(mass: 1.0, stiffness: 195, damping: 28, initialVelocity: 0)
                   : .interpolatingSpring(mass: 1.0, stiffness: 380, damping: 36, initialVelocity: 0),
                   value: presenter.isShown)
        // No blur on the content overlay. Earlier attempts:
        //   • `.blur(radius: 4)` (gaussian) — wrong character;
        //     reads as soft-focus / out-of-focus rather than
        //     in-motion. User explicitly rejected.
        //   • CIMotionBlur via NSView wrapper — closer to the
        //     reference (vertical directional smear) but
        //     `CALayer.filters` is restricted on macOS for
        //     CIMotionBlur in app contexts; per-frame
        //     ImageRenderer + CIFilter is too expensive.
        //   • Stacked-offset duplicates — would work, but
        //     SwiftUI's ViewModifier `Content` parameter can't
        //     cleanly be duplicated multiple times in an
        //     overlay without recursive layout issues.
        //
        // Skipping artificial blur for now. The spring's
        // natural motion at 60fps + the elastic content scale
        // already produce perceived motion; adding fake blur
        // didn't help. If we want a true motion-blur pass
        // later, the right surgery is a custom NSHostingView
        // subclass that snapshots its layer to NSImage on each
        // tick, applies CIMotionBlur with angle = motion
        // direction, and re-displays — and that's worth its
        // own focused session.
        //
        // Trailing compositingGroup REMOVED — we now have one
        // BEFORE the blur (so blur applies to a flattened layer,
        // proper soft-focus). A second compositingGroup at the
        // tail end was redundant and might have layered an extra
        // raster pass on top of the already-flattened content.
        .allowsHitTesting(presenter.isShown)
    }

    // MARK: - Artwork top gradient (panel-wide tint from album art)

    /// Artwork-color tint that fills the TOP of the panel and
    /// dissolves downward into clean black before reaching the
    /// transport row. Lives at the PanelRootView level (not inside
    /// MusicPanelView) so the gradient starts at the actual top of
    /// the panel — behind the Notetaker header text and the tab
    /// bar — instead of starting halfway down. Per the user:
    /// "tell me where is the top and where is the bottom"; the top
    /// of the panel is the header at y=0, not the music slab content.
    ///
    /// Only renders when the slab is open (`presenter.isShown`) and
    /// there's a track playing — pill state is too small for a
    /// useful gradient, and other tabs (Notes/Images/Videos/Files)
    /// shouldn't be tinted by music artwork they're not showing.
    @ViewBuilder
    private var artworkTopGradient: some View {
        // INVERTED gradient — "notch black extends down, then
        // color emerges below" rather than "color blooms FROM
        // the notch." Per user feedback: the previous design
        // had the brightest point of the radial gradient AT the
        // notch (center y=0), which read as "light is coming
        // OUT of the notch hardware." That broke the illusion
        // we wanted: the notch should feel like a solid piece
        // of CONTINUOUS HARDWARE that the panel grows out of,
        // not a light source. The user's mental model: notch
        // hardware is black → there should be a thin black band
        // continuing that black down into the panel → THEN the
        // album color emerges below.
        //
        // Two changes from the previous radial-from-notch:
        //   1. Radial center moved from (0.5, 0) to (0.5, 0.22)
        //      — the bloom is now ~22% down from the panel top,
        //      below the notch zone. Notch-adjacent pixels see
        //      the gradient at low intensity.
        //   2. Linear mask flipped: was "full opacity at top,
        //      fading down" → now "clear/dark at top, ramps to
        //      full at ~30%, fades back at ~85%". The masked
        //      gradient peaks in the upper-middle of the panel,
        //      not at the notch line.
        //
        // Net effect: the very top of the panel is solid black
        // (continuous with the hardware notch), and a soft glow
        // of the album's dominant color emerges in the upper-
        // middle area below the header. Reads as "the panel is
        // hanging from the notch, lit from within" instead of
        // "the notch is glowing."
        //
        // Gate: `isShown && !isMorphing`. The gradient ONLY
        // renders when the panel is fully open AND not currently
        // morphing (slab-open spring or tab-switch height morph).
        //
        // CRITICAL for slab-open smoothness. `isMorphing` is true
        // for the entire duration of:
        //   • The slab-open spring (pill → full slab) at line
        //     1523 of PanelWindowController, until ~1597 when the
        //     tail spring settles.
        //   • Tab-switch height morphs (line 1416 → 1434 in same
        //     file).
        //
        // While `isMorphing` is true, the panel's frame is
        // changing every spring tick (120Hz). If the masked
        // RadialGradient is rendered during that time, every
        // frame size change forces a full re-rasterization of
        // the gradient + linear mask combination. That
        // compositing work competes with the spring physics
        // for main-thread/GPU bandwidth, starves the tail
        // spring's sub-pixel motions (50/14 critically damped
        // with positionThreshold 0.1pt), and the user sees a
        // perceptual hard stop at the end of the open animation.
        // The user's exact words on the regression: "the
        // animation when finish is looking kinda stop. like i
        // can feel it's stopped. we fixed it before. why now
        // it's happening?"
        //
        // Earlier I removed the `!isMorphing` gate so the
        // gradient could "persist across tab switches" (per a
        // different user request). That broke the slab-open
        // smoothness. The right answer is: keep the gate. The
        // gradient appears AFTER the slab settles — which is
        // exactly the "nailed" version the user wants restored.
        // Tab-switch persistence is a future improvement that
        // needs a different mechanism (e.g., a separate
        // `isOpening` flag, or a fixed-size gradient layer that
        // doesn't re-rasterize as the panel resizes).
        if presenter.isShown,
           !presenter.isMorphing,
           let data = presenter.nowPlaying?.artworkData,
           let color = ArtworkColor.dominant(from: data) {
            // TOP-ANCHORED gradient — bloom emerges from the
            // upper-middle of the panel (just below the notch
            // zone) and dissolves downward into clean black
            // before reaching the transport row.
            //
            // Center at y=0.22 (22% down from the panel's top
            // edge) keeps the bloom's brightest point BELOW
            // the always-rendered black notch band — so the
            // notch hardware still reads as solid hardware,
            // not a light source, while the glow visibly
            // emerges from the upper portion of the panel.
            //
            // The brief "light from notch" flash glitch on
            // open is handled separately by:
            //   - The always-rendered black notch band
            //     (LinearGradient with hard top + soft bottom
            //     fade) which masks the gradient's top edge
            //     during the slab open animation, so no
            //     wallpaper or gradient bleed is visible
            //     through the notch zone before the slab is
            //     fully extended.
            //   - Pill content uses .transition(.identity) +
            //     .transaction { animation = nil } so it
            //     vanishes instantly when the slab opens
            //     (no cross-fade flash).
            //
            // STATIC gradient (no TimelineView). User reported
            // the slab open animation felt like it "stopped"
            // at the end — the previous TimelineView was re-
            // rendering the masked radial gradient at 30Hz,
            // and that constant compositing competed with the
            // slab's spring physics (120Hz tick + 50/14 tail
            // spring with sub-pixel-tight thresholds) for main-
            // thread/GPU bandwidth. The spring's last few sub-
            // pixel motions got starved out → perceptual hard
            // stop at the settle.
            // Removing the breathing animation eliminates the
            // per-frame gradient compositing, so the slab's
            // tail spring renders cleanly all the way to rest.
            // Trade-off: the gradient is now perfectly still.
            // Per the user's "let's revert" — this matches the
            // version that felt right before the breathing was
            // added.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: color.opacity(0.55), location: 0.0),
                    .init(color: color.opacity(0.30), location: 0.35),
                    .init(color: color.opacity(0.08), location: 0.7),
                    .init(color: Color.clear, location: 1.0),
                ]),
                // Top-area anchor. y=0.22 puts the bloom peak
                // just below the notch zone — close enough to
                // tint the upper panel without making the
                // notch hardware look like a light source.
                center: UnitPoint(x: 0.5, y: 0.22),
                startRadius: 0,
                endRadius: 280
            )
            .mask(
                // Full opacity at the top, fading down. Lets the
                // bloom shine clearly in the upper panel and
                // dissolves to clean black before reaching the
                // transport / tab content area at the bottom.
                LinearGradient(
                    stops: [
                        .init(color: Color.black, location: 0.0),
                        .init(color: Color.black, location: 0.45),
                        .init(color: Color.black.opacity(0.55), location: 0.7),
                        .init(color: Color.clear, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            // Cross-fade smoothly when the dominant color
            // changes (track swap).
            .animation(.easeInOut(duration: 0.4),
                       value: presenter.nowPlaying?.artworkData)
            // Fade-in/out on track-arrival or track-end. Note
            // we removed the !isMorphing gate from the outer
            // `if`, so this transition only fires when music
            // actually starts/stops — NOT on every panel-open
            // or tab-switch morph.
            //
            // REVERT: previously tried .offset(y:50) + .opacity
            // with easeOut(0.85)+0.18s delay (rise-from-bottom).
            // User reported the easeOut's zero-terminal-velocity
            // ending read as a perceptual "stop" overlapping
            // with the slab's settle, breaking the open feel.
            // Reverted to plain opacity — cleaner end, no
            // motion to compete with the slab's spring tail.
            .transition(.opacity.animation(.easeInOut(duration: 0.35)))
        }
    }

    // breathingPhase helper removed — see artworkTopGradient
    // comment for why the breathing animation was retired
    // (TimelineView's 30Hz redraws were starving the slab
    // spring's tail at the end of the open animation).

    // MARK: - Pill content overlay (resting now-playing indicator)

    /// Artwork + waveform pill body — rendered inside the SAME NSPanel
    /// that hosts the full slab content, so the resting pill and the
    /// expanded slab are literally one window morphing. This is the
    /// architectural shift the user asked for: "the pill should be
    /// always there... when you press the cursor to that, it just
    /// expands the music thing." Confirmed against Alcove's binary
    /// (NotchController + NotchPanel + _isExpanded/_isHovering flags
    /// in `/Applications/Alcove.app/Contents/MacOS/Alcove`).
    ///
    /// Visibility gate: `isResting && !isShown`. Mutually exclusive with
    /// `contentOverlay` (which is gated on `isShown`). When the panel
    /// expands, isShown flips true → pill fades out as the full content
    /// fades in. The 0.18s easeOut on the parent runs both crossfades
    /// in lockstep alongside the Core Animation frame morph.
    ///
    /// Layout: the pill content (artwork + waveform) sits ENTIRELY
    /// within the notch+menu-bar zone (the upper `notchOverlap` of the
    /// panel, ~32pt on a 16"/14" notched Mac). With closedPillBump=0pt
    /// there is no visible-below-menu-bar strip — the content reads as
    /// if it's PART OF the notch hardware itself, the same trick Alcove
    /// uses. Pixel measurement of `/Applications/Alcove.app` showed
    /// their resting pill silhouette ends at y=31.5pt — half a point
    /// shy of the menu-bar bottom — and content is rendered in the
    /// lower portion of the notch zone (below the camera lens). HStack
    /// with 14pt artwork + 16×8 waveform, centered vertically within
    /// the 32pt notch zone with horizontal padding tuned so the pair
    /// reads as integrated rather than crammed.
    @ViewBuilder
    private var pillContentOverlay: some View {
        // Priority order: system events (charging) > video
        // candidate > music. Each transient state takes over the
        // pill briefly then reverts to whatever was underneath.
        // The bouncy animation + scale transitions make the
        // morph feel tactile rather than a hard cut.
        Group {
            if case .charging(let pct, let plugged) = presenter.pendingSystemEvent {
                chargingPillContent(percent: pct, plugged: plugged)
                    .transition(.pillPop)
                    .id("charging")
            } else if case .screenshotSaved(let count) = presenter.pendingSystemEvent {
                screenshotPillContent(count: count)
                    .transition(.pillPop)
                    // Stable id across count updates — a burst
                    // updates `count` only, the view stays mounted
                    // and the count Text re-renders in place
                    // instead of re-running the entrance bounce
                    // for every shot.
                    .id("screenshot")
            } else if case .downloadStarted(let host) = presenter.pendingSystemEvent {
                downloadPillContent(host: host, completed: false)
                    .transition(.pillPop)
                    .id("download-start-\(host)")
            } else if case .downloadCompleted(let host) = presenter.pendingSystemEvent {
                downloadPillContent(host: host, completed: true)
                    .transition(.pillPop)
                    .id("download-done-\(host)")
            } else if case .noteSaved = presenter.pendingSystemEvent {
                noteSavedPillContent
                    .transition(.pillPop)
                    .id("noteSaved")
            } else if case .bluetoothConnected(let name, let isAirPods) = presenter.pendingSystemEvent {
                bluetoothPillContent(name: name, isAirPods: isAirPods, isConnected: true)
                    .transition(.pillPop)
                    .id("btConnected-\(name)")
            } else if case .bluetoothDisconnected(let name, let isAirPods) = presenter.pendingSystemEvent {
                bluetoothPillContent(name: name, isAirPods: isAirPods, isConnected: false)
                    .transition(.pillPop)
                    .id("btDisconnected-\(name)")
            } else if case .timerRunning(let remaining) = presenter.pendingSystemEvent {
                timerRunningPillContent(remainingSeconds: remaining)
                    .transition(.opacity)
                    // Stable id across tick updates so the entrance
                    // bounce only fires once on start.
                    .id("timerRunning")
            } else if case .timerFinished = presenter.pendingSystemEvent {
                timerFinishedPillContent
                    .transition(.pillPop)
                    .id("timerFinished")
            } else if case .calendarUpcoming(let title, let minutes) = presenter.pendingSystemEvent {
                calendarUpcomingPillContent(title: title, minutesUntilStart: minutes)
                    .transition(.pillPop)
                    // Stable id while the same meeting is counting
                    // down — minute updates re-render in place.
                    .id("calendar-\(title)")
            } else if case .airDropReceived(let filename) = presenter.pendingSystemEvent {
                airDropPillContent(filename: filename)
                    .transition(.pillPop)
                    .id("airdrop-\(filename)")
            } else if case .airDropSent(let count) = presenter.pendingSystemEvent {
                airDropSentPillContent(count: count)
                    .transition(.pillPop)
                    .id("airdrop-sent-\(count)")
            } else if case .airDropFailed = presenter.pendingSystemEvent {
                airDropFailedPillContent()
                    .transition(.pillPop)
                    .id("airdrop-failed")
            } else if case .trackChanged(let title, let artist) = presenter.pendingSystemEvent {
                // Track-change announcement — the panel widens to
                // banner geometry (PanelWindowController.trackBannerFrame)
                // and the body renders title/artist BELOW the notch
                // hardware in the visible apron. See TrackChangedPillBody.
                trackChangedPillContent(
                    title: title,
                    artist: artist,
                    artworkData: presenter.lastAnnouncedTrackArtwork
                )
                    .transition(.opacity)
                    .id("trackChanged-\(title)|\(artist)")
            } else if case .volumeChanged(let level, let muted) = presenter.pendingSystemEvent {
                // Volume HUD — panel widens to banner geometry
                // (PanelWindowController.volumeBannerFrame) and the
                // body renders speaker glyph + horizontal level bar
                // BELOW the notch hardware in the visible apron.
                // Stable id ("volume") so held-key tick spam updates
                // level/muted IN PLACE inside the same view instance
                // — no re-mount, no re-running entrance bounce per
                // tick. The bar's animation tracks the level value
                // continuously as the user holds the key.
                volumePillContent(level: level, muted: muted)
                    // Removal uses .volumeExit which bakes in a
                    // light 4pt blur alongside scale + opacity —
                    // softens the content edge so it visually
                    // matches the silhouette boundary as both
                    // shrink together. Round 36: "we have to
                    // match the movment of inside of the content
                    // with a little blur so it matchs perfectly."
                    //
                    // Insertion is symmetric scale+opacity (no
                    // blur on entrance — content should be crisp
                    // when it lands).
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.7, anchor: .top)
                                .combined(with: .opacity),
                            removal: .volumeExit
                                .animation(
                                    .timingCurve(0.32, 0.72, 0, 1,
                                                 duration: 0.32)
                                )
                        )
                    )
                    .id("volume")
            } else if let videoURL = presenter.pendingVideoCandidate {
                videoPreviewPillContent(for: videoURL)
                    .transition(.pillPop)
                    .id("video")
            } else if presenter.dictationPhase != .idle {
                // DICTATION TAKES OVER the pill. ONE id for ALL
                // non-idle phases ("dictation") so the view
                // doesn't get re-mounted between recording →
                // transcribing → error — the SAME view instance
                // morphs in place via `DictationPillContent`'s
                // internal property animations. That fixes the
                // "everything off-center / jumps to another
                // layer" feel the user reported.
                //
                // Transition: scale-in from 0.7× anchored at .top
                // (so the notch hardware connection never moves)
                // + opacity fade. On exit, fade-out only — the
                // pill returns to whatever was underneath
                // (music or empty pill) without a visual jolt.
                DictationPillContent(
                    phase: presenter.dictationPhase,
                    audioLevel: presenter.dictationLevel
                )
                    // SAME outer modifiers as musicPillContent
                    // (PanelRootView lines ~1790–1800). The
                    // dictation expansion is HORIZONTAL only —
                    // the host panel grows from 278pt to 420pt
                    // wide (PanelWindowController.dictationPillWidth)
                    // while keeping the same `notchOverlap`
                    // height. With the wider host pill, the
                    // HStack's Spacer pushes the indicator and
                    // waveform onto opposite wings of the notch
                    // with substantially more breathing room
                    // than the music pill — that's the visible
                    // expansion. Vertical layout stays exactly
                    // matched to the music pill so both modes
                    // share one visual rhythm.
                    .padding(.horizontal, 10)
                    .frame(height: notchOverlap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.7, anchor: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                    .id("dictation")
            } else if presenter.teleprompterPillVisible {
                // Teleprompter mode — the user hit "Start reading" on
                // a script. The pill morphs to the wider/taller
                // teleprompter geometry (driven by
                // PanelWindowController.showTeleprompterPill) and
                // this content fills it with scrolling text.
                //
                // GATED on `teleprompterPillVisible` (NOT on
                // `teleprompterScript != nil`) so the content mounts
                // in lockstep with the frame morph. The controller
                // flips the flag true at the moment
                // `morphIntoTeleprompterFrame` starts — earlier
                // versions rendered during the slab-close phase at
                // the wrong (smaller) geometry, producing visible
                // glitches.
                TeleprompterPillBody(
                    presenter: presenter,
                    notchOverlap: notchOverlap
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.animation(
                            .timingCurve(0.32, 0.72, 0, 1, duration: 0.22)
                                .delay(0.06)
                        ),
                        removal: .opacity.animation(
                            .timingCurve(0.32, 0.72, 0, 1, duration: 0.18)
                        )
                    )
                )
                .id("teleprompter-pill")
            } else if combinedPillVisible {
                // Hybrid: both music AND focus active. Wider pill
                // (panel.frame adds focusPillExtraWidth) showing
                // artwork + waveform on the LEFT WING and focus
                // aura + timer on the RIGHT WING.
                combinedPillContent
                    .transition(
                        .asymmetric(
                            insertion: .softMusicEntrance.animation(
                                .timingCurve(0.32, 0.72, 0, 1,
                                             duration: 0.20).delay(0.20)
                            ),
                            removal: .opacity
                        )
                    )
                    .id("combined-pill")
            } else if focusPillVisible {
                // Focus mode active and no music. Standard-width
                // pill, focus content (aura on left, timer on right)
                // replaces everything else.
                focusPillContent
                    .transition(
                        .asymmetric(
                            insertion: .softMusicEntrance.animation(
                                .timingCurve(0.32, 0.72, 0, 1,
                                             duration: 0.20).delay(0.20)
                            ),
                            removal: .opacity
                        )
                    )
                    .id("focus-pill")
            } else {
                musicPillContent
                    // STAGGERED INSERTION — music pill fades in
                    // during the SECOND half of the silhouette
                    // shrink, not the first.
                    //
                    // User's diagnosis (round 34): "1st layer is
                    // showing the sign of closing but the 2nd layer
                    // was in that position so it's creating an
                    // illution that instade of closing it got stuck
                    // for mili seconds." The music pill content was
                    // sitting at its final (small) position from t=0
                    // while the silhouette was still at full HUD size
                    // and shrinking toward it — visually the
                    // silhouette appeared stuck because the content
                    // inside wasn't moving WITH it.
                    //
                    // SOFT ENTRANCE — fades in with a 5pt blur
                    // that decays to 0 over 200ms, starting at
                    // t=200ms (mid-morph). The artwork gracefully
                    // sharpens into focus instead of snap-popping.
                    // Round 39: "the artwork ... appearing like a
                    // glitch ... if we can have crossfade on that
                    // or some kind of blur."
                    //
                    // 200ms duration (vs round 35's 80ms) gives
                    // the blur enough time to be perceptually
                    // smooth, not a flash. Total visible window:
                    // t=200ms (start) → t=400ms (full focus) lands
                    // exactly when the silhouette settles.
                    .transition(
                        .asymmetric(
                            insertion: .softMusicEntrance.animation(
                                .timingCurve(0.32, 0.72, 0, 1,
                                             duration: 0.20).delay(0.20)
                            ),
                            removal: .opacity
                        )
                    )
                    .id("music")
            }
        }
        // Critically-damped spring on the content swap. Bouncy was
        // overshooting on entrance AND exit — and on exit the
        // opacity component races to 0 before the scale's bounce-
        // back completes, so SwiftUI removes the view mid-animation
        // and the user sees the motion get cut off. That was the
        // "endpoints totally broken" complaint.
        //
        // Match the panel exit duration EXACTLY (270ms) using
        // easeOut. SwiftUI animation system runs alongside the
        // CADisplayLink-driven SpringFrameAnimator for panel.frame.
        // Both finish at t=270ms so content + panel.frame land at
        // the notch on the same beat — no orphaned content, no
        // overlapping mismatch.
        //
        // easeOut(0.27) has the same character as a critically
        // damped spring without the overshoot/wobble physics
        // that interpolatingSpring sometimes introduces. Cleaner
        // landing for transient pill dismiss.
        // EXACT cubic-bezier match to the panel-frame morph's
        // CAMediaTimingFunction (0.32, 0.72, 0, 1) — Apple's
        // signature out-quint. SwiftUI's `.easeOut` is a generic
        // ease-out (different curve), and the curve mismatch was
        // the "2nd layer not syncing properly" feeling: two
        // animations of the same duration but different curves
        // tick at different speeds at the midpoint and look
        // staggered. Using `.timingCurve(0.32, 0.72, 0, 1)`
        // aligns SwiftUI's content-swap curve EXACTLY with the
        // off-main CA frame morph — they advance in lockstep.
        .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.40),
                   value: presenter.pendingSystemEvent)
        .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.40),
                   value: presenter.pendingVideoCandidate)
        // Dictation pill MOUNT/UNMOUNT animation — only fires at
        // entrance (idle → non-idle) and exit (non-idle → idle).
        // Phase changes WITHIN the dictation (recording →
        // transcribing → error) stay on the SAME mounted view
        // and morph via DictationPillContent's internal property
        // animations, so this curve doesn't re-trigger and the
        // user doesn't see "another layer" appear mid-stream.
        .animation(NoxAnimations.panelOpen,
                   value: presenter.dictationPhase == .idle)
        // Progressive-blur swap mask. When the pill morphs from
        // one event type to another (music → charging, music →
        // screenshot, etc.), apply a brief gaussian blur over the
        // entire pill content for ~0.45s, peaking at the swap
        // moment. The user reported the swap "still not seamless"
        // and pointed at Alcove's charging morph; Alcove's binary
        // contains `ProgressiveBlurEffect` + `gaussianBlurFilter`
        // symbols and a `progressiveBlurTransitionTask` — same
        // technique. The blur masks the visual seam where the old
        // and new content overlap during a SwiftUI transition,
        // making the swap read as one soft morph instead of two
        // crossfading rectangles. Triggered only on case CHANGE
        // (count updates within `.screenshotSaved` don't blur).
        .modifier(PillSwapBlur(caseKey: pillEventCaseKey))
    }

    /// Identity string for the current pendingSystemEvent / video
    /// candidate. Used by `PillSwapBlur` to detect actual case
    /// transitions vs. associated-value updates within the same
    /// case (e.g., screenshot count incrementing).
    private var pillEventCaseKey: String {
        if let event = presenter.pendingSystemEvent {
            switch event {
            case .charging: return "charging"
            case .screenshotSaved: return "screenshot"
            case .downloadStarted: return "downloadStarted"
            case .downloadCompleted: return "downloadCompleted"
            case .noteSaved: return "noteSaved"
            case .bluetoothConnected(let name, _): return "btConnected-\(name)"
            case .bluetoothDisconnected(let name, _): return "btDisconnected-\(name)"
            case .timerRunning: return "timerRunning"
            case .timerFinished: return "timerFinished"
            case .calendarUpcoming(let title, _): return "calendar-\(title)"
            case .airDropReceived(let filename): return "airdrop-\(filename)"
            case .airDropSent(let count): return "airdropSent-\(count)"
            case .airDropFailed: return "airdropFailed"
            case .trackChanged(let title, let artist): return "trackChanged-\(title)|\(artist)"
            // Stable case-key for ALL volume changes regardless of
            // level — held-key spam shouldn't re-puff the silhouette
            // per tick (PillSilhouetteReact only fires on case-key
            // CHANGE). Same pattern as `screenshot` / `timerRunning`
            // where associated values update in place.
            case .volumeChanged: return "volume"
            }
        }
        if presenter.pendingVideoCandidate != nil { return "video" }
        return "music"
    }

    /// Glow color for the pill's silhouette reaction — matches
    /// the event tile's accent so the puff feels color-coded.
    /// Used by `PillSilhouetteReact` for the brief shadow during
    /// the puff.
    private var pillReactColor: Color {
        if let event = presenter.pendingSystemEvent {
            switch event {
            case .charging: return Color(red: 0.30, green: 0.85, blue: 0.45)
            case .screenshotSaved: return Color(red: 0.30, green: 0.78, blue: 0.99)
            case .noteSaved: return Color(red: 0.99, green: 0.80, blue: 0.20)
            case .downloadStarted, .downloadCompleted: return Color(red: 0.93, green: 0.13, blue: 0.13)
            case .bluetoothConnected: return Color(red: 0.45, green: 0.65, blue: 1.0)
            case .bluetoothDisconnected: return Color(red: 0.65, green: 0.65, blue: 0.70)
            case .timerRunning: return Color(red: 1.00, green: 0.55, blue: 0.20)
            case .timerFinished: return Color(red: 0.30, green: 0.85, blue: 0.45)
            case .calendarUpcoming: return Color(red: 0.99, green: 0.45, blue: 0.30)
            case .airDropReceived: return Color(red: 0.30, green: 0.78, blue: 0.99)
            case .airDropSent: return Color(red: 0.30, green: 0.78, blue: 0.99)
            case .airDropFailed: return Color(red: 0.65, green: 0.65, blue: 0.70)
            case .trackChanged: return Color(red: 0.78, green: 0.62, blue: 0.98)
            case .volumeChanged: return Color.white
            }
        }
        return Color.white
    }

    /// Charging plug-in / unplug indicator. Same horizontal layout
    /// as music: battery glyph on the left, percentage text on the
    /// right. The bolt subtly pulses while plugged to convey
    /// "energy flowing in"; the percentage text slides in from the
    /// right for additional motion polish.
    /// Compact "screenshot saved" pill content. Camera glyph on
    /// the left, "Saved" badge on the right. Auto-dismisses after
    /// the 1.4s timeout. Reads as the iOS Dynamic Island's
    /// screenshot toast — quick acknowledgement without stealing
    /// focus.
    @ViewBuilder
    private func screenshotPillContent(count: Int) -> some View {
        ScreenshotPillBody(count: count, notchOverlap: notchOverlap)
            .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    /// "Download started" / "Download complete" pill content.
    /// Platform-tinted tile (same logic as the video preview pill)
    /// + state badge. The completed variant flashes a checkmark
    /// glyph and "Done" text.
    @ViewBuilder
    private func downloadPillContent(host: String, completed: Bool) -> some View {
        let accent = videoPlatformAccent(host: host)
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(accent.opacity(0.9))
                Image(systemName: completed ? "checkmark" : "arrow.down")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)
            // Right-wing badge — checkmark when done, three-dot
            // ellipsis when in progress. Sits past the notch so
            // it actually paints; pairs with the left-wing
            // accent-tinted tile to give the user a quick read on
            // the state without a long "Done"/"Downloading" label
            // that wouldn't fit in the right wing anyway.
            Image(systemName: completed ? "checkmark" : "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    /// Pill content for clipboard text auto-saved as a note.
    /// Yellow note glyph + "Note saved" badge — matches the
    /// Notes tab's chromatic identity. Same dismissal window as
    /// screenshots so the user gets a quick acknowledgement
    /// without the panel ever opening.
    @ViewBuilder
    /// Note-saved pill — yellow pencil tile in the LEFT wing,
    /// confirmation checkmark in the RIGHT wing past the notch
    /// hardware. Earlier we rendered a "Note saved" text label
    /// after a Spacer, placing it in the central zone where the
    /// physical notch covered it. Both wings are now used:
    /// pencil signals "what" (a note write), checkmark signals
    /// "what happened" (it succeeded).
    private var noteSavedPillContent: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.80, blue: 0.20).opacity(0.9))
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            // Right-wing confirmation checkmark.
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.99, green: 0.80, blue: 0.20))
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    /// Bluetooth connect/disconnect HUD content. Mirrors the
    /// DynamicLake Pro "DynaConnect" pill the user pointed at —
    /// small device icon on the left, name + status on the right.
    /// `isConnected` flips the status text and dims the icon for
    /// disconnect. `isAirPods` swaps to the dedicated AirPods
    /// SF Symbol; everything else gets the generic headphones
    /// glyph.
    /// Read Settings → Bluetooth → Distinguish AirPods icon. When
    /// off, the AirPods glyph is collapsed back to the generic
    /// "headphones" symbol so the user gets the simpler pill (some
    /// users find the silhouette-specific icon visually noisy when
    /// they pair multiple AirPods sets across the day).
    private func bluetoothIconName(isAirPods: Bool) -> String {
        if !isAirPods { return "headphones" }
        let key = "bluetoothShowAirPodsIcon"
        let distinguish: Bool = {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }()
        return distinguish ? "airpods.gen3" : "headphones"
    }

    private func bluetoothPillContent(name: String, isAirPods: Bool, isConnected: Bool) -> some View {
        BluetoothPillBody(
            name: name,
            iconName: bluetoothIconName(isAirPods: isAirPods),
            isConnected: isConnected,
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
    }

    /// Live countdown pill — orange timer glyph + monospaced
    /// "MM:SS" remaining. Stays pinned the entire time the timer
    /// is counting (the service pushes a fresh `.timerRunning(...)`
    /// every second; the same `.id("timerRunning")` keeps the view
    /// stable so the time text updates in place without retriggering
    /// the entrance bounce on each tick).
    private func timerRunningPillContent(remainingSeconds: Int) -> some View {
        TimerRunningPillBody(
            remainingSeconds: remainingSeconds,
            timeText: formatTimerDuration(remainingSeconds),
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
    }

    /// "Timer done" celebratory pill. Green checkmark + "Time's
    /// up" badge. 3-second window so the user sees it even if
    /// they were heads-down on something else.
    private var timerFinishedPillContent: some View {
        TimerFinishedPillBody(
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
    }

    private func formatTimerDuration(_ totalSeconds: Int) -> String {
        let s = max(totalSeconds, 0)
        let m = s / 60
        let sec = s % 60
        if m >= 60 {
            let h = m / 60
            let remM = m % 60
            return String(format: "%d:%02d:%02d", h, remM, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    /// Upcoming-meeting pill — orange calendar tile + truncated
    /// title + minutes remaining. Tappable: tap routes through
    /// `presenter.onJoinUpcomingMeeting` (installed by AppDelegate)
    /// which opens the join URL in the user's default browser.
    /// We render this with a `.contentShape` rectangle so the
    /// whole pill area is tappable, not just the text label.
    @ViewBuilder
    private func calendarUpcomingPillContent(title: String, minutesUntilStart: Int) -> some View {
        CalendarUpcomingPillBody(
            title: title,
            minutesUntilStart: minutesUntilStart,
            timeLabel: calendarTimeLabel(minutes: minutesUntilStart),
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
        .contentShape(Rectangle())
        .onTapGesture {
            presenter.onJoinUpcomingMeeting?()
        }
    }

    /// Format the lead-time label inside the calendar pill. Negative
    /// minutes (event already started) read as "now" so the user
    /// doesn't see "-2 min" — confusing during the in-progress
    /// grace window.
    private func calendarTimeLabel(minutes: Int) -> String {
        if minutes <= 0 { return "now" }
        if minutes == 1 { return "in 1 min" }
        return "in \(minutes) min"
    }

    /// Track-change announcement pill — modeled on Alcove's brief
    /// "now playing" expansion. Album art on the left, a tiny music
    /// glyph + "Title · Artist" running text in the center, and four
    /// pulsing equalizer bars on the right. Auto-dismisses via the
    /// SystemEvent timeout (3.5s).
    @ViewBuilder
    private func trackChangedPillContent(title: String, artist: String, artworkData: Data?) -> some View {
        TrackChangedPillBody(
            title: title,
            artist: artist,
            fromArtworkData: presenter.bannerFromArtwork,
            toArtworkData: artworkData,
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
    }

    /// System volume HUD pill — auto-switching speaker glyph on the
    /// left, "Sound" / device-name label, then a horizontal level
    /// bar that fills to `level` (0–1). Mutes flip the icon to
    /// `speaker.slash.fill` and dim the bar regardless of level.
    ///
    /// Layout matches Alcove's volume HUD: banner-shaped expansion
    /// out of the notch, single horizontal row in the visible apron
    /// below the hardware notch. Speaker glyph hugs the LEFT curve,
    /// volume bar takes the rest of the row to the RIGHT curve.
    @ViewBuilder
    private func volumePillContent(level: Float, muted: Bool) -> some View {
        VolumePillBody(
            level: level,
            muted: muted,
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
    }

    /// AirDrop arrival pill — UTI-tinted tile + filename, with a
    /// brief cosmetic "progress completing" sweep on entrance. Tap
    /// reveals the file in Finder via `presenter.onRevealAirDrop`.
    ///
    /// Progress is purely cosmetic: macOS doesn't expose Sharingd's
    /// in-flight transfer progress to third-party apps (the system
    /// AirDrop sheet uses private SharingD.framework calls), so by
    /// the time we detect the file via FSEvents + quarantine xattr
    /// it's already on disk. The 600ms arc sweep is honest about
    /// being a flourish — it gives the pill a "completing transfer"
    /// presence rather than just a static tile flash, which reads
    /// more in keeping with how iOS handles this same handoff event.
    /// After the arc fills, it fades and the file's actual UTI glyph
    /// (photo / video / audio / generic) springs in.
    @ViewBuilder
    private func airDropPillContent(filename: String) -> some View {
        AirDropPillBody(
            filename: filename,
            fileURL: presenter.lastAirDropURL,
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
        .contentShape(Rectangle())
        .onTapGesture {
            presenter.onRevealAirDrop?()
        }
    }

    /// Confirmation pill after the user successfully sends N files via
    /// AirDrop. AirDrop logo on the left tile (matches the "received"
    /// pill's color language so both directions feel like the same
    /// family of events), then a discreet checkmark + count on the
    /// right. Apple's NSSharingService doesn't expose the recipient
    /// name to third-party apps so we deliberately avoid showing
    /// "Sent to <name>" — just the confirmation that something landed.
    @ViewBuilder
    private func airDropSentPillContent(count: Int) -> some View {
        let visible = presenter.isResting && !presenter.isShown
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.78, blue: 0.99).opacity(0.92))
                AirDropLogo()
                    .frame(width: 14, height: 14)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.45))
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
    }

    /// Brief acknowledgement pill when the user cancels the AirDrop
    /// sheet or the send fails. Same blue tile so the user reads it
    /// as "AirDrop, but the other state" — and a small slashed-circle
    /// glyph on the right rather than a checkmark. Kept short (2.0s)
    /// so it doesn't camp on top of the music pill.
    @ViewBuilder
    private func airDropFailedPillContent() -> some View {
        let visible = presenter.isResting && !presenter.isShown
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.55, green: 0.55, blue: 0.60).opacity(0.92))
                AirDropLogo()
                    .frame(width: 14, height: 14)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
    }


    @ViewBuilder
    private func chargingPillContent(percent: Int, plugged: Bool) -> some View {
        HStack(spacing: 6) {
            ChargingTile(percent: percent, plugged: plugged)
            Spacer(minLength: 0)
            // Plain Text — no inner `.transition()`. Earlier this had
            // `.move(edge: .trailing).combined(with: .opacity)` which
            // stacked on top of the parent's `.pillPop` transition,
            // causing a visible double-transition glitch where the
            // Text slid in from the right WHILE the entire pill was
            // also bouncing in. The percent value uses .contentTransition
            // for digit-level animation across charge updates without
            // needing a SwiftUI transition modifier.
            Text("\(percent)%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: presenter.isShown)
    }

    /// Color the battery tile by state — green when plugged and
    /// charging, amber when low and unplugged, neutral elsewhere.
    /// Picks up the same kind of "at-a-glance" color cue Apple
    /// uses on the menu-bar battery icon.
    private func chargingTileColor(percent: Int, plugged: Bool) -> Color {
        if plugged {
            return Color(red: 0.30, green: 0.78, blue: 0.39)
        }
        if percent < 20 {
            return Color(red: 0.95, green: 0.40, blue: 0.20)
        }
        return Color(red: 0.45, green: 0.45, blue: 0.50)
    }

    /// Compact "video URL detected" pill content. Left: video glyph
    /// tinted by source platform. Right: download button. Tap the
    /// download button → routes to `presenter.onDownloadVideo`
    /// (AppDelegate hooks this to videoStore.startDownload). If the
    /// user ignores it for 15s, the pill auto-reverts to music mode.
    @ViewBuilder
    private func videoPreviewPillContent(for url: URL) -> some View {
        let host = url.host?.lowercased() ?? ""
        let accent = videoPlatformAccent(host: host)
        let glyph = videoPlatformGlyph(host: host)
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(accent.opacity(0.85))
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            Button {
                presenter.onDownloadVideo?(url)
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.18))
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 20, height: 20)
                // Visual stays at 20×20; hit target extends to the
                // full pill height + 12pt of horizontal slack so the
                // button is reachable without precision aim. With
                // hover-expand suppressed in video-preview mode,
                // this is the only interaction on the pill — make
                // sure it lands first try.
                .padding(.vertical, 4)
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Download \(host)")
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: presenter.isShown)
    }

    /// Brand-accurate-ish accent color for the hosts we can
    /// silently download from — video sites via yt-dlp, plus the
    /// two file-share hosts yt-dlp's extractors handle (Drive,
    /// Dropbox). Falls back to neutral blue.
    private func videoPlatformAccent(host: String) -> Color {
        if host.contains("youtube") || host.contains("youtu.be") {
            return Color(red: 0.93, green: 0.13, blue: 0.13)
        }
        if host.contains("tiktok") {
            return Color(red: 0.0, green: 0.84, blue: 0.85)
        }
        if host.contains("twitter") || host.contains("x.com") {
            return Color(red: 0.10, green: 0.10, blue: 0.10)
        }
        if host.contains("vimeo") {
            return Color(red: 0.10, green: 0.55, blue: 0.83)
        }
        if host.contains("twitch") {
            return Color(red: 0.57, green: 0.30, blue: 0.85)
        }
        if host.contains("instagram") {
            return Color(red: 0.91, green: 0.31, blue: 0.55)
        }
        if host.contains("drive.google.com") {
            return Color(red: 0.96, green: 0.76, blue: 0.20) // Drive yellow
        }
        if host.contains("dropbox.com") {
            return Color(red: 0.0, green: 0.40, blue: 0.93) // Dropbox blue
        }
        return Color.accentColor
    }

    /// SF Symbol matching the link's category. Video sites get the
    /// play glyph; Drive/Dropbox get a folder glyph since the
    /// downloaded thing might be any file type.
    private func videoPlatformGlyph(host: String) -> String {
        if host.contains("drive.google.com") || host.contains("dropbox.com") {
            return "folder.fill"
        }
        return "play.fill"
    }

    /// Resting-pill content for nox Focus mode (no music playing).
    /// Layout matches the user's brief (2026-05-09): "in right it
    /// would show timer, and in the left it would show the gif of
    /// lock in." Aura on the left (the same `FocusAuraHero`
    /// pulsing-rings indicator the dashboard uses, scaled down
    /// for the pill), live HH:MM:SS-style duration on the right.
    /// Both are vertically centered in the notch overlap zone.
    ///
    /// Timer ticks once per second via `TimelineView(.periodic)`.
    /// Source = `FocusSessionTracker.shared.sessionStartDate`,
    /// which got pushed by AppDelegate's `recomputeQuietState`
    /// the moment the user flipped Focus mode on.
    @ViewBuilder
    private var focusPillContent: some View {
        // CRITICAL LAYOUT NOTE: the small resting pill is
        // ~280pt wide but the macOS notch hardware (~185pt)
        // physically occludes the CENTER of the menu-bar zone.
        // Only the LEFT and RIGHT wings — ~47pt each side of
        // the notch — render visibly to the user. Content
        // packed tight in the middle is invisible.
        //
        // 2026-05-09 fix: my earlier `HStack(spacing: 8) {
        // aura; timer }` had no Spacer, so SwiftUI packed
        // them tightly and centered the cluster under the
        // notch — invisible. Music pill uses
        // `Spacer(minLength: 0)` between artwork (left wing)
        // and waveform (right wing) for exactly this reason.
        // Same recipe here: aura on the left wing, Spacer
        // pushing the timer to the right wing.
        HStack(spacing: 0) {
            // Mode-driven indicator: Focus → anime working
            // character; Study → book glyph. Same 18pt size,
            // same left-wing position, just different content.
            Group {
                switch activePillMode {
                case .focus:
                    FocusWorkingHero(active: true)
                case .study:
                    StudyHero(active: true)
                }
            }
            .frame(width: 18, height: 18)

            Spacer(minLength: 0)

            // Effective session start picks the right tracker
            // based on which mode is active so the pill timer
            // always reflects "this mode's session", not a stale
            // counter from the other mode.
            let effectiveStart: Date? = {
                switch activePillMode {
                case .focus:
                    return focusTracker.sessionStartDate
                        ?? presenter.focusSessionStartedAt
                case .study:
                    return studyTracker.sessionStartDate
                        ?? presenter.studySessionStartedAt
                }
            }()
            let modeLabel: String = activePillMode == .study ? "Study" : "Focus"

            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                pillTimerLabel(
                    now: context.date,
                    sessionStart: effectiveStart,
                    fallback: modeLabel
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Pill timer text, with priority order:
    ///   1. **Active countdown timer** (Focus or Study, running or
    ///      paused) → MM:SS remaining. Pause shows the same digits
    ///      with a tiny ⏸ glyph + dimmer foreground so the user can
    ///      tell at a glance whether time is still burning.
    ///   2. **Open-ended session timer** → HH:MM:SS count-up since
    ///      `sessionStart`. Default when no countdown is set.
    ///   3. **Mode label** ("Focus" / "Study") → fallback when
    ///      neither timer has a wall-clock anchor yet.
    @ViewBuilder
    private func pillTimerLabel(
        now: Date, sessionStart: Date?, fallback: String
    ) -> some View {
        // Pick the right countdown timer for the active mode. Both
        // singletons run their state machines independently — the
        // pill just reads whichever one matches what the user is
        // currently in. Expired falls through to count-up so the
        // celebration UI is only on the dashboard, not duplicated
        // on the pill.
        let activeTimer: SessionTimerService = {
            switch activePillMode {
            case .focus: return focusTimer
            case .study: return studyTimer
            }
        }()
        if activeTimer.state == .running || activeTimer.state == .paused {
            let remaining = activeTimer.remaining(now: now)
            HStack(spacing: 3) {
                if activeTimer.state == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Text(formatPillCountdown(remaining))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(
                        activeTimer.state == .paused
                            ? .white.opacity(0.55) : .white
                    )
                    .lineLimit(1)
            }
        } else if let start = sessionStart {
            Text(formatPillFocusDuration(now.timeIntervalSince(start)))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        } else {
            Text(fallback)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
    }

    /// MM:SS countdown formatter for the pill. Mirror of the
    /// dashboard's `formatCountdown` — kept duplicated rather than
    /// shared because the pill version is read-only (no need for
    /// the live `LiveFocusDetailPanel` to import a separate
    /// formatter just for this).
    private func formatPillCountdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Hybrid pill content: music + focus active simultaneously.
    /// 2026-05-09 v3 layout per user spec: "We need exact rotating
    /// and note showing when lock in mode is turn on (with that
    /// side timer)."
    ///
    ///   • Left wing: VINYL-style rotating circular artwork —
    ///     continuous slow rotation conveys "music is on, locked
    ///     in." Square artwork is clipped to a circle so the
    ///     rotation reads as a record spinning rather than a
    ///     square tumbling.
    ///   • Right wing: small music.note glyph + live focus timer.
    ///     The note glyph is the "music name showing" indicator
    ///     (we don't have horizontal room for a title/artist
    ///     string in the wings, but the note conveys "music is
    ///     happening here").
    @ViewBuilder
    private var combinedPillContent: some View {
        let info = presenter.nowPlaying
        let waveformIsPlaying: Bool = info?.isPlaying ?? presenter.isAudioFlowing
        // Pick tracker matching the active mode so the timer in the
        // hybrid music-and-mode pill reads the right session start.
        // Same fall-through to the presenter's *SessionStartedAt
        // mirror as the focus-only pill — covers the brief race
        // window between AppDelegate's recompute and the tracker's
        // @Published push.
        let effectiveStart: Date? = {
            switch activePillMode {
            case .focus:
                return focusTracker.sessionStartDate
                    ?? presenter.focusSessionStartedAt
            case .study:
                return studyTracker.sessionStartDate
                    ?? presenter.studySessionStartedAt
            }
        }()
        let modeLabel: String = activePillMode == .study ? "Study" : "Focus"

        HStack(spacing: 5) {
            // Left wing: static album artwork (rotation removed
            // earlier per spec — the 3D card-flip on track change
            // carries all the music-moving-forward motion).
            pillArtwork

            Spacer(minLength: 0)

            // Right-wing cluster: visualizer + lock-in indicator
            // + timer. Tight fit but the wider pill (closedPillWidth
            // + focusPillExtraWidth = 343pt total → ~79pt right
            // wing past the notch hardware) just accommodates it.
            WaveformView(
                isPlaying: waveformIsPlaying,
                width: 18,
                height: 14,
                lineWidth: 2.4,
                // 2026-05-09 round 2: tint also lagged on
                // `displayedNowPlaying?.artworkData`. Was using
                // `info?.artworkData` (live) which jumped the
                // visualizer's color to the NEW song's palette
                // the instant MR emitted the new track — while
                // the artwork on screen + the wave pattern
                // (fixed earlier) were still on OLD. The user
                // saw "visualizer is one color [old/wrong]
                // instead of the next music one." Same
                // displayedNowPlaying source the artwork reads,
                // so all three (artwork / pattern / tint) flip
                // in lockstep when the banner finishes.
                tint: ArtworkColor.dominant(from: displayedNowPlaying?.artworkData) ?? .white,
                opacity: 0.95,
                pattern: WaveformPattern.deterministic(for: displayedTrackKey),
                isCompactResting: true,
                isInteractionActive: abs(pillSwipeOffset) > 0
                    || presenter.isMorphing
                    || presenter.trackChangedFiring
            )
            .scaleEffect(x: waveformPulse, y: 1, anchor: .trailing)
            .transition(.opacity)

            // Animated lock-in indicator — Focus uses
            // FocusWorkingHero (anime character at a laptop),
            // Study uses StudyHero (open-book + writing hand).
            // Same motif as the focus-only / study-only pill and
            // their dashboard heroes, so the indicator reads
            // consistently across the app for whichever mode is on.
            Group {
                switch activePillMode {
                case .focus:
                    FocusWorkingHero(active: true)
                case .study:
                    StudyHero(active: true)
                }
            }
            .frame(width: 14, height: 14)

            // Tick at 1Hz when a countdown is running so MM:SS
            // refreshes every second — the legacy 30s cadence was
            // fine for HH:MM count-up (minutes only), but a
            // countdown needs to show seconds advancing. Either
            // mode's countdown bumps the cadence; if neither is
            // running we stay on 30s.
            let activeTimer: SessionTimerService = (activePillMode == .focus)
                ? focusTimer : studyTimer
            let tickInterval: TimeInterval = (
                activeTimer.state == .running
                || activeTimer.state == .paused
            ) ? 1.0 : 30.0
            TimelineView(.periodic(from: .now, by: tickInterval)) { context in
                // Countdown takes priority over the count-up label
                // so the user can glance at remaining time while
                // music is playing, without opening the panel.
                if activeTimer.state == .running
                    || activeTimer.state == .paused {
                    let remaining = activeTimer.remaining(now: context.date)
                    HStack(spacing: 3) {
                        if activeTimer.state == .paused {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Text(formatPillCountdown(remaining))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(
                                activeTimer.state == .paused
                                    ? .white.opacity(0.55)
                                    : .white.opacity(0.92)
                            )
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else if let start = effectiveStart {
                    Text(focusElapsedLabel(since: start, now: context.date))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text(modeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Artwork-decode lifecycle. Mirrors the equivalent hooks
        // on `musicPillContent` so the pill's cached artwork stays
        // fresh while the COMBINED pill is the visible content.
        //
        // 2026-05-09 v2 — track-change handoff fix:
        // Earlier I had `.onChange(of: presenter.nowPlaying)` that
        // immediately reseated `displayedNowPlaying` whenever a new
        // track landed. Result: the small pill's artwork swapped
        // BEFORE the track-change banner ran its 3D card flip —
        // the banner showed old→new but the pill underneath had
        // already advanced to "new", which read as the artwork
        // jumping ahead of the animation.
        //
        // Fix: drop the eager .onChange and use the same
        // `.onReceive(presenter.$trackChangedFiring)` pattern that
        // `musicPillContent` uses. `displayedNowPlaying` is now
        // ONLY updated when `trackChangedFiring` flips back to
        // false (i.e. banner finished). During the banner's
        // ~1.85s lifetime the pill stays pinned to the OLD track,
        // so when the banner retracts the visual handoff is
        // seamless: banner ends with new artwork → pill is
        // already showing new artwork by the time it's revealed.
        .onAppear {
            if !hasEverDisplayedTrack && displayedNowPlaying == nil {
                displayedNowPlaying = presenter.nowPlaying
                displayedTrackKey = trackKey
                if presenter.nowPlaying != nil {
                    hasEverDisplayedTrack = true
                }
            }
            refreshPillArtworkImage()
        }
        .onReceive(presenter.$trackChangedFiring) { firing in
            // Only sync after the banner's done flipping — same
            // handoff pattern as musicPillContent.
            if !firing, let cur = presenter.nowPlaying {
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) {
                    displayedNowPlaying = cur
                    displayedTrackKey = "\(cur.title)|\(cur.artist)"
                }
                refreshPillArtworkImage()
            }
        }
        .onChange(of: displayedNowPlaying) { _ in
            refreshPillArtworkImage()
        }
    }

    /// Compact duration formatter for the pill timer. Matches the
    /// dashboard's hero formatter logic but with shorter unit
    /// labels because the pill has limited width (closedPillFrame
    /// = ~280pt). Drops higher-order zeros so a 5-minute session
    /// reads "5m", not "0h 05m".
    private func formatPillFocusDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return "\(m)m \(String(format: "%02d", s))s" }
        return "\(s)s"
    }

    @ViewBuilder
    private var musicPillContent: some View {
        // 2026-04-29 fix v2: bundle-ID allow-list for the
        // waveform. The previous artist-non-empty check was too
        // loose because the Perl adapter's sparse-payload
        // fallback (added earlier this session) sets artist to
        // the app name when MediaRemote omits it — so Podcasts,
        // YouTube tabs, browser audio all have non-empty artist
        // and slipped through. The waveform is intended as a
        // *music* visualizer; for non-music audio sources we
        // just want the source-app icon, no animated bars.
        //
        // Allow-list: Spotify + Apple Music. Everything else
        // (browsers, Podcasts, audiobook apps, system audio)
        // gets the icon-only treatment. If the user wants to
        // add another "music" app later (e.g. youtube-music
        // Electron, doppler), append its bundle ID here.
        // 2026-04-29 final v3:
        //   • Real music (Spotify / Apple Music) → ANIMATED waveform
        //   • Any other audio source → STATIC 3-bar indicator
        //     (paused=true forced regardless of `info?.isPlaying`,
        //     so the bars are computed once and frozen — no
        //     re-evaluation, no bouncing even if isPlaying toggles
        //     in the underlying state)
        //   • Empty/no source → no waveform (gracefully hides via
        //     the `if isAnyAudio` outer gate)
        // Net effect: the pill ALWAYS has visual content on the
        // right when any audio is active, but the bars only animate
        // when actual music is playing. No flicker, no empty space.
        // 2026-05-01: dropped the bundle-ID allow-list entirely.
        // The waveform's playing state is now driven by the
        // CoreAudio-sourced `presenter.isAudioFlowing` signal
        // (PanelPresenter), which is set by SystemAudioWatcher
        // every second based on `kAudioProcessPropertyIsRunningOutput`.
        // CoreAudio reports `true` only if audio bytes are actually
        // hitting the output device this tick — it can't lie or
        // flicker the way Spotify's `isPlaying` flag did during
        // track transitions. So we can let ANY audio source drive
        // the waveform animation; if the user pauses, CoreAudio
        // drops the signal within ~1 second and the waveform
        // freezes naturally.
        let info = presenter.nowPlaying
        let hasAnyAudio = info != nil || presenter.isAudioFlowing
        // Phase A — standalone Focus pill mode. When Focus is on but
        // no music is playing AND no audio is flowing, the panel
        // geometry shrinks to focusOnlyPillFrame (200pt × bump) via
        // enterRestingMode's three-way frame choice. The HStack
        // below detects this case and lays out a centered moon +
        // "Focus" cluster — no artwork, no waveform, no extra
        // separators. Same outer modifier chain as the music
        // path so swipe-to-skip etc continue to work seamlessly.
        // 2026-05-09: hard-disabled the inline focus-only render
        // path (was: `presenter.isFocused && info == nil && !
        // presenter.isAudioFlowing`). The new `focusPillContent`
        // route in `pillContentOverlay` (gated on `focusPillVisible`)
        // owns ALL focus-mode pill rendering — both nox's own
        // `noxFocusMode` and macOS-Focus paths. Keeping the old
        // branch around as a no-op so the rest of the HStack
        // structure (`if/else`) doesn't have to be rewritten.
        let isFocusOnlyMode = false
        return HStack(spacing: 6) {
            if isFocusOnlyMode {
                Spacer(minLength: 0)
                Image(systemName: "moon.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                // Live duration timer. TimelineView ticks at most
                // once per minute (we only display M / Hh Mm). The
                // start time comes from FocusStatusService via
                // PanelPresenter.focusSessionStartedAt; if it's
                // nil for any reason we fall back to "Focus"
                // without a timer rather than showing 0m forever.
                if let started = presenter.focusSessionStartedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(focusElapsedLabel(since: started, now: ctx.date))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .kerning(0.2)
                            .lineLimit(1)
                            .fixedSize()
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Focused for \(focusElapsedLabel(since: started, now: Date()))")
                } else {
                    Text("Focus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .kerning(0.2)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel("Focus mode is on")
                        .accessibilityHint("Non-essential pings are paused")
                }
                Spacer(minLength: 0)
            } else {
            pillArtwork
            Spacer(minLength: 0)
            // 2026-05-01 evidence-based fix. /tmp/notetaker-mra.log
            // captured: user pauses YouTube → AUDIOWATCHER never logs
            // a flip to false. Chrome keeps its audio helper's IO
            // procs alive across the pause (presumably for low-latency
            // resume), so kAudioProcessPropertyIsRunningOutput
            // returns true with silence flowing. `isAudioFlowing` is
            // therefore NOT a reliable "is something playing?" signal
            // for browser-sourced audio.
            //
            // MediaRemote's isPlaying flag IS reliable: when the user
            // pauses, MR either flips it or stops emitting (nil),
            // both of which fail the gate below.
            //
            // Combined gate:
            //   • nowPlaying with isPlaying=true → animate
            //   • nowPlaying with isPlaying=false → freeze (user paused)
            //   • no nowPlaying but audio flowing → animate (synthetic
            //     no-MR case: Discord chime, system tone — short bursts
            //     where we want some life on the pill)
            //   • no nowPlaying, no audio → frozen
            let waveformIsPlaying: Bool = {
                if let np = presenter.nowPlaying {
                    return np.isPlaying
                }
                return presenter.isAudioFlowing
            }()
            if hasAnyAudio {
                WaveformView(
                    isPlaying: waveformIsPlaying,
                    width: 26,
                    height: 18,
                    lineWidth: 2.8,
                    // Tint + pattern BOTH read from displayedNowPlaying /
                    // displayedTrackKey (lagged) so all three signals —
                    // artwork, wave shape, color — flip in lockstep at
                    // the moment the banner finishes its 3D card flip.
                    // See the matching site in `combinedPillContent`
                    // for the full story.
                    tint: ArtworkColor.dominant(from: displayedNowPlaying?.artworkData) ?? .white,
                    opacity: 0.95,
                    pattern: WaveformPattern.deterministic(for: displayedTrackKey),
                    isCompactResting: true,
                    isInteractionActive: abs(pillSwipeOffset) > 0
                        || presenter.isMorphing
                        || presenter.trackChangedFiring
                )
                .scaleEffect(x: waveformPulse, y: 1, anchor: .trailing)
                .transition(.opacity)
            }
            // Focus-mode group (layout option 8 from
            // docs/focus-indicator-layouts.html): when the system
            // Focus / DND is on and we have authorization to read
            // it, render an explicit "Focus" cluster after the
            // waveform — divider + moon + label.
            //
            // Suppression of ambient pills (charger / screenshot /
            // Bluetooth) is handled by PanelPresenter.setPendingSystemEvent.
            // This cluster is the visible counterpart that tells the
            // user "yes, nox sees your Focus is on."
            //
            // The host pill widens by `focusPillExtraWidth` (50pt) via
            // PanelWindowController.morphRestingFrameForFocusChange()
            // so this content has room without crowding the waveform.
            // Fade-in/out via the .animation(value: presenter.isFocused)
            // modifier below — synced with the panel.frame morph.
            // 2026-05-09: hard-disabled the inline "Focus indicator
            // alongside music" cluster (was: divider + moon.fill +
            // focusElapsedLabel timer). Diagnostic logging revealed
            // this was firing whenever Spotify had a paused track
            // (nowPlaying != nil → musicPillContent path → this
            // cluster). User saw it as the OLD "1m + moon" pill
            // even after focusPillVisible was supposed to take over.
            //
            // Now `pillContentOverlay`'s `else if focusPillVisible`
            // branch (which doesn't gate on nowPlaying anymore)
            // owns ALL focus-mode pill rendering: aura + live
            // session timer in place of the music pill, regardless
            // of whether music is paused/playing in the background.
            if false {
                EmptyView()
            }
            } // closes the `else` branch of isFocusOnlyMode opened
              // up at the top of the HStack body
        }
        .animation(.easeInOut(duration: 0.20), value: hasAnyAudio)
        // Match PanelWindowController.morphRestingFrameForFocusChange's
        // 0.30s out-quint curve EXACTLY so the SwiftUI fade-in/out of
        // the divider+moon+"Focus" text lands on the same beat as the
        // panel.frame grow/shrink. Mismatched curves at the same
        // duration tick at different speeds at the midpoint and look
        // staggered (same fix as the .timingCurve in the pill swap
        // animation lower in this file).
        .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.30),
                   value: presenter.isFocused)
        // Swipe-to-skip chevron hints. As the user drags past the
        // skip threshold, a chevron arrow fades in on the side
        // OPPOSITE the drag direction — i.e., dragging right
        // (commit "next") reveals a chevron.right glyph fading in
        // from the right edge, telling the user "release to skip
        // forward." Bright + slightly larger when the threshold
        // crosses (`pillSwipeArmedDirection != 0`), faint otherwise.
        // Mirrors how Apple's Mail swipe-to-archive surfaces its
        // commit affordance.
        .overlay(
            HStack {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .opacity(swipeChevronOpacity(side: .left))
                    .scaleEffect(swipeChevronScale(side: .left))
                    .padding(.leading, 4)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .opacity(swipeChevronOpacity(side: .right))
                    .scaleEffect(swipeChevronScale(side: .right))
                    .padding(.trailing, 4)
            }
            .allowsHitTesting(false)
        )
        // Swipe-to-skip. Horizontal drag on the resting pill triggers
        // previous (left swipe) or next (right swipe). Driven by a
        // SwiftUI DragGesture with a 10pt minimum distance so
        // straight clicks (used for tap-to-expand the slab) still
        // pass through. Visual feedback: the whole pill shifts
        // ±20pt during the drag (now via a soft sqrt curve so it
        // tugs less than 1:1 with the finger — feels rubber-banded
        // rather than dragged), giving the user a "tug" affordance
        // before the threshold commits.
        .offset(x: rubberBandedSwipeOffset)
        .simultaneousGesture(
            // 2026-05-17 sprint Session 2 — Alcove parity. The
            // entire decision rule now lives in SwipeGesturePolicy
            // (extracted struct, fully unit-tested) so this view
            // just translates DragGesture deltas into policy
            // inputs and reacts to the policy's decision. Changes
            // vs the 1.9.20 inline rule:
            //   • Separate `success` and `reset` thresholds give a
            //     soft dead-band at the start of the drag
            //   • `naturalSwipeDirection` flips the forward axis
            //   • Reset spring sourced from policy defaults
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard pillSwipeEnabled,
                          presenter.nowPlaying != nil,
                          presenter.isResting,
                          !presenter.isShown
                    else { return }
                    let dx = value.translation.width
                    let dy = abs(value.translation.height)
                    // Near-horizontal gate (tan(20°) ≈ 0.36) so
                    // diagonal-down scrolls don't trigger a skip.
                    guard dy < abs(dx) * 1.2 else { return }
                    pillSwipeOffset = dx
                    let decision = SwipeGesturePolicy.decide(.init(
                        delta: dx,
                        phase: .changed,
                        naturalMovement: naturalSwipeDirection,
                        successThreshold: SwipeGesturePolicy.defaultSuccessThreshold,
                        resetThreshold: SwipeGesturePolicy.defaultResetThreshold))
                    switch decision {
                    case .commitForward where pillSwipeArmedDirection != 1:
                        // Crossed the threshold — tug haptic once
                        // per crossing.
                        HapticFeedback.generic()
                        pillSwipeArmedDirection = 1
                    case .commitBackward where pillSwipeArmedDirection != -1:
                        HapticFeedback.generic()
                        pillSwipeArmedDirection = -1
                    case .idle, .scrubbing:
                        if pillSwipeArmedDirection != 0 {
                            pillSwipeArmedDirection = 0
                        }
                    default:
                        break
                    }
                }
                .onEnded { value in
                    guard pillSwipeEnabled,
                          presenter.nowPlaying != nil,
                          presenter.isResting,
                          !presenter.isShown
                    else {
                        pillSwipeOffset = 0
                        pillSwipeArmedDirection = 0
                        return
                    }
                    let decision = SwipeGesturePolicy.decide(.init(
                        delta: value.translation.width,
                        phase: .ended,
                        naturalMovement: naturalSwipeDirection,
                        successThreshold: SwipeGesturePolicy.defaultSuccessThreshold,
                        resetThreshold: SwipeGesturePolicy.defaultResetThreshold))
                    switch decision {
                    case .commitForward:
                        presenter.onMediaCommand?(.next)
                        HapticFeedback.alignment()
                    case .commitBackward:
                        presenter.onMediaCommand?(.previous)
                        HapticFeedback.alignment()
                    case .reset, .idle, .scrubbing:
                        break
                    }
                    withAnimation(NoxAnimations.swipeReset) {
                        pillSwipeOffset = 0
                    }
                    pillSwipeArmedDirection = 0
                }
        )
        // Track-change side effects:
        //  1. Update `pendingTrackSwap` to drive the artwork-swap
        //     animation. We use an explicit state-based fade
        //     orchestrated below (rather than a SwiftUI `.transition`
        //     attached to `.id(trackKey)`) because NSHostingView's
        //     animation context propagation through `.id()` boundaries
        //     is unreliable in this codebase — `.transition` sometimes
        //     fires, sometimes doesn't, depending on how the
        //     `@Published` update is delivered. State-based phase
        //     control always works.
        //  2. Pulse the waveform horizontally — purely visual, runs
        //     parallel to the artwork lift.
        // Filter on `trackKey` change only; pause/play toggles, elapsed-
        // time ticks, and pure artwork-data updates leave the pill alone.
        .onAppear {
            // Seed displayed state so the first track that ever plays
            // doesn't trigger a phantom "fade out → fade in" animation
            // (there's nothing to fade out from). Subsequent track
            // changes go through `triggerSongChange`.
            //
            // Idempotent across multiple onAppear calls (panel can be
            // unmounted and remounted): we only seed when nothing has
            // ever been displayed AND nothing is currently displayed,
            // so a second mount with a non-nil `presenter.nowPlaying`
            // doesn't double-snap and clobber state from a swap that's
            // mid-flight.
            if !hasEverDisplayedTrack && displayedNowPlaying == nil {
                displayedNowPlaying = presenter.nowPlaying
                displayedTrackKey = trackKey
                if presenter.nowPlaying != nil {
                    hasEverDisplayedTrack = true
                }
            }
            // Initial cache lookup for whatever's displayed.
            refreshPillArtworkImage()
        }
        .onChange(of: displayedNowPlaying) { _ in
            // Refresh the cached NSImage every time the displayed
            // track changes. Cache hit (already-decoded) returns
            // synchronously and lands in `pillArtworkImage` this
            // render — zero perceived load. Cache miss kicks off a
            // background decode; when it completes, the closure
            // updates `pillArtworkImage` and SwiftUI re-renders
            // with the new image. Either path keeps decode off
            // the main thread.
            refreshPillArtworkImage()
        }
        // When the slab opens or closes, hard-reset any in-flight
        // pill artwork animation so the pill never shows a stale
        // intermediate phase. Without this, a track change that
        // happened during the open animation would leave
        // `trackSwapPhase` non-zero, and on close the pill would
        // briefly flash the artwork at an offset/blur position
        // before snapping to settled.
        // Sync the music-pill state to the latest track WHEN the
        // trackChangedFiring flag goes false (banner just finished
        // dismissing). During the banner's lifetime we DELIBERATELY
        // hold the music pill at the OLD track's artwork so the
        // resting pill (visible during the 250ms pre-show window
        // AND immediately after the banner retracts) doesn't change
        // before the banner's flip animation. AppDelegate clears
        // the flag in dismissTrackBanner's completion handler;
        // that's our cue to update the pill to the new state.
        // Use .onReceive on the @Published publisher directly,
        // not .onChange. SwiftUI's `.onChange(of:)` was dropping the
        // true→false transition (verified via fileLog tracing —
        // .onChange fired for true but never for false). .onReceive
        // attaches to the Combine publisher and fires on every emission.
        .onReceive(presenter.$trackChangedFiring) { firing in
            if !firing, let cur = presenter.nowPlaying {
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) {
                    displayedNowPlaying = cur
                    displayedTrackKey = "\(cur.title)|\(cur.artist)"
                    trackSwapPhase = 0
                }
                refreshPillArtworkImage()
            }
        }
        .onChange(of: presenter.isShown) { _ in
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                trackSwapPhase = 0
                waveformPulse = 1.0
                // Sync displayed state to current if the track
                // changed while the slab was open. Comparing keys
                // avoids redundant work when nothing changed.
                let curKey = presenter.nowPlaying.map { "\($0.title)|\($0.artist)" } ?? ""
                if curKey != displayedTrackKey, let cur = presenter.nowPlaying {
                    displayedNowPlaying = cur
                    displayedTrackKey = curKey
                }
            }
            // ALWAYS refresh the pill artwork on open/close —
            // even if displayedTrackKey didn't change here. Why:
            //
            // When the user changes track from inside the slab,
            // Branch 4 of `.onChange(of: presenter.nowPlaying)`
            // takes the `isShown` early-return path and updates
            // displayedTrackKey + displayedNowPlaying to the new
            // track. If Spotify emits in two stages (track meta
            // first, artwork bytes second) AND the slab closes
            // BEFORE the artwork emission lands (or the second
            // emission is dropped by the source app — some
            // versions of Spotify only emit once), pillArtworkImage
            // stays at the nil it was set to during the first
            // emission's refresh call. The pill becomes visible
            // showing the music-note placeholder for the new track.
            //
            // Calling refreshPillArtworkImage() unconditionally
            // here recovers from that race: by the time the slab
            // closes, the source app has typically settled and
            // the artwork bytes are in `presenter.nowPlaying`.
            // refreshPillArtworkImage's "preserve on diff" logic
            // (see its body) handles the still-loading case
            // correctly — preserves existing image when key
            // matches, clears only when key truly differs.
            //
            // The earlier "comparing track keys means same-track
            // refreshes don't trip this handler" rationale was
            // wrong on a key edge: when track change + artwork-
            // load race overlap with slab-close, the pill needs
            // a defensive refresh.
            refreshPillArtworkImage()
        }
        .onChange(of: presenter.nowPlaying) { newInfo in
            NSLog("nox: 📻 nowPlaying changed title=\(newInfo?.title ?? "nil") artwork=\(newInfo?.artworkData?.count ?? 0)b oldKey=\(displayedTrackKey)")
            // Single dispatcher for every now-playing update.
            // Branches:
            //  1. Same track, content fields refreshed (artwork
            //     loaded asynchronously, isPlaying toggled, elapsed
            //     time updated) → silent update of `displayedNowPlaying`
            //     so the new artwork appears without animation.
            //  2. True first-ever track (nothing has ever played in
            //     this session) → snap to it, no animation (there
            //     was no prior artwork to fade out from).
            //  3. Music ended (newInfo == nil) → fade out only,
            //     don't run the entry phase (would flash the
            //     placeholder glyph briefly as the pill collapses).
            //  4. Genuine track change OR music restart after a stop
            //     → run the two-phase vertical-lift animation. The
            //     entry phase reads from `presenter.nowPlaying` at
            //     swap time, so a restart-from-nil correctly enters
            //     the new artwork from below.
            let newKey = "\(newInfo?.title ?? "")|\(newInfo?.artist ?? "")"

            // Branch 1: same track, just a content refresh
            if newKey == displayedTrackKey && displayedNowPlaying != nil && newInfo != nil {
                displayedNowPlaying = newInfo
                return
            }
            // Branch 2: true first-ever track this session
            if !hasEverDisplayedTrack && displayedNowPlaying == nil {
                displayedNowPlaying = newInfo
                displayedTrackKey = newKey
                if newInfo != nil {
                    hasEverDisplayedTrack = true
                }
                return
            }
            // Branch 3: music ended (or transient nil during a pause)
            if newInfo == nil {
                // 2026-05-01 sticky-on-resting fix. When the user
                // pauses YouTube and MediaRemote subsequently goes
                // silent (or emits an explicit nil), we don't want
                // to blank the pill's artwork while the pill is
                // STILL VISIBLE — it makes the thumbnail vanish for
                // the duration of the post-audio grace window. Keep
                // the last-good displayedNowPlaying as long as the
                // pill is in resting mode; the thumbnail and title
                // stay correct, the play/pause icon flips via
                // `isAudioFlowing`, and when the user resumes audio
                // the same-track emission lands in Branch 1
                // (smooth refresh, no animation).
                //
                // We only run the music-ended fade animation when
                // the pill is NOT resting — i.e. the pill is
                // actually retracting (or already retracted) and
                // the artwork-fade is the visual companion to that.
                if presenter.isResting {
                    return
                }
                trackSwapGeneration &+= 1
                let gen = trackSwapGeneration
                withAnimation(.easeIn(duration: 0.18)) {
                    trackSwapPhase = -1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    // Bail if a later track-start (or another stop)
                    // has already superseded this fade. The newer
                    // call owns the displayed state from this point.
                    guard gen == trackSwapGeneration else { return }
                    displayedNowPlaying = nil
                    displayedTrackKey = newKey
                    trackSwapPhase = 0
                }
                return
            }
            // Branch 4: real track change OR music restart → animate.
            // BUT: if the slab is currently OPEN, the pill is hidden
            // (opacity 0) and any animation we run on the pill
            // artwork can leave it stuck mid-phase. When the user
            // closes the slab, the pill suddenly reappears at the
            // stale phase position and looks like a glitch. Skip
            // the animation when hidden — silent state update
            // instead. User: "the small pills thumbnails sometime
            // gliching in background while opening the main pill."
            //
            // Same fix applies when a `.trackChanged` ANNOUNCEMENT
            // banner is up: the music pill is replaced by the
            // banner content overlay, so the user can't see the
            // music pill at all. Animating its artwork swap behind
            // the banner is invisible work; worse, with two-stage
            // Spotify emissions (metadata first, artwork ~50ms
            // later), `triggerSongChange`'s 180ms swap point can
            // land BEFORE the artwork bytes arrive — committing
            // `displayedNowPlaying` with `artworkData=nil`. When
            // the banner dismisses, the pill renders the new
            // track's title/artist with a placeholder glyph
            // because `pillArtworkImage` was set to nil. User
            // 2026-05-07: "even though music change the small
            // pill thumbnail is unchanged."
            // Snap directly to current state and refresh —
            // identical handling to the slab-open path.
            let trackChangedAnnouncing: Bool = {
                if case .trackChanged = presenter.pendingSystemEvent { return true }
                return false
            }()
            // Slab open: snap directly (the music pill is hidden
            // behind the slab, no visible animation needed).
            if presenter.isShown {
                displayedNowPlaying = newInfo
                displayedTrackKey = newKey
                trackSwapPhase = 0
                hasEverDisplayedTrack = true
                refreshPillArtworkImage()
                return
            }
            // Track-change banner about to fire OR currently showing:
            // HOLD the music pill state at OLD values. The banner does
            // the visible card-flip from old artwork → new artwork; the
            // music pill (visible during pre-show, hidden during banner,
            // visible again after dismiss) should keep showing the OLD
            // artwork until the banner finishes — otherwise the user
            // sees the music pill artwork change BEFORE the banner's
            // flip animation begins (user feedback 2026-05-07: "before
            // that it's showing the artwork change for some reason. Maybe
            // some old code left the artwork in the small build still
            // showing").
            //
            // The pill state gets synced to the new track in
            // `.onChange(of: presenter.trackChangedFiring)` below, which
            // fires when AppDelegate clears the flag in the
            // dismissTrackBanner completion handler.
            if trackChangedAnnouncing || presenter.trackChangedFiring {
                // Don't touch displayedNowPlaying / displayedTrackKey /
                // trackSwapPhase / pillArtworkImage. The OLD state
                // remains, so the music pill keeps showing the previous
                // track's artwork during the pre-show delay AND through
                // the banner sustain.
                return
            }
            if displayedNowPlaying == nil {
                trackSwapPhase = -1
            }
            triggerSongChange(newKey: newKey)
            // Snap waveform to compressed state, then spring back. The
            // explicit transaction with disablesAnimations prevents the
            // ambient onChange animation context from interpolating the
            // 1.0 → 0.85 step (which would cancel the squeeze visually).
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                waveformPulse = 0.85
            }
            // Spring-back to 1.0 with overshoot. Lower damping (0.55)
            // gives the waveform a visible bounce as it settles —
            // the "snap" the user reads as energy. Smooth interp
            // was correct but flat; this adds a tiny rebound that
            // makes the pulse feel alive.
            withAnimation(NoxAnimations.quickAnticipation) {
                waveformPulse = 1.0
            }
        }
        // Horizontal padding 8pt — anchors the artwork at the LEFT
        // EDGE of the pill (left of the camera notch) and the
        // waveform at the RIGHT EDGE (right of the notch). The
        // physical notch is centered on the display; the pill
        // extends about 35pt past the notch on each side, and the
        // artwork/waveform sit in those side strips with just enough
        // padding (8pt) to clear the bottom-corner curves. This is
        // the canonical Alcove layout — content hugging the pill's
        // outer edges with the camera as the natural visual anchor
        // in the middle. Earlier rounds tried 32pt (pulled content
        // toward the center, which the user explicitly rejected:
        // "it should in the left edge ... macbook have a notch at
        // center"), 18pt (still felt off), and now 14pt (settles
        // with the new inverse-bow silhouette).
        //
        // Padding tuning history (with the inverse-bow silhouette
        // — panelTopRadius=6 for the resting pill eats 6pt off
        // each side of the rect):
        //   8pt:  artwork sat 2pt inside the body edge, visually
        //         "falling off" — user: "thumbnail is too at edge"
        //   14pt: pulled too far inward — user: "now it's too right"
        //   10pt: current — 6pt shoulder reserve + 4pt visual gap.
        //         Artwork hugs the body edge with just enough
        //         breathing room to not read as "clipped."
        .padding(.horizontal, 10)
        // Content lives in the menu-bar zone ONLY (`notchOverlap`
        // = 32pt), NOT in the bump area below. This matches
        // Alcove's pattern where the artwork sits in the upper
        // portion of the pill (level with the menu bar) and the
        // bump is a clean rounded curl below — no content. If we
        // extended the content frame into the bump, the artwork
        // would shift downward into the curl area and look like
        // it's spilling out of the menu-bar zone.
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        // 2026-05-04: 14→8 — same FPS optimization as the slab cascade.
        // This blur fires when the music pill morphs into the slab, the
        // single most GPU-heavy moment of the open animation.
        .blur(radius: presenter.isResting && !presenter.isShown ? 0 : 8)
        // Direction-aware spring on isShown change (open/close).
        .animation(presenter.isShown
                   ? .interpolatingSpring(mass: 1.0, stiffness: 195, damping: 28, initialVelocity: 0)
                   : .interpolatingSpring(mass: 1.0, stiffness: 380, damping: 36, initialVelocity: 0),
                   value: presenter.isShown)
        // ALSO animate on isResting change (music start/stop).
        // User 2026-05-05: "there is no animation between the small
        // pill and no pill ... when it's transitioning between the
        // small pill (music) to silent."
        //
        // exitRestingMode animates panel.frame 302→185 over ~270ms
        // (300/32 spring), but without this the music pill CONTENT
        // (artwork + waveform) was snapping to invisible because the
        // animation above only fires on isShown change. Now the
        // content fades+blurs smoothly with the panel shrink — same
        // spring as exitRestingMode for synced motion.
        .animation(.interpolatingSpring(mass: 1.0, stiffness: 300, damping: 32, initialVelocity: 0),
                   value: presenter.isResting)
        .allowsHitTesting(false)
    }

    /// Stable identity for the current track. Changes when title or
    /// artist changes (i.e. user skipped, queue advanced, or source
    /// app picked a new track). Drives the artwork's `.id()` modifier
    /// so SwiftUI treats a new track as a fresh view → fires the
    /// `.verticalLift` transition for the swap. Includes both fields
    /// because some sources publish the same title across artists
    /// (covers, multi-artist compilations) and we want those treated
    /// as distinct tracks.
    private var trackKey: String {
        let info = presenter.nowPlaying
        return "\(info?.title ?? "")|\(info?.artist ?? "")"
    }

    /// Run the two-phase vertical-lift song-change animation. Phase 1:
    /// the OLD artwork (still in `displayedNowPlaying`) animates from
    /// rest to "exited up" — `trackSwapPhase` 0 → -1 over 0.18s, which
    /// drives offset 0 → -4pt, blur 0 → 7pt, opacity 1 → 0. Phase 2:
    /// after the first phase completes, snap `displayedNowPlaying` to
    /// the new track and `trackSwapPhase` to +1 (positioned 4pt below
    /// resting, fully blurred and invisible — no flash because all
    /// three modifiers leave the artwork at zero alpha at this point),
    /// then animate `trackSwapPhase` +1 → 0 over 0.22s for the
    /// rise-into-place. Total animation is 0.40s of perceived motion,
    /// well within Apple HIG's "deliberate" range.
    ///
    /// Note: we don't use SwiftUI's `.transition()` modifier because
    /// the animation context propagation through NSHostingView's
    /// `.id()` boundaries is unreliable in this codebase — the
    /// transition would sometimes fire and sometimes not, depending
    /// on the path the @Published update came through. Explicit
    /// state-based phase control fires deterministically every time.
    private func triggerSongChange(newKey: String) {
        NSLog("nox: 🎵 triggerSongChange firing newKey=\(newKey) oldKey=\(displayedTrackKey)")
        // Smoother two-phase animation. User reported the previous
        // version had the thumbnail "getting delated suddenly" mid-
        // transition — that was caused by `easeIn` (which spends
        // most of its time at low opacity then snaps to invisible
        // at the very end) combined with imperfect timing between
        // the asyncAfter and the animation completion.
        //
        // Fix: use `.smooth` for BOTH phases (gentle ease in/out
        // throughout, no sudden snap), and overlap the swap by
        // ~30ms so the new artwork starts entering BEFORE the old
        // one is fully cleared — the eye perceives one continuous
        // gesture instead of two sequential events.
        let fadeOut: TimeInterval = 0.22
        let fadeIn: TimeInterval = 0.42
        // 2026-05-01 anime.js-inspired refinement: swap point pulled
        // 40ms before fadeOut completes so the new artwork enters
        // while the old one is still mid-exit. The cross-over
        // dissolves the seam — eye reads it as one continuous
        // motion, the way anime.js stages overlapping in/out tweens
        // on the same element. Spring on the in-side picks up from
        // wherever phase landed (~-0.82, not full -1), so it
        // immediately surges back instead of starting from a dead
        // stop at full-exit.
        let swapPoint: TimeInterval = fadeOut - 0.04

        // Generation token: each invocation captures `gen` into its
        // dispatched closures, then bails on entry if the field has
        // moved on (a newer skip arrived). Prevents stale closures
        // from a prior A→B swap from clobbering the displayed state
        // mid-flight in a rapid A→B→C→D scrub. `&+=` so we don't
        // crash on Int overflow over a multi-decade session.
        trackSwapGeneration &+= 1
        let gen = trackSwapGeneration
        hasEverDisplayedTrack = true

        // Phase 1: anime.js-flavored ease-in-out cubic-bezier.
        // (0.4, 0, 0.2, 1) is the same shape anime.js calls
        // "easeInOutQuart" — slow start, accelerated middle, soft
        // landing. Replaces SwiftUI's generic `.smooth`, which has
        // a flatter middle that makes the artwork seem to drift out
        // rather than commit to leaving.
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: fadeOut)) {
            trackSwapPhase = -1
        }
        // Phase 2: swap data and animate back to rest from the
        // CURRENT phase (no opposite-side snap). The previous code
        // teleported from phase=-1 to phase=+1 before springing to
        // 0, which read as a visible "jump" — exactly what the user
        // reported on next-click. Now the new artwork tilts back
        // from the SAME side the old one left, one continuous
        // motion. Less dramatic visually but smoother.
        DispatchQueue.main.asyncAfter(deadline: .now() + swapPoint) {
            guard gen == trackSwapGeneration else { return }
            displayedNowPlaying = presenter.nowPlaying
            displayedTrackKey = newKey
            // anime.js's signature elastic settle: the new artwork
            // surges back with a subtle 6-7% overshoot, then double-
            // bounces into rest. response=0.55 stretches the bounce
            // period long enough that the eye reads it as ELASTIC
            // (not a snap), dampingFraction=0.66 leaves visible
            // amplitude on the secondary oscillation (~0.7%) before
            // settling. Matches the character of anime.js's
            // `spring(1, 100, 10, 0)` — playful but composed.
            withAnimation(NoxAnimations.trackArrival) {
                trackSwapPhase = 0
            }
        }
        // Safety reset: if the dispatched closures above never run
        // (main-thread stall, app suspended mid-swap and resumed past
        // the dispatch deadline, generation-guard bailed because a
        // newer swap took over but THAT one also stalled), the
        // artwork would be stuck at trackSwapPhase = -1 (offset -8pt,
        // 12pt blur, alpha 0 — invisible). After the full animation
        // budget plus generous slack we force trackSwapPhase back to
        // 0 IF this generation is still the latest, so the pill never
        // gets visually wedged. Wrapped in withAnimation so it doesn't
        // pop in if it actually runs.
        let safetyDeadline = swapPoint + fadeIn + 0.20
        DispatchQueue.main.asyncAfter(deadline: .now() + safetyDeadline) {
            guard gen == trackSwapGeneration else { return }
            if trackSwapPhase != 0 {
                NSLog("nox: ⚠️ song-change safety reset firing (phase=\(trackSwapPhase))")
                withAnimation(.smooth(duration: 0.18)) {
                    trackSwapPhase = 0
                }
            }
        }
    }

    /// 22×22 album-art tile sized to fill the 32pt notch zone
    /// substantially — leaves ~5pt of breathing room above (clears
    /// the camera lens) and below (clears the menu-bar bottom edge).
    /// Earlier rounds tried 14pt (looked dwarfed inside the notch),
    /// 16pt (still felt small once the notch zone was the full 32pt
    /// host instead of a 20pt bump), and 22pt (current) — at which
    /// point the user said "looking right" alongside Alcove. Reads
    /// as the dominant content element of the pill, the way Apple
    /// Music / Spotify mini-players treat their artwork.
    ///
    /// Reads from `displayedNowPlaying` (not `presenter.nowPlaying`)
    /// so the song-change animation can keep showing the OLD image
    /// during the fade-out phase. The `.offset` / `.blur` / `.opacity`
    /// modifiers follow `trackSwapPhase`: 0 at rest, animates to -1
    /// on track change (fade out upward), snaps to +1 (positioned
    /// below for entry), animates back to 0 (fade in from below).
    /// 4pt of vertical travel is ~18% of the artwork height — visible
    /// but contained; 7pt of blur is enough to read as "softening"
    /// without dissolving into a smear.
    /// The cache key associated with the currently-displayed
    /// `pillArtworkImage`. Tracked separately so we can detect
    /// "image is for a stale track" vs. "image is for the right
    /// track but data not yet loaded" — the two cases behave
    /// differently in `refreshPillArtworkImage`.
    @State private var pillArtworkImageKey: String = ""

    /// Refresh the resting-pill's decoded NSImage from `ArtworkCache`.
    /// Synchronous cache hit lands the image in `pillArtworkImage`
    /// this render; a miss decodes the JPEG on the main thread
    /// (~30-50ms) and stores the result for subsequent renders.
    ///
    /// The displayed track key is used as the cache key, so going
    /// BACK to a recently-played track returns the prior NSImage
    /// instantly — no re-decode, no flash, no main-thread block.

    private func refreshPillArtworkImage() {
        guard let info = displayedNowPlaying else {
            MediaRemoteAdapterService.fileLog("PILL refresh: displayedNowPlaying=nil → clearing pillArtworkImage")
            pillArtworkImage = nil
            pillArtworkImageKey = ""
            return
        }
        let key = "\(info.title)|\(info.artist)"
        let bytes = info.artworkData?.count ?? 0
        let newImage = ArtworkCache.shared.image(data: info.artworkData, key: key)
        MediaRemoteAdapterService.fileLog("PILL refresh: title=\"\(info.title)\" artist=\"\(info.artist)\" bytes=\(bytes) decoded=\(newImage != nil)")

        if let newImage = newImage {
            pillArtworkImage = newImage
            pillArtworkImageKey = key
            return
        }

        // No image returned (data was nil OR decode failed). Two
        // sub-cases that need different handling:
        //
        // a) The track CHANGED (key != pillArtworkImageKey): the
        //    previous image belongs to a DIFFERENT song. Keeping it
        //    on screen would show wrong artwork for the wrong track
        //    — clear to placeholder until the right artwork loads.
        //
        // b) The track is the SAME (key == pillArtworkImageKey): the
        //    new info is just a metadata refresh that happens to lack
        //    artwork (Spotify's two-stage emission, or a play/pause
        //    update). The previous image IS for this track — KEEP it
        //    on screen to avoid the "image disappears for 1-2s while
        //    waiting for re-fetch" flash. iTunes Search / cache will
        //    populate later and a subsequent refreshPillArtworkImage
        //    call will swap to the freshly-decoded image.
        //
        // This is the same "preserve on diff" pattern boring.notch
        // (TheBoredTeam/boring.notch) uses in NowPlayingController:
        // they preserve previous artwork on partial updates, only
        // clearing on a true full-update with explicit nil.
        if key != pillArtworkImageKey {
            pillArtworkImage = nil
            pillArtworkImageKey = key
        }
        // else: same track, no new image — keep existing
        // pillArtworkImage on screen. Don't update pillArtworkImageKey.
    }

    /// 2026-05-01: REVERTED PillFlipArtworkView experiment.
    /// Multiple integration issues with the parent's state-update
    /// timing. Back to the ORIGINAL SwiftUI version that was
    /// working before any of today's flip experiments.
    private var pillArtwork: some View {
        Group {
            if let img = pillArtworkImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        // anime.js-inspired refinement (2026-05-01): the 22pt artwork
        // is too small for noisy rotation+big offset to read as
        // anything other than chaos. Stripped down to scale + opacity
        // + soft blur, with a tiny lift, all driven by a phase scalar
        // that animates with a custom timing curve out and an elastic
        // spring back. Reads as a clean iris that the new artwork
        // pops back into with a delicate bounce — anime.js's "small
        // moves, exquisitely tuned" aesthetic, not the previous
        // flip-card spectacle.
        .offset(y: trackSwapPhase * 3)
        .blur(radius: abs(trackSwapPhase) * 5)
        .opacity(1 - abs(trackSwapPhase))
        .scaleEffect(1.0 - abs(trackSwapPhase) * 0.22)
    }

    // MARK: - Background layers

    private var panelBackground: some View {
        ZStack {
            // 2026-05-20 — RESTORED VisualEffectBlur underlay,
            // tuned for "matte black with a hint of glass" instead
            // of the earlier "very translucent glass" that the
            // 2026-05-13 `style: tone down live panel glass` commit
            // ripped out. Why bring it back: VisualEffectBlur now
            // routes through `NSGlassEffectView` on macOS 26 Tahoe
            // (see VisualEffectBlur.swift) — the new Liquid Glass
            // material adds a specular highlight pass on top of
            // the backdrop blur, catching light along the slab's
            // silhouette edge for the first time. Without this
            // underlay the Tahoe shine has nothing to land on.
            //
            // The black gradients above it are at HIGH opacity
            // (0.96-0.98) so the slab still reads as matte from
            // arm's length — only edge highlights leak through.
            // User feedback that triggered the original removal
            // ("apply color on cards so it feels more premium")
            // remains honored: this isn't a colored wash, it's a
            // dark surface that catches Tahoe's specular light.
            //
            // On macOS 14-15 (no NSGlassEffectView): the blur
            // layer renders as ~2% perceptible difference vs the
            // earlier solid LinearGradient. No regression.
            // On macOS 26+: visible edge shine + subtle inner
            // depth that reads as "the slab is made of glass."
            VisualEffectBlur(material: .hudWindow,
                             blendingMode: .behindWindow)
                .opacity(presenter.isShown ? 1 : 0)

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.97), location: 0.00),
                    .init(color: Color(red: 0.018, green: 0.018, blue: 0.020).opacity(0.96), location: 0.46),
                    .init(color: Color.black.opacity(0.98), location: 1.00),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(presenter.isShown ? 0.026 : 0),
                    Color.clear,
                    // Corner glow follows the shared `panelAccent`
                    // (music color when playing, lavender otherwise).
                    // Kept at a very low opacity so the slab still
                    // reads as matte black with a faint corner hint —
                    // the LOUD music color now lives on the music
                    // card instead of the background wash (per user
                    // feedback 2026-05-13: "apply the color on cards
                    // so it feels more premium" — replaces the
                    // earlier `nowPlayingAmbientTint` radial wash
                    // which was washing the whole panel).
                    panelAccent.opacity(presenter.isShown ? 0.018 : 0)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        }
    }

    /// Quiet 0.5pt rim around the silhouette — Alcove's signature
    /// treatment. Just enough edge definition to keep the slab from
    /// dissolving into very-dark wallpapers, but not so bright it
    /// reads as a sheen on glass. White at 6% opacity is below the
    /// noise floor of most desktops; the user reads it as "the slab
    /// has an edge" without being able to point to a specific stroke.
    @ViewBuilder
    private var borderStroke: some View {
        // 2026-05-13: reverted from a 3-stop LinearGradient stroke
        // to a flat Color.white.opacity(0.06). The gradient was
        // re-computing per frame of the open spring (silhouette
        // shape interpolates, so the stroke path changes, so the
        // gradient endpoints re-evaluate) — material contributor
        // to the laggy feel. A static color has zero per-frame
        // cost. Visually the difference is below the noise floor
        // on every wallpaper we tested against.
        panelSilhouette
            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            .allowsHitTesting(false)
            .opacity(presenter.isShown ? 1 : 0)
    }

    // MARK: - Drop-target accent ring

    /// Drop-target indicator. While a drag is hovering over the
    /// panel (`isDropTargeted == true`), three layered effects
    /// make the silhouette feel ALIVE rather than just colored:
    ///
    /// 1. **Outer halo** — a thick blurred stroke at low opacity,
    ///    breathing slowly (1.6s sine) between 0.25 and 0.55
    ///    opacity. Reads as "the panel is glowing toward you."
    ///
    /// 2. **Mid ring** — the existing 1.5pt accent stroke, also
    ///    breathing but at a higher opacity range and a slightly
    ///    different phase so the two layers don't pulse in
    ///    lockstep (looks more organic).
    ///
    /// 3. **Inner highlight** — a thin bright stroke at the very
    ///    edge of the silhouette, opacity tied to the same sine
    ///    so the whole composite reads as one rhythm with depth.
    ///
    /// All three layers fade in with the existing
    /// `.animation(.easeInOut(0.12), value: isDropTargeted)` on
    /// the parent stack, so the entrance/exit animation is
    /// preserved. The TimelineView-driven breath is independent
    /// — runs continuously while the drag is hovering.
    /// Drop-target indicator — DISABLED.
    ///
    /// Earlier iterations stroked the panel silhouette with the
    /// brand accent (which renders as a cyan-blue) during a drag.
    /// Combined with the macOS native drag-accept cursor badge
    /// (the green +) the composite read as a clashy greenish glow
    /// that destroyed the premium feel. The user explicitly asked
    /// to remove it.
    ///
    /// The macOS cursor badge alone signals "drop will be
    /// accepted," and the slab auto-expanding to Files tab on
    /// drag-enter (via `onTargeted` in the controller) is the
    /// affordance for "this is your destination" — those two
    /// signals together are enough.
    @ViewBuilder
    private var dropRingOverlay: some View {
        EmptyView()
    }

    // MARK: - Silhouette

    /// Panel silhouette — flat top edge fused with the menu-bar zone
    /// (top corners square), and a state-dependent bottom-corner radius.
    /// 16pt when resting (closed-pill quarter-circle corners), 34pt
    /// when expanded (slab squircle). SwiftUI re-clips against the
    /// morphing NSHostingView bounds each frame of the NSPanel.frame
    /// Core Animation morph, and the `RectangleCornerRadii`
    /// interpolation handles the radius transition so the silhouette
    /// shape changes smoothly alongside the size morph.
    private var panelSilhouette: OutwardFlaredShape {
        // Notch-hardware silhouette for BOTH resting pill AND the
        // expanded slab. 12pt outward flare at the top corners
        // (gentle S-curve as the slab widens out from the notch
        // hardware) + larger inward rounded curve at the bottom
        // that interpolates between `pillCornerRadius` (resting)
        // and `innerCornerRadius` (slab) via `panelBottomRadius`.
        // Same shape language across both states — pill→slab
        // morph becomes a continuous radius interpolation, no
        // shape-type switch mid-animation.
        //
        // Top-flare value history:
        //   2pt  — original. So subtle it was effectively a
        //          sharp 90° top corner.
        //   12pt — tried per NotchNook frame audit. Read as
        //          two visible "frog eye" bumps at the top
        //          corners on our narrower/shorter silhouette.
        //          User: "What's those on the top? Is it a
        //          frog." Their flare looks subtle because their
        //          slab is wider/taller and the same arc radius
        //          covers a smaller proportion of the corner.
        //   4pt  — current. Softens the otherwise sharp 90°
        //          corner without creating visible shoulder
        //          bumps. Sub-perceptual at our scale (~ 8px
        //          at Retina 2x) but enough to take the hard
        //          edge off where the slab meets the menu bar.
        //
        // If we ever bump panelWidth to 900+pt and the slab
        // proportions match NotchNook's, the 12pt flare can be
        // revisited.
        //
        // CRITICAL: returns the CONCRETE `OutwardFlaredShape` type,
        // NOT `AnyShape`. AnyShape is a type eraser that strips
        // the underlying shape's `animatableData` from SwiftUI's
        // animation system — wrapping in AnyShape made every
        // panelBottomRadius change SNAP to the new value (no
        // interpolation) because SwiftUI saw two type-erased
        // shape values with no shared animation path. That was
        // the root cause of the "glitch at the bottom" the user
        // kept reporting on open: the bottom corners popped
        // wider in one frame as soon as `presenter.isShown`
        // flipped, BEFORE the spring even started growing the
        // panel. Returning the concrete type lets SwiftUI's
        // `.animation(value:)` machinery interpolate
        // `bottomCornerRadius` smoothly via OutwardFlaredShape's
        // `animatableData: AnimatablePair<CGFloat, CGFloat>`
        // override.
        return OutwardFlaredShape(
            topFlareRadius: panelTopRadius,
            bottomCornerRadius: panelBottomRadius
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // 2026-05-02 brand glyph. Replaces the generic
            // `square.and.pencil` SF Symbol with the nox ring-with-
            // notch brand mark — same silhouette as the app icon,
            // just compact and untinted (the glyph itself uses
            // brandLavender; the wordmark beside it uses textPrimary).
            NoxGlyph(size: 14, lineWidth: 1.4, tint: panelAccent)

            Text("nox")
                .font(.nkTitle)
                .foregroundStyle(DS.Color.textPrimary)

            Spacer(minLength: DS.Spacing.sm)

            KeycapLabel("⌥", "Space")

            SettingsButton()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Segmented

    /// Single source of truth for the slab's accent color.
    ///
    /// Drives the active-tab chrome, the ambient background tint,
    /// the drop-picker Save zone, the panel-background corner
    /// gradient stop, and every other accent site that used to be
    /// `DS.Color.brandLavender`. When music is playing and the
    /// player has artwork, this is the artwork's dominant color
    /// (extracted + cached by `ArtworkColor.dominant`). Otherwise
    /// it falls back to brand lavender so the slab has its own
    /// identity at rest.
    ///
    /// One read per body evaluation; `ArtworkColor.dominant` is
    /// keyed on the raw artwork blob and short-circuits on cache
    /// hit, so reusing this across many call sites in the same
    /// body is essentially free.
    var panelAccent: Color {
        // 2026-05-17: honor Settings → Appearance → "Accent color".
        // `.system` short-circuits the artwork dominant lookup and
        // hands back the user's macOS system accent (System
        // Settings → Appearance), so the slab stays on a stable
        // brand color regardless of what's playing. `.artwork`
        // (default) preserves the original artwork-derived
        // behavior with lavender fallback.
        switch AccentMode.current {
        case .system:
            // `NSColor.controlAccentColor` reflects the user's
            // chosen system accent (Blue / Purple / Pink / Red /
            // Orange / Yellow / Green / Graphite). Wrapped via
            // SwiftUI.Color so it composes with our other color
            // modifiers identically to `DS.Color.brandLavender`.
            return Color(nsColor: NSColor.controlAccentColor)
        case .artwork:
            if let data = presenter.nowPlaying?.artworkData,
               let color = ArtworkColor.dominant(from: data) {
                return color
            }
            return DS.Color.brandLavender
        }
    }

    /// Dark segmented tab rail. The panel stays matte-black, but
    /// the tabs get a tactile macOS control surface: recessed rail,
    /// raised active segment, muted inactive labels.
    private var segmented: some View {
        HStack(spacing: 5) {
            ForEach(presenter.visibleTabs) { tab in
                ScribbleTabButton(
                    tab: tab,
                    isSelected: presenter.activeTab == tab,
                    accentColor: panelAccent
                ) {
                    withAnimation(.selection) { presenter.activeTab = tab }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.026, green: 0.026, blue: 0.030),
                            Color(red: 0.010, green: 0.010, blue: 0.012)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.065), lineWidth: 0.6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.45), lineWidth: 0.8)
                        .blur(radius: 1.1)
                        .offset(y: 1)
                        .mask(
                            RoundedRectangle(cornerRadius: 19, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.clear, Color.black],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                )
                // 2026-05-13: SwiftUI `.shadow()` removed. CPU-side
                // gaussian convolution per frame during the open
                // spring — same reason the panel root's .shadow()
                // was killed back on 2026-05-04 (replaced by
                // CALayer.shadowPath there). The two strokeBorder
                // overlays above already give the tab rail its
                // "recessed" depth feel via the dark inner shadow
                // mask; the SwiftUI .shadow on top was just adding
                // cost without visible difference on the dark slab.
        )
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 3)
        .animation(.selection, value: presenter.visibleTabs)
    }

    // MARK: - Divider & content

    private var divider: some View {
        Rectangle()
            .fill(DS.Color.divider)
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        // LAZY tab mount via switch. Earlier I tried always-
        // mounting all 5 tabs in a ZStack to eliminate
        // first-paint-during-morph glitches — but that caused
        // a noticeable FPS drop on the open animation: SwiftUI
        // re-evaluates every mounted view's body on observable
        // state changes, and with 5 always-resident views (each
        // with LazyVStack/LazyVGrid + observed stores) running
        // alongside the 120Hz spring's frame ticks, body eval
        // and layout passes piled up enough to drop frames
        // during the morph.
        //
        // Reverted to the switch statement (lazy mount). Only
        // the active tab is in the SwiftUI tree at a time. The
        // other four don't pay any per-frame cost. The
        // first-paint glitch we tried to fix should be
        // mitigated by the OTHER recent changes — concrete
        // `OutwardFlaredShape` (no AnyShape erasure on the
        // bottom corner), `withAnimation` on `isShown` toggles,
        // `isMorphing` wired into `handleActiveTabChange`, and
        // the spring's sub-pixel render guard — without
        // burning CPU on 5 always-mounted view bodies.
        //
        // No `.opacity(isMorphing ? 0 : 1)` fade-in (the
        // workaround the user explicitly didn't want). Content
        // appears at full opacity the moment the active tab's
        // body materializes.
        //
        // 2026-05-04 REVERTED — visited-tabs cache regressed open/close
        // smoothness (multiple alive tab views meant @Published changes
        // re-evaluated more bodies during the morph). Back to lazy
        // mount via switch; will re-approach tab-switch lag separately
        // after researching the right technique.
        Group {
            switch presenter.activeTab {
            case .music:
                MusicPanelView()
            case .notes:
                NotesListView()
            case .images:
                ImagesGridView()
            case .videos:
                VideosGridView()
            case .files:
                FilesGridView()
            case .script:
                ScriptsView()
            }
        }
        .id(presenter.activeTab)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .offset(y: -4))
        ))
        .animation(.easeOut(duration: 0.22), value: presenter.activeTab)
    }

    /// Single source of truth for the panel's inner content layout.
    /// Extracted so it can be referenced both by the live render
    /// (in `contentOverlay`) AND by `ImageRenderer` when capturing
    /// the snapshot for the motion-blur overlay. Both paths render
    /// the exact same view tree at the same dimensions, so the
    /// blurred ghost aligns 1:1 with the live content underneath.
    private var renderableContent: some View {
        // GPU-ACCELERATED CONTENT MATERIALIZATION + DROP-FROM-TOP.
        // User 2026-05-05: "i think it's missing frame ... can we
        // use gpu and cpu both on this?"
        //
        // `.drawingGroup()` on the VStack forces SwiftUI to render
        // the entire content tree to an offscreen Metal texture
        // (GPU-side) per frame. Without it, each per-element
        // .blur() spawns its own Metal blur pass + the layer
        // compositor reblends them per frame on the CPU side —
        // that's the dropped-frame cost on 120Hz ProMotion.
        //
        // With drawingGroup, all 4 elements + their blurs + opacity
        // + offsets are computed once into one Metal texture, then
        // the spring animates that texture's parameters. Reduces
        // per-frame cost from 4× blur passes to 1× passes.
        //
        // Each element starts ABOVE the panel's top edge (where
        // it's clipped by the silhouette mask) and slides DOWN
        // into its final position. Combined with the pill's clipShape,
        // elements appear to "drop in through the top of the pill"
        // as if cascading through a slot.
        //
        // Y-offsets bumped 2-3× from initial subtle values for the
        // "premium drop-in" effect:
        //   header:    -28pt y-offset (clipped above when closed)
        //   segmented: -32pt y-offset (more dramatic for tab cascade)
        //   divider:   -28pt y-offset
        //   content:   -40pt y-offset (most pronounced — the main material)
        // 2026-05-04 PER-FRAME COST FIX: cascade now gates on
        // `isShown && !isMorphing` instead of just `isShown`. Real
        // frame-drop data showed cluster of drops in the second
        // half of the morph (fraction 0.4+, max dt 235ms) — caused
        // by panel.frame growth + cascade animations + blur passes
        // all competing for the same frame budget AT THE SAME TIME.
        //
        // New strategy is sequential:
        //   1. Panel.frame morphs (cascade stays at "hidden" state)
        //   2. Spring settles → isMorphing flips false
        //   3. Cascade fires with the panel already at full size
        //
        // During phase 1, the only per-frame work is the panel
        // silhouette + dark background. Cheap. During phase 2,
        // panel is static and only the content cascade is animating
        // — also cheap. The two heavy operations no longer overlap.
        // 2026-05-04: cascade blurs RESTORED. The diagnostic
        // confirmed they weren't the lag cause (shadow was). Now
        // that shadow is GPU-accelerated via CALayer.shadowPath,
        // we have budget for the cascade blurs again, and the
        // visual "materialization" feel is preserved.
        // 2026-05-04 (user feedback: "bounce at first like normal
        // spring, but easy ease curve at the end where it feels
        // laggy usually"): cascade now uses `.snappy(duration:
        // extraBounce:)`. Apple's WWDC23 preset designed exactly
        // for this case — spring physics with bounce in the
        // motion phase, but settles cleanly at the duration
        // boundary with NO sub-pixel tail.
        //
        // duration: 0.32  → perceptual settle time (lands by here)
        // extraBounce: 0.15 → ~10% overshoot in the motion phase
        //
        // Falls back to .interpolatingSpring tuned for similar
        // character on macOS 13 (no .snappy preset). Stiffness 350
        // / damping 22 → ω_n=18.7, ratio=0.59 → ~10% bounce, lands
        // ~360ms.
        VStack(spacing: 0) {
            header
                .blur(radius: presenter.cascadeReady ? 0 : 8)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -28)
                .animation(cascadeAnimation, value: presenter.cascadeReady)
            segmented
                .padding(.horizontal, DS.Spacing.md)
                .blur(radius: presenter.cascadeReady ? 0 : 10)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -32)
                .animation(cascadeAnimation.delay(0.04), value: presenter.cascadeReady)
            divider
                .padding(.top, DS.Spacing.sm)
                .blur(radius: presenter.cascadeReady ? 0 : 4)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -28)
                .animation(cascadeAnimation.delay(0.06), value: presenter.cascadeReady)
            content
                .blur(radius: presenter.cascadeReady ? 0 : 12)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -40)
                .animation(cascadeAnimation.delay(0.08), value: presenter.cascadeReady)
                // 2026-05-20 — progressive Liquid Glass fade at
                // the top edge of every tab's content area. List
                // content scrolling UP toward the divider now
                // disappears UNDER a blurred fade instead of
                // clipping at a hard line — same effect Apple
                // ships at the top of iOS notification stacks
                // and Alcove ships on its expanded music card.
                //
                // 14pt strip is the eyeballed minimum that reads
                // as "fade" rather than "horizontal band." Below
                // 12pt the gradient compresses too tight and the
                // blur looks like a one-pixel haze; above 18pt
                // it starts eating real content area. 14pt sits
                // in the sweet spot.
                //
                // `.bottomToTop` gradient direction: full blur at
                // the top edge of this overlay (touching the
                // divider above it), fading to clear by the
                // bottom — so content emerging UP into this band
                // becomes progressively more frosted as it
                // approaches the chrome.
                //
                // `.allowsHitTesting(false)` because the blur
                // strip overlays scroll views; without this it
                // would eat clicks/scrolls in the top 14pt of
                // every content area.
                .overlay(alignment: .top) {
                    ProgressiveBlurView(direction: .bottomToTop,
                                        intensity: .medium)
                        .frame(height: 14)
                        .allowsHitTesting(false)
                        .opacity(presenter.cascadeReady ? 1 : 0)
                }
        }
        // GPU-friendly compositing without breaking hit testing.
        // .drawingGroup() was tried but flattened content into a
        // Metal texture that lost drag-and-drop interactions on
        // the segmented bar (user 2026-05-05: "not allowed" icon
        // on image tab while dragging).
        //
        // .compositingGroup() is less aggressive: it groups the
        // children into a single compositing layer (so opacity/
        // blur effects apply uniformly to the group), but PRESERVES
        // SwiftUI's hit-test tree underneath. Helps batch the per-
        // element blur passes into a single GPU compositing
        // operation while keeping segmented-bar drops working.
        .compositingGroup()
    }

    // (Motion-blur snapshot lifecycle now in PanelWindowController.
    // It captures the settled panel.contentView via cacheDisplay
    // after each animateOpen completes, applies CIMotionBlur, and
    // stores on presenter.motionBlurImage for the next open's
    // overlay.)
}

// MARK: - Pill swap blur (Alcove-style progressive blur)
//
// Adapted from Alcove's `ProgressiveBlurEffect` + `gaussianBlurFilter`
// approach (decoded from their binary's symbol table). When the
// pill morphs between event types, a brief gaussian blur is applied
// over the entire pill content. The blur peaks right at the swap
// moment and decays as the new content settles, masking the visual
// seam where SwiftUI's transition would otherwise show two
// rectangles crossfading. Net effect: the swap reads as one soft
// shape morph instead of two competing views.
//
// Triggers ONLY on `caseKey` change (e.g., music → screenshot),
// not on associated-value updates within the same case (e.g.,
// screenshot count ticking from 1 to 2). This way burst-screenshot
// counts don't re-blur on every shot — the blur fires once at the
// initial swap and then the count animates in place.
/// Dock tab button. Inactive = clean SF Symbol at low opacity, no
/// background. Active = same icon, bolder weight + bright color,
/// PLUS a soft white highlight pill rendered BEHIND it via
/// `matchedGeometryEffect` so the pill smoothly slides between
/// positions when the active tab changes.
///
/// 2026-05-04 redesign per user inspiration (creative VR layout
/// reference). Replaces the previous "per-button bordered tile"
/// pattern that made the bar read as heavy and uniform regardless
/// of selection state. The new pattern is the modern macOS Tahoe /
/// iOS pattern — inactive states are quiet, only the active state
/// has visual weight. The sliding pill is what makes the
/// interaction feel alive.
/// Hand-drawn marker stroke used by `ScribbleTabButton`. There are
/// 15 distinct path variants so each activation picks a different
/// mark — reads as the user's pen drawing a slightly different
/// squiggle every time, never the same exact line twice. All paths
/// are normalized to a 60×8 reference rect; SwiftUI scales them to
/// the rendered frame.
///
/// Animatable via `.trim(from:to:)` for the draw-on stroke effect.
/// Wraps any artwork view in a vinyl-record presentation:
/// circular clip + continuous slow rotation + a tiny dark hole
/// at the dead center (the spindle hole) so the rotation reads
/// as a record on a turntable rather than a confused square
/// tumbling.
///
/// 12s per revolution — close to a real 33⅓ rpm vinyl's perceived
/// speed at this scale; fast enough to read as "moving" within a
/// glance but slow enough to never be distracting in peripheral
/// vision. Pure CADisplayLink-like animation via SwiftUI's
/// `TimelineView(.animation)` so the rotation doesn't depend on
/// a `withAnimation` block somewhere up the tree.
private struct VinylArtwork<Content: View>: View {
    @ViewBuilder let content: () -> Content
    private let revolutionSeconds: Double = 12.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date
                .timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: revolutionSeconds)
                / revolutionSeconds
            ZStack {
                content()
                    .rotationEffect(.degrees(t * 360))
                    .clipShape(Circle())
                // Spindle hole — a tiny black dot at center sells
                // the "record" metaphor without taking real
                // pixels from the artwork. Skipped at very small
                // sizes where it'd be a single pixel.
                Circle()
                    .fill(Color.black)
                    .frame(width: 3, height: 3)
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
        }
    }
}

/// `variant` is NOT animatable — switching variants snaps the path
/// shape, which is the desired behavior (each new selection draws
/// a fresh mark from scratch).
private struct MarkerStroke: Shape {
    let variant: Int  // 0..<MarkerStroke.variantCount

    static let variantCount = 15

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let sx = rect.width / 60
        let sy = rect.height / 8
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * sx, y: y * sy)
        }

        switch variant % Self.variantCount {
        case 0:  // wavy — the original four-bump squiggle
            p.move(to: pt(1, 5))
            p.addQuadCurve(to: pt(15, 4), control: pt(8, 2))
            p.addQuadCurve(to: pt(30, 5), control: pt(22, 6))
            p.addQuadCurve(to: pt(45, 5), control: pt(38, 2))
            p.addQuadCurve(to: pt(59, 4), control: pt(52, 8))

        case 1:  // zigzag — sharp triangle wave
            p.move(to: pt(1, 5))
            p.addLine(to: pt(9, 1))
            p.addLine(to: pt(17, 6))
            p.addLine(to: pt(25, 1))
            p.addLine(to: pt(33, 6))
            p.addLine(to: pt(41, 1))
            p.addLine(to: pt(49, 6))
            p.addLine(to: pt(57, 2))
            p.addLine(to: pt(59, 4))

        case 2:  // double-wave — two stacked smaller crests
            p.move(to: pt(1, 5))
            p.addQuadCurve(to: pt(14, 5), control: pt(7, 2))
            p.addQuadCurve(to: pt(28, 5), control: pt(21, 7))
            p.addQuadCurve(to: pt(42, 5), control: pt(35, 2))
            p.addQuadCurve(to: pt(56, 5), control: pt(49, 7))
            p.addLine(to: pt(59, 5))

        case 3:  // tilde — gentle long wavelength
            p.move(to: pt(1, 4))
            p.addQuadCurve(to: pt(30, 4), control: pt(15, 0))
            p.addQuadCurve(to: pt(59, 4), control: pt(45, 8))

        case 4:  // single hump — one big arc up
            p.move(to: pt(1, 6))
            p.addQuadCurve(to: pt(59, 6), control: pt(30, 0))

        case 5:  // single dip — one big arc down
            p.move(to: pt(1, 2))
            p.addQuadCurve(to: pt(59, 2), control: pt(30, 8))

        case 6:  // rough line — slightly wobbly straight
            p.move(to: pt(1, 4))
            p.addLine(to: pt(12, 4))
            p.addLine(to: pt(20, 5))
            p.addLine(to: pt(30, 4))
            p.addLine(to: pt(40, 5))
            p.addLine(to: pt(48, 4))
            p.addLine(to: pt(59, 4))

        case 7:  // slope up — rising
            p.move(to: pt(1, 7))
            p.addLine(to: pt(12, 6))
            p.addLine(to: pt(20, 5))
            p.addLine(to: pt(30, 4))
            p.addLine(to: pt(40, 3))
            p.addLine(to: pt(48, 2))
            p.addLine(to: pt(59, 1))

        case 8:  // slope down — falling
            p.move(to: pt(1, 1))
            p.addLine(to: pt(12, 2))
            p.addLine(to: pt(20, 3))
            p.addLine(to: pt(30, 4))
            p.addLine(to: pt(40, 5))
            p.addLine(to: pt(48, 6))
            p.addLine(to: pt(59, 7))

        case 9:  // S-curve — rise then fall
            p.move(to: pt(1, 6))
            p.addQuadCurve(to: pt(30, 4), control: pt(15, 1))
            p.addQuadCurve(to: pt(59, 2), control: pt(45, 8))

        case 10:  // triple peak — three small zigzag peaks
            p.move(to: pt(1, 5))
            p.addLine(to: pt(9, 2))
            p.addLine(to: pt(17, 5))
            p.addLine(to: pt(25, 2))
            p.addLine(to: pt(33, 5))
            p.addLine(to: pt(41, 2))
            p.addLine(to: pt(49, 5))
            p.addLine(to: pt(59, 4))

        case 11:  // asymmetric — varying amplitudes
            p.move(to: pt(1, 5))
            p.addQuadCurve(to: pt(14, 4), control: pt(8, 2))
            p.addQuadCurve(to: pt(25, 4), control: pt(19, 6))
            p.addQuadCurve(to: pt(35, 4), control: pt(30, 1))
            p.addQuadCurve(to: pt(45, 4), control: pt(40, 7))
            p.addQuadCurve(to: pt(59, 5), control: pt(52, 2))

        case 12:  // cursive flourish — exaggerated mid-loop
            p.move(to: pt(1, 5))
            p.addQuadCurve(to: pt(18, 4), control: pt(12, 2))
            p.addQuadCurve(to: pt(28, 4), control: pt(24, 6))
            p.addQuadCurve(to: pt(38, 4), control: pt(32, 0))
            p.addQuadCurve(to: pt(50, 4), control: pt(44, 6))
            p.addQuadCurve(to: pt(59, 5), control: pt(56, 2))

        case 13:  // sharp wave — angular peaks (between zigzag and wavy)
            p.move(to: pt(1, 5))
            p.addLine(to: pt(8, 1))
            p.addLine(to: pt(14, 5))
            p.addLine(to: pt(22, 1))
            p.addLine(to: pt(28, 5))
            p.addLine(to: pt(36, 1))
            p.addLine(to: pt(42, 5))
            p.addLine(to: pt(50, 1))
            p.addLine(to: pt(56, 5))
            p.addLine(to: pt(59, 5))

        case 14:  // tapered — amplitude grows then shrinks
            p.move(to: pt(1, 4))
            p.addQuadCurve(to: pt(18, 4), control: pt(10, 3))
            p.addQuadCurve(to: pt(30, 4), control: pt(26, 1))
            p.addQuadCurve(to: pt(38, 4), control: pt(34, 7))
            p.addQuadCurve(to: pt(59, 4), control: pt(46, 5))

        default:
            p.move(to: pt(1, 4))
            p.addLine(to: pt(59, 4))
        }
        return p
    }
}

private struct ScribbleTabButton: View {
    /// User-facing selector for the active-tab decoration. Lives
    /// in Settings → Appearance → "Active tab indicator".
    /// Default `.capsule` (matches the shipped 1.9.20 chrome);
    /// the other three styles (capsule + marker, marker only,
    /// none) let the user choose between the older sketch-style
    /// gesture, pure marker, or pure typography.
    ///
    /// History (kept for context): the marker squiggle was
    /// restored 2026-05-13 after a premium-HUD pass stripped it,
    /// disabled same day because it collided visually with the
    /// new capsule, then 2026-05-17 brought back as one of four
    /// user-pickable indicator styles. All `MarkerStroke`
    /// variants and draw-trim state stay in place so the styles
    /// that hide the marker have no compile-time cost — don't
    /// strip the supporting code.
    @AppStorage(SettingsKey.tabIndicatorStyleRaw) private var tabIndicatorStyleRaw: String = TabIndicatorStyle.capsule.rawValue

    /// Convenience accessor — collapses the stored raw value
    /// into the typed enum and falls back to `.capsule` if the
    /// stored string is ever stale (manual UserDefaults edit,
    /// future enum case rename, etc.).
    private var indicatorStyle: TabIndicatorStyle {
        TabIndicatorStyle(rawValue: tabIndicatorStyleRaw) ?? .capsule
    }

    /// Whether the marker squiggle should render under the
    /// active tab for the current style choice. Used by both
    /// the overlay and the per-activation animation gates so
    /// no draw-trim work runs for the marker-less styles.
    private var showMarkerUnderline: Bool { indicatorStyle.showsMarker }

    let tab: PanelTab
    let isSelected: Bool
    /// Color used by the selected-tab capsule's gradient fill and
    /// strokeBorder. Driven by the parent: now-playing artwork's
    /// dominant color when music is playing, otherwise brand
    /// lavender. Defaults to lavender so older instantiation sites
    /// (and previews) keep working.
    var accentColor: Color = DS.Color.brandLavender
    let action: () -> Void

    @State private var isHovered: Bool = false
    /// 0 → 1 stroke-trim that draws the lavender marker underline
    /// in left-to-right when the tab becomes active. Reset to 0
    /// on deselect so the next activation re-draws from scratch.
    /// Driven only when `showMarkerUnderline` is on.
    @State private var drawProgress: CGFloat = 0
    /// Currently displayed marker variant (0..<MarkerStroke.variantCount).
    /// Re-rolled on every activation so each pick draws a different
    /// squiggle. Randomized at init so first paint is already hand-drawn.
    @State private var variant: Int = Int.random(in: 0..<MarkerStroke.variantCount)
    /// Last variant used — kept so the re-roll avoids drawing the
    /// same mark twice in a row (perceptible variety on every click).
    @State private var lastVariant: Int = -1

    var body: some View {
        Button(action: action) {
            Text(tab.title.lowercased())
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(textColor)
                .fixedSize()
                .frame(width: tabWidth, height: 28)
                .background(segmentBackground)
                .overlay(segmentRim)
                // Marker-underline overlay. Sits at the bottom of the
                // pill, hugging the inner edge so the gesture reads
                // as "underline under the label" not "shape under
                // the chrome." Lavender stroke with a soft glow,
                // animates in via stroke-trim when isSelected flips
                // true. Old design system feature restored 2026-05-13
                // after a "premium HUD" pass stripped it out — the
                // capsule alone read as static, no tap-feedback
                // gesture.
                .overlay(alignment: .bottom) {
                    if showMarkerUnderline && isSelected {
                        // Marker stroke + glow now follow the
                        // shared accent color (artwork-dominant
                        // when music has art, lavender fallback)
                        // so re-enabling `showMarkerUnderline`
                        // continues to feel of-a-piece with the
                        // rest of the slab's color story.
                        // Rendering geometry matches the original
                        // 2026-05-13 introduction (commit ab90e1e):
                        // 1.8pt stroke, 6pt frame, and a NEGATIVE
                        // 3pt horizontal pad so the path extends
                        // past each text edge. The later +8 inset
                        // / 1.6pt / 5pt frame compressed the 60-unit
                        // reference curve into ~24pt of effective
                        // width, which pinched the curves into
                        // angular jaggies (2026-05-17 user feedback:
                        // "we had much cleaner hand draw stuff").
                        // Restoring the original numbers so the
                        // mark reads as a confident pen gesture,
                        // not a ruler-tight cap.
                        MarkerStroke(variant: variant)
                            .trim(from: 0, to: drawProgress)
                            .stroke(
                                accentColor,
                                style: StrokeStyle(lineWidth: 1.8,
                                                   lineCap: .round,
                                                   lineJoin: .round)
                            )
                            .shadow(color: accentColor.opacity(0.45),
                                    radius: 4)
                            .frame(height: 6)
                            .padding(.horizontal, -3)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .help(tab.title)
        .onHover { hovering in
            withAnimation(NoxAnimations.quickAnticipation) {
                isHovered = hovering
            }
        }
        .onChange(of: isSelected) { newValue in
            // Gated so the per-tap animation work only runs when
            // the marker underline is enabled. Body uses macOS 13's
            // single-arg `(newValue)` closure form (the two-arg
            // `(oldValue, newValue)` overload is macOS 14+).
            guard showMarkerUnderline else { return }
            if newValue {
                variant = nextVariant(excluding: lastVariant)
                lastVariant = variant
                drawProgress = 0
                withAnimation(.easeOut(duration: 0.55)) {
                    drawProgress = 1
                }
            } else {
                drawProgress = 0
            }
        }
        .onAppear {
            // First paint: if this tab is already active when the
            // panel mounts, show the underline at full draw — no
            // entrance animation on first paint (would read as a
            // glitch, not a gesture).
            guard showMarkerUnderline else { return }
            if isSelected {
                lastVariant = variant
                drawProgress = 1
            }
        }
        .onChange(of: tabIndicatorStyleRaw) { _ in
            // User just changed the Appearance picker. If the new
            // style still shows the marker and this tab is the
            // active one, draw straight to full so the underline
            // appears without waiting for the next tab switch.
            // If the new style hides the marker, clear any
            // in-flight stroke trim instantly.
            if indicatorStyle.showsMarker {
                if isSelected {
                    lastVariant = variant
                    drawProgress = 1
                }
            } else {
                drawProgress = 0
            }
        }
    }

    private var textColor: Color {
        if isSelected { return Color.white.opacity(0.96) }
        return isHovered ? Color.white.opacity(0.78) : Color.white.opacity(0.50)
    }

    private var tabWidth: CGFloat {
        switch tab {
        case .music: return 60
        case .notes: return 64
        case .images, .videos: return 74
        case .files: return 58
        case .script: return 66
        }
    }

    @ViewBuilder
    private var segmentBackground: some View {
        if isSelected && indicatorStyle.showsCapsule {
            // 2026-05-13: dropped the two .shadow(...) modifiers
            // that wrapped this fill (lavender glow + drop shadow).
            // Each one was a separate GPU pass per render frame
            // during the panel open spring. Visual presence comes
            // from the gradient fill + the lavender marker
            // underline overlay — shadows were redundant accent.
            //
            // 2026-05-17: gated on `indicatorStyle.showsCapsule`
            // so the marker-only / none styles get truly chrome-
            // free inactive-looking inactive tabs (instead of
            // selected ones still carrying the capsule).
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.13),
                            accentColor.opacity(0.12),
                            Color.black.opacity(0.24)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        } else if isHovered {
            // Hover-only background: dropped the drop shadow here
            // too. Hover is a transient state and per-frame shadow
            // re-renders during hover-in spring were also wasted.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.035))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.clear)
        }
    }

    @ViewBuilder
    private var segmentRim: some View {
        if isSelected && indicatorStyle.showsCapsule {
            // 2026-05-17: gated on `indicatorStyle.showsCapsule`
            // for the same reason as `segmentBackground` — marker-
            // only and none styles drop all capsule chrome.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            accentColor.opacity(0.48),
                            accentColor.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
        }
    }

    /// Pick a random variant from `0..<MarkerStroke.variantCount`
    /// avoiding `excluding`. Guarantees consecutive activations
    /// don't draw the same squiggle twice in a row.
    private func nextVariant(excluding: Int) -> Int {
        let candidates = (0..<MarkerStroke.variantCount).filter { $0 != excluding }
        return candidates.randomElement() ?? Int.random(in: 0..<MarkerStroke.variantCount)
    }
}

/// REMOVED 2026-05-01 — see git history for the experimental
/// two-image card-flip implementation. Reverted to the original
/// single-image SwiftUI artwork in `PanelRootView.pillArtwork`.
/// To revisit: the timing race between `pillArtworkImage` and
/// `displayedTrackKey` updates needs to be solved at the parent
/// level (atomic dual-update) before a sub-view can rely on
/// either one for change detection.
private struct _RemovedPillFlipArtworkView_DoNotUse: View {
    let image: NSImage?
    let trackKey: String

    @State private var displayedImage: NSImage? = nil
    @State private var displayedKey: String = ""
    @State private var nextImage: NSImage? = nil
    @State private var rotation: Double = 0
    @State private var isFlipping: Bool = false

    private var cosRotation: Double {
        cos(rotation * .pi / 180)
    }

    var body: some View {
        ZStack {
            artworkTile(image: displayedImage)
                .rotation3DEffect(
                    .degrees(rotation),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    anchorZ: 0,
                    perspective: 0.6
                )
                .opacity(cosRotation >= 0 ? 1 : 0)

            artworkTile(image: nextImage)
                .rotation3DEffect(
                    .degrees(rotation - 180),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    anchorZ: 0,
                    perspective: 0.6
                )
                .opacity(cosRotation < 0 ? 1 : 0)
        }
        .onAppear {
            // Initial mount: take the current image silently. We
            // also seed displayedKey so the first onChange of a
            // genuinely new track fires the flip (rather than
            // misfiring on first mount).
            if displayedImage == nil {
                displayedImage = image
                displayedKey = trackKey
            }
        }
        // 2026-05-01 v2: drive change detection off the String
        // trackKey, NOT the NSImage reference. SwiftUI's onChange
        // requires Equatable; NSImage's Equatable conformance via
        // NSObject isEqual is unreliable across SwiftUI's diff
        // (same content + new instance can compare unequal, and
        // ArtworkCache returns the same instance for the same key
        // so the SwiftUI diff sometimes thinks no change happened
        // even when it did). String is rock-solid Equatable —
        // when title|artist genuinely changes, this fires.
        .onChange(of: trackKey) { newKey in
            // Skip if it's the same key (defensive — onChange should
            // already filter this but be explicit).
            if newKey == displayedKey { return }
            // Skip the very first transition from "" → real key —
            // that's a fresh mount, not a track change. Same logic
            // as the artist-empty filter for the bloom: we only
            // animate when there was previously a real track and
            // now there's a different real track.
            if displayedKey.isEmpty {
                displayedImage = image
                displayedKey = newKey
                return
            }
            // Genuine track change → flip. Capture the new image
            // (which might still be nil on first publish if artwork
            // loads async — that's OK, the flip animates to a
            // placeholder back face, and a subsequent image update
            // will fill it in via onChange-of-image below).
            triggerFlip(toImage: image, newKey: newKey)
        }
        .onChange(of: image) { newImage in
            // Three cases:
            //   a) In-flight flip: update nextImage (back face).
            //   b) Same track (trackKey unchanged): silent direct
            //      update of displayedImage. This is the
            //      "artwork loaded async after title" case for
            //      Spotify's two-stage emission.
            //   c) Track is mid-change (trackKey != displayedKey):
            //      DO NOTHING. The trackKey onChange handler will
            //      fire shortly and trigger the flip, capturing
            //      this new image as the back face. If we silently
            //      updated displayedImage now, the flip would
            //      have the same image on both faces — no visible
            //      animation. This was the bug the user reported:
            //      "still using same photo for rotation."
            if isFlipping {
                nextImage = newImage
                return
            }
            if trackKey == displayedKey {
                // Same track — silent direct update.
                displayedImage = newImage
            }
            // else: track is changing, let onChange(of: trackKey)
            //       handle it. Don't touch displayedImage here.
        }
    }

    @ViewBuilder
    private func artworkTile(image: NSImage?) -> some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func triggerFlip(toImage newImage: NSImage?, newKey: String) {
        isFlipping = true
        nextImage = newImage
        let duration: TimeInterval = 0.45
        withAnimation(.smooth(duration: duration)) {
            rotation = 180
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) {
            displayedImage = nextImage
            displayedKey = newKey
            nextImage = nil
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                rotation = 0
            }
            isFlipping = false
        }
    }
}

private struct PillSwapBlur: ViewModifier {
    let caseKey: String
    @State private var previousKey: String = ""
    @State private var blur: Double = 0

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .onChange(of: caseKey) { newKey in
                // Suppress the blur swap-mask for trackChanged
                // AND volumeChanged. Per user 2026-05-08: "instade
                // of using blur for syncing too separate thing /
                // We can have smooth motion while closing / It's
                // like 2 is closing and when blur it will be
                // tranjasation but it will be simuntanius."
                //
                // The blur was a crutch to mask that we have two
                // separate content branches crossfading. The
                // premium solution: rely on SwiftUI's simultaneous
                // crossfade via `.transition(.opacity)` on each
                // branch + the unified 0.40s curve. Old branch
                // fades OUT and new branch fades IN at the SAME
                // time, in lockstep with the silhouette morph.
                // One simultaneous motion, no blur required.
                let isBannerSwap =
                    newKey.hasPrefix("trackChanged") ||
                    previousKey.hasPrefix("trackChanged") ||
                    newKey == "volume" ||
                    previousKey == "volume"
                if newKey != previousKey && !previousKey.isEmpty && !isBannerSwap {
                    triggerBlur()
                }
                previousKey = newKey
            }
            .onAppear { previousKey = caseKey }
    }

    /// Two-stage spring tuned to finish in lockstep with the
    /// 0.40s panel-frame morph (Apple out-quint cubic-bezier).
    /// 130ms ramp + 270ms decay = 400ms total, lands EXACTLY
    /// when the silhouette settles. 4pt peak blur masks the
    /// content swap seam without obscuring the morph.
    private func triggerBlur() {
        withAnimation(.easeOut(duration: 0.13)) {
            blur = 4
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            withAnimation(.easeOut(duration: 0.27)) {
                blur = 0
            }
        }
    }
}

// MARK: - Pill silhouette reaction (whole-pill puff + glow)
//
// The user reported "only text and svg is showing the pill is
// not reacting." Without this, transient events animate inside
// the pill but the silhouette itself is static. This modifier
// adds a brief whole-pill scale puff (~3.5%) plus an event-tinted
// soft glow on every event-case change. Subtle enough that it
// doesn't feel disruptive, present enough that the pill clearly
// "responds" to the event.
//
// Triggers ONLY on caseKey change (not on count updates within
// `.screenshotSaved`) so a screenshot burst doesn't re-puff per
// shot — the pill puffs once on entry, the count animates in
// place, and it puffs again only when transitioning to a
// different event type.
private struct PillSilhouetteReact: ViewModifier {
    let caseKey: String
    let glowColor: Color
    /// When true, skip the scale puff + tinted glow on case change.
    /// Used for `.trackChanged` (the panel widens to banner geometry,
    /// the silhouette flex IS the announcement — a glow on top would
    /// read as a notification firing rather than music transitioning).
    let suppressReact: Bool
    @State private var previousKey: String = ""
    @State private var react: Double = 0

    func body(content: Content) -> some View {
        content
            // Per "the pill is not moving like apple" feedback —
            // the previous incarnation dropped scale entirely and
            // relied on glow alone, so the silhouette never read
            // as physically responding to the event. Dynamic
            // Island's tell IS the silhouette growing. Re-added
            // scale anchored at .top so the top edge stays welded
            // to the notch hardware while the bottom + sides
            // extend outward like a breath. With haloPadding=100pt
            // the panel window has plenty of room for the
            // silhouette to grow ~5% without clipping.
            //
            // Magnitude tuning:
            //   • 1.045 peak — readable as physical growth at a
            //     220pt-wide pill (~10pt outward total) without
            //     reading as goofy or jumping at the user.
            //   • Anchor .top — the silhouette's top edge is the
            //     "connection" to the notch hardware. Anchoring
            //     there means width scaling pushes equally to
            //     both sides while height scaling extends only
            //     downward. The notch handoff stays clean.
            .scaleEffect(1 + react * 0.045, anchor: .top)
            // Tinted glow that ramps with the puff. Radius scales
            // with `react` so the glow only paints during the puff
            // — zero cost when settled. Pairs with the scale to
            // give the puff a soft chromatic halo as it grows.
            .shadow(color: glowColor.opacity(react * 0.45),
                    radius: react * 22)
            .onChange(of: caseKey) { newKey in
                // Derive suppression from the new key directly so it's
                // robust regardless of when SwiftUI updates the struct's
                // captured `suppressReact` property relative to firing
                // this closure. trackChanged + volume both use geometry
                // as the announcement; a glow on top reads as a
                // notification firing rather than the activity
                // expanding. ALSO suppress when leaving those states
                // back to neutral — the dismiss morph IS the cue, the
                // glow on top would feel like a second event firing.
                // User feedback: "don't make that glow behind I think
                // that's too much."
                let isBannerEvent: (String) -> Bool = { key in
                    key.hasPrefix("trackChanged") || key == "volume"
                }
                let suppressed = suppressReact
                    || isBannerEvent(newKey)
                    || isBannerEvent(previousKey)
                if newKey != previousKey && !previousKey.isEmpty && !suppressed {
                    triggerPuff()
                }
                previousKey = newKey
            }
            .onAppear { previousKey = caseKey }
    }

    /// Quick spring up + slower spring back. Same two-stage
    /// pattern as the screenshot icon punch so all the reactions
    /// feel of a piece.
    private func triggerPuff() {
        withAnimation(NoxAnimations.quickAnticipation) {
            react = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(NoxAnimations.trackArrival) {
                react = 0
            }
        }
    }
}

// MARK: - Screenshot pill body
//
// Standalone view so it owns its own @State for the per-shot
// punch + flash animations. Lives outside PanelRootView so the
// animation state survives re-evals of the parent body when other
// presenter state changes (e.g., a track update).
private struct ScreenshotPillBody: View {
    let count: Int
    let notchOverlap: CGFloat
    @EnvironmentObject var presenter: PanelPresenter

    /// 0 = neutral, 1 = punched. Spring-driven by `triggerPunch`
    /// on every screenshot capture. Drives icon scale + rotation
    /// for the "shutter snap" feel.
    @State private var iconPunch: Double = 0
    /// 0 = invisible, 1 = peak white. Decays to 0 over ~280ms
    /// after each capture — the camera-flash glint.
    @State private var flashOpacity: Double = 0

    /// Tile shape responds to whether we have a real thumbnail —
    /// 32×20 (16:10ish, matches typical screenshot proportions)
    /// when there's a thumbnail to show, 22×22 square when
    /// falling back to the camera glyph. The shape change reads
    /// as "this thing is your screenshot," not just a generic
    /// icon. Animates smoothly because both width and height
    /// are bound to the same conditional.
    private var hasThumbnail: Bool { presenter.lastScreenshotThumbnail != nil }
    private var tileWidth: CGFloat { hasThumbnail ? 32 : 22 }
    private var tileHeight: CGFloat { hasThumbnail ? 20 : 22 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.78, blue: 0.99).opacity(0.9))
                if let thumb = presenter.lastScreenshotThumbnail {
                    // Real screenshot. Filling the tile via
                    // .fill content mode + clip means small text
                    // / busy areas just become an abstract
                    // "this is your screen" tile — readable as
                    // identity even at 32×20.
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tileWidth, height: tileHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .scaleEffect(1.0 + iconPunch * 0.18)
                        .rotationEffect(.degrees(iconPunch * 4))
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(1.0 + iconPunch * 0.35)
                        .rotationEffect(.degrees(iconPunch * 8))
                }
            }
            .frame(width: tileWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                // White flash overlay clipped to the tile.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white)
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)
            )
            // The tile size itself animates when the
            // thumbnail-vs-icon state changes — that's the
            // "shape responds" cue. Same bouncy curve as the
            // entrance so it feels of a piece.
            .animation(.bouncy(duration: 0.32, extraBounce: 0.15),
                       value: hasThumbnail)

            Spacer(minLength: 0)

            Text(count > 1 ? "Saved · \(count)" : "Saved")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.trailing, 4)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.18), value: count)
                // Subtle scale bump on count change so the burst
                // count "lands" with a tiny pop in addition to
                // the numeric ticker.
                .scaleEffect(1.0 + iconPunch * 0.08)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Whole-pill micro-bump — the entire camera tile + count
        // breathes outward on a punch and settles. ~3% scale; the
        // larger 35% on the icon is what reads as the "shutter
        // pop", this is the subtle envelope around it.
        .scaleEffect(1.0 + iconPunch * 0.03)
        .onAppear { triggerPunch() }
        .onChange(of: count) { _ in triggerPunch() }
    }

    /// Two-stage spring: aggressive snap up to 1, slower
    /// underdamped settle back to 0. The flash overlay runs
    /// in parallel, peaking with the snap and fading on the way
    /// down. Gives one capture event a satisfying pop without
    /// requiring `keyframeAnimator` (macOS 14+).
    private func triggerPunch() {
        withAnimation(NoxAnimations.quickAnticipation) {
            iconPunch = 1
            flashOpacity = 0.55
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(NoxAnimations.panelOpen) {
                iconPunch = 0
            }
            withAnimation(.easeOut(duration: 0.28)) {
                flashOpacity = 0
            }
        }
    }
}

// MARK: - Keycap label

private struct KeycapLabel: View {
    let keys: [String]

    init(_ keys: String...) {
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: DS.FontSize.xs, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DS.Color.bgSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            }
        }
    }
}

// MARK: - Settings button

private struct SettingsButton: View {
    @State private var isHovered = false

    var body: some View {
        // We deliberately do NOT use `SettingsLink` or the SwiftUI
        // `Settings { }` scene. The panel's SwiftUI tree is mounted via
        // `NSHostingController` inside an `NSPanel`, which creates a
        // separate SwiftUI root that does not inherit the App scene's
        // environment. `SettingsLink` resolves an unbound `\.openSettings`
        // there and silently no-ops; the legacy `showSettingsWindow:`
        // action selector also fails because `LSUIElement = true` means
        // there's no main window in the responder chain.
        //
        // `SettingsWindow.open()` instead routes to AppDelegate, which
        // owns an `NSWindow` directly and pushes a SwiftUI `SettingsView`
        // into it via `NSHostingController` — bypassing the scene
        // plumbing entirely.
        Button {
            NSLog("nox: gear button tapped")
            SettingsWindow.open()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? DS.Color.textSecondary : DS.Color.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
    }
}

#Preview {
    PanelRootView()
        .preferredColorScheme(.dark)
        .frame(width: 340, height: 700)
        .background(Color.black)
}

// MARK: - Vertical-Lift song-change transition
//
// Premium song-change animation for the resting-pill artwork. Designed
// to be visually DIFFERENT from Alcove's spin/flip — Alcove rotates the
// artwork tile around its Y axis with a small bumpy bounce; we slide
// vertically with a soft blur. Same intent ("a track changed, here's
// the new one") expressed through orthogonal motion (vertical vs
// rotational), so the two HUDs stay distinguishable side-by-side on the
// same Mac.
//
// Outgoing artwork: drifts ↑3pt with a 6pt blur and fades to 0 alpha.
// Incoming artwork: starts 3pt below resting, 6pt blurred, 0 alpha;
// rises ↑ to its anchor, blur clearing and alpha rising as it settles.
//
// 3pt is small but legible inside a 14pt artwork tile (≈21% of the
// tile's height). Larger values would feel like the artwork is jumping
// out of the pill bounds; smaller values would be imperceptible.
//
// 6pt of blur is enough to read as "the artwork softened" but not
// enough to dissolve into a featureless smear. SwiftUI's `.blur` runs
// as a Metal filter scoped to this 14×14 surface, so cost is trivially
// small (~196 input pixels, four-tap kernel).

private struct VerticalLiftEnter: ViewModifier {
    /// 0 = entering (4pt below, 7pt blur, alpha 0)
    /// 1 = settled (anchor position, no blur, full alpha)
    let progress: Double

    func body(content: Content) -> some View {
        content
            .offset(y: (1 - progress) * 4)
            .blur(radius: (1 - progress) * 7)
            .opacity(progress)
    }
}

private struct VerticalLiftExit: ViewModifier {
    /// 1 = anchored (full presence)
    /// 0 = exited (4pt above, 7pt blur, alpha 0)
    let progress: Double

    func body(content: Content) -> some View {
        content
            .offset(y: -(1 - progress) * 4)
            .blur(radius: (1 - progress) * 7)
            .opacity(progress)
    }
}

extension AnyTransition {
    /// Asymmetric vertical-lift transition. Use for views that get a
    /// fresh `.id()` on each "new content" event — the outgoing copy
    /// drifts up and out, the incoming copy rises into place from
    /// below. Pair with an `.animation(_, value:)` on the parent so
    /// the SwiftUI run-loop has an animation context to drive the
    /// modifier interpolation.
    static var verticalLift: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: VerticalLiftEnter(progress: 0),
                identity: VerticalLiftEnter(progress: 1)
            ),
            removal: .modifier(
                active: VerticalLiftExit(progress: 0),
                identity: VerticalLiftExit(progress: 1)
            )
        )
    }

    /// Pill entrance transition — bouncy pop from 0.6× scale +
    /// alpha. Anchored at `.top` (NOT `.center`) because the
    /// silhouette's TOP edge is hidden behind the notch hardware
    /// and ABOVE the menu bar where overshoot is invisible. With
    /// the previous `.center` anchor, the bouncy spring's overshoot
    /// (extra ~4% during the bounce peak) was scaling the
    /// silhouette in BOTH directions — and with `closedPillBump = 0`
    /// the silhouette ends exactly at the menu-bar edge, so the
    /// downward portion of the overshoot pushed ~1pt of dark
    /// silhouette BELOW the menu bar for a frame or two before
    /// settling. That was the "glitch on top" the user reported.
    /// `.top` anchor keeps the scale pivot at the hidden top edge
    /// so all overshoot grows DOWNWARD from there — bottom moves
    /// from 60% of height to 100%, and the overshoot to ~104%
    /// stays inside the visible silhouette envelope rather than
    /// sticking out.
    static var pillEnter: AnyTransition {
        // 2026-05-05: anchor changed to .top so transient pill
        // content emerges FROM THE NOTCH HARDWARE BOUNDARY (top
        // edge of pill = the notch zone) rather than from the
        // center. User: "when a screenshot is taken in empty
        // state the animation comes from up. it should be from
        // INSIDE OF THE NOTCH and after the animation finishes
        // it should return to the notch."
        //
        // With .center anchor: content scaled from middle of pill,
        // looking like it appeared "from up" (since the pill is
        // at top of screen).
        // With .top anchor: scale pivot is at the notch boundary,
        // so content emerges DOWNWARD from the notch hardware —
        // matching the "drops out of the notch" feel.
        .scale(scale: 0.65, anchor: .top).combined(with: .opacity)
    }

    /// Pill exit transition — scales DOWN to .top (returns INTO
    /// the notch hardware) + fades. User wants the transient pill
    /// to "return to the notch" after auto-dismiss. .top anchor
    /// makes the exit shrink TOWARD the notch boundary, mirroring
    /// the entry direction.
    static var pillExit: AnyTransition {
        .scale(scale: 0.7, anchor: .top).combined(with: .opacity)
    }

    /// Convenience: the asymmetric pair as a single transition.
    static var pillPop: AnyTransition {
        .asymmetric(insertion: .pillEnter, removal: .pillExit)
    }

    /// Volume HUD exit — scale-down + fade + LIGHT BLUR. The blur
    /// softens the edge of the shrinking content so it visually
    /// matches the silhouette pace better. Without blur, the
    /// content's edge stays sharp while the silhouette boundary
    /// is morphing — eye picks up the mismatch as a "stuck" feel.
    /// 4pt peak blur is light enough to keep content recognizable
    /// while letting it dissolve smoothly with the silhouette.
    /// User feedback round 36: "we have to match the movment of
    /// inside of the content with a little blur so it matchs
    /// perfectly."
    static var volumeExit: AnyTransition {
        .modifier(
            active: VolumeExitModifier(progress: 0),
            identity: VolumeExitModifier(progress: 1)
        )
    }
}

/// At progress=1 (identity): scale 1.0, opacity 1.0, blur 0
/// At progress=0 (active/exit): scale 0.7, opacity 0, blur 2pt
///
/// Round 40 (background-blur perception fix): blur reduced 4pt→2pt.
/// 4pt was perceptible as a sudden "background blur ramp-up" once
/// the value crossed ~2pt threshold mid-animation. 2pt stays
/// perceptually subtle throughout — just enough to soften the
/// content edge so it dissolves with the silhouette.
private struct VolumeExitModifier: ViewModifier {
    let progress: Double  // 0 = exited, 1 = at-rest

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.7 + (progress * 0.3), anchor: .top)
            .opacity(progress)
            .blur(radius: (1.0 - progress) * 2.0)
    }
}

/// Soft entrance: at progress=0 view is at opacity 0 + 2.5pt blur,
/// at progress=1 view is at opacity 1 + 0pt blur. Used for the
/// music pill's appearance after a volume HUD dismiss so the
/// artwork "blurs in" smoothly instead of snapping to focus.
///
/// Round 40: blur reduced 5pt→2.5pt for the same reason as
/// VolumeExitModifier — keeps the blur perceptually subtle so
/// the user doesn't feel a sudden "blur intensity jump."
private struct SoftEntranceModifier: ViewModifier {
    let progress: Double  // 0 = invisible, 1 = visible

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1.0 - progress) * 2.5)
    }
}

extension AnyTransition {
    /// Music pill / fallback content soft entrance — fades in
    /// with a brief blur tail so the artwork doesn't snap-pop
    /// into focus. Round 39: "the artwork ... appearing like a
    /// glitch ... if we can have crossfade on that or some kind
    /// of blur."
    static var softMusicEntrance: AnyTransition {
        .modifier(
            active: SoftEntranceModifier(progress: 0),
            identity: SoftEntranceModifier(progress: 1)
        )
    }
}

// MARK: - Panel silhouette shape (inverse-bow top, rounded bottom)
//
// The S-CURVE technique (per boring.notch / Atoll / DynamicNotchKit
// / DynamicNotch — all share MrKai77's reference implementation):
// at each TOP corner, draw an `addQuadCurve` whose CONTROL POINT
// sits at the rect's outer corner. Because the control is outside
// the eventual filled region, the curve bows INWARD into the
// silhouette, creating the concave-outward "shoulder" curve where
// the slab tucks under the menu bar.
//
// Bottom corners stay as standard convex rounded corners (a single
// quarter-arc), NOT another inverse-bow. The previous flare design
// double-inset the silhouette (top→body via topR, then body→bottom
// via bottomR), creating the visible "S-bump" / fish-tail effect
// the user reported as "we are having s bump." With normal rounded
// bottoms there's exactly one inset at the bottom — same as any
// standard rounded rectangle, no extra vertex, no visible bump.
//
// Geometry:
//   Top edge:    full rect width (minX → maxX)
//   Top corners: inverse-bow quad curve over `topR` height/width.
//                Tangent is HORIZONTAL at start (parallel to menu
//                bar) and VERTICAL at end (parallel to body side).
//   Body sides:  vertical at x = topR (inset by topR from rect)
//   Bottom corners: standard convex rounded corners, radius bottomR
//   Bottom edge: width = rect.width - 2*topR - 2*bottomR
//
// History:
//   v1: Symmetric rounded rectangle. No notch character.
//   v2: "Outward flare" via quarter-arcs at top + inset bottom
//       edge. Created S-BUMPS — two tapers stacked, visible
//       vertex at body→bottom transition. ("frog face")
//   v3: Plain rounded rect, square top. Lost the S-curve.
//   v4 (current): Inverse-bow quad curves at top, normal
//       rounded corners at bottom. Per `boring.notch`'s
//       NotchShape.swift L36-L119. Smooth shoulder curve at
//       top with no body-to-bottom vertex.
//
// Type name kept as `OutwardFlaredShape` for compat with the
// rest of the codebase. The `animatableData: AnimatablePair`
// interpolates BOTH `topFlareRadius` and `bottomCornerRadius`
// during the pill→slab morph, so the shoulder curve scales
// smoothly alongside the bottom radius animation.

// Module-internal (was `private`) so other panels in the same
// target — currently `LockNotchIndicatorView` — can render with
// the EXACT same alcove silhouette (inverse-bow top shoulders,
// rounded bottom corners) instead of approximating with Capsule.
struct OutwardFlaredShape: Shape {
    /// Inverse-bow shoulder radius at the top corners. Drives the
    /// extent of the concave-outward dip where the slab edge
    /// "tucks under" the menu bar. Pill ~6pt, slab ~22pt — small
    /// values read as a chamfer; larger values read as a
    /// pronounced shoulder.
    var topFlareRadius: CGFloat
    /// Convex rounded-corner radius at the bottom. Pill ~8pt,
    /// slab ~34pt.
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlareRadius, bottomCornerRadius) }
        set {
            topFlareRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Clamp radii so they always fit inside `rect`.
        let topR = max(0, min(topFlareRadius, rect.height / 2, rect.width / 2))
        let bottomR = max(0, min(bottomCornerRadius,
                                 rect.height - topR,
                                 max(0, rect.width / 2 - topR)))
        let leftX = rect.minX
        let rightX = rect.maxX
        let topY = rect.minY
        let bottomY = rect.maxY
        let bodyLeftX = leftX + topR
        let bodyRightX = rightX - topR

        // Move to top-left corner of rect (full panel width).
        path.move(to: CGPoint(x: leftX, y: topY))

        // TOP-LEFT inverse-bow shoulder.
        // Control point at (bodyLeftX, topY) — sits ON the top
        // edge, INSIDE the rect's bounds but OUTSIDE the eventual
        // filled region. Pulls the quadratic Bezier inward into
        // the silhouette → concave-outward "shoulder" curve.
        // Reference: boring.notch NotchShape.swift L48-L51.
        path.addQuadCurve(
            to: CGPoint(x: bodyLeftX, y: topY + topR),
            control: CGPoint(x: bodyLeftX, y: topY)
        )

        // Left body side — straight vertical down to where the
        // bottom-left rounded corner starts.
        path.addLine(to: CGPoint(x: bodyLeftX, y: bottomY - bottomR))

        // BOTTOM-LEFT convex rounded corner.
        path.addArc(
            center: CGPoint(x: bodyLeftX + bottomR, y: bottomY - bottomR),
            radius: bottomR,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // Bottom edge between the two rounded corners.
        path.addLine(to: CGPoint(x: bodyRightX - bottomR, y: bottomY))

        // BOTTOM-RIGHT convex rounded corner.
        path.addArc(
            center: CGPoint(x: bodyRightX - bottomR, y: bottomY - bottomR),
            radius: bottomR,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )

        // Right body side — straight vertical up to where the
        // top-right inverse-bow starts.
        path.addLine(to: CGPoint(x: bodyRightX, y: topY + topR))

        // TOP-RIGHT inverse-bow shoulder (mirror of top-left).
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: topY),
            control: CGPoint(x: bodyRightX, y: topY)
        )

        // Close back along the top edge to the starting point.
        path.closeSubpath()
        return path
    }
}

// MARK: - Bluetooth pill body (ping ripple on connect, contracting on disconnect)

/// Standalone pill content for `.bluetoothConnected` / `.bluetoothDisconnected`.
///
/// On CONNECT: a single ping ripple emanates from the icon — a Circle
/// behind the tile that scales 1.0 → 2.6× over 700ms while fading
/// from 0.5 opacity to 0. Reads as the pairing handshake actually
/// completing — same visual vocabulary AirPods use on iOS when
/// they latch.
///
/// On DISCONNECT: the opposite — a contracting ring that starts at
/// 2.4× and pulls back to 1.0×, fading from 0.45 to 0. "The thing
/// just walked away."
///
/// Tile + label content matches the previous static pill so the
/// horizontal layout stays consistent across the family.
private struct BluetoothPillBody: View {
    let name: String
    let iconName: String
    let isConnected: Bool
    let notchOverlap: CGFloat
    let visible: Bool

    /// Driven by onAppear. For connect it goes 0 → 1 (ring expands);
    /// for disconnect it goes 0 → 1 (ring contracts). Read by the
    /// scale + opacity computed properties below to map onto the
    /// actual visual values.
    @State private var rippleProgress: Double = 0
    /// Tile-content scale on entrance — 0.7 → 1.0 spring so the
    /// glyph "lands" rather than fades.
    @State private var iconScale: Double = 0.7

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                // Ripple ring behind the tile. Pinned to the tile
                // size, scaled from there. Drawn first so the
                // tile's solid fill paints over the ripple's center
                // — only the ring outside the tile is visible.
                Circle()
                    .stroke(
                        (isConnected
                         ? Color(red: 0.45, green: 0.65, blue: 1.0)
                         : Color(white: 0.7)),
                        lineWidth: 1.5
                    )
                    .frame(width: 22, height: 22)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        (isConnected
                         ? Color(red: 0.45, green: 0.65, blue: 1.0)
                         : Color(white: 0.55))
                            .opacity(0.9)
                    )
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(iconScale)
            }
            .frame(width: 22, height: 22)
            // Tile clips, but the ripple is drawn outside the
            // RoundedRectangle's shape inside the same ZStack —
            // we DON'T clip the ZStack so the ripple can extend.
            // (The tile clip happens via the RoundedRectangle
            // fill itself defining the visible bounds.)

            // Spacer spans the notch-hardware area (~185pt of the
            // 278pt pill). Anything rendered here is hidden by the
            // physical notch cutout — we keep the middle empty.
            Spacer(minLength: 0)

            // RIGHT-WING badge — lives past the notch hardware in the
            // ~46pt right-wing zone where pixels actually paint. Tiny
            // status dot (filled blue for connected, hollow gray for
            // disconnected) so the user can read state at a glance
            // even if they missed the ripple's expand/contract
            // direction. Keeps the pill information-dense without
            // fighting the notch.
            Image(systemName: isConnected ? "circle.fill" : "circle")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(
                    isConnected
                    ? Color(red: 0.45, green: 0.65, blue: 1.0)
                    : Color.white.opacity(0.55)
                )
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(NoxAnimations.bouncy) {
                iconScale = 1.0
            }
            // Ripple curve: ease-out so the ring leaves quickly,
            // then dwells at the outer edge before fading out.
            withAnimation(.easeOut(duration: 0.7)) {
                rippleProgress = 1.0
            }
        }
    }

    /// Connect: ring scales OUT (1 → 2.6×). Disconnect: ring
    /// scales IN (2.4 → 1.0×). Different start values give the
    /// two events distinct visual personalities.
    private var rippleScale: Double {
        if isConnected {
            return 1.0 + rippleProgress * 1.6
        } else {
            return 2.4 - rippleProgress * 1.4
        }
    }

    /// Both directions fade out — the ring shouldn't linger after
    /// the event completes. Connect starts at 0.5 alpha; disconnect
    /// starts a touch lower (0.45) since the contracting motion is
    /// more visible than the expanding one.
    private var rippleOpacity: Double {
        let start = isConnected ? 0.5 : 0.45
        return start * (1.0 - rippleProgress)
    }
}

// MARK: - Timer running pill body (ticking pulse + last-10s heartbeat)

/// Standalone pill content for `.timerRunning(remainingSeconds:)`.
///
/// Three layers of motion, all derived from the remaining time so
/// the pill's energy ramps up as the timer approaches zero:
///
/// 1. **Always-on tick**: the timer glyph does a subtle 1Hz
///    breathe (1.0 → 1.06 scale, ~0.18 amplitude opacity), driven
///    by a TimelineView from wall-clock time so it never desyncs
///    or gets hijacked by parent re-renders. Reads as the second-
///    hand of an analog clock.
/// 2. **Color shift**: tile fill transitions through the orange
///    band at start, drifts to amber (≤ 30s), then to red (≤ 10s).
///    Smooth `easeInOut` interpolation so percentage changes
///    don't snap.
/// 3. **Last-10s heartbeat**: tile + glyph briefly punch +6%
///    scale on every second tick when remainingSeconds ≤ 10.
///    Synchronized to the wall-clock seconds tick so it lands
///    on each digit change.
///
/// The countdown text uses `.contentTransition(.numericText)` for
/// smooth digit cross-fades on each tick — already there, kept as-is.
private struct TimerRunningPillBody: View {
    let remainingSeconds: Int
    let timeText: String
    let notchOverlap: CGFloat
    let visible: Bool

    /// Heartbeat scale on the tile during the last 10 seconds.
    /// Defaults to 1.0; punched to 1.06 on each tick by the
    /// onChange below, springs back down via the implicit
    /// animation.
    @State private var heartbeat: Double = 1.0

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tileColor)

                // 1Hz breathing scale on the timer glyph, driven
                // off wall-clock time. Like the ChargingTile bolt:
                // decoupled from SwiftUI animation system so the
                // parent's bouncy on `pendingSystemEvent` updates
                // can't propagate through and jitter the pulse.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                         paused: false)) { context in
                    let phase = breatheValue(at: context.date)
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(1.0 + phase * 0.06)
                        .opacity(1.0 - phase * 0.12)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .scaleEffect(heartbeat)

            Spacer(minLength: 0)

            Text(timeText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.95))
                .padding(.trailing, 4)
                .contentTransition(.numericText(countsDown: true))
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.4), value: tileColor)
        .onChange(of: remainingSeconds) { newValue in
            // Heartbeat only kicks in for the final stretch — earlier
            // ticks would fatigue the user across a 25-minute Pomodoro.
            // Punch up, then spring back down on the same value so the
            // animation completes within the second.
            guard newValue > 0 && newValue <= 10 else { return }
            heartbeat = 1.06
            withAnimation(NoxAnimations.panelOpen) {
                heartbeat = 1.0
            }
        }
    }

    /// Sinusoidal 0…1 breathing curve — same shape the charging
    /// bolt uses, scaled to the timer-glyph budget. 1Hz period so
    /// it lines up with the digit ticks visually.
    private func breatheValue(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let omega = 2.0 * Double.pi / 1.0   // 1s period
        return (sin(t * omega) + 1.0) / 2.0
    }

    /// Tile color ramps with urgency:
    /// - > 30s: warm orange (start state)
    /// - 11–30s: amber (heads-up)
    /// - ≤ 10s: red (final stretch)
    /// SwiftUI interpolates between Color values automatically, so
    /// the `.animation(.easeInOut, value: tileColor)` on the parent
    /// view crossfades the fill smoothly on each band change.
    private var tileColor: Color {
        if remainingSeconds <= 10 {
            return Color(red: 0.95, green: 0.30, blue: 0.30).opacity(0.95)
        }
        if remainingSeconds <= 30 {
            return Color(red: 0.99, green: 0.70, blue: 0.20).opacity(0.94)
        }
        return Color(red: 1.00, green: 0.55, blue: 0.20).opacity(0.92)
    }
}

// MARK: - Timer finished pill body (checkmark draw-in + halo flash)

/// Standalone pill content for `.timerFinished`.
///
/// Two synchronized animations on entrance:
/// 1. **Checkmark draw-in**: trim from 0 → 1 over 320ms with
///    ease-out, so the strokes appear to be hand-written rather
///    than just popping into existence.
/// 2. **Halo flash**: a green Circle behind the tile scales
///    1.0 → 1.7× and fades from 0.4 alpha to 0 over 600ms — the
///    "celebratory pop" that punctuates the timer hitting zero.
///
/// After the checkmark settles, the whole tile does a small
/// 1.0 → 1.04 → 1.0 pulse to draw the eye, mirroring iOS's
/// "task complete" cell affordance.
private struct TimerFinishedPillBody: View {
    let notchOverlap: CGFloat
    let visible: Bool

    @State private var checkProgress: Double = 0
    @State private var haloScale: Double = 1.0
    @State private var haloOpacity: Double = 0.4
    @State private var pulse: Double = 1.0

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.30, green: 0.85, blue: 0.45))
                    .frame(width: 22, height: 22)
                    .scaleEffect(haloScale)
                    .opacity(haloOpacity)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.92))
                    .frame(width: 22, height: 22)

                CheckmarkShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 12, height: 9)
            }
            .frame(width: 22, height: 22)
            .scaleEffect(pulse)

            Spacer(minLength: 0)

            // Right-wing bell glyph. Reinforces "timer just rang"
            // beyond the green checkmark + halo burst on the left.
            // Sits past the notch hardware so it actually paints.
            Image(systemName: "bell.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.45))
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            // Halo flash: scale out + fade out over 600ms.
            withAnimation(.easeOut(duration: 0.6)) {
                haloScale = 1.7
                haloOpacity = 0
            }
            // Checkmark draws in slightly behind the halo's start —
            // 60ms delay so the user's eye lands on the green burst
            // first, then resolves to the checkmark.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.easeOut(duration: 0.32)) {
                    checkProgress = 1.0
                }
            }
            // Settle pulse: small bounce after the checkmark
            // completes so the tile reads as "task done."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(NoxAnimations.quickAnticipation) {
                    pulse = 1.04
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(NoxAnimations.snappy) {
                        pulse = 1.0
                    }
                }
            }
        }
    }
}

/// Hand-drawn checkmark path for the `.trim(from:to:)` draw-in
/// animation. Two-segment polyline — short down-right stroke
/// from (0, 0.55) to (0.35, 1.0), then a longer up-right stroke
/// from (0.35, 1.0) to (1.0, 0). Coordinates are normalized to a
/// 1×1 box; the parent `.frame(width: 12, height: 9)` scales it
/// to the right pixel size for the 22pt tile.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.35,
                              y: rect.minY + rect.height * 1.0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// Apple's AirDrop logo, drawn as a SwiftUI Shape. There is no
/// public SF Symbol matching the logo (verified via enumeration of
/// `NSImage(systemSymbolName:)`), and the closest fallbacks
/// (`shareplay`, `dot.radiowaves.up.forward`) don't read as AirDrop
/// — wrong arc orientation, wrong brand silhouette. So we draw it.
///
/// The AirDrop mark is three concentric semicircle arcs forming a
/// dome, with a small upward-pointing triangular wedge cut at the
/// bottom (where the dome meets its baseline). Each arc has a tiny
/// gap on either side of the wedge so the wedge appears to "punch
/// through" the lower arcs.
///
/// The shape is a STROKED path — the caller wraps it in a
/// `.stroke()` modifier with the desired tint and line width. The
/// triangular wedge is rendered as a separate filled path (same
/// `AirDropLogo` view stacks both via ZStack).
struct AirDropLogo: View {
    /// Stroke + fill color for both the dome arcs and the wedge.
    /// Defaults to white so existing call sites don't need to change.
    var tint: Color = .white
    /// Stroke width for the arcs. The wedge fill uses the same `tint`.
    /// Default 1.2 matches the original transient-pill rendering;
    /// callers wanting a heavier mark for larger sizes (e.g. the
    /// drop picker) can bump this.
    var lineWidth: CGFloat = 1.2

    var body: some View {
        ZStack {
            AirDropArcs()
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            AirDropWedge()
                .fill(tint)
        }
    }
}

struct AirDropArcs: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Dome center — slightly above geometric middle so arcs
        // fit comfortably inside the rect height and the wedge
        // has room to land below the arc legs without poking out
        // the bottom of the frame.
        let cx = rect.midX
        let cy = rect.minY + rect.height * 0.45
        // Half-width of the wedge gap at the bottom of the dome.
        // Each arc skips this much on either side of the bottom.
        let wedgeHalfDeg: Double = 28
        // Three concentric arcs, decreasing radii.
        let radii: [CGFloat] = [
            rect.width * 0.40,
            rect.width * 0.27,
            rect.width * 0.14
        ]
        // Bypass `addArc`'s clockwise convention entirely by drawing
        // each arc as a polyline of small line segments. Math is
        // unambiguous: for angle θ, point in user-space y-down is
        // `(cx + r·cos θ, cy - r·sin θ)` — the `-sin` flip makes
        // positive θ map to "above center" visually, so:
        //   θ =   0° → right of center (3 o'clock)
        //   θ =  90° → above center (12 o'clock = visual top)
        //   θ = 180° → left of center (9 o'clock)
        //   θ = 270° (or -90°) → below center (6 o'clock = visual bottom)
        //
        // Dome traces from `-90° + wedgeHalfDeg` (just RIGHT of the
        // bottom = around 5 o'clock visually) by INCREASING θ
        // (visually CCW) over the top, ending at `270° - wedgeHalfDeg`
        // (just LEFT of bottom = around 7 o'clock visually).
        //
        // Earlier this used `addArc` with `clockwise: false` and the
        // visual result was just the wedge — arc never appeared in
        // the screenshot. Polyline approach gives us full control.
        let startDeg = -90.0 + wedgeHalfDeg   // ≈ -62°
        let endDeg = 270.0 - wedgeHalfDeg     // ≈ 242°
        let steps = 60
        for r in radii {
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let deg = startDeg + (endDeg - startDeg) * t
                let rad = deg * .pi / 180.0
                let x = cx + r * CGFloat(cos(rad))
                let y = cy - r * CGFloat(sin(rad))
                if i == 0 {
                    p.move(to: CGPoint(x: x, y: y))
                } else {
                    p.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        return p
    }
}

struct AirDropWedge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Small upward-pointing isoceles triangle centered between
        // the arc legs. The arc legs end at:
        //   y = cy + r*sin(wedgeHalfDeg) where cy=0.45*h, r=0.40*w,
        //   sin(28°)≈0.47 → y ≈ 0.45h + 0.40w*0.47 ≈ 0.45h + 0.19w
        // For square 14×14: y ≈ 0.45*14 + 0.19*14 ≈ 6.3 + 2.65 = 8.95
        // Wedge apex starts ABOVE the arc legs' meeting line and
        // base sits BELOW. Centered at midX.
        let cx = rect.midX
        let apexY = rect.minY + rect.height * 0.45
        let baseY = rect.minY + rect.height * 0.85
        let halfBase = rect.width * 0.13
        p.move(to: CGPoint(x: cx, y: apexY))                  // apex (top)
        p.addLine(to: CGPoint(x: cx - halfBase, y: baseY))   // bottom-left
        p.addLine(to: CGPoint(x: cx + halfBase, y: baseY))   // bottom-right
        p.closeSubpath()
        return p
    }
}

// MARK: - Calendar upcoming pill body (urgency pulse on imminent)

/// Standalone pill content for `.calendarUpcoming(title:minutesUntilStart:)`.
///
/// Two animation modes based on imminence:
/// - **> 1 minute out**: static — pill is informational. Calendar
///   icon scales in once on entrance (0.7 → 1.0 spring), no looping
///   animation. We don't want to spam the eye for a 5-minute lead.
/// - **≤ 1 minute (or already started)**: subtle 1.5Hz pulse on the
///   icon (1.0 → 1.08 scale + 1.0 → 0.85 opacity). Reads as
///   "this is starting now, look up." Driven by TimelineView so it
///   doesn't conflict with parent re-renders the same way the
///   charging bolt was glitching before.
///
/// Time-remaining label uses `.contentTransition(.numericText)` so
/// minute decrements crossfade smoothly across pushes.
private struct CalendarUpcomingPillBody: View {
    let title: String
    let minutesUntilStart: Int
    let timeLabel: String
    let notchOverlap: CGFloat
    let visible: Bool

    @State private var iconScale: Double = 0.7

    private var isImminent: Bool { minutesUntilStart <= 1 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.45, blue: 0.30).opacity(0.92))

                // Calendar glyph — pulses when imminent, static
                // otherwise. The same TimelineView pattern as the
                // timer breathe — wall-clock-driven so it survives
                // parent animation propagation untouched.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                         paused: !isImminent)) { context in
                    let phase = isImminent ? pulseValue(at: context.date) : 0
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(iconScale * (1.0 + phase * 0.08))
                        .opacity(1.0 - phase * 0.15)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            // Spacer crosses the notch hardware zone.
            Spacer(minLength: 0)

            // RIGHT-WING countdown — "2m", "now", "1h" — short enough
            // to fit past the notch. Full meeting title can't fit
            // here (right wing is ~46pt) and would just truncate to
            // garbage; the time-until-start is the actionable bit
            // anyway. Tap-to-join still routes through the whole
            // pill, so the title isn't lost — it lives in the
            // panel's calendar pane when the user opens it.
            Text(shortCountdownLabel(timeLabel: timeLabel, minutes: minutesUntilStart))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .contentTransition(.numericText(countsDown: true))
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(NoxAnimations.bouncy) {
                iconScale = 1.0
            }
        }
    }

    /// Compress the parent's "in 2 min" / "in 1 hr 5 min" / "now"
    /// label into a 3-4-character right-wing badge. The pill's
    /// right wing is ~46pt past the notch — enough for a short
    /// numeric badge but not the full prose timeLabel.
    ///
    /// Format priority:
    ///   • now / starting → "now"
    ///   • >= 60 min      → "Nh" rounded down (e.g. 90 min → "1h")
    ///   • else           → "Nm" (e.g. "2m", "12m")
    private func shortCountdownLabel(timeLabel: String, minutes: Int) -> String {
        if minutes <= 0 { return "now" }
        if minutes >= 60 {
            let h = minutes / 60
            return "\(h)h"
        }
        return "\(minutes)m"
    }

    /// 1.5Hz urgency pulse — slightly faster than the timer's 1Hz
    /// breathe to read as "act now" rather than "still ticking."
    private func pulseValue(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let omega = 2.0 * Double.pi / 0.66   // 1.5Hz
        return (sin(t * omega) + 1.0) / 2.0
    }
}

// MARK: - Track-changed pill body (album art + title/artist + equalizer)

/// Standalone pill content for `.trackChanged`. Modeled on Alcove's
/// brief "now playing" expansion that announces a new track for ~3.5s.
/// Layout follows the calendar/AirDrop pill convention:
/// `[ left tile ] [ Spacer crossing notch ] [ right wing ]`. Left tile
/// is the album art (or a fallback music glyph if MR didn't supply
/// artwork yet); right wing is the "Title · Artist" stack plus a
/// pulsing equalizer.
///
/// Why a separate body view instead of inlining: the equalizer's
/// TimelineView and the artwork's entrance scale want their own
/// `@State`. If this lived inline in PanelRootView, every
/// pendingSystemEvent transition would yank the state's identity and
/// the equalizer would skip frames. Owning the state here keeps it
/// stable for the full 3.5s announcement.
private struct TrackChangedPillBody: View {
    let title: String
    let artist: String
    /// Artwork the pill was displaying BEFORE this announcement
    /// fired. Rendered on the FRONT face of the two-faced flip.
    let fromArtworkData: Data?
    /// Artwork the pill should display AFTER this announcement
    /// completes. Rendered on the BACK face (pre-rotated 180°).
    let toArtworkData: Data?
    let notchOverlap: CGFloat
    let visible: Bool

    // Alcove-parity entry, RE-CALIBRATED against the supplied frames
    // 749–770:
    //   • Frame 749  — resting pill (just an "lll" equalizer)
    //   • Frame 750–755 — pill RETRACTED to invisible
    //   • Frame 756  — panel begins growing from notch-hidden
    //   • Frame 757  — small shape forming (panel mid-grow)
    //   • Frame 758  — panel at full banner size; ARTWORK FACE-ON
    //                  (NOT rotating — earlier rev had it rotating
    //                  which the user explicitly called out as wrong)
    //   • Frame 762–770 — text emerges in the apron
    //   • Frame 780+ — settled
    // The artwork doesn't flip. It fades in (with a tiny pop scale)
    // coordinated with the panel grow. ~33ms grow + ~150ms text emerge.
    // Animation state — minimal and SINGLE-VECTOR per element so
    // they don't fight the panel.frame spring underneath. Each
    // element has at most ONE motion + opacity:
    //   • Artwork: opacity + tiny scale-pop (0.92 → 1.0). The
    //     micro-scale is the "Alcove special touch" — the tile
    //     lands with a delicate settle, not flat on entry.
    //   • Text:    opacity + tiny upward slide (3pt → 0). Subtle
    //     emergence so the text looks like it's "rising into
    //     place" rather than just appearing.
    // Earlier revs had artwork rotation + scale + tilt + text
    // slide all firing concurrently, which read as "super stiff"
    // because too many vectors competed in 22pt of pill area.
    // Two-faced card flip for the artwork — same pattern as the
    // slab's `MusicPanelView.artworkFlipAngle` (lines 1100-1175).
    // User feedback 2026-05-07: "we need to tilt the artwork when
    // it's changing the music and the thing expanding".
    //
    // Starts at 0° showing the FRONT face (fromArtworkData = OLD
    // artwork). Animates to 180° during the banner expansion,
    // revealing the BACK face (toArtworkData = NEW artwork) which
    // is pre-rotated 180° so it appears upright when the parent
    // rotation reaches 180°.
    //
    // The user visibly sees the artwork CHANGING — old card flips
    // away, new card flips in.
    @State private var artworkFlipAngle: Double = 0
    @State private var textYOffset: Double = 3
    @State private var textOpacity: Double = 0.0

    /// Sign of cos(artworkFlipAngle) — drives which face is visible.
    /// >0 means front face is forward (cos > 0 in 0–90° and 270–360°),
    /// <0 means back face is forward (90–270°). Same trick the slab
    /// uses to swap front/back visibility mid-rotation.
    private var artworkFlipCosineSign: CGFloat {
        cos(artworkFlipAngle * .pi / 180) >= 0 ? 1 : -1
    }

    /// Lavender accent — kept only for the equalizer bars + the
    /// fallback music-glyph tile when MR hasn't supplied artwork.
    /// Not used as a halo color; that glow was removed for trackChanged.
    private var accent: Color { Color(red: 0.78, green: 0.62, blue: 0.98) }

    /// Single artwork face. Renders the JPEG bytes if available,
    /// otherwise the lavender placeholder tile with a music note.
    /// Used for both the front (old) and back (new) faces of the
    /// two-faced card flip.
    ///
    /// 2026-05-09 — bug fix for YouTube thumbnails during the flip.
    /// User report: "instead of the thumbnail showing the real
    /// thing, it shows half of the thumbnail at first when tilting,
    /// when it going back to the small pill, it shows the real
    /// actual artwork. But in the time of 3D tilt, it just don't
    /// show it."
    ///
    /// Root cause: previously this returned an
    /// `Image(...).resizable().aspectRatio(.fill)` with no explicit
    /// frame or hard clip. For a 16:9 source (YouTube thumbnails
    /// are 1280×720) SwiftUI fills the proposed square by scaling
    /// height to fit and overflowing width on both sides. With the
    /// outer `.clipShape` + `.compositingGroup` + `.rotation3DEffect`
    /// stack, the compositing group's offscreen rasterization can
    /// capture the overflow because the clip only affects the final
    /// visible result, not the layer baked into the rotating
    /// transform. During the rotation that overflow becomes visible
    /// and reads as "half the thumbnail showing."
    ///
    /// Fix: bake the frame + clip into each face. The rotating
    /// compositing group now sees a true 22×22 square regardless of
    /// source aspect ratio, matching how the resting pill's
    /// `PillArtworkLayerView` handles it via CALayer.resizeAspectFill
    /// + masksToBounds.
    @ViewBuilder
    private func artworkFace(data: Data?) -> some View {
        Group {
            if let data = data,
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    accent.opacity(0.18)
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipped()
    }

    var body: some View {
        // CORRECT LAYOUT (re-derived from frames 770/780/850):
        // Two rows, one BEHIND the notch hardware in the wings,
        // one BELOW the notch hardware in the visible apron.
        //
        //   Row 1 — at notch-hardware height (notchOverlap tall):
        //     [ artwork ]         (notch hardware blocks middle)         [ eq ]
        //     The artwork sits in the LEFT WING of the panel
        //     (auxiliary menu-bar area beside the notch). The
        //     equalizer sits in the RIGHT WING. Both wings are
        //     visible; the centre is hidden by the notch.
        //
        //   Row 2 — below the notch (visible apron):
        //                       Title · Artist
        //     Centred text, single line, NO leading music note glyph
        //     (Alcove screenshots confirm there's no ♪ prefix). The
        //     earlier rev placed everything in one row in the apron
        //     and added a music-note prefix — both wrong.
        // VStack of two rows — same layout pattern as `musicPillContent`
        // (which works correctly inside the panel silhouette). The
        // earlier ZStack approach with `.frame(maxWidth: .infinity)`
        // on each row produced a layout where the HStack's intrinsic
        // size + Spacer + frame.infinity interaction left content
        // hugging the panel-frame edge instead of the silhouette
        // edge — the artwork "touched the left side" and the bottom
        // text wasn't visible at all.
        VStack(spacing: 0) {
            // ROW 1 — wings at notch level. Artwork on the left,
            // equalizer on the right. Spacer takes the middle so
            // each wing item sticks to its edge of the silhouette.
            // Same `.padding(.horizontal, 10) .frame(height: notchOverlap)`
            // pattern as the music pill.
            HStack(spacing: 0) {
                // TWO-FACED CARD FLIP — same pattern as the slab's
                // `MusicPanelView.artworkFlipAngle` track-change
                // flip. Front face shows the OLD artwork
                // (`fromArtworkData`); back face shows the NEW
                // artwork (`toArtworkData`) pre-rotated 180° so it
                // appears upright when the parent rotation reaches
                // 180°. As `artworkFlipAngle` animates 0 → 180°,
                // the user visibly sees the artwork CHANGE.
                ZStack {
                    // FRONT face — OLD artwork (the one that was
                    // displayed in the resting pill before the
                    // track-change announcement fired).
                    artworkFace(data: fromArtworkData)
                        .opacity(artworkFlipCosineSign > 0 ? 1 : 0)

                    // BACK face — NEW artwork. Pre-rotated 180°
                    // around Y so when the outer rotation passes
                    // through 180° the back face content is right-
                    // side up (not mirrored).
                    artworkFace(data: toArtworkData)
                        .rotation3DEffect(
                            .degrees(180),
                            axis: (x: 0, y: 1, z: 0)
                        )
                        .opacity(artworkFlipCosineSign < 0 ? 1 : 0)
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                // compositingGroup BEFORE the outer rotation so both
                // faces are flattened into one layer that the 3D
                // transform applies to. Without this, SwiftUI re-
                // rasterizes each face per frame during rotation
                // (visible jitter).
                .compositingGroup()
                .rotation3DEffect(
                    .degrees(artworkFlipAngle),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    anchorZ: 0,
                    perspective: 0.5
                )
                // EXPLICIT value-bound animation so SwiftUI animates
                // every change to `artworkFlipAngle` with this exact
                // curve, regardless of whether the change happened
                // inside a `withAnimation` block or got wrapped in
                // some inherited animation context. Earlier
                // `withAnimation(.easeInOut(0.7))` in onAppear was
                // apparently being clobbered by the parent's
                // `.animation(.easeOut(0.27), value: pendingSystemEvent)`
                // — declaratively binding the curve here is more
                // robust than relying on transaction inheritance.
                .animation(.easeInOut(duration: 0.7).delay(0.05),
                           value: artworkFlipAngle)

                Spacer(minLength: 0)

                // Bars lerp between OLD song's color and NEW song's
                // color in lockstep with the 3D artwork flip. Lavender
                // `accent` is the fallback when ArtworkColor.dominant
                // can't extract a color (no artwork bytes / extraction
                // fails) — same fallback as the small pill's
                // WaveformView so a song without artwork looks
                // consistent across both surfaces.
                TrackChangedEqualizer(
                    fromAccent: ArtworkColor.dominant(from: fromArtworkData) ?? accent,
                    toAccent: ArtworkColor.dominant(from: toArtworkData) ?? accent,
                    flipProgress: artworkFlipAngle / 180.0
                )
                    .frame(width: 20, height: 16)
                    .opacity(textOpacity)
            }
            // Symmetric .padding(.horizontal, 10) — exactly matches
            // the resting music pill (PanelRootView:
            // `musicPillContent → .padding(.horizontal, 10)`).
            // User direction: artwork and equalizer stay in the
            // SAME positions during the announcement; only the
            // apron drops below.
            .padding(.horizontal, 10)
            .frame(height: notchOverlap)

            // ROW 2 — text in the apron strip.
            // Height = trackBannerBump (36pt). Alcove frame 850
            // measurement: text top is 5pt below the apron top, NOT
            // apron-centred. So use alignment: .top + 5pt padding
            // instead of alignment: .center.
            HStack(spacing: 5) {
                // Leading music-note glyph — Alcove parity (user
                // screenshot 2026-05-07 confirms it: "re:birth ·
                // 50landing" reads with the ♪ prefix). Earlier rev
                // removed this based on a different screenshot read
                // but Alcove definitely shows it.
                Image(systemName: "music.note")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !artist.isEmpty {
                    Text("·")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(artist)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: PanelWindowController.trackBannerBump, alignment: .top)
            // Alcove parity: text fades out at the left and right
            // edges so it doesn't read as solid white slammed against
            // the apron boundary. User feedback 2026-05-07: "the
            // text you gave is too white sides are faded into the
            // alcove". Horizontal mask gradient — opaque in the
            // centre, fading to clear over the outer 10% on each
            // side. When the text is shorter than the apron, the
            // gradient sits outside the rendered glyphs and has no
            // visible effect.
            // Stronger fade per user feedback 2026-05-07: "still texts
            // side are not faded enough". Stops moved 0.10 → 0.18 and
            // 0.90 → 0.82 so the fade region is now the outer 18% of
            // each side instead of just 10% — visibly softer, more
            // pronounced taper into the apron edge.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .white, location: 0.18),
                        .init(color: .white, location: 0.82),
                        .init(color: .clear, location: 1.00),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .offset(y: textYOffset)
            .opacity(textOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            // CRITICAL: dispatch the artworkFlipAngle change to the
            // NEXT runloop tick. If we set it synchronously inside
            // onAppear, SwiftUI batches the @State change with the
            // initial mount's render — the .animation(value:) modifier
            // sees the value as already 180° at first body call and
            // skips the animation. The async dispatch forces a fresh
            // value transition (0° initial render → 180° next tick)
            // that SwiftUI's animation system actually animates.
            DispatchQueue.main.async {
                artworkFlipAngle = 180
            }
            withAnimation(NoxAnimations.snappy.delay(0.28)) {
                textYOffset = 0
                textOpacity = 1.0
            }
        }
    }
}

/// Four-bar equalizer that animates via TimelineView so each frame's
/// height is computed from a wall-clock phase. Wall-clock-driven
/// (not state-driven) so the bars stay smooth even if the parent
/// re-renders mid-animation. Frequencies are deliberately offset
/// per-bar so the bars don't pulse in sync.
///
/// **2026-05-09 color fix:** previously `accent` was a hardcoded
/// lavender constant in the parent (`Color(red: 0.78, green: 0.62,
/// blue: 0.98)`). User-reported bug: "during the 3D titling, the
/// audio visualizer color is bugged — instead of fading and
/// getting the next music's gradient, it's getting something
/// different." The hardcoded lavender was that "something
/// different." Now the bars LERP between the OLD song's dominant
/// artwork color and the NEW song's dominant artwork color, with
/// the lerp factor driven by the same `artworkFlipAngle` that
/// rotates the artwork card. By the time the flip finishes the
/// bars match the new song's palette — visible continuity with
/// the small pill's WaveformView that takes over after dismiss.
private struct TrackChangedEqualizer: View {
    /// Bar color at the START of the flip (artworkFlipAngle = 0°).
    /// Should be the OLD song's dominant color.
    let fromAccent: Color
    /// Bar color at the END of the flip (artworkFlipAngle = 180°).
    /// Should be the NEW song's dominant color.
    let toAccent: Color
    /// 0...1 progress through the flip. SwiftUI animates this
    /// alongside the artwork rotation, so the lerped color rolls
    /// continuously across the transition.
    let flipProgress: Double

    private let barCount = 4
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 1.4

    /// LRGB-space lerp between two SwiftUI Colors. Samples each
    /// Color's RGB components via NSColor, interpolates linearly,
    /// rebuilds. Computed per body re-eval — fast enough that
    /// firing on every TimelineView tick (~30Hz × 0.7s flip = ~20
    /// allocations per transition) is invisible perf-wise.
    private var barAccent: Color {
        let t = max(0.0, min(1.0, flipProgress))
        let nsA = NSColor(fromAccent).usingColorSpace(.sRGB) ?? .white
        let nsB = NSColor(toAccent).usingColorSpace(.sRGB) ?? .white
        let r = nsA.redComponent + (nsB.redComponent - nsA.redComponent) * CGFloat(t)
        let g = nsA.greenComponent + (nsB.greenComponent - nsA.greenComponent) * CGFloat(t)
        let b = nsA.blueComponent + (nsB.blueComponent - nsA.blueComponent) * CGFloat(t)
        return Color(NSColor(
            srgbRed: r, green: g, blue: b, alpha: 1.0
        ))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let accent = barAccent
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = sin(t * 5.5 + Double(i) * 0.95) +
                                sin(t * 3.2 + Double(i) * 1.7) * 0.5
                    let normalized = (phase + 1.5) / 3.0   // → 0…1
                    let height = 4 + max(0, normalized) * 10
                    Capsule()
                        .fill(accent.opacity(0.92))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Volume HUD pill body (notch-anchored speaker glyph + level bar)

/// Standalone pill content for `.volumeChanged`. Renders below the
/// hardware notch in the visible apron of the volume banner frame
/// (PanelWindowController.volumeBannerFrame: notchOverlap +
/// volumeBannerBump tall, volumeBannerWidth wide).
///
/// LAYOUT (single row in the apron, mirrors Alcove's volume HUD):
///   • Auto-switching speaker glyph on the LEFT
///     (mute → speaker.slash.fill, low → speaker.wave.1.fill,
///      mid → speaker.wave.2.fill, high → speaker.wave.3.fill)
///   • Horizontal level bar on the RIGHT — track + fill, fill
///     animates to `level` with a tracking spring so held-key
///     keystrokes flow continuously
///
/// Held-key behavior: every keypress re-pushes pendingSystemEvent
/// with a new (level, muted) tuple. SwiftUI's id-stable view
/// instance (id "volume" in pillContentOverlay) re-renders in
/// place — fill width tracks the new level via the .animation
/// modifier, no entrance bounce per tick.
private struct VolumePillBody: View {
    let level: Float
    let muted: Bool
    let notchOverlap: CGFloat
    let visible: Bool

    /// Speaker glyph based on level + mute. Per user spec:
    /// "if it's below 50 one curve and if it's more then 50 2
    /// curve line."
    ///   • mute or 0  → speaker.slash.fill
    ///   • 0–49%      → speaker.wave.1.fill (one curve)
    ///   • 50–100%    → speaker.wave.2.fill (two curves)
    private var speakerSymbol: String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    /// Speaker glyph view with smooth symbol-morph transition on
    /// macOS 14+, plain Image on older systems. Wrapped here so
    /// the body can stay clean of @available branching.
    @ViewBuilder
    private var speakerImage: some View {
        if #available(macOS 14.0, *) {
            Image(systemName: speakerSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(muted ? 0.45 : 0.95))
                .contentTransition(.symbolEffect(.replace.downUp))
        } else {
            Image(systemName: speakerSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(muted ? 0.45 : 0.95))
        }
    }

    /// Entrance animation state. The pill silhouette has its own
    /// frame-morph spring (in PanelWindowController.showVolumeBanner,
    /// 1100/62 stiffness/damping ≈ 130ms tactile landing). Content
    /// rides ON TOP of that morph with its own opacity + scale spring
    /// so the elements feel like they land into the pill rather than
    /// pop in. Two elements get staggered:
    ///   • icon + label (left wing): scale-up from 0.85, fade in
    ///   • bar (right wing):          scale-up from 0.85 anchored at
    ///                                trailing so it slides from the
    ///                                right edge inward
    /// 50ms delay so content arrives just as the panel-frame spring
    /// reaches its tactile-landing zone.
    var body: some View {
        // ROUND 14 — REMOVED competing @State + onAppear springs.
        // They were running CONCURRENTLY with the panel-frame
        // SpringFrameAnimator (CADisplayLink driven). Two springs
        // fighting for main-thread time produced the lag/jitter
        // the user reported during expand/close.
        //
        // Now: only the parent's `.transition(.opacity)` handles
        // entrance — Core Animation does the alpha fade off-thread,
        // no main-thread cost. Icon morph still uses
        // .contentTransition(.symbolEffect.replace) on macOS 14+
        // (also Core Animation, off-thread).
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                speakerImage
                    .frame(width: 14, alignment: .center)
                    .animation(.smooth(duration: 0.28), value: speakerSymbol)

                Text("Sound")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize()
            }

            Spacer(minLength: 0)

            VolumeLevelBar(level: level, muted: muted)
                .frame(width: 60, height: 3)
        }
        .frame(maxWidth: .infinity)
        // Asymmetric padding — left 18pt for the icon+text wing,
        // right 22pt so the bar sits proportionally inside the
        // right wing without crowding the silhouette's right
        // curve. Bar narrowed 80 → 60pt per user feedback "the
        // bar should be more small by matching the side properly."
        .padding(.leading, 18)
        .padding(.trailing, 22)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
    }
}

/// Horizontal level meter — track behind, fill on top. Fill width
/// is `geometry.width × level`, animated with a tracking spring so
/// rapid level changes (held volume key) read as one continuous
/// motion rather than tick-by-tick steps. Mute dims the fill so
/// the user can tell at a glance whether mute toggled with the
/// same level still set.
///
/// Bar HEIGHT 4pt — matches Alcove's reference silhouette inside
/// the slim 18pt apron. Earlier tried 6pt when the apron was
/// taller (44pt) — at the slim 18pt apron, 6pt would feel
/// proportionally too thick.
private struct VolumeLevelBar: View {
    let level: Float
    let muted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track — subtle white tint at low alpha. Reads as
                // "available range" without competing with the fill.
                Capsule()
                    .fill(Color.white.opacity(0.22))

                // Fill — solid white, dimmed when muted. Width is
                // proportional to level, clamped to track width so
                // we don't overshoot if a buggy CoreAudio reading
                // returns >1.
                Capsule()
                    .fill(Color.white.opacity(muted ? 0.32 : 0.95))
                    .frame(width: max(0, min(CGFloat(level), 1)) * geo.size.width)
                    // Tracking spring — re-targets continuously as
                    // level updates per tick. Response 0.22 reads
                    // as "snappy but smooth," damping 0.85 keeps
                    // it overdamped (no bounce on each step which
                    // would jitter the fill).
                    .animation(
                        .interactiveSpring(
                            response: 0.22,
                            dampingFraction: 0.85,
                            blendDuration: 0.12
                        ),
                        value: level
                    )
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - AirDrop pill body (cosmetic progress sweep + UTI icon)

/// Standalone pill content for `.airDropReceived`. Owns its own
/// `@State` so the entrance animation runs once per arrival even
/// when the parent re-renders (e.g. when the system event slot
/// is replaced). Two phases:
///
/// 1. **0–600ms**: white arc sweeps 0 → 1 around the empty tile
///    (the tile background fills with the AirDrop blue tint). Text
///    label reads "Receiving…". This is purely cosmetic — by the
///    time we get an `onArrival` callback, the file is already on
///    disk; macOS doesn't expose Sharingd's in-flight progress to
///    third parties so we can't show real %. The 600ms duration is
///    short enough that the user reads it as "transfer just
///    completed" rather than waiting for nothing.
///
/// 2. **600ms onward**: arc fades, the UTI-specific glyph (photo /
///    video / music / generic) springs in (0.6 → 1.0 bouncy), and
///    the label flips to the actual filename. Stays in this state
///    for the remainder of the pill's lifetime (~3.4s of the 4s
///    total `airDropReceived` timeout).
private struct AirDropPillBody: View {
    let filename: String
    let fileURL: URL?
    let notchOverlap: CGFloat
    let visible: Bool

    /// 0…1 fill of the entrance arc. Animates from 0 to 1 over the
    /// first 600ms via withAnimation in onAppear.
    @State private var arcFill: Double = 0
    /// True after the arc completes. Drives the cross-fade from arc
    /// → file glyph and the label swap from "Receiving…" to filename.
    @State private var didComplete: Bool = false
    /// Glyph scale on settle — 0.6 at the moment of completion,
    /// springs to 1.0 to give the file icon a tactile "pop in"
    /// rather than a flat fade.
    @State private var iconScale: Double = 0.6

    private static let arcDuration: Double = 0.6

    var body: some View {
        // AirDrop pill: blue tile, AirDrop logo as the persistent
        // icon throughout the pill's lifetime. The earlier design
        // showed the logo only during a 600ms pre-completion phase
        // and then swapped to a UTI glyph (photo.fill / etc.) —
        // but that meant users almost never saw the AirDrop logo
        // itself, since the brief glimpse passed before they
        // looked. Now the logo IS the icon. Icon-only — no text.
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.78, blue: 0.99).opacity(0.92))

                // Hand-drawn AirDrop logo (`AirDropLogo` SwiftUI
                // View). Apple keeps the actual `airdrop` symbol
                // private (verified by SF Symbols enumeration) so
                // we draw it: 3 concentric dome arcs + upward
                // wedge, matching the system mark.
                AirDropLogo()
                    .frame(width: 14, height: 14)
                    .scaleEffect(iconScale)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            // Single-step entrance: AirDrop logo springs in from
            // 0.6× → 1.0× scale. No arc-sweep state machine, no
            // UTI-glyph swap — just the logo appearing with a
            // tactile "pop in" so the entrance still feels alive.
            withAnimation(NoxAnimations.panelOpen) {
                iconScale = 1.0
            }
        }
    }

    /// SF Symbol for the arrived file based on its UTI. Reads via
    /// `URL.resourceValues(forKeys: [.contentTypeKey])` (the modern
    /// UniformTypeIdentifiers path), falling back to extension-based
    /// guessing if the resource read fails (e.g. file moved by the
    /// time we ask). Symbols are chosen to match Apple's own quick-
    /// look glyph language: `photo` for images, `play.rectangle.fill`
    /// for video, `music.note` for audio, `doc.fill` otherwise.
    private var glyphForFile: String {
        guard let url = fileURL else { return "doc.fill" }
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            if type.conforms(to: .image) { return "photo.fill" }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return "play.rectangle.fill" }
            if type.conforms(to: .audio) { return "music.note" }
            if type.conforms(to: .pdf) { return "doc.richtext.fill" }
            if type.conforms(to: .archive) { return "doc.zipper" }
        }
        // Extension fallback in case the resource fetch fails.
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff": return "photo.fill"
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return "play.rectangle.fill"
        case "mp3", "wav", "m4a", "flac", "aac", "ogg": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "zip", "tar", "gz", "rar", "7z": return "doc.zipper"
        default: return "doc.fill"
        }
    }
}

// MARK: - Charging tile (pill content for charging events)

/// 22pt rounded square that shows a battery/bolt glyph and animates
/// while the pill is in "charging" mode. The bolt does a continuous
/// 1.0 → 1.18 scale + opacity pulse (~1.4s cycle) to convey "energy
/// flowing in"; the unplugged battery glyph stays static. On first
/// appearance the entire tile springs from 0.6 → 1.0 scale to give
/// the pill morph a satisfying tactile pop.
///
/// The pulse runs off `TimelineView(.animation)` rather than
/// `withAnimation` / `.animation(...repeatForever, value:)`. The
/// parent `chargingPillContent` lives inside a SwiftUI subtree
/// that has `.animation(.bouncy, value: presenter.pendingSystemEvent)`
/// applied to it — every time the OS reports a fresh charging
/// snapshot (which can land mid-pulse), the bouncy curve was
/// propagating into the icon's animation context and briefly
/// hijacking the pulse, reading as a visible jitter / glitch on
/// the bolt. TimelineView computes the scale/opacity from wall-
/// clock time per refresh tick, so it has no dependency on
/// SwiftUI's state-driven animation system and the parent's
/// bouncy can't reach it. As a bonus, this also fixes the
/// timing-drift issue where `repeatForever` would desync after
/// a few seconds because `.animation(...,value:)` doesn't
/// faithfully resume from the same phase across re-evaluations.
private struct ChargingTile: View {
    let percent: Int
    let plugged: Bool

    @State private var appeared: Bool = false

    /// Pulse period in seconds. 1.4s end-to-end (~0.7s up,
    /// ~0.7s down) reads as "breathing" rather than "twitching."
    private let pulsePeriod: Double = 1.4

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tileColor)
            // Wall-clock-driven pulse. TimelineView ticks at the
            // display's refresh rate (capped to `minimumInterval`
            // when paused / occluded) and recomputes the scale +
            // opacity on each tick. Because the values are derived
            // directly from `context.date`, no @State changes are
            // involved — the parent's `.animation(.bouncy, value:)`
            // can't propagate into this subtree because there's no
            // animation event to attach to. While unplugged the
            // timeline is effectively idle (paused: true), so we
            // don't burn the GPU on a static glyph.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                     paused: !plugged)) { context in
                let phase = pulsePhase(for: context.date)
                Image(systemName: plugged ? "bolt.fill" : "battery.50")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .scaleEffect(plugged ? 1.0 + phase * 0.18 : 1.0)
                    .opacity(plugged ? 1.0 - phase * 0.15 : 1.0)
                    // Force a clean unmount/remount when plugged
                    // flips. SwiftUI's `.id(_:)` makes it treat
                    // pre/post values as DIFFERENT views — the
                    // old Image is dropped instantly, the new
                    // one mounts instantly. Without this, the
                    // parent pillContentOverlay's
                    // `.animation(.bouncy, value: pendingSystemEvent)`
                    // was propagating into the Image's
                    // `systemName` swap and crossfading between
                    // `battery.50` and `bolt.fill` — both
                    // visible during the fade, which the user
                    // saw as the discharged logo overlapping
                    // the charging pill icon.
                    .id(plugged)
            }
            // Belt-and-braces: also kill any animation on the
            // ZStack containing tile + icon so unintended
            // crossfades from outside this view tree can't
            // sneak in.
            .transaction { $0.animation = nil }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .scaleEffect(appeared ? 1.0 : 0.6)
        .onAppear {
            withAnimation(.bouncy(duration: 0.45, extraBounce: 0.3)) {
                appeared = true
            }
        }
    }

    /// Sinusoidal 0…1 pulse derived from wall-clock time. Using
    /// `(sin + 1) / 2` instead of a raw sin gives a smooth
    /// up-and-down curve in the 0..1 range that the scale and
    /// opacity readers can scale into their target ranges.
    private func pulsePhase(for date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let omega = 2.0 * Double.pi / pulsePeriod
        return (sin(t * omega) + 1.0) / 2.0
    }

    private var tileColor: Color {
        if plugged {
            return Color(red: 0.30, green: 0.78, blue: 0.39)
        }
        if percent < 20 {
            return Color(red: 0.95, green: 0.40, blue: 0.20)
        }
        return Color(red: 0.45, green: 0.45, blue: 0.50)
    }
}


/// Breathing drop-target halo. Lives in its own View struct so
/// the `.animation(.repeatForever)` lifecycle is bound to a
/// stable `@State` flag that flips on first appear — this is
/// SwiftUI's blessed pattern for continuous animations and is
/// far more reliable than embedding a TimelineView under a
/// conditional. The previous implementation had the breath
/// rendering invisibly because TimelineView under `if` was being
/// optimized out.
private struct DropRingBreath: View {
    let silhouette: OutwardFlaredShape
    let accent: Color

    @State private var pulsing = false

    var body: some View {
        ZStack {
            // Wide soft halo — large stroke + blur, high opacity
            // contrast so the breath is unmistakable visually.
            silhouette
                .stroke(accent.opacity(pulsing ? 0.65 : 0.20), lineWidth: 12)
                .blur(radius: 6)

            // Mid stroke — sharp 2pt accent for definition.
            silhouette
                .stroke(accent.opacity(pulsing ? 0.95 : 0.55), lineWidth: 2)
        }
        .onAppear {
            // Kick the pulse the moment the view mounts.
            // 1.4s autoreverse breath, infinite loop.
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

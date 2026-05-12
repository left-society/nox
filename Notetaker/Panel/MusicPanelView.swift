import SwiftUI
import AppKit

/// Alcove-style compact music HUD — small album-art tile on the left,
/// title/artist stacked next to it, a small live-audio waveform on the
/// trailing edge, then a scrubbable progress bar and the three transport
/// controls beneath. This is the "music page" surface the panel routes
/// to when audio is playing.
///
/// Why this shape (vs. the earlier tall vertical column with a 180pt
/// album-art tile and a ~480pt total content height): the fixed-height
/// slab couldn't contain the previous layout — the bottom row of
/// controls and source badge spilled past the silhouette's rounded
/// bottom corners and into the haloPadding margin where the black
/// background was no longer painted. The user explicitly referenced
/// Alcove ("the alcove one is what i want") with a screenshot showing
/// a dense horizontal info-row + linear progress + 3-button cluster
/// that fits in roughly 200pt of vertical content. This file matches
/// that shape; `PanelWindowController.innerPanelHeight(for:)` separately
/// shrinks the slab when `.music` is the active tab so the black
/// background actually wraps the content.
///
/// Mount cost is still tiny — the heaviest thing in here is the
/// optional `NSImage(data:)` decode for artwork, which is fast because
/// the data is already in memory (came across the MediaRemote
/// notification payload). No async fetches, no scroll content, no
/// list — same lightweight first-paint posture that made this view the
/// auto-route default during playback.
///
/// Bindings:
/// - `presenter.nowPlaying`: source of truth, forwarded here from
///   `MediaRemoteService` via `NotchOrchestrator`. Re-renders happen
///   exactly when the snapshot changes — title flip, play↔pause,
///   artwork swap.
/// - `presenter.onMediaCommand`: closure to dispatch play/pause/skip.
///   Owned by NotchOrchestrator's MediaRemoteService; wired in once
///   at launch.
/// Tagged enum for which "drill-into-status" detail panel is open
/// inside the Live tab. Top-level so future modules (Battery,
/// Weather, Wi-Fi) can add cases here without rebuilding
/// MusicPanelView's local state.
enum LiveExpandedPanel: Hashable {
    case focus
    case study
    // case battery, case weather, case wifi  — add as built
}

struct MusicPanelView: View {
    @EnvironmentObject var presenter: PanelPresenter

    /// Drag-to-scrub state for the progress bar. While `isScrubbing`
    /// is true, the bar renders `scrubProgress` instead of the live
    /// playback fraction — gives the user immediate feedback as they
    /// drag, even though the seek doesn't land until they release.
    /// Apple Music / Spotify desktop both use this pattern.
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    /// Hover state for the progress bar — when true, the scrubber
    /// thumb appears (so the user can SEE the bar is interactive
    /// before they grab it). Also slightly thickens the track.
    @State private var isProgressHovering = false
    /// Timestamp of the last transport command we dispatched. Used to
    /// debounce rapid-fire button taps — Spotify and Music both react
    /// to MediaRemote commands within ~80-150ms, but the *AppleScript*
    /// helpers we route seek through can stall a few hundred ms. If
    /// the user mashes Next, we'd otherwise queue up a stack of
    /// commands the source app processes serially, manifesting as
    /// "skipped 4 tracks at once." Hard-floor the inter-command
    /// interval at 150ms.
    @State private var lastCommandAt: Date = .distantPast
    /// Settings-driven gate. Default true for first-launch users
    /// so the visualizer is on out-of-the-box.
    @AppStorage("sphereVisualizerEnabled") private var sphereEnabled: Bool = true

    /// Mirrors the dashboard's @AppStorage so the Focus pill on
    /// the home screen re-renders the moment the user flips
    /// `noxFocusMode` from the dashboard. Without this binding,
    /// `liveFocusPillActive` (which reads UserDefaults inline)
    /// wouldn't trigger a SwiftUI invalidation when the
    /// dashboard's toggle flips, so the pill would stay grey
    /// until the next unrelated state change forced a redraw.
    @AppStorage(SettingsKey.noxFocusMode) private var noxFocusMode: Bool = false

    /// Sibling to `noxFocusMode` — user's Study mode toggle. Same
    /// AppStorage shape so the Study pill in `liveStatusRow` re-
    /// renders when the bool flips elsewhere (mutex with Focus, or
    /// future surfaces). Mirrored intentionally so future status
    /// pills (battery, weather) can follow the same pattern.
    @AppStorage(SettingsKey.noxStudyMode) private var noxStudyMode: Bool = false

    /// Which expanded "drill-into-status" panel is currently open
    /// inside the Live tab. nil = home (the music + calendar
    /// HStack). Set by tapping a pill in `liveStatusRow`; cleared
    /// by the panel's own back button.
    ///
    /// Designed as a tagged enum (rather than a Bool) so the same
    /// surface can host future Battery / Weather / Wi-Fi panels —
    /// each gets a case here, a row pill in `liveStatusRow`, and
    /// a switch arm in body.
    @State private var expandedLivePanel: LiveExpandedPanel? = nil

    /// 3D-tilt swap phase for the artwork. -1 = exiting (tilted away
    /// from viewer + faded), 0 = at rest, +1 = entering (tilted
    /// from below toward viewer). Animated by `triggerArtworkSwap`
    /// on track changes AND immediately on `dispatch(.next/.previous)`
    /// — the eager trigger means the artwork starts moving the moment
    /// the user clicks the button, not after the source app finally
    /// reports the new track. That's what makes Alcove's transitions
    /// feel zero-latency: the animation runs in PARALLEL with the
    /// underlying track change, so the new artwork lands at the end
    /// of the in-flight tilt rather than after a lag.
    @State private var artworkSwapPhase: Double = 0
    /// Cumulative Y-axis flip angle for the new (DynamicNotch-style)
    /// swap animation. Each track change does `+= 180`; the cosineSign
    /// modifier mirrors the X scale on the back face so the artwork
    /// is never visually mirrored. Reference: jackson-storm/DynamicNotch
    /// `Features/NowPlaying/Components/ArtworkView.swift` —
    /// `AlbumArtFlipModifier`. Single rotation + sign-flip is the
    /// cleanest possible "vinyl card flip" — replaces the previous
    /// 5-axis stack (offset + blur + scale + 3D rotate + opacity)
    /// the user described as "weird tilted."
    @State private var artworkFlipAngle: Double = 0
    /// Direction of the swap: -1 = previous (tilt toward right edge),
    /// +1 = next (tilt toward left edge). Determines the rotation
    /// axis sign so the artwork visually moves in the direction
    /// matching the user's intent.
    @State private var artworkSwapDirection: Double = 1
    /// Stable identity for the currently-displayed track, used to
    /// detect actual track changes vs. content-only refreshes.
    @State private var displayedTrackKey: String = ""
    /// The artwork data we're CURRENTLY displaying. Decoupled from
    /// `presenter.nowPlaying.artworkData` so that during a swap-out,
    /// we can keep showing the OLD artwork until the swap-in phase
    /// — preventing a frame where the new artwork appears at full
    /// alpha before the entrance animation runs.
    @State private var displayedArtworkData: Data? = nil
    /// Title/artist/album we're currently displaying. Decoupled from
    /// `presenter.nowPlaying` (just like `displayedArtworkData`) so
    /// title/artist text fades through the swap animation in lockstep
    /// with the artwork — without this, the text would SNAP to the
    /// new values the moment Spotify's MediaRemote pushed them, while
    /// the artwork was still tilting out. User saw the artwork
    /// animate but the text snap, and reported "still laggy inside."
    /// elapsedTime / isPlaying are NOT decoupled — those need to be
    /// live (progress bar, waveform).
    @State private var displayedTitle: String = ""
    @State private var displayedArtist: String = ""
    @State private var displayedAlbum: String = ""
    /// Cached decoded NSImage for the slab artwork. Populated from
    /// `ArtworkCache` synchronously on cache hit, asynchronously
    /// on miss. Keeps the main thread off the NSImage(data:) decode
    /// hot path and gives instant return-to-recent.
    @State private var displayedArtworkImage: NSImage? = nil
    /// The INCOMING artwork during a flip animation. Pre-loaded
    /// onto the card's BACK face the moment a track change is
    /// detected, so the rotation reveals the new artwork as it
    /// rotates past 90° — a true card flip with two distinct sides
    /// rather than the previous "same image rotates 178°, then snap
    /// to new at 89% of the duration" pattern.
    ///
    /// User feedback 2026-05-06: "It is like changing two artworks
    /// for two different pieces of music. We need to make the
    /// animation between the first artwork and the second artwork.
    /// On the other side of the flip, it is the second artwork."
    /// Promoted to displayedArtworkImage at flip completion; reset
    /// to nil after promotion so the next flip starts clean.
    @State private var nextArtworkImage: NSImage? = nil
    /// Source-app sound volume on a 0-1 scale. Polled on track
    /// change and dispatched on slider drag. Spotify and Apple Music
    /// both expose `sound volume` (0-100) in AppleScript.
    @State private var sourceVolume: Double = 0.7
    /// While the user is actively dragging the volume slider, we
    /// suppress polled-value updates so the slider doesn't jitter
    /// between the user's intended value and the value we just
    /// dispatched (round-trip latency is ~100ms). Released when the
    /// slider's onEditingChanged ends.
    @State private var isAdjustingVolume: Bool = false

    /// Snappy spring with defined endpoint — bounce in motion phase,
    /// clean settle at duration, no sub-pixel tail. Matches
    /// PanelRootView's cascadeAnimation. See full rationale there.
    private var cascadeAnimation: Animation {
        if #available(macOS 14.0, *) {
            return .snappy(duration: 0.32, extraBounce: 0.15)
        } else {
            return .interpolatingSpring(mass: 1.0, stiffness: 350, damping: 22)
        }
    }

    /// Should the status row above the music+calendar grid render
    /// at all? True iff at least one status pill should be on
    /// screen. The Focus pill is now ALWAYS rendered (so users
    /// have a discoverable way IN to the Focus detail panel even
    /// when macOS Focus is off — user feedback 2026-05-08:
    /// "focus thing is gone it should be always there so people
    /// can turn it on"). Future Battery / Weather / Wi-Fi pills
    /// will OR into this — they'll be conditionally visible
    /// based on their own data, but Focus is the always-on
    /// anchor of the row.
    private var shouldShowLiveStatusRow: Bool {
        true
    }

    /// Active state for the Focus status pill. True when EITHER
    /// nox's own Focus mode is on (`noxFocusMode` @AppStorage —
    /// triggers SwiftUI re-render on flip) or macOS Focus is
    /// active (`presenter.isFocused` Combine-published — same).
    /// Mirrors `LiveFocusDetailPanel.isInFocusState` so the pill
    /// on the home screen and the dashboard hero never disagree.
    private var liveFocusPillActive: Bool {
        noxFocusMode || presenter.isFocused
    }

    var body: some View {
        // Top-level switch: either we're showing the home view
        // (status row + music + calendar) or we've drilled into a
        // detail panel (Focus / future Battery / Weather).
        //
        // The switch is wrapped in a Group so the .transition +
        // .animation modifiers cleanly cross-fade between states
        // without identity collisions.
        Group {
            if let panel = expandedLivePanel {
                switch panel {
                case .focus:
                    LiveFocusDetailPanel(
                        onBack: {
                            withAnimation(.easeOut(duration: 0.22)) {
                                expandedLivePanel = nil
                            }
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24)),
                        removal: .opacity.combined(with: .offset(x: 24))
                    ))
                case .study:
                    LiveStudyDetailPanel(
                        onBack: {
                            withAnimation(.easeOut(duration: 0.22)) {
                                expandedLivePanel = nil
                            }
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24)),
                        removal: .opacity.combined(with: .offset(x: 24))
                    ))
                }
            } else {
                liveHomeView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: -24)),
                        removal: .opacity.combined(with: .offset(x: -24))
                    ))
            }
        }
        .animation(.easeOut(duration: 0.22), value: expandedLivePanel)
        // When the user toggles Focus off while already inside the
        // Focus detail panel, kick them back to home automatically
        // — leaving them stranded on a "Focus is off" detail page
        // with no live data feels broken. The .onChange fires after
        // presenter.isFocused flips false so we get the smooth
        // cross-fade for free.
        .onChange(of: presenter.isFocused) { newValue in
            if !newValue && expandedLivePanel == .focus {
                withAnimation(.easeOut(duration: 0.22)) {
                    expandedLivePanel = nil
                }
            }
        }
        // Same auto-pop for Study — when the user flips noxStudyMode
        // off via the toggle inside LiveStudyDetailPanel, kick them
        // back to home rather than stranding them on a "Study is off"
        // detail page with no live data.
        .onChange(of: noxStudyMode) { newValue in
            if !newValue && expandedLivePanel == .study {
                withAnimation(.easeOut(duration: 0.22)) {
                    expandedLivePanel = nil
                }
            }
        }
    }

    /// The default Live view: status row (when relevant) above the
    /// music + calendar HStack. Extracted so the body's switch can
    /// transition between this and the detail panels cleanly.
    private var liveHomeView: some View {
        // Gradient lives at PanelRootView level now (so it covers
        // the actual TOP of the panel, behind the header / tabs)
        // — see `artworkTopGradient` there. This view just lays
        // out the music HUD content on top of the panel-level tint.
        //
        // Composition: optional status row at top, then the
        // now-playing block (artwork + title/artist/album +
        // waveform visualizer) wrapped in an inset rounded card
        // to give the "what's playing" identity a defined surface —
        // pattern Apple uses on the Sonoma+ Music app's mini
        // player and Settings detail cards. Progress / transport /
        // volume stay flat on the slab below for the airy Apple
        // Music transport-row look.
        // 2026-04-29 layout: transport (prev/play/next) + volume
        // moved INTO the now-playing card's right wing — see
        // `inlineControlsCluster`. The bottom transport row is
        // gone, removing ~58pt of vertical space and any chance
        // of the play button clipping. `transportControls` is
        // kept as a private helper for now (referenced internally
        // by the dispatch chain) but isn't rendered.
        // 2026-05-06: split layout — music on the LEFT, today's
        // calendar events on the RIGHT. Mirrors the layout the
        // user sketched in their reference screenshot. Calendar
        // pane connects to real Apple Calendar via the existing
        // EventKit-backed `CalendarMonitorService` instance owned
        // by AppDelegate.
        //
        // 1.9.10 (idea: "everything starts from the live section"
        // borrowed from SuperIsland's HomeScreenView pattern): an
        // optional status row sits above the music + calendar
        // grid. Each pill in the row is a clickable entry point
        // for a "drill into status" detail panel — Focus first,
        // future Battery / Weather / Wi-Fi modules slot into the
        // same row. The row hides itself when nothing has data
        // worth showing so the music + calendar layout stays
        // unchanged for users without active status.
        VStack(alignment: .leading, spacing: shouldShowLiveStatusRow ? 14 : 0) {
        if shouldShowLiveStatusRow {
            liveStatusRow
                .blur(radius: presenter.cascadeReady ? 0 : 10)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -16)
                .animation(cascadeAnimation, value: presenter.cascadeReady)
        }
        HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
            // PER-ELEMENT MATERIALIZATION (Alcove-inspired). User
            // 2026-05-05: "they apply [blur] inside of each content."
            //
            // Each element materializes individually with its own
            // blur + opacity, staggered so they "cascade into focus"
            // as the panel opens. Reverse on close — elements
            // dissolve out individually with stagger.
            //
            // Stagger pattern (delays):
            //   Artwork (foundation, anchors visual):  0.00s
            //   Progress bar (next, info layer):       0.04s
            //   Transport row (last, interaction):     0.08s
            // Total stagger spread: 80ms — subtle but visible,
            // matches Alcove's "elements appear in sequence" feel.
            // 2026-05-04 (matches PanelRootView): cascade uses
            // .snappy on macOS 14+, fallback to a tuned
            // interpolatingSpring on macOS 13. Spring with bounce
            // in motion phase, clean settle at duration boundary,
            // no sub-pixel tail. See cascadeAnimation comment in
            // PanelRootView for the rationale.
            nowPlayingCard
                .blur(radius: presenter.cascadeReady ? 0 : 10)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -28)
                .animation(cascadeAnimation, value: presenter.cascadeReady)
            progressBar
                .blur(radius: presenter.cascadeReady ? 0 : 12)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -32)
                .animation(cascadeAnimation.delay(0.04), value: presenter.cascadeReady)
            // 2026-05-02 transport + inline mini-volume row.
            iosStyleTransportRow
                .blur(radius: presenter.cascadeReady ? 0 : 14)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -36)
                .animation(cascadeAnimation.delay(0.08), value: presenter.cascadeReady)
            // BluetoothBatteryRow removed at user request — the
            // component file is still present (BluetoothBatteryRow.swift)
            // but isn't rendered.
            Spacer(minLength: 0)
        }
        // 2026-05-06 (rev 7): TRUE 50/50 SPLIT. User asked for the
        // music side and the calendar side to take equal width so
        // the panel reads as a balanced two-pane layout (was 310/
        // 160 = music-dominant).
        //
        // Math (498pt inner content area):
        //   music   235pt
        //   spacer   14
        //   divider   0.5
        //   spacer   14
        //   calendar 234.5pt   (filling remaining via maxWidth:.infinity)
        // Total: 498pt. Music ≈ Calendar. Visually symmetric.
        //
        // Transport row was reworked in lockstep (rev 7): the
        // inline volume slider doesn't fit at 235pt without
        // squeezing the play button off-center. Volume removed
        // entirely — system volume keys + the source-app's own
        // controls cover that need.
        .frame(width: 235)

        // Fixed gap so the divider sits centered between the panes
        // instead of being shoved to one side by SwiftUI's flex
        // distribution. 14pt total = 7pt left of divider + 7pt right.
        Color.clear.frame(width: 14)

        // Vertical divider between music and calendar panes.
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 0.5)
            .padding(.vertical, 4)

        Color.clear.frame(width: 14)

        // Calendar pane — fills the rest of the panel width.
        // Inner content area ≈ 498pt (530 panel - 32 padding).
        // Music 320 + 14 + 0.5 + 14 = 348.5pt, leaves 149.5pt for
        // calendar. Tight but enough for date header + 2-3 events.
        if let calendarService = AppDelegate.shared?.calendarMonitor {
            CalendarTodayPane(service: calendarService)
                .frame(maxWidth: .infinity)
                .blur(radius: presenter.cascadeReady ? 0 : 14)
                .opacity(presenter.cascadeReady ? 1 : 0)
                .offset(y: presenter.cascadeReady ? 0 : -36)
                .animation(cascadeAnimation.delay(0.10), value: presenter.cascadeReady)
        }
        }
        }   // closes the outer VStack(alignment: .leading) opened
            // above shouldShowLiveStatusRow / liveStatusRow
        // .compositingGroup() — same GPU-friendly batching as on
        // renderableContent. Preserves transport button hit testing
        // while letting Metal compose the staggered blur cascade in
        // a single pass.
        .compositingGroup()
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.md)
        // 2026-04-29: bumped bottom 6pt → 14pt so the progress
        // bar's time labels clear the panel's bottom rounded
        // corner. With 6pt the label descenders were getting
        // sliced off by the silhouette's curved bottom edge —
        // user reported "numbers are unvisible here." 14pt gives
        // the 11pt-tall labels a comfortable 3pt safe area below.
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // ── Live status row ─────────────────────────────────────
    //
    // Horizontal strip of clickable pills above the music + calendar
    // grid. Each pill is an entry point into a "drill into status"
    // detail panel. For now: just Focus. Future: Battery, Weather,
    // Wi-Fi, etc. — each adds a pill here + a case in
    // LiveExpandedPanel + a switch arm in body.
    //
    // The row is rendered only when `shouldShowLiveStatusRow` is
    // true (currently: presenter.isFocused). When all status pills
    // are inactive the row collapses entirely so the music+calendar
    // layout looks unchanged.
    private var liveStatusRow: some View {
        HStack(spacing: 8) {
            // Focus pill — split into TWO tap zones per user spec
            // (2026-05-09):
            //   • Left (icon + "Focus" label) → toggle nox Focus
            //     directly. Quick "I'm locked in" / "I'm done"
            //     without leaving the home screen.
            //   • Right (chevron) → drill into the Focus detail
            //     dashboard for stats + settings.
            // Active = nox's own Focus mode OR macOS Focus
            // (mirroring LiveFocusDetailPanel.isInFocusState) so
            // the pill lights up regardless of which path turned
            // Focus on.
            statusPill(
                label: "Focus",
                // Bolt instead of moon — keeps the lock-in motif
                // consistent across the Live status row, the
                // dashboard hero, and the controls toggle. Moon
                // implied DND/quiet (passive); bolt implies energy
                // / actively engaged (the actual Focus mood).
                systemImage: liveFocusPillActive ? "bolt.fill" : "bolt",
                isActive: liveFocusPillActive,
                onToggle: {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        // Mutex with Study — turning Focus on flips
                        // Study off so we never have two "deep work"
                        // pills lit simultaneously.
                        if !noxFocusMode {
                            noxStudyMode = false
                        }
                        noxFocusMode.toggle()
                    }
                },
                onDrillIn: {
                    withAnimation(.easeOut(duration: 0.22)) {
                        expandedLivePanel = .focus
                    }
                }
            )
            // Study pill — sits right beside Focus per user spec
            // (2026-05-09): "see the focus one? it should be just
            // beside it." Same split-action chip shape as Focus:
            // left zone toggles `noxStudyMode`, right zone drills
            // into the Study detail panel. Mutex with Focus on the
            // toggle path.
            statusPill(
                label: "Study",
                // Lightbulb instead of book — same lock-in motif
                // shift Focus got. The book glyph read as static
                // ("a book on a shelf"); lightbulb reads as
                // "actively learning right now," which is what
                // Study mode actually means in nox.
                systemImage: noxStudyMode ? "lightbulb.fill" : "lightbulb",
                isActive: noxStudyMode,
                onToggle: {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        if !noxStudyMode {
                            noxFocusMode = false
                        }
                        noxStudyMode.toggle()
                    }
                },
                onDrillIn: {
                    withAnimation(.easeOut(duration: 0.22)) {
                        expandedLivePanel = .study
                    }
                }
            )
            // Future status pills slot in here.
            Spacer(minLength: 0)
        }
    }

    /// Split-action status pill. Two tap zones share one chip
    /// background:
    ///   • LEFT  (icon + label) → `onToggle` — primary action.
    ///   • RIGHT (chevron)      → `onDrillIn` — open the detail
    ///                             dashboard for that module.
    ///                             Optional — pass nil for modules
    ///                             that don't have a detail panel
    ///                             yet (Study V1 does this) and the
    ///                             chevron + divider are omitted,
    ///                             leaving a single-zone toggle pill.
    /// A 0.5pt vertical hairline between them telegraphs that
    /// they're independent zones, while the shared rounded
    /// background keeps the whole thing reading as one chip.
    private func statusPill(label: String, systemImage: String,
                            isActive: Bool,
                            onToggle: @escaping () -> Void,
                            onDrillIn: (() -> Void)? = nil) -> some View {
        HStack(spacing: 0) {
            // Left zone — toggle.
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            isActive ? DS.Color.accent : .white.opacity(0.55)
                        )
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.92 : 0.70))
                        .kerning(0.2)
                        .lineLimit(1)
                }
                .padding(.leading, 11)
                .padding(.trailing, onDrillIn == nil ? 11 : 9)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive
                ? "Turn \(label) off"
                : "Turn \(label) on")

            if let onDrillIn = onDrillIn {
                // Hairline divider between the two zones.
                Rectangle()
                    .fill(.white.opacity(isActive ? 0.16 : 0.10))
                    .frame(width: 0.5, height: 14)

                // Right zone — drill into details.
                Button(action: onDrillIn) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white.opacity(isActive ? 0.70 : 0.50))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(label) details")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(isActive ? 0.085 : 0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            isActive
                                ? DS.Color.accent.opacity(0.30)
                                : .white.opacity(0.09),
                            lineWidth: 0.5
                        )
                )
        )
        .shadow(
            color: isActive ? DS.Color.accent.opacity(0.12) : Color.clear,
            radius: isActive ? 8 : 0,
            x: 0,
            y: isActive ? 3 : 0
        )
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }

    /// Inset card wrapping the artwork + metadata + waveform row.
    /// Gives the now-playing block a defined surface so it reads
    /// as ONE cohesive "this is what's playing" element rather
    /// than three orphans floating on the slab.
    ///
    /// Surface spec mirrors macOS Sonoma+ inset cards:
    ///   • 14pt corner radius (`DS.Radius.card`)
    ///   • 5% white fill — visible-but-quiet lift off the black
    ///     slab; never competes with the artwork's saturation
    ///   • 0.5pt hairline stroke at 7% white — defines the edge
    ///     without screaming
    ///   • 12pt internal padding so artwork + text breathe
    ///     against the card walls
    private var nowPlayingCard: some View {
        // 2026-05-04 FAKE-GLASS treatment per user feedback after
        // moving the panel background to pure black. The previous
        // setup (VisualEffectBlur + Color.black.opacity(0.30) +
        // SwiftUI .shadow(radius:14)) was costing TWO expensive
        // per-frame operations on this card:
        //   1. NSVisualEffectView Metal compositing pass (even at
        //      .withinWindow), and
        //   2. SwiftUI .shadow CPU gaussian convolution on the
        //      animating card bounds during the cascade.
        // User: "this section of the pill is making it feel like
        // it's lagging."
        //
        // Replaced with pure GPU-only treatment that achieves the
        // same "lifted card" character at near-zero cost:
        //   • Linear gradient fill (top: white 0.07, bottom: white 0.03)
        //     — gives the soft "top-lit glass" look. CALayer fill,
        //     no offscreen render, no compositing pass.
        //   • Border at white 0.10 — free (CALayer stroke).
        //   • SHADOW REMOVED — the panel already has its big drop
        //     shadow (CALayer shadowPath, GPU). A second shadow
        //     here was redundant.
        // Visually reads as "subtle elevation on the dark slab"
        // without any of the per-frame cost.
        //
        // 2026-05-06: briefly tried a hero+bloom variant (2C+9D
        // from the design-ideas grid) at the user's request, but
        // they reverted — back to this small-tile flat-glass card.
        infoRow
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.070),
                                Color.white.opacity(0.036)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }

    /// Artwork-color tint that flows FROM THE TOP and dissolves
    /// INTO THE BOTTOM. Uses the artwork itself (heavily blurred +
    /// scaled) as the color source — no need to extract a dominant
    /// color explicitly, the blur averages the artwork down to its
    /// tonal field. The vertical mask gradient (full at top → clear
    /// at bottom) is what makes it dissolve cleanly into the slab's
    /// black background by the time the eye reaches the transport
    /// row. Per the user's note: "Gradiant should come from the top
    /// and desolve into the bottom So it looks cleaner."
    ///
    /// 0.7 opacity (up from 0.45) makes the tint actually visible —
    /// the previous value was so subtle that the user reported it
    /// as not present. The mask hits zero opacity by 60% of the
    /// 240pt header height, leaving the lower 40% of the panel
    /// completely on the slab's black background for transport-
    /// button contrast.
    @ViewBuilder
    private var artworkGradientHeader: some View {
        if let data = presenter.nowPlaying?.artworkData,
           let image = NSImage(data: data) {
            // Top-only gradient header. Per the user's clarification:
            // "I said gradient comes from top (top means the top not
            // the bottom half)." Previous version masked through 85%
            // of a 240pt header, which painted the gradient through
            // the middle of the panel. New version: 140pt total
            // height, mask fully clear by 50%, so the gradient lives
            // strictly in the upper ~70pt of the panel (the area
            // around the artwork tile) and the panel below is clean
            // black.
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 140)
                .blur(radius: 50, opaque: true)
                .opacity(0.7)
                .scaleEffect(1.6)
                .frame(maxWidth: .infinity, alignment: .top)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: Color.black, location: 0.0),
                            .init(color: Color.black.opacity(0.6), location: 0.3),
                            .init(color: Color.clear, location: 0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // MARK: - Top info row
    //
    // Artwork + title/artist + waveform, all in a single horizontal
    // strip. This is the primary visual anchor of the music HUD —
    // mirrors the Alcove reference where the art tile reads as the
    // "what's playing" surface and the text reads to the right of it.
    // The waveform on the trailing edge is the same primitive the closed
    // notch pill uses, giving the two surfaces a shared "audio is
    // alive" tell.

    private var infoRow: some View {
        // Text snaps to new values directly from `presenter.nowPlaying`.
        // We tried decoupled `displayedTitle/Artist/Album` state with
        // a fade-and-slide modifier on the text block, but the user
        // reported the transport row visibly JUMPING during a Next
        // click — the modifier was the regression ("previous titling
        // wasn't causing this"). Snapping the text removes any
        // dependency between the text block's transform/opacity and
        // the layout below it, which is what the user wants.
        //
        // EMPTY → PLAYING SMOOTHING (2026-04-29): bound the labels
        // to the `displayed*` state vars (which update inside
        // `applyDisplayed`, called from `runFullArtworkSwap` at
        // the BOTTOM of the artwork tilt-out — the exact moment
        // the artwork is invisible at phase=-1). With direct
        // `info?.title` binding, the text snapped to the new value
        // at t=0 while the artwork was still at the start of its
        // 800ms tilt — a visible "text jumped, art is still
        // animating" desync the user reported as "kind of jumps to
        // the music part." Now text changes happen IN LOCKSTEP
        // with the artwork swap: both update at the swap moment,
        // both fade back in together. Critical: NO offset/transform
        // on the text block — that was the layout-reflow bug from
        // the previous decoupled attempt. Just synchronized content
        // changes, layout stays nailed.
        //
        // Empty-state fallback: when `displayedTitle` is empty
        // (nothing playing yet), show "Nothing playing" placeholder.
        // Once a track lands, this flips to the real title at the
        // synchronized swap moment.
        let displayedTitleResolved = displayedTitle.isEmpty ? "Nothing playing" : displayedTitle
        let title = displayedTitleResolved
        let artist = displayedArtist
        let album = displayedAlbum
        return HStack(alignment: .center, spacing: 14) {
            artwork
            // Tappable metadata stack — clicking any of the title/
            // artist/album labels brings the source app forward.
            // Same gesture as tapping the artwork. Reads as "click
            // anywhere on the now-playing card to jump to the
            // source." User: "When I click on it ... it should open
            // Spotify or whatever I'm using."
            Button {
                openSourceApp()
            } label: {
                // 2026-05-04 (user feedback: "writing coming from
                // right side not by blur, feels like less framerate
                // just this thing"): the text VStack now hides
                // during isMorphing and fades in after settle.
                //
                // Reason: the title/artist/album use .lineLimit(1)
                // .truncationMode(.tail). As panel.frame grows from
                // 185 → 460pt during the morph, the text container's
                // available width grows too, and SwiftUI re-evaluates
                // the truncation point on every CADisplayLink tick.
                // Characters effectively fill in from left toward
                // right as more space opens up, frame by frame —
                // that's the "writing coming from right side"
                // appearance, distinct from the smooth blur fade
                // the other cascade elements use. Looks "low
                // framerate" because truncation steps happen at
                // discrete pt boundaries (one character at a time),
                // not at sub-pixel precision like blur/opacity.
                //
                // Hiding text during morph defers the reflow until
                // panel.frame is settled. Then the text fades in at
                // its final width via opacity — same character as
                // the other cascade items, no truncation animation.
                VStack(alignment: .leading, spacing: 4) {
                    // Title — always rendered.
                    titleText(title)
                    // Artist — ALWAYS rendered (non-conditional). Empty
                    // value falls back to a single space char so the
                    // Text view still reserves its line height. This is
                    // what fixes the "transport row jumps" bug:
                    // previously this line was wrapped in
                    // `if !artist.isEmpty { ... }`, so a track with
                    // missing artist had ZERO height for this row,
                    // and any track change that flipped artist between
                    // empty and non-empty (very common with Spotify's
                    // two-stage emission — title arrives first, artist
                    // ~100-200ms later) reflowed the whole VStack.
                    // Reflow propagated through the parent VStack,
                    // bumping the progress bar / transport row down
                    // by ~22pt mid-animation. Locking the height to
                    // 3 stable lines kills the reflow.
                    // Artist line doubles as the empty-state subtitle.
                    // When nothing is playing, this slot fills with a
                    // helpful hint ("Open Spotify, Apple Music, or any
                    // audio source") instead of sitting blank — the
                    // user reported the empty state felt "empty" /
                    // unintentional. The slot retains the same line
                    // height in both states (13pt medium), so the
                    // layout is locked and the empty→playing
                    // transition is just a content swap (which fires
                    // synchronously with the artwork tilt — see the
                    // displayed* binding above).
                    artistText(
                        text: displayedTitle.isEmpty
                            ? "Open Spotify, Apple Music, or any audio source"
                            : (artist.isEmpty ? " " : artist),
                        isHint: displayedTitle.isEmpty,
                        artist: artist
                    )
                    // Album — same fix as artist. Hidden in empty
                    // state (the subtitle above already conveys the
                    // hint; a third dimmed line of placeholder text
                    // would over-load the empty card).
                    albumText(album)
                }
                // No fade or offset on the text block. Earlier this
                // had `.opacity(1.0 - abs(artworkSwapPhase))` and
                // `.offset(x: artworkSwapPhase * 4 * artworkSwapDirection)`
                // to keep text in lockstep with the artwork tilt.
                // The user reported visible JUMPS in the transport
                // row beneath the text block when these modifiers
                // were present ("previous titling wasn't causing
                // this"). Removing them lets the text snap as before
                // and isolates the swap animation to the artwork
                // tile alone — which is what the user wants.
                //
                // What we DO animate: the opacity and color of the
                // artist/album lines tied to `displayedTitle`
                // emptiness. Going empty → playing or vice versa
                // changes the hint/value, the hint dim 0.55, and the
                // artist value brightness 0.85 — easing those
                // crossfades in over ~0.35s removes the harsh snap
                // without re-introducing the layout-reflow bug
                // (no offset, no transform — just opacity/color).
                // Cap title block at 280pt so the sphere
                // visualizer sits visually adjacent to the title
                // text. With the wider 530pt slab, the previous
                // `maxWidth: .infinity` stretched the title block
                // full-width and pushed the sphere alone to the far
                // right corner — felt disconnected from the music
                // card. 280pt is comfortable for typical track
                // titles; longer ones still truncate via
                // .lineLimit(1).
                // Shrunk 280 → 200 so the inline controls cluster
                // (transport + volume) sits visually near the
                // CENTER of the card instead of pinned to the
                // right edge. With balanced Spacers around the
                // cluster, less title width = more room for the
                // Spacers to flex, which moves the cluster
                // leftward toward the geometric middle of the
                // card. Long titles still truncate via lineLimit(1).
                // 2026-05-02: was capped at 200pt to leave room for
                // the inline-controls cluster on the right. With
                // controls moved to a row below, the title block
                // briefly grew to fill the remaining width.
                // 2026-05-06: re-capped at 200pt now that the music
                // panel is split — calendar pane lives on the right
                // half. With `maxWidth: .infinity` the title block
                // stretched the now-playing card to fill the whole
                // music side (~320pt), which on the split slab read
                // as a card with a big empty right side. 200pt
                // keeps the card tight to its content while leaving
                // text truncation working via .lineLimit(1).
                .frame(maxWidth: 200, alignment: .leading)
                // .clipped() — text views inside have
                // .fixedSize(horizontal: true, vertical: false) so
                // they render at full intrinsic width regardless
                // of parent. .clipped() on this VStack clips the
                // right-side overflow at the available width
                // boundary. Net effect: text renders ONCE at full
                // width and the visible portion is determined by
                // parent clipping — no per-frame truncation
                // re-evaluation as panel.frame animates. Replaces
                // the "characters filling in from the right" with
                // "stable text revealed by clip-edge expansion."
                .clipped()
                .contentShape(Rectangle())
                // Smooth crossfade for the opacity/color changes
                // tied to empty↔playing. Doesn't animate text
                // content (atomic on macOS 13), but the surrounding
                // chrome eases — combined with the artwork tilt
                // that's running in parallel, the empty→playing
                // transition reads as one coordinated motion
                // instead of a hard snap.
                .animation(.smooth(duration: 0.35), value: displayedTitle.isEmpty)
                .animation(.smooth(duration: 0.35), value: artist.isEmpty)
                .animation(.smooth(duration: 0.35), value: album.isEmpty)
            }
            .buttonStyle(.plain)
            .help(sourceAppHelpText())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.metadataAccessibilityLabel(
                title: title, artist: artist, album: album
            ))

            // 2026-05-02 iOS-style restructure. Per the user's
            // reference screenshot (iOS lock-screen Now Playing
            // widget), transport controls move OUT of the title
            // row and BELOW the progress bar — see `transportRow`.
            // The title row is now just artwork + title VStack,
            // with the title block expanding to fill the remaining
            // width like Apple's lock-screen widget does. Volume
            // slider removed entirely; user can use system volume
            // (matches the iOS reference which has no inline
            // volume slider in the compact widget).
            Spacer(minLength: 0)
        }
    }

    /// Inline prev / play / next / volume cluster that lives in
    /// the right wing of the now-playing card. Replaces the
    /// previous bottom transport row + waveform. Two-row stack:
    ///   • Top: prev (28pt) — play (38pt) — next (28pt)
    ///   • Bottom: speaker icon + compact volume slider (90pt)
    ///
    /// Vertical layout matches the artwork tile's 76pt height so
    /// the card stays visually balanced (artwork left, controls
    /// right, both 76pt tall).
    @ViewBuilder
    private func inlineControlsCluster(accent: Color) -> some View {
        // 2026-05-01 v2 (evidence-based revert). The earlier swap to
        // `presenter.isAudioFlowing` was based on the assumption that
        // CoreAudio would drop the signal promptly when the user
        // paused in the source app. /tmp/notetaker-mra.log proved
        // otherwise — Chrome keeps its audio-helper IO procs alive
        // through pause, so isAudioFlowing stays TRUE indefinitely
        // for browser-sourced audio. The icon was therefore stuck
        // on pause.fill forever for paused YouTube. Reverting to
        // MediaRemote's isPlaying flag (or nil = paused) gives a
        // ~2s lag (waiting for MR's pause-event emit) which is
        // strictly better than infinite. For Spotify/Music both
        // signals agree.
        let isPlaying = presenter.nowPlaying?.isPlaying ?? false
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 10) {
                MusicControlButton(
                    systemImage: "backward.fill",
                    glyphSize: 12,
                    buttonSize: 28,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Previous track"
                ) { dispatch(.previous) }
                MusicControlButton(
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    glyphSize: 16,
                    buttonSize: 38,
                    isPrimary: true,
                    accent: accent,
                    accessibility: isPlaying ? "Pause" : "Play"
                ) { dispatch(.togglePlayPause) }
                MusicControlButton(
                    systemImage: "forward.fill",
                    glyphSize: 12,
                    buttonSize: 28,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Next track"
                ) { dispatch(.next) }
            }
            volumeControl
                .frame(width: 130)
        }
    }

    /// 2026-05-02 compact volume row.
    ///
    /// User feedback: full-width slider was too prominent —
    /// dominated the bottom of the music card. Pulled in to a
    /// fixed 160pt slider beside the speaker icon, centered
    /// horizontally. Reads as a quiet trim control rather than
    /// the focal element. Same underlying state binding as the
    /// original `volumeControl`. Disabled / dimmed when the
    /// source app doesn't support remote-volume AppleScript
    /// (anything other than Spotify or Music).
    private var iosStyleVolumeRow: some View {
        let bundleID = presenter.nowPlaying?.sourceBundleID
        let supported = bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: volumeIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(supported ? 0.55 : 0.25))
                .frame(width: 16, alignment: .center)
            Slider(
                value: Binding(
                    get: { sourceVolume },
                    set: { newValue in
                        sourceVolume = newValue
                        setSourceVolume(newValue)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isAdjustingVolume = editing
                }
            )
            .controlSize(.mini)
            .frame(width: 160)
            .tint(Color.white.opacity(0.75))
            .disabled(!supported)
            Spacer(minLength: 0)
        }
    }

    /// 2026-05-02 transport + inline mini-volume row.
    ///
    /// Layout (left → right):
    ///   [── balance spacer ──]  [⏪ ⏸ ⏩]  [🔊─slider]
    ///
    /// The transport cluster (prev/play/next) is the visual focal
    /// point and stays HORIZONTALLY CENTERED via a balance spacer
    /// on the left equal in width to the volume control on the
    /// right. Volume is a quiet 70pt mini-slider with a small
    /// speaker icon — reads as a trim control, not a primary
    /// element.
    private var iosStyleTransportRow: some View {
        let isPlaying = presenter.nowPlaying?.isPlaying ?? false
        let accent = ArtworkColor.dominant(from: presenter.nowPlaying?.artworkData) ?? .white

        // 2026-05-06 (rev 7): VOLUME REMOVED + just centered cluster.
        //
        // Was: [flank-spacer 65pt | spacer | prev play next | spacer
        //       | volume-cluster 65pt] — needed 65pt flanks to keep
        // the play button centered on the panel midline while the
        // volume slider sat on the right.
        //
        // With the music VStack now at 235pt (50/50 split with the
        // calendar pane), there's no room for the volume cluster
        // without squeezing the buttons off-center. Cleanest fix
        // is to drop the inline volume entirely. System volume
        // keys + the source app's own controls cover that need;
        // we'd rather have a clean centered transport than a
        // cramped one.
        //
        // New layout: Spacer | prev play next | Spacer. Cluster
        // (~166pt) centers in 235pt VStack with ~35pt of breathing
        // room on each side.
        // Live horizontal swipe progress for transport-button
        // animation. Negative = swiping LEFT (next). Positive =
        // swiping RIGHT (previous). PanelWindowController writes
        // this to the presenter on every gesture tick.
        //
        // Per-button factor: each side of the transport row picks
        // up the abs of progress IN ITS DIRECTION, clamped to 0–1.
        // The corresponding button scales up + tints with the
        // accent color in real time as the user drags. The opposite
        // button stays at rest. Same pattern Alcove uses
        // (`useAccentColorOnGestures`).
        let swipe = presenter.swipeHorizontalProgress
        let nextActive = max(0, -swipe)        // 0–1, leftward swipe magnitude
        let prevActive = max(0, swipe)         // 0–1, rightward swipe magnitude

        return HStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 22) {
                MusicControlButton(
                    systemImage: "backward.fill",
                    glyphSize: 16,
                    buttonSize: 36,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Previous track"
                ) { dispatch(.previous) }
                .scaleEffect(1 + prevActive * 0.18)
                .shadow(
                    color: accent.opacity(prevActive * 0.55),
                    radius: prevActive * 16,
                    x: 0, y: 0
                )
                .animation(
                    .spring(response: 0.28, dampingFraction: 0.72),
                    value: prevActive
                )

                MusicControlButton(
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    glyphSize: 22,
                    buttonSize: 50,
                    isPrimary: true,
                    accent: accent,
                    accessibility: isPlaying ? "Pause" : "Play"
                ) { dispatch(.togglePlayPause) }

                MusicControlButton(
                    systemImage: "forward.fill",
                    glyphSize: 16,
                    buttonSize: 36,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Next track"
                ) { dispatch(.next) }
                .scaleEffect(1 + nextActive * 0.18)
                .shadow(
                    color: accent.opacity(nextActive * 0.55),
                    radius: nextActive * 16,
                    x: 0, y: 0
                )
                .animation(
                    .spring(response: 0.28, dampingFraction: 0.72),
                    value: nextActive
                )
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Text helpers (with macOS 14+ content crossfade)
    //
    // Wraps Text views for the title/artist/album so the actual
    // string content crossfades on changes (macOS 14's
    // `.contentTransition(.opacity)`). On macOS 13 the call is a
    // no-op and the text snaps as before — but the surrounding
    // chrome (color, opacity) still eases via the `.animation`
    // modifier on the parent VStack, so the empty→playing
    // transition is much softer than the old hard snap.

    @ViewBuilder
    private func titleText(_ value: String) -> some View {
        // Plain truncating text — `lineLimit(1)` + `truncationMode(.tail)`
        // respect parent width and ellipsize cleanly.
        //
        // 2026-05-06 REGRESSION FIX: previously this used
        // `.fixedSize(horizontal: true, vertical: false)` to dodge
        // per-frame truncation re-evaluation during the panel-frame
        // morph (the "writing comes from right side" effect). The
        // tradeoff turned out catastrophic: any title longer than
        // the visible width forced the WHOLE music card to lay out
        // at the title's full intrinsic width, overflowing the
        // panel. Long YouTube video titles broke the card's
        // background, pushed artwork off-screen, and stranded the
        // transport row at the wrong width — user reported the
        // entire music UI as "looking like this and full of lags."
        //
        // The morph-time truncation jitter is a much smaller cost
        // than a broken layout for any non-trivial title, so we
        // take it. If it ever becomes visible again, the right
        // counter is to gate text opacity on `isMorphing` (hide
        // during morph, fade in after settle) — NOT fixedSize,
        // which trades morph jitter for permanent layout breakage.
        let base = Text(value)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(value)
        if #available(macOS 14.0, *) {
            base.contentTransition(.opacity)
        } else {
            base
        }
    }

    @ViewBuilder
    private func artistText(text: String, isHint: Bool, artist: String) -> some View {
        // No fixedSize — see titleText() for the regression rationale.
        let base = Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(isHint ? 0.55 : 0.85))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(artist)
            .opacity(isHint || !artist.isEmpty ? 1 : 0)
        if #available(macOS 14.0, *) {
            base.contentTransition(.opacity)
        } else {
            base
        }
    }

    @ViewBuilder
    private func albumText(_ value: String) -> some View {
        // No fixedSize — see titleText() for the regression rationale.
        let base = Text(value.isEmpty ? " " : value)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(value)
            .opacity(value.isEmpty ? 0 : 1)
        if #available(macOS 14.0, *) {
            base.contentTransition(.opacity)
        } else {
            base
        }
    }

    // MARK: - Volume control

    /// Compact horizontal slider with a state-aware speaker glyph
    /// on the leading edge. Drag dispatches the new volume to the
    /// source app via `set sound volume to N` AppleScript. While
    /// the user is dragging, the polled value (refreshed on every
    /// track change + 2s) is suppressed so the slider doesn't
    /// fight the user's input.
    @ViewBuilder
    private var volumeControl: some View {
        let bundleID = presenter.nowPlaying?.sourceBundleID
        let supported = bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
        HStack(spacing: 6) {
            Image(systemName: volumeIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(supported ? 0.65 : 0.30))
                .frame(width: 16, alignment: .center)
                // Symbol-effect replace transitions are macOS 14+.
                // We target 13.0, so the icon swap is just a hard
                // re-render on state change. Visually fine — the
                // surrounding scale + opacity already give the
                // toggle plenty of feedback.
            Slider(
                value: Binding(
                    get: { sourceVolume },
                    set: { newValue in
                        sourceVolume = newValue
                        setSourceVolume(newValue)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isAdjustingVolume = editing
                }
            )
            .controlSize(.mini)
            .frame(width: 78)
            .tint(Color.white.opacity(0.88))
            .disabled(!supported)
        }
        .help(supported
              ? "Adjust \(bundleID == "com.spotify.client" ? "Spotify" : "Apple Music") volume"
              : "Volume control supported for Spotify and Apple Music")
    }

    /// State-driven SF Symbol — slash when muted, ramps up through
    /// "wave.1" / "wave.2" as volume increases. Reads at a glance
    /// without needing to look at the slider knob.
    private var volumeIcon: String {
        if sourceVolume <= 0.001 { return "speaker.slash.fill" }
        if sourceVolume < 0.34 { return "speaker.fill" }
        if sourceVolume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    // toggleLike() and saveToSpotifyLikedSongs() removed — the
    // heart button was removed per user request because Spotify's
    // AppleScript dictionary doesn't expose a saved-tracks flag,
    // so the only Spotify path was a Cmd+S keystroke through
    // System Events that needs Accessibility permission. Without
    // that grant the heart filled but the song never actually
    // got saved ("UI lies"). With the button gone, this whole
    // branch is dead code.

    /// Push a new volume to the source app. 0-1 range gets scaled
    /// to AppleScript's 0-100 integer range.
    private func setSourceVolume(_ value: Double) {
        guard let bundleID = presenter.nowPlaying?.sourceBundleID else { return }
        let v = max(0, min(100, Int((value * 100).rounded())))
        let appName: String
        switch bundleID {
        case "com.apple.Music": appName = "Music"
        case "com.spotify.client": appName = "Spotify"
        default: return
        }
        let script = "tell application \"\(appName)\" to set sound volume to \(v)"
        runAppleScriptAsync(script)
    }

    /// Read the source app's current volume and reflect it into
    /// our @State. Called on track change so the volume slider
    /// stays accurate when the user changed Spotify / Music's
    /// volume from elsewhere while the slab was closed.
    ///
    /// Was `refreshLikedAndVolume` — the liked-state poll was
    /// removed when the heart button was removed (Spotify's
    /// AppleScript dictionary doesn't expose a saved-tracks flag,
    /// and without the heart there's no UI to drive).
    private func refreshVolume() {
        guard let bundleID = presenter.nowPlaying?.sourceBundleID else { return }
        let appName: String
        switch bundleID {
        case "com.apple.Music": appName = "Music"
        case "com.spotify.client": appName = "Spotify"
        default: return
        }

        let volScript = "tell application \"\(appName)\" to get sound volume"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            guard let scriptObj = NSAppleScript(source: volScript) else { return }
            let descriptor = scriptObj.executeAndReturnError(&error)
            if error != nil { return }
            let raw = descriptor.int32Value
            let normalized = Double(raw) / 100.0
            DispatchQueue.main.async {
                guard !isAdjustingVolume else { return }
                sourceVolume = max(0, min(1, normalized))
            }
        }
    }

    /// Background-queue dispatch wrapper for fire-and-forget
    /// AppleScript. Errors logged to the console so silent
    /// permission-denied / app-not-running cases are still
    /// diagnosable from a Console.app filter.
    private func runAppleScriptAsync(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let scriptObj = NSAppleScript(source: script) {
                _ = scriptObj.executeAndReturnError(&error)
                if let error = error {
                    NSLog("[MusicPanel] AppleScript failed: \(error)")
                }
            }
        }
    }

    /// Build a single VoiceOver phrase from the three metadata
    /// fields — empties are skipped so the user doesn't hear
    /// awkward leading commas when artist or album is missing.
    private static func metadataAccessibilityLabel(
        title: String, artist: String, album: String
    ) -> String {
        [title, artist, album]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: - Artwork

    /// Square album art at a fixed 72pt — small enough to leave room
    /// for the title/artist strip, large enough to read as the visual
    /// anchor of the row. Decoded inline because the data is already
    /// in memory (came across the MediaRemote payload). Falls back to
    /// a styled placeholder so the view still mounts cleanly when
    /// artwork hasn't arrived yet (some apps send title burst first,
    /// artwork on a follow-up notification).
    private var artwork: some View {
        Button {
            openSourceApp()
        } label: {
            // TWO-FACED CARD FLIP. 2026-05-06 rewrite per user feedback:
            // "the animation should be in between the two artworks so
            // that the flipping is from one artwork to the other. On
            // the other side of the flip, it is the second artwork."
            //
            // Previous version rotated a SINGLE image 180° and swapped
            // the image data at 89% of the rotation — so for almost
            // the entire flip, the user saw the OLD artwork rotating;
            // the new artwork only appeared in the last 2° of motion.
            // Now both faces of the card carry their own artwork:
            //   • FRONT face — `displayedArtworkImage` (the current
            //     track's art). Visible while cos(angle) > 0, i.e.
            //     0°-90° and 270°-360°.
            //   • BACK face — `nextArtworkImage` (the incoming track's
            //     art, pre-loaded by `runFullArtworkSwap`). Has an
            //     intrinsic 180° Y-rotation so when the outer rotation
            //     reaches 180° the back face's content is right-side
            //     up (180 + 180 = 360 = 0 mod 360). Visible while
            //     cos(angle) < 0, i.e. 90°-270°.
            //
            // At the 90° edge-on moment both faces read as zero-width
            // strips, so the opacity flip is invisible — the user
            // sees a continuous rotation that LOSES the old artwork
            // as the front recedes and GAINS the new artwork as the
            // back rotates into view. True card flip, no snap.
            //
            // After the spring settles the completion handler in
            // `runFullArtworkSwap` promotes nextArtworkImage →
            // displayedArtworkImage and resets artworkFlipAngle to 0
            // so the next flip starts from the same clean state.
            ZStack {
                // FRONT face — current artwork. The placeholder /
                // source-icon fallback chain is preserved so first-
                // paint and missing-art cases still work.
                Group {
                    if let image = displayedArtworkImage {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else if let icon = sourceAppIcon(),
                              !isMusicAppSource(presenter.nowPlaying?.sourceBundleID) {
                        // Source-app-icon fallback ONLY for non-music
                        // sources — WhatsApp audio, some YouTube tabs,
                        // podcasts, browser-tab audio, etc. For Spotify
                        // and Apple Music we deliberately skip this
                        // branch and show the neutral placeholder so
                        // the brief metadata-vs-artwork window doesn't
                        // flash a Spotify logo.
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(8)
                            .background(
                                LinearGradient(
                                    colors: [DS.Color.bgSubtle, DS.Color.bgHover],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else {
                        placeholderArt
                    }
                }
                .opacity(artworkFlipCosineSign > 0 ? 1 : 0)

                // BACK face — incoming artwork. Pre-rotated 180°
                // around Y so when the outer rotation passes through
                // 180° the back face content is right-side up.
                if let nextImage = nextArtworkImage {
                    Image(nsImage: nextImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .rotation3DEffect(
                            .degrees(180),
                            axis: (x: 0, y: 1, z: 0)
                        )
                        .opacity(artworkFlipCosineSign < 0 ? 1 : 0)
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            // Flatten the whole stack (both faces + border + shadow)
            // into a single rasterized layer BEFORE the rotation.
            // Without compositingGroup, SwiftUI re-rasterizes each
            // child layer per frame during the rotation — visible
            // jitter on track-change flips. With it, Core Animation
            // applies the 3D transform to one flat texture.
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // Outer Y-axis rotation drives the flip. perspective: 0.5
            // gives modest foreshortening — the right edge recedes
            // on a forward flip, left edge on a reverse, without the
            // exaggerated cinematic depth that read as too dramatic
            // for a music-card swap.
            //
            // No `scaleEffect(x: cosineSign)` here. The previous
            // version mirrored the WHOLE card at >90° to compensate
            // for the back face appearing flipped — but since each
            // face now has its own image, mirroring would also flip
            // the back face's pre-rotation, producing the wrong
            // result. The back face's intrinsic 180° rotation handles
            // its own orientation; the front face is invisible at
            // >90° so its mirroring doesn't matter.
            .rotation3DEffect(
                .degrees(artworkFlipAngle),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                anchorZ: 0,
                perspective: 0.5
            )
        }
        .buttonStyle(.plain)
        .help(sourceAppHelpText())
        .onAppear {
            // Seed displayed state from current snapshot so the
            // first track that mounts doesn't trigger a phantom
            // swap animation.
            applyDisplayed(from: presenter.nowPlaying)
            // Pull the source app's current liked + volume so the
            // heart and slider reflect reality on first paint.
            refreshVolume()
        }
        .onChange(of: presenter.nowPlaying) { newInfo in
            let newKey = newInfo.map { "\($0.title)|\($0.artist)" } ?? ""
            // Same-track artwork refresh (async artwork arrived for
            // a track whose title/artist already landed). Critical:
            // ALSO trigger a cache lookup so the decoded NSImage is
            // populated. Without this, we'd update raw data but
            // never the displayed image — exactly the "next song's
            // thumbnail not appearing" bug. Spotify regularly pushes
            // metadata in two-stage emissions: title/artist first,
            // artwork ~100-300ms later as a same-track refresh.
            if newKey == displayedTrackKey {
                displayedArtworkData = newInfo?.artworkData
                if let info = newInfo, let data = info.artworkData {
                    let key = "\(info.title)|\(info.artist)"
                    // Per BUG-012 fix: ArtworkCache.image() no longer
                    // takes an onReady closure (it was documented as
                    // never firing). Just consume the synchronous
                    // return value.
                    if let img = ArtworkCache.shared.image(data: data, key: key) {
                        displayedArtworkImage = img
                    }
                }
                return
            }
            // Real track change → run the flip. The cumulative
            // `artworkFlipAngle += 180` pattern naturally handles
            // mid-flight consecutive clicks — every track change
            // just adds another 180° to the rotation, so a fast
            // double-tap ends at 360° (back at the start) with
            // both intermediate swaps visible. No more "teleport
            // from -1 → +1" bug the old artworkSwapPhase had.
            if false {
                // (placeholder branch kept to preserve history; see
                // git for the previous swap-phase implementation)
            } else {
                // Cold change: full sequence.
                runFullArtworkSwap(newInfo: newInfo, newKey: newKey)
            }
            // New track → re-poll source-app state. Liked status
            // is per-track, so a skip can flip the heart between
            // filled and empty. Volume is global to the source so
            // it doesn't strictly need re-polling per track, but
            // doing it here is the cheapest hook we have and keeps
            // a long-lived slab in sync if the user changed Spotify
            // / Music's volume from somewhere else.
            refreshVolume()
        }
    }

    /// Snapshot the displayed text fields + artwork from a
    /// NowPlayingInfo. Called from onAppear and at the bottom of
    /// each swap so the text fades + tilts in lockstep with the
    /// artwork rather than snapping ahead of the animation.
    ///
    /// Artwork goes through `ArtworkCache` for instant return-to-
    /// recent + off-main-thread decode for fresh tracks.
    private func applyDisplayed(from info: NowPlayingInfo?) {
        displayedArtworkData = info?.artworkData
        displayedTitle = info?.title ?? ""
        displayedArtist = info?.artist ?? ""
        displayedAlbum = info?.album ?? ""
        // Resolve the decoded NSImage via the cache. Hit returns
        // synchronously; miss schedules a background decode and
        // refreshes when ready. Either way, no main-thread block
        // on `NSImage(data:)`.
        guard let info = info else {
            displayedArtworkImage = nil
            return
        }
        let key = "\(info.title)|\(info.artist)"
        // Per BUG-012 fix: ArtworkCache.image() no longer takes
        // a stale-decode-rejection closure (it never fired anyway).
        // The synchronous decode either returns the image now or
        // returns nil (which we propagate below).
        let img = ArtworkCache.shared.image(data: info.artworkData, key: key)
        // ALWAYS update displayedArtworkImage — including when img
        // is nil (cache miss, decode in flight). Setting to nil
        // here clears any stale image from a previous track so the
        // slab shows the placeholder source-app icon during the
        // decode window. Without this clear, the OLD track's
        // artwork would camp on screen while the new track's
        // metadata (title, artist, album) was already displayed —
        // exactly the "thumbnail is not changing" bug the user
        // reported. The decode-completion closure replaces this
        // nil with the decoded image once ready.
        displayedArtworkImage = img
    }

    /// Full out-and-in artwork swap. Now the only swap path —
    /// dispatch no longer kicks an eager tilt because that caused
    /// the new artwork to briefly appear at phase=-1 (tilted +
    /// faded ~9% opacity) before the spring brought it back to
    /// center, which read as a jump.
    ///
    /// Timing chosen so the data swap happens AFTER the tilt-out
    /// completes (phase fully at -1, opacity exactly 0):
    ///   • tilt-out runs 0.24s with .smooth (a hair longer than
    ///     the swap deadline below so phase has actually reached
    ///     -1 by the time we swap)
    ///   • 0.24s later: swap data at phase=-1 (opacity=0,
    ///     completely invisible — swap is imperceptible)
    ///   • spring back to phase=0 with .spring(0.45, 0.85) —
    ///     critically-damped, no overshoot
    /// X-axis scale value that compensates for the back face of the
    /// Y-axis rotation. `cos(angle) > 0` → 1.0 (front face, normal),
    /// `cos(angle) < 0` → -1.0 (back face, mirror). The exact 90°/270°
    /// boundaries pick a side based on the rotation direction sign so
    /// the transition is smooth even at the singularity.
    private var artworkFlipCosineSign: CGFloat {
        let cosine = cos(artworkFlipAngle * .pi / 180)
        if cosine > 0.001 { return 1 }
        if cosine < -0.001 { return -1 }
        // Exactly edge-on. Pick the side based on rotation direction.
        return artworkFlipAngle.truncatingRemainder(dividingBy: 360) >= 0 ? -1 : 1
    }

    private func runFullArtworkSwap(newInfo: NowPlayingInfo?, newKey: String) {
        // CRITICAL: do NOT overwrite `artworkSwapDirection` here.
        // The previous version unconditionally set it to 1 (next-
        // direction), which made the back button animate IDENTICAL
        // to next — the user reported "do reverse animation for
        // when someone do the back button." `dispatch(.previous)`
        // already set direction = -1 BEFORE this function runs;
        // overwriting clobbered that intent. If this is called
        // from natural queue advancement (no user click), direction
        // stays at its last user-set value, which is the right
        // intuition.
        // GATE THE FLIP. Per 2026-04-29 user feedback ("it's
        // rotating too much without actual thumbnail"), the
        // 180° flip is only visually meaningful when there's
        // REAL artwork on BOTH sides of the swap. Placeholder→
        // placeholder rotation looks like motion for motion's
        // sake — Apple's Music.app and the open-source flip
        // implementations (DynamicNotch, Alcove) all guard
        // against this case.
        //
        // Decision matrix:
        //   • old has art + new has art   → flip (the whole point)
        //   • old has art + new has none  → crossfade (track is
        //     loading; flipping reveals an empty placeholder which
        //     looks broken)
        //   • old has none + new has art  → crossfade (artwork
        //     just landed for an existing track)
        //   • neither has art             → snap, no animation
        //     (nothing visible would change anyway)
        let oldHasArt = displayedArtworkImage != nil
        let newHasArt = (newInfo?.artworkData?.isEmpty == false)
        let shouldFlip = oldHasArt && newHasArt

        if shouldFlip {
            // True two-faced card flip. Pre-load the incoming artwork
            // onto the BACK face BEFORE starting the rotation, so the
            // rotation reveals the actual new artwork at 90°+ rather
            // than the previous "old image rotates 178°, snap to new
            // at 89%" pattern.
            //
            // Resolve the next image synchronously from the cache
            // (decodes off main thread on a miss; we accept a brief
            // black-back-face if the decode lands mid-flip — much
            // rarer than the previous mid-flip snap).
            if let info = newInfo, let data = info.artworkData {
                let key = "\(info.title)|\(info.artist)"
                nextArtworkImage = ArtworkCache.shared.image(data: data, key: key)
            } else {
                nextArtworkImage = nil
            }

            // Run the flip. easeInOut keeps the motion symmetric
            // around 90° — the front recedes at the same rate the
            // back approaches, so the eye reads it as one continuous
            // rotation rather than two phases.
            let flipDuration: TimeInterval = 0.45
            withAnimation(.easeInOut(duration: flipDuration)) {
                artworkFlipAngle += 180
            }

            // Promote the back face to the front face AFTER the
            // rotation settles. At this moment artworkFlipAngle is
            // 180° (or a multiple) and cos(angle) is -1 — the back
            // face is currently visible. Swap displayedArtworkImage
            // to nextArtworkImage and reset artworkFlipAngle to 0
            // INSIDE the same render pass: SwiftUI batches the two
            // state changes, the now-visible back face becomes the
            // new front face, and cos(0) = +1 keeps it visible. No
            // visual flash because the image content doesn't change.
            //
            // Text fields update at the same beat so the title /
            // artist read out the new track at the moment the new
            // artwork is fully facing forward. Without this, the
            // text would update at the flip START (when SwiftUI
            // diffs presenter.nowPlaying) and snap ahead of the
            // visible artwork.
            DispatchQueue.main.asyncAfter(deadline: .now() + flipDuration) {
                applyDisplayed(from: newInfo)
                displayedTrackKey = newKey
                nextArtworkImage = nil
                artworkFlipAngle = 0
            }
        } else {
            // Quiet crossfade — no rotation. Mirrors Apple Music's
            // own mini-player swap behaviour for placeholder
            // states, and stops the "rotating too much" feel.
            withAnimation(.easeInOut(duration: 0.30)) {
                applyDisplayed(from: newInfo)
                displayedTrackKey = newKey
            }
        }
    }

    /// Pull the source app's NSImage icon by bundleID. Used as a
    /// fallback artwork when the source doesn't publish track
    /// artwork (WhatsApp audio, some browser tabs, podcasts).
    private func sourceAppIcon() -> NSImage? {
        guard let bundleID = presenter.nowPlaying?.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// True for sources that ALWAYS provide track artwork once the
    /// metadata fully lands — Spotify and Apple Music. Used to gate
    /// the source-app-icon fallback so the user doesn't see a
    /// transient "Spotify logo" flash during the brief window
    /// between a notification firing (title/artist only) and the
    /// artwork bytes arriving via iTunes Search / cache. For these
    /// sources we prefer to show the neutral music-note placeholder
    /// instead, which reads as "art still loading" rather than
    /// "art replaced with app logo."
    private func isMusicAppSource(_ bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return false }
        return bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
    }

    /// Hover help text for the artwork tile — tells the user
    /// clicking it will open the source app. Falls back to a
    /// generic label when source isn't known.
    private func sourceAppHelpText() -> String {
        if let bundleID = presenter.nowPlaying?.sourceBundleID,
           let name = Self.localizedAppName(forBundleID: bundleID) {
            return "Open \(name)"
        }
        return "Open the source app"
    }

    /// Bring the source app to the foreground. Called when the user
    /// clicks the artwork or the title/artist row — the panel acts
    /// as a remote, but click-on-info is the universal "take me
    /// where this is coming from" gesture. User: "When I click on
    /// it ... it's not opening Spotify. What I need is that when I
    /// click on that thing, it should open Spotify or whatever I'm
    /// using."
    private func openSourceApp() {
        // Route through the presenter callback (wired to
        // NotchOrchestrator.openSourceApp) so the dispatcher can
        // jump to the actual playing browser tab — not just bring
        // Chrome to whatever tab is currently active. Falls back to
        // a plain NSWorkspace open when the callback isn't wired
        // (shouldn't happen in production but useful for previews).
        if let handler = presenter.onOpenSourceApp {
            handler()
            return
        }
        guard let bundleID = presenter.nowPlaying?.sourceBundleID else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("nox: failed to open \(bundleID): \(error)")
            }
        }
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DS.Color.bgSubtle,
                    DS.Color.bgHover
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
        }
    }

    /// Gradient colors for the progress-bar fill. Leading edge is
    /// white (full energy at the play head), trailing edge picks up
    /// the dominant color from the album artwork. Falls back to
    /// pure-white gradient when no artwork is loaded.
    private var progressBarColors: [Color] {
        if let tint = ArtworkColor.dominant(from: presenter.nowPlaying?.artworkData) {
            return [Color.white, tint]
        }
        return [Color.white, Color.white.opacity(0.75)]
    }

    /// Combines artist + album when both are present, falls back to
    /// just the artist (or empty). Apple Music tends to publish both;
    /// Spotify and YouTube often only publish artist.
    private var artistLine: String {
        let info = presenter.nowPlaying
        let artist = info?.artist ?? ""
        let album = info?.album ?? ""
        if !artist.isEmpty && !album.isEmpty {
            return "\(artist) — \(album)"
        }
        return artist
    }

    // MARK: - Progress bar
    //
    // Alcove-style horizontal scrubber. We render it whenever the
    // MediaRemote payload includes both a duration and a positional
    // snapshot (Spotify and Apple Music always do; YouTube tabs in
    // Safari typically don't, and the bar collapses gracefully when
    // timing isn't available — controls and metadata still stand alone).
    //
    // Smoothness: MediaRemote only refreshes its snapshot every ~1s
    // during playback, so naïvely binding to `elapsedTime` would step
    // the bar in 1s jumps. Instead we drive a `TimelineView` that
    // re-evaluates `info.currentPosition(at:)` four times a second —
    // cheap, since the helper is just `elapsedTime + drift` arithmetic.
    // When the user pauses, `currentPosition` returns the snapshot's
    // elapsedTime as a constant, so the bar freezes in place without
    // us doing anything special.

    @ViewBuilder
    private var progressBar: some View {
        // We render the bar whenever there's a current track (info
        // present), even if duration / elapsed time aren't published
        // yet. Without timing data, the bar appears as an empty
        // track — visual continuity is more important than
        // conditional hiding (the user reported earlier that the
        // bar "is not visible at all" because some tracks took a
        // moment to publish duration, leaving an awkward gap in the
        // layout). With timing data, the bar fills in.
        if let info = presenter.nowPlaying {
            // Treat any non-finite or non-positive duration as "no
            // timing." This guards against AppleScript / MediaRemote
            // sources that occasionally publish duration: 0 or NaN
            // (e.g. live radio streams, podcast preroll) — without
            // this, `clamped / total` divides by zero and the bar
            // jumps to NaN width.
            let rawTotal = info.duration ?? 0
            let total = (rawTotal.isFinite && rawTotal > 0) ? rawTotal : 0
            let hasTiming = total > 0 && info.elapsedTime != nil
            // 2026-04-29 jitter pass: dropped tick rate 0.25s → 0.5s
            // (4 Hz → 2 Hz). The progress bar's pixel position only
            // visibly moves once per second at typical track lengths
            // (a 4-min track / 1000pt-wide bar = 0.27px/sec), so a
            // 2 Hz refresh is still smooth enough to look continuous
            // while halving the re-eval cost during music playback.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let position = hasTiming ? (info.currentPosition(at: context.date) ?? 0) : 0
                let clamped = hasTiming ? min(max(position, 0), total) : 0
                // While the user is actively scrubbing, render the
                // bar at their drag position so the UI feels locked
                // to the cursor. As soon as they release, we snap
                // back to the live `clamped` from the timeline (and
                // dispatch a real seek to the source app — see
                // `seek(toFraction:)`).
                // `total > 0` is guaranteed when hasTiming is true
                // (see the validity check above), so the division is
                // safe — but compute defensively anyway in case a
                // future refactor flips the invariant.
                let progress: Double = {
                    guard hasTiming, total > 0 else { return 0 }
                    return isScrubbing ? scrubProgress : clamped / total
                }()
                let displayed = isScrubbing ? scrubProgress * total : clamped
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let trackHeight: CGFloat = (isProgressHovering || isScrubbing) ? 6 : 4
                        ZStack(alignment: .leading) {
                            // Track: recessed pill the bar slides over.
                            // Thickens slightly on hover/scrub for
                            // tactile "I'm interactive" feedback.
                            Capsule()
                                .fill(Color.white.opacity(0.145))
                                .frame(height: trackHeight)
                            // Fill with artwork-color gradient.
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: progressBarColors,
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(
                                    width: max(2, geo.size.width * progress),
                                    height: trackHeight
                                )
                            // Scrubber thumb — visible on HOVER as
                            // well as during scrubbing. The hover
                            // visibility is the affordance: when the
                            // user mouses over the bar, the dot
                            // appears, signaling "this is grabbable."
                            // Smooth size/offset animations make the
                            // hover transition feel polished rather
                            // than popping in instantly.
                            Circle()
                                .fill(Color.white.opacity(0.98))
                                .frame(width: 10, height: 10)
                                .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 1)
                                .shadow(color: progressBarColors.last?.opacity(0.38) ?? Color.clear, radius: 5, x: 0, y: 0)
                                .offset(x: max(0, geo.size.width * progress - 5))
                                .opacity((isScrubbing || isProgressHovering) ? 1 : 0)
                                .animation(.easeOut(duration: 0.15),
                                           value: isProgressHovering)
                        }
                        .frame(height: 14, alignment: .center)
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isProgressHovering = hovering
                            }
                            // Only push the cursor when there's
                            // actually something to scrub (timing
                            // available). Pushing pointingHand on a
                            // dead bar is a lie — the click won't do
                            // anything. Pop on exit either way to
                            // avoid leaking pushed cursors if the
                            // view disappears mid-hover.
                            if hovering, hasTiming {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        // Hit area is taller than the visible track
                        // (14pt vs 4pt) so the bar is easy to grab —
                        // SwiftUI's gesture system requires a real
                        // surface to hit-test against, and a 4pt
                        // capsule is essentially impossible to land
                        // on with a trackpad. `contentShape(Rectangle)`
                        // makes the entire 14pt-tall band draggable.
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    // Don't allow scrubbing on a bar
                                    // with no timing — visual movement
                                    // would imply seekability we don't
                                    // have. Better to feel inert than
                                    // to feel broken.
                                    guard hasTiming, geo.size.width > 0 else { return }
                                    let frac = max(0, min(1, value.location.x / geo.size.width))
                                    isScrubbing = true
                                    scrubProgress = frac
                                }
                                .onEnded { value in
                                    guard hasTiming, geo.size.width > 0 else {
                                        isScrubbing = false
                                        return
                                    }
                                    let frac = max(0, min(1, value.location.x / geo.size.width))
                                    isScrubbing = false
                                    // `.alignment` haptic on release —
                                    // matches Alcove's "snap to value"
                                    // feel. Reads as the bar locking
                                    // into the new position.
                                    HapticFeedback.alignment()
                                    seek(toFraction: frac, total: total)
                                }
                        )
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(hasTiming
                            ? "\(Self.timeString(displayed)) of \(Self.timeString(total))"
                            : "Position not available")
                    }
                    .frame(height: 14)
                    if hasTiming {
                        HStack {
                            Text(Self.timeString(displayed))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Text("-\(Self.timeString(max(total - displayed, 0)))")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        // 2026-04-29: 10pt horizontal inset so the
                        // time labels don't crash into the rounded
                        // corners of the panel silhouette. The panel
                        // bottom corners curve inward — without this
                        // padding the labels sat hard against the
                        // edges and read as clipped or invisible
                        // (user: "numbers are unvisible here"). The
                        // progress bar above stays edge-to-edge for
                        // the gradient effect; only the text needs
                        // safe-area inset.
                        .padding(.horizontal, 10)
                        // Hide the time labels from VoiceOver — the
                        // bar's own accessibilityValue already
                        // announces position/total, so reading these
                        // separately is redundant chatter.
                        .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// Send a seek command to the source app. macOS's MediaRemote
    /// `MRMediaRemoteSendCommand` doesn't expose a public seek, so
    /// we route through AppleScript for the two main supported apps
    /// (Spotify and Apple Music — both implement
    /// `set player position to <seconds>`). Other sources (YouTube
    /// in a browser tab, Podcasts, third-party players) silently
    /// no-op; the bar still updates visually while the user is
    /// dragging, which is the more important feedback. Run on a
    /// background queue because `NSAppleScript.executeAndReturnError`
    /// can take 100-300ms — blocking the main thread would cause a
    /// visible UI hitch on release.
    private func seek(toFraction fraction: Double, total: TimeInterval) {
        guard let bundleID = presenter.nowPlaying?.sourceBundleID else { return }
        // Defend against `total` going non-finite at the call site
        // (the progress bar already filters but seek is callable
        // from anywhere a future caller might add).
        guard total.isFinite, total > 0, fraction.isFinite else { return }
        let appName: String
        switch bundleID {
        case "com.spotify.client": appName = "Spotify"
        case "com.apple.Music": appName = "Music"
        default: return
        }
        let target = max(0, min(total, fraction * total))

        // OPTIMISTIC LOCAL UPDATE — fire BEFORE dispatching the
        // AppleScript so the bar lands at the new position on the
        // very next render. Without this, `lastInfo.elapsedTime`
        // stays at the pre-seek value, the TimelineView keeps
        // extrapolating from there, and the bar visibly snaps
        // back to the old position until the 2.5s AppleScript
        // refresher catches up. User: "I'm clicking it and it's
        // reacting to the click, but it's not moving the bar
        // where it should move." The next authoritative refresh
        // (within 2.5s) will land within a fraction of a second
        // of `target` and there's no perceptible jump because the
        // optimistic value is already correct.
        if let last = presenter.nowPlaying {
            presenter.nowPlaying = NowPlayingInfo(
                title: last.title,
                artist: last.artist,
                album: last.album,
                artworkData: last.artworkData,
                isPlaying: last.isPlaying,
                sourceBundleID: last.sourceBundleID,
                duration: last.duration,
                elapsedTime: target,
                infoTimestamp: Date()
            )
        }

        let script = "tell application \"\(appName)\" to set player position to \(target)"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let scriptObj = NSAppleScript(source: script) {
                _ = scriptObj.executeAndReturnError(&error)
                // Log permission/app-not-running failures to the
                // console so we can diagnose silent seek issues
                // without crashing or showing a UI alert. The user
                // already gets the "scrubber didn't move" visual
                // feedback when the source ignores the seek; the
                // log gives us something actionable in postmortems.
                if let error = error {
                    NSLog("[MusicPanel] seek to \(target)s in \(appName) failed: \(error)")
                }
            }
        }
    }

    /// MM:SS formatter scoped to the panel — kept small/inline rather
    /// than promoted to a global helper, since this is the only place
    /// in the app that needs to format track time. If a second consumer
    /// shows up we'll refactor; until then, the locality keeps the
    /// reading flow tight.
    private static func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Transport controls

    /// Three buttons — prev / play-pause / next — sized identically to
    /// the previous vertical layout (44pt hit area, 18 / 26 / 18pt
    /// glyphs). Spacing is wider here than the old design because the
    /// row sits in a much shorter content area and needs to read as
    /// the focal point; clustering the three buttons closer would make
    /// the row feel cramped against the progress bar above it.
    private var transportControls: some View {
        // See `inlineControlsCluster` for the evidence-based revert
        // away from isAudioFlowing — Chrome doesn't drop CoreAudio's
        // IO-running flag on pause, so that signal is stuck-on for
        // browser audio.
        let isPlaying = presenter.nowPlaying?.isPlaying ?? false
        // Pull the artwork's dominant color and use it as the accent
        // tint on the transport-button backgrounds. Same color as
        // the timeline gradient, so the whole bottom half of the
        // panel reads as a unified chromatic accent. Falls back to
        // white so the previous monochrome look returns when no
        // artwork is available.
        let accent = ArtworkColor.dominant(from: presenter.nowPlaying?.artworkData) ?? .white
        // Symmetric 3-zone layout for the transport row: heart on
        // the LEFT edge, prev/play/next centered, volume on the
        // RIGHT edge. The two outer Spacers + .frame on each zone
        // pin the center cluster to the visual middle of the slab,
        // and the heart's left edge mirrors the slider's right
        // edge — what the user asked for when they said "this design
        // can be more symmetrical."
        return HStack(spacing: 0) {
            // LEFT zone: empty 110pt placeholder, mirrors the
            // right-zone volume slider's width so the center
            // cluster (prev/play/next) stays at the panel's true
            // visual center. Heart/like button used to live here
            // but was removed per user request — Spotify's
            // AppleScript dictionary doesn't expose the saved-
            // tracks flag, so the button required a Cmd+S
            // keystroke route that needs Accessibility permission;
            // without that grant the heart filled but the song
            // never actually got saved ("UI lies"). Removing the
            // control eliminates the broken-state UX entirely.
            Color.clear
                .frame(width: 110, height: 1)
            Spacer(minLength: 0)
            // CENTER zone: the three transport buttons. Same
            // glyph sizes, same spacing, same haptic dispatch
            // as before — only the wrapping HStack moved.
            HStack(spacing: 24) {
                MusicControlButton(
                    systemImage: "backward.fill",
                    glyphSize: 16,
                    buttonSize: 38,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Previous track"
                ) {
                    dispatch(.previous)
                }
                MusicControlButton(
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    glyphSize: 22,
                    buttonSize: 50,
                    isPrimary: true,
                    accent: accent,
                    accessibility: isPlaying ? "Pause" : "Play"
                ) {
                    dispatch(.togglePlayPause)
                }
                MusicControlButton(
                    systemImage: "forward.fill",
                    glyphSize: 16,
                    buttonSize: 38,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Next track"
                ) {
                    dispatch(.next)
                }
            }
            Spacer(minLength: 0)
            // RIGHT zone: volume control. Width matches the LEFT
            // zone exactly so the middle cluster lands on the
            // panel's centerline.
            volumeControl
                .frame(width: 110, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    /// Debounced wrapper around `presenter.onMediaCommand` — drops
    /// any command that lands within 150ms of the previous one. This
    /// prevents a stack of queued commands from rapid taps overshooting
    /// the user's intent (e.g. mashing Next four times when they meant
    /// "skip forward one track but the source app was slow"). Toggle
    /// play/pause is the most visible failure mode of un-debounced
    /// dispatch — without this, a double-tap can land as
    /// pause-then-play on Spotify while Apple Music swallows the
    /// second command, leaving the two sources out of sync visually.
    private func dispatch(_ command: MediaRemoteService.Command) {
        let now = Date()
        if now.timeIntervalSince(lastCommandAt) < 0.15 { return }
        lastCommandAt = now
        // `.generic` is the lightest of the three NSHapticFeedback
        // patterns — a quiet "tick" that confirms the button
        // registered. Stronger patterns on a transport button get
        // tiring across a session. The 150ms debounce above also
        // serves as a haptic anti-spam guard, mirroring Alcove's
        // `hasRecentlyTriggeredHaptic` flag pattern.
        HapticFeedback.generic()

        // No eager tilt-out. Earlier this kicked off a tilt
        // animation IMMEDIATELY on click so the response felt
        // zero-latency, but the swap point at the bottom of the
        // tilt (where displayed data updates) caused visible
        // glitches — the new artwork would briefly appear at
        // phase=-1 (rotated + faded) before the spring brought
        // it back to center, which read as a jump/flicker on the
        // user's screen. Now: dispatch only sends the command;
        // the full swap animation runs once when nowPlaying
        // actually changes (handled in the `.onChange(of:)` of
        // the artwork view via `runFullArtworkSwap`). Trade-off:
        // ~200-400ms of "nothing happens visually" between click
        // and animation start, but no glitch — which is what the
        // user prioritized.
        switch command {
        case .next:
            artworkSwapDirection = 1
        case .previous:
            artworkSwapDirection = -1
        default:
            break
        }

        presenter.onMediaCommand?(command)
    }

    // MARK: - Source badge
    //
    // Tiny "playing in <App>" credit underneath the controls — helps
    // the user orient when multiple media apps are open simultaneously
    // (Spotify in the background, Safari with a YouTube tab in front,
    // etc.); the source bundle is the only reliable signal for which
    // app a play/pause command will land on. Smaller and more recessed
    // here than in the previous layout because the compact HUD doesn't
    // have the room — kept anyway because removing it makes the multi-
    // source case opaque.

    @ViewBuilder
    private var sourceBadge: some View {
        if let info = presenter.nowPlaying,
           let bundleID = info.sourceBundleID,
           let appName = Self.localizedAppName(forBundleID: bundleID) {
            HStack(spacing: 6) {
                // Speaker glyph — gives the badge a visual hook so
                // it reads as "audio source" at a glance, rather
                // than a generic line of text floating below the
                // controls. Sized to match the label cap-height.
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text("Playing in \(appName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // Pill background — subtle white overlay that lifts the
            // badge off the slab surface and reads as a discrete
            // chip. Without this the text floated formless below the
            // transport row.
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
        }
    }

    private static func localizedAppName(forBundleID bundleID: String) -> String? {
        // Hard-coded canonical names for the apps we know about take
        // precedence over the bundle's `CFBundleDisplayName`. Some
        // apps publish Display values like "Spotify Free" or
        // "Apple Music" that read awkwardly in the badge ("Playing
        // in Apple Music" reads weirdly when the app is just the
        // built-in Music). The canonical map keeps the badge tight.
        if let canonical = canonicalShortName(forBundleID: bundleID) {
            return canonical
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return shortName(forBundleID: bundleID)
        }
        let bundle = Bundle(url: url)
        let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return display ?? name ?? shortName(forBundleID: bundleID)
    }

    /// Curated short names for the apps we care about. Returning
    /// nil means "fall through to `urlForApplication` / `shortName`."
    private static func canonicalShortName(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Music":            return "Music"
        case "com.spotify.client":         return "Spotify"
        case "com.apple.podcasts":         return "Podcasts"
        case "com.apple.TV":               return "TV"
        case "com.apple.Safari":           return "Safari"
        case "com.google.Chrome":          return "Chrome"
        case "com.google.Chrome.canary":   return "Chrome Canary"
        case "company.thebrowser.Browser": return "Arc"
        case "com.brave.Browser":          return "Brave"
        case "org.mozilla.firefox":        return "Firefox"
        case "com.microsoft.edgemac":      return "Edge"
        default: return nil
        }
    }

    /// Best-effort fallback when we can't resolve a real Bundle —
    /// e.g. unknown bundles or running in a sandbox where
    /// `urlForApplication` returns nil.
    private static func shortName(forBundleID bundleID: String) -> String? {
        if let canonical = canonicalShortName(forBundleID: bundleID) {
            return canonical
        }
        // Strip the reverse-DNS prefix, capitalize the last segment
        // so "com.example.MyPlayer" → "MyPlayer".
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last
    }
}

/// Extracted into its own struct so the per-button @State (hover) is
/// scoped correctly — a single shared @State on MusicPanelView would
/// flicker every button at once on cursor entry.
/// SF Symbol contentTransition with macOS 13 fallback. macOS 14+ uses
/// the polished `symbolEffect(.replace)` (fade + scale + crossfade);
/// macOS 13 uses plain `.opacity` contentTransition.
private struct SymbolReplaceTransition: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content.contentTransition(.opacity)
        }
    }
}

private struct MusicControlButton: View {
    let systemImage: String
    let glyphSize: CGFloat
    let buttonSize: CGFloat
    let isPrimary: Bool
    /// Artwork-extracted accent color. Used to tint the button's
    /// background fill so the transport row picks up the same
    /// chromatic identity as the timeline gradient and waveform.
    let accent: Color
    let accessibility: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background fill: primary buttons get an artwork-
                // tinted gradient (white → accent) — same color
                // language as the timeline, so the whole transport
                // row feels chromatically connected to the playing
                // track. Secondary buttons (prev/next) fade in a
                // subtle accent-tinted hover background only on
                // cursor entry.
                if isPrimary {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isPressed ? 0.26 : isHovered ? 0.21 : 0.17),
                                    accent.opacity(isPressed ? 0.42 : isHovered ? 0.34 : 0.28),
                                    Color.black.opacity(0.24)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                        )
                        .shadow(color: accent.opacity(isHovered ? 0.24 : 0.14), radius: isHovered ? 10 : 6)
                } else {
                    // Resting state for prev/next: subtle white
                    // halo at 6% opacity so the buttons read as
                    // buttons even before hover. On hover/press
                    // the halo brightens AND picks up the artwork
                    // accent tint — same chromatic language as
                    // the play button. Per user feedback that the
                    // transport row felt "flat / not Apple-grade":
                    // visible-at-rest backgrounds are how Apple
                    // Music's macOS small player and Sonoma+
                    // Settings rows distinguish controls from
                    // chrome.
                    Circle()
                        .fill(
                            isPressed
                                ? accent.opacity(0.22)
                                : isHovered
                                    ? Color.white.opacity(0.095)
                                    : Color.white.opacity(0.060)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(isHovered ? 0.11 : 0.065), lineWidth: 0.5)
                        )
                }

                Image(systemName: systemImage)
                    .font(.system(size: glyphSize, weight: isPrimary ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(isPrimary ? 1.0 : 0.85))
                    // SF Symbol smooth swap (e.g. play.fill ↔ pause.fill).
                    // Without this, the icon hard-cuts when toggling play
                    // state. macOS 14+ uses .symbolEffect(.replace) for
                    // the fade+scale; macOS 13 falls back to .opacity
                    // contentTransition (still smooth, just less polished).
                    .modifier(SymbolReplaceTransition())
                    // Tiny scale spring on press for tactile feedback —
                    // 8% squeeze on press, bouncy snap back on release.
                    .scaleEffect(isPressed ? 0.92 : 1.0)
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.08)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    // Bouncy release — the button "pops" back from
                    // the pressed state with a slight overshoot,
                    // giving the press a tactile rebound. Lower
                    // damping than the default spring so the bounce
                    // is visible. Keeps the press DOWN sharp
                    // (easeOut) and only adds spring on release.
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                        isPressed = false
                    }
                }
        )
    }
}

// MARK: - Live → Focus detail panel

/// What opens when the user taps the Focus pill in the Live tab's
/// status row. Translates layout option E from
/// `docs/focus-card-in-live.html` into SwiftUI.
///
/// Sections shipped in v1 (everything else from the mockup is
/// gated on data we don't have yet):
///   • Hero — moon icon + "Focus mode" title + "On" / "Off" state
///   • Behavior — the existing `respectFocusMode` toggle, surfaced
///     here so the user can flip it without leaving the Live tab
///   • Currently muted — static list of pill types we suppress
///     while Focus is on, derived from PanelPresenter.isMutedByFocus
///   • Allowed through — the inverse: pill types that pass the
///     gate even during Focus
///
/// Deliberately deferred for v1 (would need data we can't read
/// from INFocusStatusCenter): active Focus name (Personal / Work),
/// timestamp Focus turned on, voice-transcription suppression
/// toggle.

/// Single day cell in the redesigned hero card's 7-day ring strip.
/// Composes a label + a ring (filled proportional to progress) +
/// the day's minute count. Shared between the Focus and Study
/// dashboards — the only difference is the accent color and glyph
/// passed in by the parent.
///
/// Visual states:
///   • progress >= 1 → ring fully filled with `accent` at full
///     opacity, glyph + time both colored. Reads as "goal hit."
///   • 0 < progress < 1 → ring partially filled with `accent` at
///     50% opacity, glyph dimmed. Reads as "in progress / missed."
///   • progress == 0 → ring is just the muted track, glyph at low
///     opacity. Reads as "no activity."
///   • isToday → label gets a pill border + brighter text. Today is
///     always the rightmost cell so the eye lands there naturally.
/// Stepper button that supports macOS-style press-and-hold ramping.
/// Single tap fires `apply(1)` — increments cleanly through 1, 2,
/// 3, 4, 5… so the user can dial in an exact value. Press-and-hold
/// kicks in after a 350 ms grace period: starts auto-firing
/// `apply(5)` every 80 ms so the value scrubs quickly through long
/// distances without endless tapping. Release at any point cancels.
///
/// User report 2026-05-09: "Timer is not counting from 1-2-3-4-5,
/// it's counting from 1-6-11 like this. So can we do it like when
/// a user is pressing on this continuously it can go quick like 5
/// at a time but when user is only clicking it will grow number by
/// 1?" — exactly this two-mode behavior.
private struct PressAndHoldStepper: View {
    let systemImage: String
    /// Caller does the math + clamping. Receives a positive
    /// magnitude (1 for tap, 5 for held-repeat); apply the sign
    /// inside the closure for minus vs plus.
    let apply: (Int) -> Void

    @State private var isPressed = false
    @State private var didFireTap = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white.opacity(isPressed ? 1.0 : 0.78))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.10), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        didFireTap = true
                        // Initial tap fires +1 immediately so a
                        // single click feels responsive.
                        apply(1)
                        // After a short grace period, escalate to
                        // fast-repeat mode firing +5 every 80 ms.
                        // 350 ms is the sweet spot — long enough
                        // that an intentional tap doesn't trigger
                        // the ramp, short enough that holding
                        // doesn't feel sluggish.
                        repeatTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            while !Task.isCancelled {
                                apply(5)
                                try? await Task.sleep(nanoseconds: 80_000_000)
                            }
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        didFireTap = false
                        repeatTask?.cancel()
                        repeatTask = nil
                    }
            )
    }
}

private struct GoalRingDay: View {
    let label: String
    let minutes: Int
    let progress: Double
    let isToday: Bool
    let accent: Color
    let glyph: String

    private var hit: Bool { progress >= 1.0 }
    private var hasActivity: Bool { progress > 0 }

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: isToday ? .semibold : .medium))
                .foregroundStyle(isToday ? .white : .white.opacity(0.55))
                // 2026-05-09: lineLimit(1) + tightened horizontal
                // padding (6 → 3). The goal hero card column gets
                // ~38–42pt per day at the current panel width;
                // 3-letter labels like "Mon" / "Wed" used to wrap
                // onto two lines ("Mo / n", "We / d") with the
                // looser 6pt padding. Hard cap to one line ensures
                // they never break.
                //
                // 2026-05-09 perf: `minimumScaleFactor(0.85)` and
                // `fixedSize` were dropped after the user reported
                // dashboard-open lag. `minimumScaleFactor` triggers
                // SwiftUI to attempt MULTIPLE layout passes per
                // label trying to find a size that fits — for 7
                // GoalRingDay instances during the open animation's
                // repeated layout, that's a measurable perf hit.
                // The 3pt padding alone gives enough headroom that
                // day labels never overflow; the scale-factor
                // belt-and-suspenders is no longer needed.
                .lineLimit(1)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    isToday
                    ? AnyView(
                        Capsule()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                            .background(Capsule().fill(.white.opacity(0.04)))
                    )
                    : AnyView(EmptyView())
                )

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.10), lineWidth: 2.2)
                Circle()
                    .trim(from: 0, to: max(0.001, progress))
                    .stroke(
                        accent.opacity(hit ? 1.0 : (hasActivity ? 0.55 : 0.0)),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: glyph)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(
                        accent.opacity(hit ? 1.0 : (hasActivity ? 0.55 : 0.40))
                    )
            }
            .frame(width: 26, height: 26)

            Text(timeLabel)
                .font(.system(size: 9.5, weight: hit ? .semibold : .medium))
                .foregroundStyle(timeColor)
                .monospacedDigit()
        }
    }

    private var timeColor: Color {
        if isToday { return accent }
        if hit { return .white }
        if hasActivity { return .white.opacity(0.55) }
        return .white.opacity(0.30)
    }

    private var timeLabel: String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

struct LiveFocusDetailPanel: View {
    @EnvironmentObject var presenter: PanelPresenter
    @AppStorage(SettingsKey.respectFocusMode) private var respectFocusMode: Bool = true
    /// Closure invoked when the user taps the "‹ Live" back arrow
    /// at the top. MusicPanelView passes a closure that clears its
    /// `expandedLivePanel` state.
    let onBack: () -> Void

    /// Cascade entrance curve — same one `MusicPanelView` uses for
    /// its `liveHomeView` content. Snappy with a touch of bounce
    /// on macOS 14+, interpolating spring fallback on older OSes.
    /// Used by the cascade gate in `body` to fade dashboard content
    /// in AFTER the panel's open spring has settled.
    private var cascadeAnimation: Animation {
        if #available(macOS 14.0, *) {
            return .snappy(duration: 0.32, extraBounce: 0.15)
        } else {
            return .interpolatingSpring(mass: 1.0, stiffness: 350, damping: 22)
        }
    }

    @ObservedObject private var tracker = FocusSessionTracker.shared
    /// Pomodoro-style countdown timer for the active Focus session.
    /// Drives the timer card between the hero and the stats grid —
    /// idle state shows duration chips, running state shows the
    /// big countdown + pause/stop, paused state freezes it,
    /// expired state celebrates and offers "start another" chips.
    @ObservedObject private var focusTimer = FocusTimerService.shared

    /// True while the Focus-on-idle hero is showing the custom-
    /// duration editor (— / + steppers + minute field) instead of
    /// the four-preset chip strip. Tapping the trailing "+" chip
    /// flips this on; tapping × in the editor flips it off.
    @State private var customTimerExpanded: Bool = false

    /// User-entered custom duration in minutes. Defaults to 30
    /// (a common pomodoro variant past the standard 25). Clamped
    /// to 1...300 on commit so the user can't accidentally start
    /// an hours-long timer with a typo.
    @State private var customTimerMinutes: Int = 30

    /// nox's own quiet-mode flag. Independent of macOS Focus —
    /// flipping this from the panel suppresses ambient pills
    /// (charger / screenshot / AirDrop / Bluetooth / track-change)
    /// without depending on Apple's Focus mode being active.
    /// User feedback 2026-05-08: "Let's do it in our own instade
    /// of apple" — exactly this. The dashboard hero, session
    /// timer, and stats are now driven by the COMBINED state
    /// (nox quiet OR macOS Focus with respect-Focus on), but
    /// the primary toggle on this card flips this flag directly.
    @AppStorage(SettingsKey.noxFocusMode) private var noxFocusMode: Bool = false

    var body: some View {
        // 2026-05-08 redesign: replaced the static "moon hero +
        // grouped controls" layout with the live-session
        // dashboard chosen from the HTML mockup review (variant
        // A). Hero shows a running HH:MM session timer; two stat
        // tiles show "pills muted this session" (with type
        // breakdown chips) + a 60-min sparkline; toggles tucked
        // at the bottom. Every visible piece binds to data that
        // `FocusSessionTracker` actually emits, so this is a
        // truthful "what is Focus doing for me right now" view.
        //
        // 2026-05-09 redesign: the panel is back to **3 cards**
        // (hero / stats / controls). The timer (Pomodoro chips +
        // countdown ring + pause/stop) is now part of the hero
        // card itself — it morphs through Focus-off → Focus-on
        // → Timer-running → Timer-expired states. Adding a fourth
        // standalone timerCard row was the wrong call — it
        // competed with the hero for attention and stretched the
        // panel vertically with no real benefit.
        //
        // Outer spacing 8pt — back to the pre-timer rhythm now
        // that we're not packing in a fourth row.
        // 2026-05-09 redesign — RiseUp-inspired single composed card
        // for the goal hero, plus a dedicated Pomodoro timer strip
        // below it (preset chips → countdown ring when running),
        // plus a single-row controls strip at the bottom.
        // Mockup: docs/focus-redesign-riseup.html.
        // 2026-05-09 layout — two-column composition. Goal hero card
        // takes the left ~60%, timer + controls stack on the right
        // ~40%. User direction: "focus the whole thing can be a bit
        // more smaller so right side have place and in that place we
        // can put timer section horizontally — and underit the rest."
        // Saves vertical room (no third stacked card) so the panel
        // fits comfortably in the regular Live slab without growing.
        VStack(alignment: .leading, spacing: 6) {
            backRow
            // 2026-05-11 LAZY MOUNT (upgrade from the earlier
            // opacity-only cascade gate). Earlier round wrapped
            // the dashboard in `.opacity(presenter.cascadeReady
            // ? 1 : 0)` — that hid pixels but DIDN'T defer cost:
            // the view tree still mounted on panel show, SwiftUI
            // still computed layouts for FocusWorkingHero +
            // 7 GoalRingDay rings + timer strip, and the inner
            // 30Hz TimelineView in FocusWorkingHero still ticked
            // from the very first frame of the open spring.
            // Result: open animation still felt laggy.
            //
            // Now using `if presenter.cascadeReady` — until the
            // flag flips (~30ms after show() starts), this branch
            // returns nothing, so nox doesn't instantiate the
            // dashboard subtree at all. No layout work, no
            // TimelineView ticking, no per-frame cost — the
            // panel.frame spring has the main thread to itself
            // through its steepest acceleration phase.
            //
            // When cascadeReady flips true, the content mounts
            // with a single combined transition (opacity +
            // upward slide + slight blur fade) that matches what
            // the old opacity-only gate looked like, so the
            // entrance still feels like a cascade rather than a
            // jarring pop-in.
            if presenter.cascadeReady {
                HStack(alignment: .top, spacing: 8) {
                    goalHeroCard
                        .layoutPriority(2)
                    VStack(spacing: 6) {
                        timerStrip
                        controlsStrip
                        Spacer(minLength: 0)
                    }
                    // 2026-05-09 width fix: 180 → 220. Old width
                    // forced the timer chip row to wrap. 220pt
                    // fits the full row.
                    .frame(width: 220)
                }
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .offset(y: -16))
                        .animation(cascadeAnimation),
                    removal: .opacity
                ))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Pomodoro timer strip — sits in the right column above the
    /// controls strip. Three
    /// states driven by `focusTimer.state`:
    ///   • idle → preset chips (15 / 25 / 45 / 90 min) + custom-
    ///     duration "+" button. Tap a chip to start a Pomodoro at
    ///     that length; tap "+" to expand into a stepper editor.
    ///   • running / paused → compact countdown row (mini ring +
    ///     remaining time + pause/resume + stop).
    ///   • expired → restart prompt + Done.
    /// Reuses the existing `customTimerExpanded`, `commitCustomTimer`,
    /// `durationChip`, `customTimerEditor`, and `focusTimer.*`
    /// helpers that were previously embedded inside the hero card.
    @ViewBuilder
    private var timerStrip: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            timerStripContent(now: context.date)
        }
    }

    @ViewBuilder
    private func timerStripContent(now: Date) -> some View {
        let state = focusTimer.state
        Group {
            switch state {
            case .idle:
                timerIdleRow
            case .running, .paused:
                timerRunningRow(now: now, paused: state == .paused)
            case .expired:
                timerExpiredRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: state)
    }

    /// Idle state — chip strip wrapped to 2 rows for the narrow
    /// right column. Top row: label + 15/25 chips. Bottom row:
    /// 45/90 chips + custom `+` button. When the user taps `+` the
    /// whole strip morphs to the custom-duration editor.
    private var timerIdleRow: some View {
        if customTimerExpanded {
            AnyView(customTimerEditor)
        } else {
            AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(DS.Color.accent.opacity(0.85))
                        Text("Timer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer(minLength: 0)
                        durationChip(minutes: 15)
                        durationChip(minutes: 25)
                    }
                    HStack(spacing: 5) {
                        Spacer(minLength: 0)
                        durationChip(minutes: 45)
                        durationChip(minutes: 90)
                        customExpandChip
                    }
                }
            )
        }
    }

    /// Running / paused state — compact countdown row. Smaller than
    /// the original hero version (32pt ring vs 56pt) so it fits in
    /// a single strip without competing with the goal card above.
    private func timerRunningRow(now: Date, paused: Bool) -> some View {
        let remaining = focusTimer.remaining(now: now)
        let progress = focusTimer.progress(now: now)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        DS.Color.accent.opacity(paused ? 0.45 : 0.95),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
                Image(systemName: paused ? "pause.fill" : "timer")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(paused ? .white.opacity(0.55) : DS.Color.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(paused ? "PAUSED" : "FOCUS ON")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(paused ? .yellow.opacity(0.85) : DS.Color.accent)
                Text(formatCountdown(remaining))
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(paused ? .white.opacity(0.55) : .white)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                if paused { focusTimer.resume() }
                else { focusTimer.pause() }
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(DS.Color.accent.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(paused ? "Resume timer" : "Pause timer")

            Button {
                focusTimer.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop timer")
        }
    }

    /// Expired state — celebration + ack. Tapping the chip resets
    /// the timer to .idle and the strip flips back to the chip row
    /// so the user can start another.
    private var timerExpiredRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.Color.accent)
            Text("Session done")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button {
                focusTimer.acknowledge()
            } label: {
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Color.accent.opacity(0.45)))
            }
            .buttonStyle(.plain)
        }
    }

    /// Opens System Settings → Focus pane via the public URL scheme.
    /// This is the only HONEST way to drive macOS Focus from a
    /// third-party app — Apple doesn't expose a programmatic toggle,
    /// `INFocusStatusCenter` is read-only, and the private
    /// `DoNotDisturbKit.framework` is sealed behind stripped binaries
    /// on macOS 26 (verified — the symbols Apple used historically
    /// like `setMode:` are no longer reachable via dlopen).
    ///
    /// Earlier iterations tried UI-scripting Control Centre via
    /// AppleScript and AXIdentifier walks. Functional on the test
    /// machine, but unacceptable in practice because:
    ///   • Opening Control Centre takes over the user's screen,
    ///     which the user explicitly called out as disruptive.
    ///   • Control Centre stealing focus dismissed the nox panel
    ///     mid-tap, so the toggle felt broken.
    ///   • Across locales / future macOS revisions, the AX
    ///     identifiers shift and the script breaks silently.
    private func openFocusSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private var backRow: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Live")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(DS.Color.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Live")
    }

    // MARK: - Goal hero card (RiseUp redesign)

    /// User-configurable daily Focus goal. Default 60 min — stored
    /// in `SettingsKey.dailyFocusGoalMinutes`. Tappable from the
    /// "Daily goal" controls row to change. Drives the per-day
    /// rings (each fills `dayMinutes / goal`) and the "X of 7
    /// goals completed" subtext.
    @AppStorage(SettingsKey.dailyFocusGoalMinutes) private var dailyFocusGoal: Int = 60

    /// Single composed hero card holding the goal headline, weekly
    /// progress, the 7-day ring strip, and aggregate footer. One
    /// card → one focal point, vs the old four-card stack that had
    /// the user's eye bouncing between disconnected stat tiles.
    private var goalHeroCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            goalHeroContent(now: context.date)
        }
    }

    @ViewBuilder
    private func goalHeroContent(now: Date) -> some View {
        let goal = max(5, dailyFocusGoal)
        // 2026-05-09 perf: compute the 7-day data ONCE, derive
        // every aggregate from it. Previously the body called
        // `goalsCompletedThisWeek` (internally loops 7 ×
        // dayMinutes), `totalMinutesThisWeek` (loops 7 more
        // times), AND the `ForEach` loop (7 more dayMinutes calls
        // + 7 dayLabel calls). Per-body-eval cost: 21+ tracker
        // calls + 7 DateFormatter operations. Multiplied by the
        // open animation's repeated body evals = noticeable lag
        // on dashboard open. Now: 7 dayMinutes calls + 7 dayLabel
        // calls, derived aggregates are O(1).
        let perDay: [(minutes: Int, label: String)] = (0..<7).map { i in
            let daysAgo = 6 - i
            let mins = tracker.dayMinutes(daysAgo: daysAgo, now: now)
            let label = dayLabel(daysAgo: daysAgo, now: now)
            return (mins, label)
        }
        let goalsHit = perDay.reduce(0) { $0 + ($1.minutes >= goal ? 1 : 0) }
        let goalsPct = Int((Double(goalsHit) / 7.0 * 100).rounded())
        let weekTotal = perDay.reduce(0) { $0 + $1.minutes }
        let weekAvg = weekTotal / 7
        // Avg-vs-goal ratio for the footer ring artwork. Caps at 1
        // so a power week doesn't render an overflowed ring.
        let avgVsGoal = min(1.0, Double(weekAvg) / Double(goal))

        VStack(alignment: .leading, spacing: 0) {
            // ── Header: icon + goal copy + weekly progress ────────
            HStack(alignment: .top, spacing: 12) {
                // 2026-05-09 icon swap: was a static moon SF Symbol
                // ("Focus" mode used to read as "quiet/sleep" via
                // moon iconography). User feedback on the redesign:
                // "since it's for lock in, why does the logo look
                // like this?" Reusing the existing animated
                // `FocusWorkingHero` (anime character at a laptop,
                // head bob + typing motion) — already on-brand for
                // the "locked in / actively focused" state. Animation
                // pauses + dims when Focus is OFF.
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DS.Color.accent.opacity(isInFocusState ? 0.22 : 0.14))
                    FocusWorkingHero(active: isInFocusState)
                        .frame(width: 26, height: 26)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus at least \(goal) min today")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        Text("\(goalsHit) of 7 goals")
                            .foregroundStyle(.white)
                            .fontWeight(.semibold)
                        Text(" this week (\(goalsPct)%)")
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .font(.system(size: 10.5))
                }

                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.bottom, 6)

            // ── 7-day ring strip ─────────────────────────────────
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    let isToday = i == 6
                    let day = perDay[i]
                    let progress = min(1.0, Double(day.minutes) / Double(goal))
                    GoalRingDay(
                        label: day.label,
                        minutes: day.minutes,
                        progress: progress,
                        isToday: isToday,
                        accent: DS.Color.accent,
                        // Bolt = "energy / locked in" feel. Moon
                        // read as "DND / quiet" which conflicted
                        // with Focus's actual intent (deep work,
                        // user is actively engaged). Bolt also
                        // intensifies as the ring fills — reads as
                        // "this day's session was charged."
                        glyph: "bolt.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            // ── Footer: total / avg / hero ring ──────────────────
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.top, 6)
                .padding(.bottom, 6)

            HStack(spacing: 10) {
                footerStat(big: formatMinutesShort(weekTotal), small: "Total this week")
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 0.5, height: 26)
                footerStat(big: formatMinutesShort(weekAvg), small: "Avg daily")
                Spacer(minLength: 4)
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.10), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: avgVsGoal)
                        .stroke(DS.Color.accent,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.accent)
                }
                .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DS.Color.accent.opacity(isInFocusState ? 0.16 : 0.08),
                            DS.Color.accent.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    DS.Color.accent.opacity(isInFocusState ? 0.26 : 0.10),
                    lineWidth: 0.6
                )
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.78),
                   value: isInFocusState)
    }

    /// Compact "Total / Avg" cell used in the hero footer.
    private func footerStat(big: String, small: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(big)
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(small)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    /// Three-letter day-of-week label ("Sun", "Mon", ...) for a
    /// given offset from `now`. Uses the user's current calendar so
    /// the week boundary respects locale settings.
    ///
    /// **Perf:** uses a cached static formatter. The earlier
    /// implementation allocated a fresh `DateFormatter` per call,
    /// and the dashboard calls this 7 times per body eval —
    /// `DateFormatter()` is one of the slowest things to allocate
    /// in Swift (~2-5ms each, locale + calendar setup + format
    /// parse). User reported the dashboard's open animation was
    /// laggy; the 7×N formatter allocations during the open
    /// transition's repeated layout passes were a major chunk of
    /// the lag budget. Static formatter = one alloc for the app's
    /// lifetime, sub-microsecond per call after that.
    private func dayLabel(daysAgo: Int, now: Date) -> String {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .day, value: -daysAgo, to: now) else {
            return ""
        }
        return Self.weekdayFormatter.string(from: d)
    }

    /// Shared `EEE` formatter — see `dayLabel(daysAgo:now:)` for
    /// rationale.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.calendar = Calendar.current
        f.locale = Locale.current
        return f
    }()

    /// Compact human-readable minutes — "53m", "2h 5m", "12h 4m".
    /// Used in both the per-day time labels and the footer
    /// aggregates so the visual rhythm stays consistent.
    private func formatMinutesShort(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// Slim utility strip below the hero card — Focus mode toggle +
    /// daily-goal stepper. Drops the previous full-height controls
    /// card; toggles read as utility now, not main content.
    /// Two-row controls strip sized for the narrow right column.
    /// Row 1: Focus mode toggle (icon + label + switch). Row 2:
    /// Daily-goal pill that cycles through preset minutes on tap.
    /// Cycling through 15/30/60/90/120 updates the per-day rings
    /// in real-time.
    private var controlsStrip: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                    noxFocusMode.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    // Bolt instead of moon — same lock-in motif
                    // shift the ring glyphs got. The toggle reads
                    // as "energy on / energy off" now, which is
                    // the correct Focus mood vs. moon's "DND" feel.
                    Image(systemName: isInFocusState ? "bolt.fill" : "bolt")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isInFocusState
                                         ? DS.Color.accent
                                         : Color.white.opacity(0.55))
                    Text("Focus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(
                        get: { noxFocusMode },
                        set: { newValue in
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                noxFocusMode = newValue
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DS.Color.accent)
                    .scaleEffect(0.65)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                let steps = [15, 30, 60, 90, 120]
                let current = max(5, dailyFocusGoal)
                let nextIdx = (steps.firstIndex(where: { $0 > current }) ?? 0)
                dailyFocusGoal = steps[nextIdx]
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "target")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Goal \(dailyFocusGoal)m")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.accent)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
    }

    /// Live-running hero card — animated moon, "FOCUS ON" label,
    /// HH:MM since session start, and the wall-clock instant the
    /// session began on the right. Re-renders every 1s via
    /// `TimelineView` so the duration ticks without a manual
    /// timer. When Focus is off, the gradient fill dims and the
    /// hero shows a "tap toggle below" prompt instead of the
    /// timer.
    private var heroCard: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            heroContent(now: context.date)
        }
    }

    /// True if EITHER nox's own Focus mode is on, OR macOS Focus
    /// is on AND the user has the auto-sync toggle enabled. This
    /// is what the dashboard hero / timer / stats reflect — the
    /// session counts time spent in any focus condition,
    /// regardless of how it got there.
    private var isInFocusState: Bool {
        if noxFocusMode { return true }
        if presenter.isFocused {
            // Mirror the same default-true gating that
            // PanelPresenter.setPendingSystemEvent uses so the
            // hero state never disagrees with the suppression
            // gate.
            if UserDefaults.standard.object(forKey: SettingsKey.respectFocusMode) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: SettingsKey.respectFocusMode)
        }
        return false
    }

    /// One enum to drive the hero card's morph. Combines Focus
    /// state with timer state into a single 4-state machine so
    /// the SwiftUI body has a clean switch instead of nested ifs.
    private enum HeroState: Equatable {
        /// Focus mode is off. Hero shows "Focus off" prompt.
        case focusOff
        /// Focus is on, no timer set. Hero shows session duration
        /// + SINCE + a chip strip below for setting a Pomodoro.
        case focusOnIdle
        /// A countdown timer is running OR paused. Hero replaces
        /// the duration display with a circular ring + remaining
        /// time + pause/resume + stop.
        case timerActive(paused: Bool)
        /// The timer hit zero and is awaiting the user's
        /// acknowledgment. Hero shows a celebration + chip strip
        /// for a one-tap restart + Done button.
        case timerExpired
    }

    private var heroState: HeroState {
        switch focusTimer.state {
        case .running: return .timerActive(paused: false)
        case .paused:  return .timerActive(paused: true)
        case .expired: return .timerExpired
        case .idle:    return isInFocusState ? .focusOnIdle : .focusOff
        }
    }

    /// Hero card content. Single source of truth for the four
    /// states above — same gradient + stroke wrapper, different
    /// content tree per state. The wrapper's `.animation(value:)`
    /// makes state transitions interpolate the gradient/stroke
    /// intensity smoothly.
    @ViewBuilder
    private func heroContent(now: Date) -> some View {
        Group {
            switch heroState {
            case .focusOff:
                heroFocusOffRow
            case .focusOnIdle:
                heroFocusOnIdleColumn(now: now)
            case .timerActive(let paused):
                heroTimerRunningRow(now: now, paused: paused)
            case .timerExpired:
                heroTimerExpiredColumn
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DS.Color.accent.opacity(isInFocusState ? 0.18 : 0.06),
                            DS.Color.accent.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    DS.Color.accent.opacity(isInFocusState ? 0.28 : 0.10),
                    lineWidth: 0.6
                )
        )
        // Animate gradient/stroke intensity + the state-tree morph
        // in lockstep. value: heroState catches every transition
        // (focus on/off, timer start/pause/stop/expire), value:
        // isInFocusState catches the gradient color shift even
        // when heroState happens to be the same string (pre-timer
        // legacy guard — keep for defensive coverage).
        .animation(.spring(response: 0.34, dampingFraction: 0.78),
                   value: heroState)
        .animation(.spring(response: 0.34, dampingFraction: 0.78),
                   value: isInFocusState)
    }

    // MARK: - Hero card sub-rows

    /// State A — Focus mode is off. Single-row layout: dimmed
    /// anime hero on the left, "FOCUS OFF" eyebrow + prompt copy
    /// in the middle. No SINCE column; nothing's happening yet.
    private var heroFocusOffRow: some View {
        HStack(spacing: 12) {
            FocusWorkingHero(active: false)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text("FOCUS OFF")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(DS.Color.accent.opacity(0.78))
                    .textCase(.uppercase)
                Text("Tap toggle below to start")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
    }

    /// State B — Focus is on, no timer set. Top row matches the
    /// legacy hero (anime + FOCUS ON + duration + SINCE).
    /// Underneath: a thin divider + a horizontal Timer chip
    /// strip so the user can start a Pomodoro without leaving
    /// the dashboard.
    private func heroFocusOnIdleColumn(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FocusWorkingHero(active: true)
                    .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FOCUS ON")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(DS.Color.accent)
                        .textCase(.uppercase)
                    if let start = tracker.sessionStartDate {
                        Text(formatSessionDuration(now.timeIntervalSince(start)))
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    } else {
                        // Brief race window between recompute and
                        // tracker emit — show a placeholder so the
                        // layout doesn't jump.
                        Text("0s")
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer(minLength: 8)
                if let start = tracker.sessionStartDate {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("SINCE")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(.white.opacity(0.45))
                        Text(formatTimeOfDay(start))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }

            // Hairline divider — the tiniest possible separator,
            // strong enough to read the chip strip as a different
            // group but quiet enough not to feel like a heavy
            // sub-section.
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)

            // Timer chip strip — embedded inside the hero card.
            // Morphs to a custom-duration editor when the user taps
            // the trailing "+" chip; back to chips on cancel/start.
            if customTimerExpanded {
                customTimerEditor
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.accent.opacity(0.85))
                    Text("Timer")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.trailing, 2)
                    ForEach([15, 25, 45, 90], id: \.self) { minutes in
                        durationChip(minutes: minutes)
                    }
                    customExpandChip
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Trailing chip that opens the custom-duration editor. Same
    /// capsule chrome as the preset chips so it reads as one of
    /// them, just with a `+` glyph instead of "Nm".
    private var customExpandChip: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                customTimerExpanded = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(minWidth: 28)
                .background(
                    Capsule()
                        .fill(DS.Color.accent.opacity(0.22))
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.Color.accent.opacity(0.45),
                                              lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Custom timer duration")
    }

    /// Custom-duration editor that replaces the chip strip when
    /// the user taps `+`. Single row, same height as the chip strip
    /// so the hero card doesn't jump:
    ///
    ///   ⏱ Custom  [−][ 30 ][+] min  [▶ Start]  [×]
    ///
    /// −/+ step by 5 minutes (clamped 1...300). The number is also
    /// directly editable via the inline TextField — type a number,
    /// hit Return → starts a timer at that duration.
    private var customTimerEditor: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.accent.opacity(0.85))
            Text("Custom")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.trailing, 2)

            // Stepper-style cluster: − [N] + with the number
            // editable inline. The −/+ buttons use
            // PressAndHoldStepper: single tap = ±1, press-and-hold
            // ramps to ±5 every 80 ms after a 350 ms grace.
            HStack(spacing: 0) {
                PressAndHoldStepper(systemImage: "minus") { delta in
                    customTimerMinutes = max(1, customTimerMinutes - delta)
                }

                TextField("", value: Binding(
                    get: { customTimerMinutes },
                    set: { customTimerMinutes = max(1, min(300, $0)) }
                ), format: .number)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30)
                .onSubmit { commitCustomTimer() }

                PressAndHoldStepper(systemImage: "plus") { delta in
                    customTimerMinutes = min(300, customTimerMinutes + delta)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(.white.opacity(0.06))
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                    )
            )

            Text("min")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 1)

            Spacer(minLength: 4)

            // Start — accent-filled so the user knows it commits.
            Button {
                commitCustomTimer()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .heavy))
                    Text("Start")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(DS.Color.accent.opacity(0.55))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Start custom timer")

            // Cancel — quiet × that reverts to the chip strip
            // without starting anything.
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    customTimerExpanded = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel custom timer")
        }
    }

    /// Tiny circular stepper button — used by the custom timer's
    /// −/+ cluster. Filled-circle visual at 22×22 so the tap target
    /// stays comfortable even though the icon is only 9pt.
    private func stepperButton(
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Validate, clamp, and start a Pomodoro at the user's custom
    /// duration. Auto-flips Focus mode on if it isn't already (same
    /// rule as the preset chips). Collapses the editor back to the
    /// chip strip so the hero is ready for "Start another" if they
    /// stop early.
    private func commitCustomTimer() {
        let mins = max(1, min(300, customTimerMinutes))
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            if !noxFocusMode { noxFocusMode = true }
            focusTimer.start(duration: TimeInterval(mins * 60))
            customTimerExpanded = false
        }
    }

    /// State C — Pomodoro countdown is running (or paused).
    /// Replaces the full hero row with a ring + remaining-time
    /// + pause/resume + stop. The session duration is implicit
    /// via the ring's progress, so we don't need the elapsed
    /// counter or SINCE column here.
    private func heroTimerRunningRow(now: Date, paused: Bool) -> some View {
        let remaining = focusTimer.remaining(now: now)
        let progress = focusTimer.progress(now: now)

        return HStack(spacing: 14) {
            // Circular progress ring with countdown digits in the
            // center. Compact 56pt — same diameter as the FocusHero
            // it replaces in this state, so the hero card height
            // stays roughly constant across the morph.
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        DS.Color.accent.opacity(paused ? 0.45 : 0.95),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
                Text(formatCountdown(remaining))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(paused ? .white.opacity(0.55) : .white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(paused ? "PAUSED" : "FOCUS ON")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(
                        paused
                            ? .yellow.opacity(0.85)
                            : DS.Color.accent
                    )
                    .textCase(.uppercase)
                Text(formatCountdown(remaining))
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(paused ? .white.opacity(0.55) : .white)
                    .lineLimit(1)
                Text(paused ? "paused" : "remaining")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Pause/Resume + Stop. Pause/Resume is the primary
            // (accent-filled), Stop is secondary (white-tinted).
            HStack(spacing: 8) {
                Button {
                    if paused { focusTimer.resume() }
                    else      { focusTimer.pause() }
                } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(DS.Color.accent.opacity(0.55))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(paused ? "Resume timer" : "Pause timer")

                Button {
                    focusTimer.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(.white.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop timer")
            }
        }
    }

    /// State D — Timer hit zero. Celebration row + chip strip
    /// for one-tap restart + Done button. The chime + panel
    /// vibrate fired at the moment of expiry; this is the
    /// resting celebration state until the user dismisses.
    private var heroTimerExpiredColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TIME'S UP")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.green)
                        .textCase(.uppercase)
                    Text("Start another?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                Button {
                    focusTimer.acknowledge()
                } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)

            // Restart chips — same shape as the idle state's
            // chips so the user has muscle memory. Includes the
            // same custom-duration "+" affordance.
            if customTimerExpanded {
                customTimerEditor
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.accent.opacity(0.85))
                    Text("Again")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.trailing, 2)
                    ForEach([15, 25, 45, 90], id: \.self) { minutes in
                        durationChip(minutes: minutes)
                    }
                    customExpandChip
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Hero card helpers

    /// Tap-to-start chip embedded in the Focus-on-idle hero row
    /// and the Timer-expired hero row. Starting a chip auto-flips
    /// Focus mode ON if it's off — committing to a Pomodoro block
    /// implies committing to the focus session it lives inside.
    private func durationChip(minutes: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                if !noxFocusMode { noxFocusMode = true }
                focusTimer.start(duration: TimeInterval(minutes * 60))
            }
        } label: {
            Text("\(minutes)m")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.Color.accent.opacity(0.38))
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.Color.accent.opacity(0.65),
                                              lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    /// MM:SS — used by the running-state hero ring + remaining-
    /// time text. Ceil so a sub-second tail (0.4s left) reads as
    /// "0:01" not "0:00", which would feel like the timer hit
    /// zero a second early.
    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }


    /// Two-tile stats grid — TOTAL · TODAY (left) and THIS WEEK
    /// (right with a 7-bar daily sparkline). Mirror of the Study
    /// detail panel's grid so both panels speak the same metric
    /// vocabulary. Persisted across app restarts via UserDefaults
    /// (see `FocusSessionTracker.minutesByDay`).
    private var statsGrid: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 10) {
                statTileTotalToday(now: ctx.date)
                statTileThisWeek(now: ctx.date)
            }
        }
    }

    private func statTileTotalToday(now: Date) -> some View {
        let total = tracker.totalMinutesToday(now: now)
        let active = tracker.isSessionActive
        return VStack(alignment: .leading, spacing: 3) {
            Text("TOTAL · TODAY")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(total)")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if active {
                Text("Session in progress")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.Color.accent.opacity(0.85))
            } else if total > 0 {
                Text("Nice work")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text("Tap Focus mode below to start")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
    }

    private func statTileThisWeek(now: Date) -> some View {
        let mins = tracker.totalMinutesThisWeek(now: now)
        let buckets = tracker.weekBuckets(now: now)
        let maxBucket = max(1, buckets.max() ?? 1)
        return VStack(alignment: .leading, spacing: 5) {
            Text("THIS WEEK")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(mins)")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { idx, value in
                    let isToday = idx == buckets.count - 1
                    Capsule(style: .continuous)
                        .fill(weekBarColor(value: value, isToday: isToday))
                        .frame(width: 6, height: weekBarHeight(value: value, max: maxBucket))
                }
            }
            .frame(height: 18, alignment: .bottom)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
    }

    private func weekBarHeight(value: Int, max: Int) -> CGFloat {
        let pct = CGFloat(value) / CGFloat(max)
        return 2 + 18 * pct
    }

    private func weekBarColor(value: Int, isToday: Bool) -> Color {
        if value == 0 { return .white.opacity(0.10) }
        return isToday ? DS.Color.accent : DS.Color.accent.opacity(0.55)
    }

    /// Format a session duration as "1h 23m" / "23m" / "45s".
    /// Drops higher-order zeros so a 5-minute session reads as
    /// "5m", not "0h 05m".
    private func formatSessionDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// Locale-aware short time of day for the SINCE column
    /// ("12:00 PM" in en-US, "12:00" in en-GB / 24h locales).
    private func formatTimeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// Focus-mode toggle row. Drives nox's OWN `noxFocusMode`
    /// `@AppStorage` — independent of macOS Focus, no Apple
    /// Shortcuts setup required. Tap anywhere on the row to flip
    /// (whole row is the hit target; the visible Toggle inside
    /// has `allowsHitTesting(false)` so it's purely a visual
    /// indicator).
    ///
    /// Suppression effect: when on, ambient pills (charger /
    /// screenshot / AirDrop / Bluetooth / track-change) get
    /// swallowed by `PanelPresenter.setPendingSystemEvent`'s
    /// focus-mode early return — same gate that already handled
    /// macOS-Focus suppression, just OR'd with this flag now.
    ///
    /// Voice: this row is for "I'm locked in, stop interrupting
    /// me." Subtitle copy reflects that mental model — "Locked
    /// in. Pings paused." when active, "Tap to lock in." when
    /// not.
    ///
    /// Animation contract:
    ///   • Tap fires `withAnimation(.spring(...))` so the toggle
    ///     thumb glides AND every dependent view (hero gradient,
    ///     moon hero, label color, timer appearance) animates in
    ///     lockstep.
    ///   • The moon icon swap (`moon` ↔ `moon.fill`) uses SF
    ///     Symbol's `.symbolEffect(.replace)` for a clean morph
    ///     on macOS 14+; older systems fall back to the implicit
    ///     opacity crossfade SwiftUI does for any Image swap.
    ///   • The icon-tile fill brightens slightly when on
    ///     (0.16 → 0.22) so the row "lights up" beyond just
    ///     the toggle itself moving.
    private var quietModeRow: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DS.Color.accent.opacity(noxFocusMode ? 0.22 : 0.16))
                Image(systemName: noxFocusMode ? "moon.fill" : "moon")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)
                    .modifier(IconReplaceEffect(value: noxFocusMode))
            }
            .frame(width: 26, height: 26)

            // 2026-05-09: subtitle removed per user spec ("remove
            // that small words from there please"). Just the title
            // — the toggle's on/off state is the descriptor.
            Text("Focus mode")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 12)

            Toggle("", isOn: $noxFocusMode)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DS.Color.accent)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            // Wrap the binding flip in a spring so the toggle
            // thumb AND the hero gradient / timer / moon hero
            // animate together. Without this the assignment is
            // synchronous and SwiftUI snaps the toggle to its
            // new position with no transition.
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                noxFocusMode.toggle()
            }
        }
    }

    /// Two-row card. Top row is the Focus toggle (Shortcuts-CLI-
    /// driven) or its setup CTA. Bottom row is the working
    /// "Auto-hide pills" toggle. Same chrome as the onboarding
    /// `GroupedCard` — 14pt corners, white-0.04 fill, hairline
    /// divider between rows.
    private var controlsCard: some View {
        VStack(spacing: 0) {
            // Row 1 — nox's own quiet-mode toggle. Replaces the
            // earlier macOS-Focus-driven row (which required Apple
            // Shortcuts setup, or AppleScript-Control-Centre that
            // hijacked the screen). User feedback 2026-05-08:
            // "Let's do it in our own instade of apple."
            // Tap anywhere on the row → `noxFocusMode` flips →
            // suppression takes effect immediately.
            quietModeRow

            // Hairline divider — same treatment as the onboarding's
            // GroupedCard rows.
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.leading, 64)
                .padding(.trailing, 16)

            // Row 2 — app-level "respect Focus" preference.
            // Drives the count above (every suppressed pill goes
            // through this gate).
            //
            // 2026-05-08 fix v2: switched from Button-wrapped row
            // to `.onTapGesture` directly. Buttons inside an
            // NSPanel-hosted SwiftUI tree can have flaky hit
            // detection when other Buttons sit beside them in
            // the same VStack — sometimes only the first Button
            // receives taps. `.onTapGesture` is more permissive
            // and reliably fires regardless of sibling Buttons.
            // The inner Toggle stays `.allowsHitTesting(false)`
            // so the row tap is the single hit target — no
            // double-fire when clicking the switch directly.
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Color.accent.opacity(0.10))
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Color.accent.opacity(0.85))
                }
                .frame(width: 26, height: 26)

                // Subtitle removed per user spec 2026-05-09 — the
                // title is enough to describe the toggle's purpose.
                Text("Auto-hide pills during Focus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 12)

                Toggle("", isOn: $respectFocusMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DS.Color.accent)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                NSLog("nox: Auto-hide row tapped, respectFocusMode \(respectFocusMode) -> \(!respectFocusMode)")
                respectFocusMode.toggle()
            }
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

// MARK: - Live → Study detail panel

/// Sibling to `LiveFocusDetailPanel` — same shape, study branding.
/// Opens when the user taps the chevron on the Study status pill.
///
/// Lean version of the Focus dashboard:
///   • Hero — book icon + "Study mode" title + "ON/OFF" + live
///     session timer (HH:MM since `studySessionStartedAt`).
///   • Controls — single toggle row that flips `noxStudyMode`.
///
/// Skipped (vs. Focus): the stats grid (pills muted, sparkline) —
/// those rely on `FocusSessionTracker` which is Focus-specific. We
/// can wire a SessionTracker for Study later if the user wants
/// productivity stats; for V1 the timer alone is the value.
struct LiveStudyDetailPanel: View {
    @EnvironmentObject var presenter: PanelPresenter
    @AppStorage(SettingsKey.noxStudyMode) private var noxStudyMode: Bool = false
    @AppStorage(SettingsKey.noxFocusMode) private var noxFocusMode: Bool = false
    @ObservedObject private var tracker = StudySessionTracker.shared

    /// Cascade entrance curve — see the matching helper on
    /// `LiveFocusDetailPanel`. Both dashboards gate their content
    /// on `presenter.cascadeReady` with this animation so heavy
    /// rendering stays out of the open-spring critical path.
    private var cascadeAnimation: Animation {
        if #available(macOS 14.0, *) {
            return .snappy(duration: 0.32, extraBounce: 0.15)
        } else {
            return .interpolatingSpring(mass: 1.0, stiffness: 350, damping: 22)
        }
    }

    /// Pomodoro-style countdown timer for the active Study session.
    /// Same `SessionTimerService` class powering Focus's timer; the
    /// `.study` singleton has its own UserDefaults snapshot key and
    /// expiry notification, so the two timers don't share state.
    @ObservedObject private var studyTimer = SessionTimerService.study

    /// True while the Study-on-idle hero is showing the custom-
    /// duration editor instead of the four-preset chip strip.
    /// Mirrors `LiveFocusDetailPanel`'s same-named flag — tapping
    /// the trailing "+" chip flips this on; × in the editor flips
    /// it off.
    @State private var customTimerExpanded: Bool = false

    /// User-entered custom duration in minutes for the Study timer.
    /// Defaults to 30. Clamped to 1...300 on commit. Independent
    /// of Focus's custom-timer state — both can have different
    /// last-used custom values without interfering.
    @State private var customTimerMinutes: Int = 30

    /// Closure invoked when the user taps the "‹ Live" back arrow.
    let onBack: () -> Void

    var body: some View {
        // 2026-05-09 redesign — same two-column composition as the
        // Focus dashboard. Goal hero on the left, controls stacked
        // on the right. Study doesn't currently have a Pomodoro
        // timer (the SessionTimerService.study exists but no UI
        // surfaces it yet) so the right column is just the
        // controls strip; if/when we add a Study timer it slots
        // right in above controlsStrip with the same shape Focus uses.
        VStack(alignment: .leading, spacing: 6) {
            backRow
            // Lazy mount — see matching site in
            // `LiveFocusDetailPanel.body` for full rationale.
            // Keeps the StudyHero + 7 ring strip + timer strip
            // OUT OF THE VIEW TREE until `cascadeReady` flips, so
            // SwiftUI doesn't instantiate or lay out any of it
            // during the panel.frame open spring's steepest
            // phase. Mounts with a single combined transition
            // when ready, matching the entrance feel of the
            // earlier opacity-gated version but without paying
            // its hidden cost.
            if presenter.cascadeReady {
                HStack(alignment: .top, spacing: 8) {
                    goalHeroCard
                        .layoutPriority(2)
                    VStack(spacing: 6) {
                        timerStrip
                        controlsStrip
                        Spacer(minLength: 0)
                    }
                    .frame(width: 220)
                }
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .offset(y: -16))
                        .animation(cascadeAnimation),
                    removal: .opacity
                ))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Goal hero card (RiseUp redesign)

    /// User-configurable daily Study goal. Default 90 min — slightly
    /// higher than Focus's 60 since study sessions tend to be longer-
    /// form (reading, problem sets, deep learning) than the
    /// fragmented-deep-work cadence Focus targets. Tappable from the
    /// "Daily goal" row to cycle through 30/60/90/120/180.
    @AppStorage(SettingsKey.dailyStudyGoalMinutes) private var dailyStudyGoal: Int = 90

    private var goalHeroCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            goalHeroContent(now: context.date)
        }
    }

    @ViewBuilder
    private func goalHeroContent(now: Date) -> some View {
        let goal = max(5, dailyStudyGoal)
        // 2026-05-09 perf: same de-duplication fix the Focus dash
        // got. Compute the 7-day data once, derive every aggregate
        // from it. Cuts tracker calls per body eval from 21+ down
        // to 7. See LiveFocusDetailPanel's matching site for the
        // full rationale.
        let perDay: [(minutes: Int, label: String)] = (0..<7).map { i in
            let daysAgo = 6 - i
            let mins = tracker.dayMinutes(daysAgo: daysAgo, now: now)
            let label = dayLabel(daysAgo: daysAgo, now: now)
            return (mins, label)
        }
        let goalsHit = perDay.reduce(0) { $0 + ($1.minutes >= goal ? 1 : 0) }
        let goalsPct = Int((Double(goalsHit) / 7.0 * 100).rounded())
        let weekTotal = perDay.reduce(0) { $0 + $1.minutes }
        let weekAvg = weekTotal / 7
        let avgVsGoal = min(1.0, Double(weekAvg) / Double(goal))

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // 2026-05-09 icon swap (parity with Focus's
                // FocusWorkingHero swap): the static book SF Symbol
                // is replaced with the existing animated `StudyHero`
                // illustration (breathing book + soft glow). Same
                // character users see in the resting Study pill, so
                // dashboard reads as continuous with the pill rather
                // than a different icon set.
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DS.Color.accent.opacity(noxStudyMode ? 0.22 : 0.14))
                    StudyHero(active: noxStudyMode)
                        .frame(width: 26, height: 26)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Study at least \(goal) min today")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        Text("\(goalsHit) of 7 goals")
                            .foregroundStyle(.white)
                            .fontWeight(.semibold)
                        Text(" this week (\(goalsPct)%)")
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .font(.system(size: 10.5))
                }

                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.bottom, 6)

            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    let isToday = i == 6
                    let day = perDay[i]
                    let progress = min(1.0, Double(day.minutes) / Double(goal))
                    GoalRingDay(
                        label: day.label,
                        minutes: day.minutes,
                        progress: progress,
                        isToday: isToday,
                        accent: DS.Color.accent,
                        // Lightbulb = "insight / actively learning"
                        // — Study's counterpart to Focus's bolt.
                        // Both glyphs read as energy, but in their
                        // respective modes (lock-in vs learning).
                        // The literal book glyph repeated 7 times
                        // read as static iconography; lightbulb
                        // intensifies as the day's ring fills,
                        // matching how you'd describe a productive
                        // study day ("things lit up today").
                        glyph: "lightbulb.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.top, 6)
                .padding(.bottom, 6)

            HStack(spacing: 10) {
                footerStat(big: formatMinutesShort(weekTotal), small: "Total this week")
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 0.5, height: 26)
                footerStat(big: formatMinutesShort(weekAvg), small: "Avg daily")
                Spacer(minLength: 4)
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.10), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: avgVsGoal)
                        .stroke(DS.Color.accent,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.accent)
                }
                .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DS.Color.accent.opacity(noxStudyMode ? 0.16 : 0.08),
                            DS.Color.accent.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    DS.Color.accent.opacity(noxStudyMode ? 0.26 : 0.10),
                    lineWidth: 0.6
                )
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.78),
                   value: noxStudyMode)
    }

    private func footerStat(big: String, small: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(big)
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(small)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func dayLabel(daysAgo: Int, now: Date) -> String {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .day, value: -daysAgo, to: now) else {
            return ""
        }
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: d)
    }

    private func formatMinutesShort(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    // MARK: - Pomodoro timer strip (mirror of Focus's)

    /// Pomodoro-style timer strip for Study sessions. Same three-
    /// state shape as Focus's `timerStrip`: idle (chip strip),
    /// running/paused (countdown row + pause/stop), expired
    /// (celebration + Done). Backed by `studyTimer` instead of
    /// `focusTimer`. UI helpers (durationChip, customTimerEditor,
    /// stepperButton, commitCustomTimer, formatCountdown) are
    /// already defined on this struct from earlier work — only the
    /// strip + state-row helpers are new here.
    private var timerStrip: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            timerStripContent(now: context.date)
        }
    }

    @ViewBuilder
    private func timerStripContent(now: Date) -> some View {
        let state = studyTimer.state
        Group {
            switch state {
            case .idle:
                timerIdleRow
            case .running, .paused:
                timerRunningRow(now: now, paused: state == .paused)
            case .expired:
                timerExpiredRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: state)
    }

    /// Idle state — two-row chip layout (parallel to Focus's). Top
    /// row: label + 15/25 chips. Bottom row: 45/90 + custom `+`.
    /// Tapping `+` morphs the strip into the custom-duration editor.
    private var timerIdleRow: some View {
        if customTimerExpanded {
            AnyView(customTimerEditor)
        } else {
            AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(DS.Color.accent.opacity(0.85))
                        Text("Timer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer(minLength: 0)
                        durationChip(minutes: 15)
                        durationChip(minutes: 25)
                    }
                    HStack(spacing: 5) {
                        Spacer(minLength: 0)
                        durationChip(minutes: 45)
                        durationChip(minutes: 90)
                        customExpandChip
                    }
                }
            )
        }
    }

    /// Running / paused state — compact countdown row reading
    /// "STUDY ON" / "PAUSED" eyebrow above the MM:SS countdown.
    private func timerRunningRow(now: Date, paused: Bool) -> some View {
        let remaining = studyTimer.remaining(now: now)
        let progress = studyTimer.progress(now: now)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        DS.Color.accent.opacity(paused ? 0.45 : 0.95),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
                Image(systemName: paused ? "pause.fill" : "timer")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(paused ? .white.opacity(0.55) : DS.Color.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(paused ? "PAUSED" : "STUDY ON")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(paused ? .yellow.opacity(0.85) : DS.Color.accent)
                Text(formatCountdown(remaining))
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(paused ? .white.opacity(0.55) : .white)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                if paused { studyTimer.resume() }
                else { studyTimer.pause() }
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(DS.Color.accent.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(paused ? "Resume timer" : "Pause timer")

            Button {
                studyTimer.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop timer")
        }
    }

    /// Expired state — celebration + Done button. Tapping Done
    /// resets the timer to .idle and the strip flips back to the
    /// chip row so the user can start another.
    private var timerExpiredRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.Color.accent)
            Text("Session done")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button {
                studyTimer.acknowledge()
            } label: {
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Color.accent.opacity(0.45)))
            }
            .buttonStyle(.plain)
        }
    }

    /// Two-row controls strip sized for the narrow right column.
    /// Mirrors Focus's controlsStrip shape — Study toggle row + goal
    /// pill row. Cycle through 30/60/90/120/180 by tapping the goal.
    private var controlsStrip: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                    if !noxStudyMode {
                        noxFocusMode = false
                    }
                    noxStudyMode.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    // Lightbulb — Study counterpart to Focus's bolt
                    // in the parallel controlsStrip. Both read as
                    // "actively engaged energy," differentiated
                    // only by what kind of work mode they signal.
                    Image(systemName: noxStudyMode ? "lightbulb.fill" : "lightbulb")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(noxStudyMode
                                         ? DS.Color.accent
                                         : Color.white.opacity(0.55))
                    Text("Study")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(
                        get: { noxStudyMode },
                        set: { newValue in
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                if newValue { noxFocusMode = false }
                                noxStudyMode = newValue
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DS.Color.accent)
                    .scaleEffect(0.65)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                let steps = [30, 60, 90, 120, 180]
                let current = max(5, dailyStudyGoal)
                let nextIdx = (steps.firstIndex(where: { $0 > current }) ?? 0)
                dailyStudyGoal = steps[nextIdx]
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "target")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Goal \(dailyStudyGoal)m")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.accent)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
    }

    private var backRow: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Live")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(DS.Color.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Live")
    }

    private var heroCard: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            heroContent(now: context.date)
        }
    }

    /// Hero card state machine — same shape as
    /// `LiveFocusDetailPanel.HeroState`. Combines Study toggle state
    /// with timer state so the SwiftUI body uses one switch instead
    /// of nested ifs.
    private enum HeroState: Equatable {
        case studyOff
        case studyOnIdle
        case timerActive(paused: Bool)
        case timerExpired
    }

    private var heroState: HeroState {
        switch studyTimer.state {
        case .running: return .timerActive(paused: false)
        case .paused:  return .timerActive(paused: true)
        case .expired: return .timerExpired
        case .idle:    return noxStudyMode ? .studyOnIdle : .studyOff
        }
    }

    /// Hero card content. Single source of truth for the four
    /// states above — same gradient + stroke wrapper, different
    /// content tree per state. The wrapper's `.animation(value:)`
    /// makes state transitions interpolate the gradient/stroke
    /// intensity smoothly.
    @ViewBuilder
    private func heroContent(now: Date) -> some View {
        Group {
            switch heroState {
            case .studyOff:
                heroStudyOffRow
            case .studyOnIdle:
                heroStudyOnIdleColumn(now: now)
            case .timerActive(let paused):
                heroTimerRunningRow(now: now, paused: paused)
            case .timerExpired:
                heroTimerExpiredColumn
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DS.Color.accent.opacity(noxStudyMode ? 0.18 : 0.06),
                            DS.Color.accent.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    DS.Color.accent.opacity(noxStudyMode ? 0.28 : 0.10),
                    lineWidth: 0.6
                )
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.78),
                   value: heroState)
        .animation(.spring(response: 0.34, dampingFraction: 0.78),
                   value: noxStudyMode)
    }

    // MARK: - Hero card sub-rows

    /// State A — Study mode is off. Single-row layout with the
    /// dimmed book glyph + STUDY OFF eyebrow + prompt copy.
    private var heroStudyOffRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Color.accent.opacity(0.08))
                Image(systemName: "book.closed")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text("STUDY OFF")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(DS.Color.accent.opacity(0.78))
                    .textCase(.uppercase)
                Text("Tap toggle below to start")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
    }

    /// State B — Study is on, no timer set. Top row: book glyph +
    /// STUDY ON + duration + SINCE column. Underneath: hairline
    /// divider + a `⏱ Timer  [chips]` strip embedded inside the
    /// same card so the user can start a Pomodoro without leaving
    /// the dashboard.
    private func heroStudyOnIdleColumn(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DS.Color.accent.opacity(0.20))
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(DS.Color.accent)
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("STUDY ON")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(DS.Color.accent)
                        .textCase(.uppercase)
                    if let start = presenter.studySessionStartedAt {
                        Text(formatSessionDuration(now.timeIntervalSince(start)))
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    } else {
                        Text("0s")
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer(minLength: 8)
                if let start = presenter.studySessionStartedAt {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("SINCE")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(.white.opacity(0.45))
                        Text(formatTimeOfDay(start))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)

            // Timer chip strip — embedded inside the hero card.
            // Morphs to a custom-duration editor when the user taps
            // the trailing "+" chip; back to chips on cancel/start.
            if customTimerExpanded {
                customTimerEditor
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.accent.opacity(0.85))
                    Text("Timer")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.trailing, 2)
                    ForEach([15, 25, 45, 90], id: \.self) { minutes in
                        durationChip(minutes: minutes)
                    }
                    customExpandChip
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// State C — Pomodoro countdown is running (or paused).
    /// Replaces the full hero row with a ring + remaining-time
    /// + pause/resume + stop controls.
    private func heroTimerRunningRow(now: Date, paused: Bool) -> some View {
        let remaining = studyTimer.remaining(now: now)
        let progress = studyTimer.progress(now: now)

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        DS.Color.accent.opacity(paused ? 0.45 : 0.95),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
                Text(formatCountdown(remaining))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(paused ? .white.opacity(0.55) : .white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(paused ? "PAUSED" : "STUDY ON")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(
                        paused
                            ? .yellow.opacity(0.85)
                            : DS.Color.accent
                    )
                    .textCase(.uppercase)
                Text(formatCountdown(remaining))
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(paused ? .white.opacity(0.55) : .white)
                    .lineLimit(1)
                Text(paused ? "paused" : "remaining")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                Button {
                    if paused { studyTimer.resume() }
                    else      { studyTimer.pause() }
                } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(DS.Color.accent.opacity(0.55))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(paused ? "Resume timer" : "Pause timer")

                Button {
                    studyTimer.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(.white.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop timer")
            }
        }
    }

    /// State D — Timer hit zero. Celebration row + chip strip
    /// for one-tap restart + Done button.
    private var heroTimerExpiredColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TIME'S UP")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.green)
                        .textCase(.uppercase)
                    Text("Start another?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                Button {
                    studyTimer.acknowledge()
                } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)

            if customTimerExpanded {
                customTimerEditor
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.accent.opacity(0.85))
                    Text("Again")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.trailing, 2)
                    ForEach([15, 25, 45, 90], id: \.self) { minutes in
                        durationChip(minutes: minutes)
                    }
                    customExpandChip
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Hero card helpers (timer chips + custom editor)

    /// Tap-to-start chip. Auto-flips Study mode on if it's off
    /// AND mutex-flips Focus off — same rule as the live-status-row
    /// pill toggles, so starting a Study timer can't leave Focus
    /// quietly competing in the background.
    private func durationChip(minutes: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                if !noxStudyMode {
                    if noxFocusMode { noxFocusMode = false }
                    noxStudyMode = true
                }
                studyTimer.start(duration: TimeInterval(minutes * 60))
            }
        } label: {
            Text("\(minutes)m")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.Color.accent.opacity(0.38))
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.Color.accent.opacity(0.65),
                                              lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    /// Trailing "+" chip that opens the custom-duration editor.
    private var customExpandChip: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                customTimerExpanded = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(minWidth: 28)
                .background(
                    Capsule()
                        .fill(DS.Color.accent.opacity(0.22))
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.Color.accent.opacity(0.45),
                                              lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Custom timer duration")
    }

    /// Custom-duration editor — same single-row layout as the Focus
    /// version: `⏱ Custom  [− N +] min  [▶ Start]  [×]`.
    private var customTimerEditor: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.accent.opacity(0.85))
            Text("Custom")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.trailing, 2)

            HStack(spacing: 0) {
                PressAndHoldStepper(systemImage: "minus") { delta in
                    customTimerMinutes = max(1, customTimerMinutes - delta)
                }

                TextField("", value: Binding(
                    get: { customTimerMinutes },
                    set: { customTimerMinutes = max(1, min(300, $0)) }
                ), format: .number)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30)
                .onSubmit { commitCustomTimer() }

                PressAndHoldStepper(systemImage: "plus") { delta in
                    customTimerMinutes = min(300, customTimerMinutes + delta)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(.white.opacity(0.06))
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                    )
            )

            Text("min")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 1)

            Spacer(minLength: 4)

            Button {
                commitCustomTimer()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .heavy))
                    Text("Start")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(DS.Color.accent.opacity(0.55))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Start custom timer")

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    customTimerExpanded = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel custom timer")
        }
    }

    private func stepperButton(
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commitCustomTimer() {
        let mins = max(1, min(300, customTimerMinutes))
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            if !noxStudyMode {
                if noxFocusMode { noxFocusMode = false }
                noxStudyMode = true
            }
            studyTimer.start(duration: TimeInterval(mins * 60))
            customTimerExpanded = false
        }
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Stats grid

    /// Two-tile stats grid driven by `StudySessionTracker`. Same
    /// layout vocabulary as the Focus dashboard (left tile = hero
    /// number + subtext, right tile = hero number + sparkline) but
    /// with study-relevant metrics: total minutes today and minutes
    /// in the last 60 minutes.
    private var statsGrid: some View {
        // TimelineView re-renders the grid every 30s so the live
        // session's contribution to today's bucket and the week
        // total stays current.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 10) {
                statTileTotalToday(now: ctx.date)
                statTileThisWeek(now: ctx.date)
            }
        }
    }

    private func statTileTotalToday(now: Date) -> some View {
        let total = tracker.totalMinutesToday(now: now)
        let active = tracker.isSessionActive
        return VStack(alignment: .leading, spacing: 4) {
            Text("TOTAL · TODAY")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(total)")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if active {
                Text("Session in progress")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.Color.accent.opacity(0.85))
            } else if total > 0 {
                Text("Nice work")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text("Tap toggle below to start")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
    }

    /// Second stat tile — minutes studied across the last 7 days
    /// with a 7-bar daily sparkline (one bar per day, today on the
    /// right). Bars scale to the highest bucket in the week so a
    /// busy Monday still shows distinct relative heights.
    private func statTileThisWeek(now: Date) -> some View {
        let mins = tracker.totalMinutesThisWeek(now: now)
        let buckets = tracker.weekBuckets(now: now)
        let maxBucket = max(1, buckets.max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("THIS WEEK")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(mins)")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { idx, value in
                    let isToday = idx == buckets.count - 1
                    Capsule(style: .continuous)
                        .fill(barColor(value: value, isToday: isToday))
                        .frame(width: 6, height: barHeight(value: value, max: maxBucket))
                }
            }
            .frame(height: 20, alignment: .bottom)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
        )
    }

    private func barHeight(value: Int, max: Int) -> CGFloat {
        // Min 2pt so empty days read as a row of muted dots rather
        // than disappearing. Max 20pt — slightly taller than the
        // hourly sparkline since week-bars carry more information
        // density per bar.
        let pct = CGFloat(value) / CGFloat(max)
        return 2 + 18 * pct
    }

    private func barColor(value: Int, isToday: Bool) -> Color {
        if value == 0 {
            return .white.opacity(0.10)
        }
        return isToday
            ? DS.Color.accent
            : DS.Color.accent.opacity(0.55)
    }

    // MARK: - Controls

    /// Single-toggle controls card. Mirrors the row treatment used
    /// in Focus's controlsCard — whole row is the hit target so the
    /// user doesn't have to pixel-aim the Toggle thumb.
    private var controlsCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                    if !noxStudyMode {
                        // Mutex with Focus.
                        noxFocusMode = false
                    }
                    noxStudyMode.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            noxStudyMode
                                ? DS.Color.accent
                                : Color.white.opacity(0.55)
                        )
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Study mode")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Quiet pills + persistent indicator")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { noxStudyMode },
                        set: { newValue in
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                if newValue {
                                    noxFocusMode = false
                                }
                                noxStudyMode = newValue
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DS.Color.accent)
                    .scaleEffect(0.78)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    private func formatSessionDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    private func formatTimeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

// MARK: - SF Symbol replace effect (with backport fallback)

/// Wraps `.contentTransition(.symbolEffect(.replace))` so a
/// state-driven SF-Symbol swap morphs in place rather than
/// snapping. `.contentTransition` is the right API for *state*
/// driven swaps (vs. `.symbolEffect(.replace, value:)`, which is
/// for one-shot triggers — the `value:` form needs the value to
/// conform to `DiscreteSymbolEffect`, which `Bool` doesn't).
/// macOS 14+ supports the symbol-effect transition; older systems
/// fall back to SwiftUI's default opacity crossfade.
///
/// `value` here exists so `withAnimation` callers re-render the
/// icon when the bool flips, and any `.animation(value:)` higher
/// up the tree picks up the change too.
private struct IconReplaceEffect: ViewModifier {
    let value: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}

// MARK: - Focus working hero (anime "locked in at the laptop")
//
// Pure-SwiftUI illustration of a tiny character working at a
// laptop, in the spirit of the anime "studying / working" GIFs
// the user referenced (Pinterest / Tenor "anime crazy work GIF",
// "anime typing", "Studio Ghibli laptop"). Captures the aesthetic:
//   • Round head (cute, anime proportions)
//   • Two small eye lines — closed/concentrating
//   • Soft rounded body
//   • Laptop slab at the bottom
//   • Hands typing — alternating tiny up/down motion at ~4Hz
//   • Subtle head bob ±4% (concentration)
//
// Scales from the small-pill 18pt up to the dashboard hero 42-56pt.
// At 18pt every element is a few pixels but the head + laptop +
// typing motion still read as "someone is working." At 56pt the
// proportions land like a sticker / pixel-art sprite.

/// Tiny inline focus indicator — used in the hybrid music+focus
/// resting pill where space is tight (combined right-wing alongside
/// the timer text). Just a breathing brand-purple disc with a soft
/// halo. At 8pt the FocusWorkingHero would be unreadable mush; this
/// is the right resolution for an inline badge.
struct MiniFocusDot: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: !active)) { context in
            let t = context.date
                .timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.6) / 1.6
            let breathe = 1 + 0.18 * sin(t * 2 * .pi)
            Circle()
                .fill(DS.Color.accent)
                .scaleEffect(breathe)
                .shadow(color: DS.Color.accent.opacity(active ? 0.65 : 0),
                        radius: 3, x: 0, y: 0)
                .opacity(active ? 1 : 0.45)
        }
    }
}

struct FocusWorkingHero: View {
    let active: Bool

    /// Whole-cycle duration. 1.6s = a comfortable typing rhythm
    /// (slightly slower than a real keystroke cadence so the
    /// motion reads as deliberate, not frantic). Head bob and
    /// hand bounce are both phase-locked to this cycle.
    private let cycleDuration: Double = 1.6

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !active)) { context in
                let t = context.date
                    .timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycleDuration)
                    / cycleDuration
                ZStack {
                    softGlow(side: side)
                    sittingFigure(t: t, side: side)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Soft brand-purple glow around the figure — gives the
    /// illustration a "lit-up / focused energy" feel without
    /// adding visible chrome at small sizes.
    @ViewBuilder
    private func softGlow(side: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        DS.Color.accent.opacity(active ? 0.32 : 0),
                        DS.Color.accent.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: side * 0.55
                )
            )
    }

    /// The tiny character at a laptop. Drawn as composed Shapes
    /// with relative coordinates so everything scales cleanly.
    @ViewBuilder
    private func sittingFigure(t: Double, side: CGFloat) -> some View {
        // Head bob ±4% scale on a sine cycle.
        let bob = 1 + 0.04 * sin(t * 2 * .pi)

        // Hand "typing" alternation: left up while right down,
        // swap every half cycle. Use sin(2π · 2t) for 2 cycles
        // per master cycle = 4 keystrokes per 1.6s ≈ 2.5 Hz.
        let leftHand = sin(t * 4 * .pi)
        let rightHand = sin(t * 4 * .pi + .pi)  // 180° phase shift

        ZStack {
            // Laptop slab — wide thin rounded rect at the bottom
            // 30% of the canvas.
            RoundedRectangle(cornerRadius: side * 0.04, style: .continuous)
                .fill(DS.Color.accent.opacity(active ? 0.85 : 0.45))
                .frame(width: side * 0.78, height: side * 0.06)
                .offset(y: side * 0.30)

            // Laptop screen — thin slanted rect rising from the
            // slab. We approximate the open-laptop wedge with a
            // Trapezoid shape.
            LaptopScreen()
                .fill(DS.Color.accent.opacity(active ? 0.55 : 0.30))
                .frame(width: side * 0.62, height: side * 0.18)
                .offset(y: side * 0.18)

            // Body — rounded square behind the head, just barely
            // visible above the laptop. Slightly darker shade.
            RoundedRectangle(cornerRadius: side * 0.10, style: .continuous)
                .fill(DS.Color.accent.opacity(active ? 0.95 : 0.50))
                .frame(width: side * 0.46, height: side * 0.32)
                .offset(y: side * 0.06)

            // Hands — two small dots over the laptop slab,
            // bouncing up/down to imply typing.
            Circle()
                .fill(Color.white.opacity(active ? 0.92 : 0.55))
                .frame(width: side * 0.07, height: side * 0.07)
                .offset(x: -side * 0.16, y: side * 0.27 - leftHand * side * 0.025)
            Circle()
                .fill(Color.white.opacity(active ? 0.92 : 0.55))
                .frame(width: side * 0.07, height: side * 0.07)
                .offset(x: side * 0.16, y: side * 0.27 - rightHand * side * 0.025)

            // Head — round, brand-purple-tinted off-white so it
            // pops against the body. Subtle bob.
            Circle()
                .fill(Color(red: 1.0, green: 0.96, blue: 1.0))
                .frame(width: side * 0.42, height: side * 0.42)
                .scaleEffect(bob)
                .offset(y: -side * 0.18)

            // Eyes — two short horizontal dashes. Closed-eye
            // (concentrating) look. Position relative to the
            // head's bobbed center.
            HStack(spacing: side * 0.10) {
                Capsule()
                    .fill(Color(red: 0.20, green: 0.10, blue: 0.30))
                    .frame(width: side * 0.06, height: side * 0.012)
                Capsule()
                    .fill(Color(red: 0.20, green: 0.10, blue: 0.30))
                    .frame(width: side * 0.06, height: side * 0.012)
            }
            .scaleEffect(bob)
            .offset(y: -side * 0.18)

            // Cheek blush — single low-opacity pink dot, anime
            // signature. Skipped at very small sizes (under
            // ~24pt) since it'd be a single pixel.
            if side > 24 {
                Circle()
                    .fill(Color(red: 1.0, green: 0.65, blue: 0.78).opacity(0.6))
                    .frame(width: side * 0.06, height: side * 0.06)
                    .offset(x: -side * 0.10, y: -side * 0.16)
                    .scaleEffect(bob)
            }
        }
        .opacity(active ? 1 : 0.55)
    }
}

/// Sibling indicator to `FocusWorkingHero` for Study mode. Keep
/// simple per the user's brief ("everything same just the things
/// will be study related" + "keep things simple") — a closed-book
/// SF Symbol with a gentle breathing pulse so it reads as alive
/// without competing with the timer next to it.
///
/// Same size + same render contract as FocusWorkingHero so the pill
/// content's `Group { switch activePillMode }` swaps cleanly without
/// any layout jiggle.
struct StudyHero: View {
    let active: Bool

    /// Whole-cycle duration for the breathing pulse. 2.4s = slower
    /// than the typing rhythm in FocusWorkingHero so the two modes
    /// have visibly different cadences (typing = quick + alert;
    /// study = slow + steady).
    private let cycleDuration: Double = 2.4

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !active)) { context in
                let t = context.date
                    .timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycleDuration)
                    / cycleDuration
                // Sine breathing between 0.93x and 1.0x — subtle,
                // avoids the "throbbing" look of bigger swings.
                let breath = 0.93 + 0.07 * (0.5 + 0.5 * sin(t * 2 * .pi))
                ZStack {
                    softGlow(side: side)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: side * 0.78,
                                      weight: .semibold))
                        .foregroundStyle(DS.Color.accent)
                        .scaleEffect(breath)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .opacity(active ? 1 : 0.55)
    }

    /// Soft brand-purple glow behind the book — same recipe as
    /// FocusWorkingHero's glow so both heroes share the visual
    /// language. Subtle radial gradient that fades to clear at the
    /// edges.
    private func softGlow(side: CGFloat) -> some View {
        RadialGradient(
            colors: [
                DS.Color.accent.opacity(0.32),
                DS.Color.accent.opacity(0.08),
                .clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: side * 0.55
        )
        .blendMode(.plusLighter)
    }
}

/// Trapezoid-shaped laptop screen. The bottom edge is wider than
/// the top, mimicking a slightly-tilted-back laptop screen as seen
/// from a 3/4 angle.
private struct LaptopScreen: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Top edge — narrower
        let topInset = rect.width * 0.18
        path.move(to: CGPoint(x: rect.minX + topInset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topInset, y: rect.minY))
        // Bottom edge — full width
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Focus aura hero (LEGACY — still used at small pill sizes)
//
// Originally introduced as the "lock-in" indicator on the Focus
// dashboard. Replaces the SleepingMoonHero on the Focus dashboard. Rationale:
// the sleeping crescent reads as "DND / sleep", but Focus mode in
// nox is for the user who's "locked in" — a more active /
// concentrated state. The aura is concentric brand-purple rings
// pulsing outward from a solid focal dot — radar / sonar / lock-on
// language. Pure SwiftUI, no assets, scales cleanly from the small
// resting pill (18pt) up to the dashboard hero (42pt).
//
// Phase-staggered rings give the loop a continuous "always pulsing
// outward" feel — at any moment one ring is fully expanded /
// faded, another is mid-expansion, another is just starting. No
// dead beats. When `active == false` the rings vanish and the dot
// dims to 35% opacity (same neutral pose as the legacy sleeping
// moon's "Focus is off" state).

struct FocusAuraHero: View {
    let active: Bool

    /// Fraction-of-cycle phase for each ring. 3 rings spaced
    /// 1/3rd of a cycle apart gives a continuous emanation
    /// without any visual gap.
    private let ringCount = 3
    /// Whole cycle duration. A bit slower than a heartbeat so it
    /// reads as deliberate / meditative, not panicky.
    private let cycleDuration: Double = 2.4

    var body: some View {
        // 2026-05-09 simplified design. The previous 3-ring radar
        // scan was elegant on the 42pt dashboard hero but
        // disappeared at the 18pt small-pill scale: a 0.81pt
        // stroke fading from 0.75 opacity is below the legibility
        // threshold for the dark pill background. User saw it as
        // a blank pill ("Now it's black") with just the timer
        // showing.
        //
        // New design: ONE bold central disc (60% of frame) +
        // ONE outer pulse ring expanding outward. Both sized
        // generously so they're unmistakably present at 18pt
        // AND scale up cleanly to 42pt for the dashboard hero.
        //
        // Behavior:
        //   • Core disc breathes ±12% in scale over the cycle
        //     (slow heartbeat).
        //   • Pulse ring grows 0.7 → 1.6 of frame, fading from
        //     full opacity to 0. Single ring, low cognitive
        //     overhead — reads as "this thing is alive" without
        //     looking like a radar scan.
        //   • A soft brand-purple glow surrounds the core
        //     regardless of phase, so even between pulse rings
        //     the dot has visible aura.
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !active)) { context in
                let t = context.date
                    .timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycleDuration)
                    / cycleDuration
                ZStack {
                    // Single pulse ring — solid stroke with
                    // generous line width so it reads at small
                    // sizes. Scale 0.7 → 1.6, opacity 0.7 → 0.
                    pulseRing(phase: t, side: side)

                    // Central glowing disc — always-visible
                    // anchor. Size scales with the breath cycle.
                    coreDisc(t: t, side: side)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func pulseRing(phase p: Double, side: CGFloat) -> some View {
        let scale = 0.70 + p * 0.90
        let opacity = active ? max(0, (1 - p) * 0.70) : 0
        Circle()
            .stroke(
                DS.Color.accent,
                lineWidth: max(1.6, side * 0.085)
            )
            .scaleEffect(scale)
            .opacity(opacity)
    }

    @ViewBuilder
    private func coreDisc(t: Double, side: CGFloat) -> some View {
        let breathe = 1 + 0.12 * sin(t * 2 * .pi)
        // Outer glow — soft halo that's visible against the
        // dark pill regardless of pulse-ring phase.
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        DS.Color.accent.opacity(active ? 0.55 : 0),
                        DS.Color.accent.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: side * 0.55
                )
            )
            .scaleEffect(breathe)
        // Solid bright disc at the core — the unmistakable
        // "something is here" anchor.
        Circle()
            .fill(DS.Color.accent)
            .frame(
                width: side * 0.55 * breathe,
                height: side * 0.55 * breathe
            )
            .opacity(active ? 1 : 0.45)
    }
}

// MARK: - Sleeping moon character

/// Animated cartoon-style crescent moon for the Focus detail
/// panel hero. Pure SwiftUI — no Lottie / no external asset.
///
/// Composition:
///   1. Soft lavender halo pulse — outermost layer, breathes
///      slowly so the whole composition feels alive
///   2. Crescent moon — drawn as a stroke-only Path, brand-tinted,
///      with a subtle continuous Y bob (gentle floating motion)
///   3. Sleeping eyes — two short curved arcs ("u u"), closed,
///      blink occasionally for character (Apple-style micro-detail)
///   4. Pink blush dot — left cheek, low opacity, kawaii signature
///   5. Floating "Z" trail — three Zs of decreasing size that rise
///      and fade in a staggered loop, the universal sleep cue
///
/// When `active == false` (Focus is off) the animation freezes
/// at a neutral pose: crescent visible, eyes closed, no Z's, no
/// halo pulse. This way the same view fits the Focus-off state
/// without an awkward "static moon glyph" fallback.
struct SleepingMoonHero: View {
    let active: Bool

    /// Continuous animation phase, 0...1 looped over a 3.6s
    /// cycle. Drives the bob, halo pulse, blink schedule, and
    /// Z trail timing. Single source of truth so every motion
    /// element stays musical / synchronized.
    @State private var phase: Double = 0
    /// Animation timer task. Held so we can cancel on disappear
    /// / when active flips false (no point animating an idle
    /// view — keeps the GPU off the hook on inactive panels).
    @State private var animTask: Task<Void, Never>? = nil

    private let cycleDuration: Double = 3.6 // seconds per loop

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { ctx in
            // Phase 0...1 over cycleDuration, computed off the
            // timeline date so motion is frame-rate-independent.
            let t = active
                ? (ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration)
                : 0.0

            ZStack {
                halo(phase: t)
                moonCrescent(phase: t)
                if active {
                    zTrail(phase: t)
                }
            }
            .compositingGroup()
        }
    }

    // MARK: pieces

    /// Outer halo — soft radial wash that grows / fades subtly.
    /// Visual job: makes the hero feel "lit" against the dark
    /// card, without competing with the crescent inside.
    private func halo(phase t: Double) -> some View {
        let pulse = 0.55 + 0.45 * (sin(t * 2 * .pi) * 0.5 + 0.5)
        let scale = 0.92 + 0.08 * (sin(t * 2 * .pi) * 0.5 + 0.5)
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        DS.Color.accent.opacity(active ? 0.32 : 0.16),
                        DS.Color.accent.opacity(0.0)
                    ],
                    center: .center,
                    startRadius: 4,
                    endRadius: 36
                )
            )
            .scaleEffect(scale)
            .opacity(active ? pulse : 0.55)
    }

    /// Stroke-only crescent. Drawn as the difference between two
    /// circles with a Path, tinted lavender. Bobs gently up and
    /// down on the same cycle as the halo.
    private func moonCrescent(phase t: Double) -> some View {
        let bob = active ? sin(t * 2 * .pi) * 1.6 : 0
        return ZStack {
            // Filled crescent body — uses a mask trick: full
            // disc minus an offset disc gives a crescent shape.
            Circle()
                .fill(DS.Color.accent.opacity(0.95))
                .frame(width: 38, height: 38)
                .mask(
                    ZStack {
                        Circle()
                        Circle()
                            .frame(width: 32, height: 32)
                            .offset(x: 9, y: -3)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
                .shadow(color: DS.Color.accent.opacity(0.5),
                        radius: 6, x: 0, y: 0)
            // Closed eyes — two short curved arcs. Drawn slightly
            // INSET from the crescent's left half so they sit on
            // the visible portion (not the bitten-out half).
            ClosedEyesShape(spacing: 7)
                .stroke(.white.opacity(0.92),
                        style: StrokeStyle(lineWidth: 1.8,
                                           lineCap: .round,
                                           lineJoin: .round))
                .frame(width: 18, height: 6)
                .offset(x: -3, y: 0)
            // Pink kawaii blush — soft circle on the lower-left
            // cheek. Low opacity so it reads as a tint, not a
            // marking.
            Circle()
                .fill(Color(red: 1.0, green: 0.65, blue: 0.78))
                .opacity(0.45)
                .frame(width: 6, height: 4)
                .offset(x: -7, y: 5)
        }
        .offset(y: bob)
    }

    /// Three "Z"s rising in a stagger. Each spawns at a different
    /// phase offset and animates rise + fade across the cycle, so
    /// at any given moment one is starting, one is mid-rise, one
    /// is fading at the top. Continuous parade of sleep cues.
    private func zTrail(phase t: Double) -> some View {
        ZStack {
            zMark(phase: t,           offset: 0.0,  size: 9,  startX: 14)
            zMark(phase: t,           offset: 0.33, size: 11, startX: 18)
            zMark(phase: t,           offset: 0.66, size: 13, startX: 22)
        }
    }

    private func zMark(phase t: Double, offset: Double,
                       size: CGFloat, startX: CGFloat) -> some View {
        // Local phase in 0...1, with the per-Z offset applied.
        let p = (t + offset).truncatingRemainder(dividingBy: 1.0)
        // Y rises 0 → -22 over the cycle. Slight curve via easeOut
        // so the rise decelerates near the top (more graceful).
        let easeOut = 1.0 - pow(1.0 - p, 2.0)
        let dy = -22.0 * easeOut
        // Opacity: ramp in 0…0.15, hold, ramp out 0.7…1.0.
        let opacity: Double = {
            if p < 0.15 { return p / 0.15 }
            if p > 0.70 { return max(0, 1.0 - (p - 0.70) / 0.30) }
            return 1.0
        }()
        // Slight horizontal drift so they don't stack identically.
        let dx = sin(p * .pi) * 1.5

        return Text("Z")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(DS.Color.accent.opacity(0.85))
            .offset(x: startX + dx, y: -10 + dy)
            .opacity(opacity)
    }
}

/// Two arcs side by side — closed eyes on the moon character.
/// Drawn as one Path so a single .stroke applies to both.
private struct ClosedEyesShape: Shape {
    var spacing: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Each eye is a small downward-opening arc (half of a
        // squashed ellipse), drawn from left-tip to right-tip.
        // The "spacing" param is the gap between the inner tips
        // of the two eyes.
        let eyeWidth = (rect.width - spacing) / 2
        let centerY = rect.midY
        // Left eye
        let leftStart = CGPoint(x: rect.minX, y: centerY)
        let leftEnd   = CGPoint(x: rect.minX + eyeWidth, y: centerY)
        path.move(to: leftStart)
        path.addQuadCurve(
            to: leftEnd,
            control: CGPoint(x: leftStart.x + eyeWidth / 2, y: centerY + rect.height)
        )
        // Right eye
        let rightStart = CGPoint(x: rect.maxX - eyeWidth, y: centerY)
        let rightEnd   = CGPoint(x: rect.maxX, y: centerY)
        path.move(to: rightStart)
        path.addQuadCurve(
            to: rightEnd,
            control: CGPoint(x: rightStart.x + eyeWidth / 2, y: centerY + rect.height)
        )
        return path
    }
}

/// Lightweight wrapping flow layout. SwiftUI's HStack overflows
/// off-canvas; LazyVGrid wants column counts up front. This
/// computes per-line widths on the fly so chips wrap naturally.
/// Kept local to MusicPanelView.swift — promote to a shared
/// utility if we end up using it elsewhere.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = layout(into: maxWidth, subviews: subviews)
        let totalHeight = lines.reduce(0) { $0 + $1.height } + max(0, CGFloat(lines.count - 1)) * lineSpacing
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = layout(into: bounds.width, subviews: subviews)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for item in line.items {
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct LineItem { let view: LayoutSubview; let size: CGSize }
    private struct Line { let items: [LineItem]; let height: CGFloat }

    private func layout(into maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var currentItems: [LineItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let widthIfAdded = currentItems.isEmpty
                ? size.width
                : currentWidth + spacing + size.width
            if widthIfAdded > maxWidth, !currentItems.isEmpty {
                lines.append(Line(items: currentItems, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }
            currentItems.append(LineItem(view: view, size: size))
            currentWidth = currentItems.isEmpty
                ? size.width
                : currentWidth + (currentItems.count == 1 ? 0 : spacing) + size.width
            currentHeight = max(currentHeight, size.height)
        }
        if !currentItems.isEmpty {
            lines.append(Line(items: currentItems, height: currentHeight))
        }
        return lines
    }
}

#Preview {
    let presenter = PanelPresenter()
    presenter.nowPlaying = NowPlayingInfo(
        title: "SMILEY (Feat. BIBI)",
        artist: "YENA",
        album: "˙ᵕ˙ (SMiLEY)",
        artworkData: nil,
        isPlaying: true,
        sourceBundleID: "com.spotify.client",
        duration: 215,
        elapsedTime: 78,
        infoTimestamp: Date()
    )
    return MusicPanelView()
        .environmentObject(presenter)
        .preferredColorScheme(.dark)
        .frame(width: 380, height: 230)
        .background(Color.black)
}

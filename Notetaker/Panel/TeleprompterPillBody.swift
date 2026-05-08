import SwiftUI

/// Content for the teleprompter pill — the actual scrolling-text
/// reading pane that lives inside the wider+taller pill silhouette
/// while a script is being read.
///
/// Geometry contract: the host panel's frame is sized via
/// `PanelWindowController.teleprompterPillFrame(for:)`. The pill's
/// inner silhouette has a `notchOverlap` zone at the top (covered
/// by the camera hardware) plus a `teleprompterPillBump` apron
/// below. This view fills the silhouette and uses a top inset
/// equal to `notchOverlap` so the scrolling text only renders in
/// the visible apron — never behind the camera notch.
///
/// Scroll engine: anchor-time-driven via TimelineView at 60 Hz.
/// `progress = (now - startedAt) / totalDuration` where
/// `totalDuration = (wordCount / WPM) × 60`. Scroll offset =
/// `viewportH - progress × (textHeight + viewportH)` so the text
/// starts entirely below the visible apron and ends entirely
/// above.
///
/// Interaction model:
///   • Tap on body → toggle pause/resume (safer default — accidental
///     taps don't kill the reading session).
///   • × button → save position + stop completely.
///   • Auto-stop → when progress hits 1.0 we flash "Done" for ~1.4s,
///     reset position to 0 (so next start is fresh), then dismiss.
struct TeleprompterPillBody: View {
    @ObservedObject var presenter: PanelPresenter
    let notchOverlap: CGFloat

    /// Bump portion of the pill (visible apron below the notch).
    /// Mirrors `PanelWindowController.teleprompterPillBump`.
    private let bump: CGFloat = 76

    /// Inset from the apron's edges to the text column.
    private let textTopInset: CGFloat = 6
    private let textBottomInset: CGFloat = 8

    @State private var textHeight: CGFloat = 0

    /// Latched true when the script's progress hits 1.0 — kicks off
    /// the "Done" flash, after which we auto-stop. Reset on view
    /// dismount via `.onDisappear`.
    @State private var didReachEnd: Bool = false

    /// True for the brief window after auto-stop fires while the
    /// "Done" flash is on screen. Suppresses the scrolling text so
    /// the user only sees the completion pulse.
    @State private var showingDoneFlash: Bool = false

    var body: some View {
        if let script = presenter.teleprompterScript,
           let startedAt = presenter.teleprompterStartedAt {
            content(for: script, startedAt: startedAt)
                .onDisappear {
                    didReachEnd = false
                    showingDoneFlash = false
                }
        } else {
            // Defensive — script cleared mid-render. Render
            // transparent rather than crashing on the optional.
            Color.clear
        }
    }

    @ViewBuilder
    private func content(for script: Script, startedAt: Date) -> some View {
        let words = max(1, ScriptStore.wordCount(script.body))
        let totalDuration = max(2.5, (Double(words) / max(1.0, Double(script.wpm))) * 60.0)
        let viewportH = bump - textTopInset - textBottomInset

        ZStack(alignment: .topLeading) {
            // ── Bottom progress strip ────────────────────────────
            VStack {
                Spacer()
                progressBar(totalDuration: totalDuration, startedAt: startedAt)
                    .frame(height: 2)
            }

            // ── Scrolling text ───────────────────────────────────
            if !showingDoneFlash {
                scrollingText(
                    script: script,
                    startedAt: startedAt,
                    totalDuration: totalDuration,
                    viewportH: viewportH
                )
            }

            // ── Pause indicator (overlay) ────────────────────────
            if presenter.teleprompterPausedAtElapsed != nil && !showingDoneFlash {
                pauseOverlay
            }

            // ── End-of-script "Done" flash ───────────────────────
            if showingDoneFlash {
                doneFlash
            }

            // ── Close button ─────────────────────────────────────
            HStack {
                Spacer()
                closeButton
            }
            .padding(.top, 6)
            .padding(.trailing, 12)
        }
        .padding(.top, notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Tap on bare-pill area toggles pause/resume — much safer
        // than tap-to-stop, which forced users to start over after
        // any errant click.
        .contentShape(Rectangle())
        .onTapGesture {
            presenter.toggleTeleprompterPause()
        }
        .onPreferenceChange(TeleprompterTextHeightKey.self) { h in
            textHeight = h
        }
    }

    // MARK: - Scrolling text view

    @ViewBuilder
    private func scrollingText(
        script: Script,
        startedAt: Date,
        totalDuration: TimeInterval,
        viewportH: CGFloat
    ) -> some View {
        // Pause this clock when paused — prevents the offset from
        // drifting as the wall-clock continues. We also short-circuit
        // the progress computation against `pausedAtElapsed` so it
        // freezes exactly at the pause moment.
        let isPaused = presenter.teleprompterPausedAtElapsed != nil

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { ctx in
            // Effective elapsed: frozen if paused, otherwise from
            // the date diff. This single computation drives offset,
            // progress bar, and end-detection — no chance of the
            // three drifting out of sync.
            let elapsed: TimeInterval = {
                if let frozen = presenter.teleprompterPausedAtElapsed {
                    return frozen
                }
                return ctx.date.timeIntervalSince(startedAt)
            }()
            let progress = min(1.0, elapsed / totalDuration)
            let travel = textHeight + viewportH
            let offset = viewportH - CGFloat(progress) * travel

            Text(script.body)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineSpacing(7)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TeleprompterTextHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .padding(.horizontal, 50)
                .offset(y: offset)
                // End detection — kicks off the "Done" flash exactly
                // once per session. `didReachEnd` is a State guard so
                // the TimelineView's ~60Hz ticks don't re-fire it.
                .onChange(of: progress) { p in
                    if !didReachEnd && p >= 1.0 && !isPaused {
                        triggerEndOfScript(scriptID: script.id)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: viewportH, alignment: .top)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.20),
                    .init(color: .black, location: 0.80),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .padding(.top, textTopInset)
        .allowsHitTesting(false)
    }

    // MARK: - Overlays

    /// Subtle "‖ Paused" indicator that fades in when paused. Sits
    /// in the center of the apron so it reads as a distinct state
    /// rather than competing with the text.
    private var pauseOverlay: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.78))
            Text("Paused")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.black.opacity(0.55))
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, notchOverlap + 18)  // pin in the apron, not behind notch
        .transition(.opacity)
    }

    /// "Done" flash that plays when the script reaches its end. A
    /// soft check-mark + "Done" pair, ~1.4s, then auto-stops.
    private var doneFlash: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(DS.Color.accent)
            Text("Done")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, notchOverlap)
        .transition(.opacity)
    }

    // MARK: - Close

    private var closeButton: some View {
        Button {
            // Save position before tearing down state — the presenter
            // clears the script ref on stop, so we have to grab the
            // current elapsed first.
            saveCurrentPosition()
            presenter.stopTeleprompter()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .heavy))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(Color.white.opacity(0.08))
                )
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Progress bar

    @ViewBuilder
    private func progressBar(totalDuration: TimeInterval, startedAt: Date) -> some View {
        let isPaused = presenter.teleprompterPausedAtElapsed != nil
        TimelineView(.animation(minimumInterval: 0.10, paused: isPaused)) { ctx in
            let elapsed: TimeInterval = {
                if let frozen = presenter.teleprompterPausedAtElapsed {
                    return frozen
                }
                return ctx.date.timeIntervalSince(startedAt)
            }()
            let progress = min(1.0, max(0.0, elapsed / totalDuration))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                    Rectangle()
                        .fill(isPaused
                              ? Color.white.opacity(0.30)
                              : Color.white.opacity(0.55))
                        .frame(width: geo.size.width * progress)
                }
            }
        }
    }

    // MARK: - End-of-script + position-save plumbing

    /// Fires once when the scroll reaches the script's end. Resets
    /// the saved position to 0 (so a re-start plays fresh), shows
    /// the "Done" flash, then auto-stops after a brief hold.
    private func triggerEndOfScript(scriptID: String) {
        didReachEnd = true
        // Reset saved position so next run starts from beginning,
        // not the very end (which would just immediately re-trigger).
        if let store = AppDelegate.shared?.environment?.scriptStore {
            try? store.saveReadPosition(id: scriptID, offset: 0)
        }
        withAnimation(.easeOut(duration: 0.18)) {
            showingDoneFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            presenter.stopTeleprompter()
        }
    }

    /// Persist the current elapsed-seconds back to the script so a
    /// future tap on Start picks up where we left off. Called from
    /// the × button before the presenter clears state.
    private func saveCurrentPosition() {
        guard let script = presenter.teleprompterScript,
              let started = presenter.teleprompterStartedAt else { return }
        let elapsed: TimeInterval = {
            if let frozen = presenter.teleprompterPausedAtElapsed {
                return frozen
            }
            return Date().timeIntervalSince(started)
        }()
        let words = max(1, ScriptStore.wordCount(script.body))
        let totalDuration = max(2.5, (Double(words) / max(1.0, Double(script.wpm))) * 60.0)
        // Don't save past-end as a position — re-start should be
        // fresh, not "instantly done."
        if elapsed >= totalDuration - 0.5 {
            try? AppDelegate.shared?.environment?.scriptStore.saveReadPosition(
                id: script.id, offset: 0
            )
            return
        }
        try? AppDelegate.shared?.environment?.scriptStore.saveReadPosition(
            id: script.id, offset: Int(elapsed)
        )
    }
}

private struct TeleprompterTextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

import SwiftUI

/// Live preview of how a script will look + read in the actual
/// teleprompter pill. Embedded inside the Script tab editor so the
/// user can dial in WPM and see the result before committing to
/// `Start reading`.
///
/// Uses the same geometry vocabulary as the (forthcoming) real
/// teleprompter pill — rounded "track-banner" rect, top/bottom fade
/// mask, generous line-height — so this isn't a fake preview, it's a
/// scaled-down rehearsal of the real thing.
///
/// Scroll engine: `TimelineView(.animation)` ticks at 60Hz, we
/// derive progress from elapsed-time and total-read-duration
/// (`words / WPM × 60`). For preview we play a snippet (first ~3
/// sentences capped at 200 chars), scroll it once at WPM speed, hold
/// 1.5s at the bottom, then reset. The hold-and-reset gives the
/// preview a clear rhythm — much less jarring than wrapping mid-text.
///
/// Why TimelineView instead of `withAnimation`: the animation has to
/// re-derive its end-point every time `wpm` or the snippet changes,
/// and SwiftUI's implicit-animation mechanism gets confused by rapid
/// successive changes (slider drags). TimelineView is purely
/// time-driven, so dragging the WPM slider just changes how fast the
/// existing scroll progresses — no animation cancellation, no jitter.
struct ScriptPreviewPill: View {
    let text: String
    let wpm: Int

    /// External play/pause toggle (parent owns the control).
    @Binding var isPlaying: Bool

    /// Captures the laid-out height of the snippet so we know how far
    /// to scroll. Set via PreferenceKey from the Text's GeometryReader.
    @State private var textHeight: CGFloat = 0

    /// When playback was last (re)started. We use elapsed from this
    /// instant to compute the current scroll position. Reset on
    /// `text` / `wpm` change so edits are reflected immediately.
    @State private var anchor: Date = Date()

    /// Hover state — used to show the play/pause toggle overlay.
    @State private var isHovering: Bool = false

    // Geometry — chosen to feel pill-like inside the slab while still
    // being a useful preview.
    private let viewportHeight: CGFloat = 84
    private let cornerRadius: CGFloat = 18
    private let fontSize: CGFloat = 16
    private let lineSpacing: CGFloat = 6
    private let horizontalPadding: CGFloat = 24
    private let holdDuration: TimeInterval = 1.5

    /// First 3 sentences capped at 200 chars — enough to feel real,
    /// short enough to loop cleanly without dragging on. Fallback to
    /// raw text for short scripts that have no sentence breaks.
    private var snippet: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        // Try to split on sentence-enders. Keep punctuation by adding
        // it back when we join (split() drops the separator).
        let parts = trimmed
            .split(whereSeparator: { ".!?".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let chosen: String
        if parts.count >= 3 {
            chosen = parts.prefix(3).joined(separator: ". ") + "."
        } else if !parts.isEmpty {
            chosen = parts.joined(separator: ". ") + "."
        } else {
            chosen = trimmed
        }

        if chosen.count > 220 {
            // Cut on a word boundary to avoid mid-word ellipsis.
            let cap = chosen.prefix(220)
            if let lastSpace = cap.lastIndex(of: " ") {
                return String(chosen[..<lastSpace]) + "…"
            }
            return String(cap) + "…"
        }
        return chosen
    }

    private var snippetWords: Int {
        ScriptStore.wordCount(snippet)
    }

    /// Time it would take to read the snippet at the chosen WPM.
    /// Clamped so a 1-word snippet doesn't try to scroll in 0.4s.
    private var scrollDuration: TimeInterval {
        max(2.5, (Double(snippetWords) / max(1.0, Double(wpm))) * 60.0)
    }

    /// One full cycle: scroll + hold.
    private var cycleDuration: TimeInterval { scrollDuration + holdDuration }

    var body: some View {
        ZStack {
            // Pill background — slightly translucent so the panel's
            // backdrop bleeds through, matching the rest of the slab.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                )

            // Scrolling text or empty placeholder.
            if snippet.isEmpty {
                emptyPlaceholder
            } else {
                scrollingViewport
            }

            // Hover overlay — pause/play toggle bottom-right.
            if isHovering && !snippet.isEmpty {
                hoverControl
            }
        }
        .frame(height: viewportHeight)
        .onHover { isHovering = $0 }
        .onChange(of: text) { _ in resetAnchor() }
        .onChange(of: wpm) { _ in resetAnchor() }
        .onChange(of: isPlaying) { playing in
            if playing { resetAnchor() }
        }
    }

    // MARK: - Scrolling viewport

    @ViewBuilder
    private var scrollingViewport: some View {
        // The .clipShape MUST match the pill so text doesn't bleed
        // outside the rounded corners during the scroll.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(anchor)
            let cycle = elapsed.truncatingRemainder(dividingBy: cycleDuration)
            let offset = computeOffset(cycle: cycle)

            Text(snippet)
                .font(.system(size: fontSize, weight: .medium, design: .rounded))
                .lineSpacing(lineSpacing)
                .foregroundStyle(.white.opacity(0.94))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: SnippetHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .padding(.horizontal, horizontalPadding)
                .offset(y: offset)
                .onPreferenceChange(SnippetHeightKey.self) { h in
                    if abs(h - textHeight) > 0.5 {
                        textHeight = h
                        // New layout means our scroll math is off —
                        // reset the clock so it starts fresh.
                        resetAnchor()
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: viewportHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .mask(fadeMask)
    }

    /// Fade-in/fade-out mask top + bottom so text visibly enters and
    /// exits rather than popping at the pill edges.
    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.18),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Y-offset for the snippet text at this point in the cycle.
    /// - cycle in [0, scrollDuration): scroll from "below pill" to
    ///   "above pill"
    /// - cycle in [scrollDuration, cycleDuration): hold off-screen
    ///   (text gone), then anchor wraps and we restart
    private func computeOffset(cycle: TimeInterval) -> CGFloat {
        // If the snippet fits inside the viewport, just center it
        // statically — scrolling tiny text up and down looks weird.
        if textHeight <= viewportHeight - 8 {
            return (viewportHeight - textHeight) / 2
        }

        // Travel = full text height + viewport height, so the text
        // starts entirely below the bottom edge and ends entirely
        // above the top edge.
        let travel = textHeight + viewportHeight

        if cycle >= scrollDuration {
            // Hold phase — text is off the top. We render slightly
            // off so the fade mask hides it cleanly.
            return -textHeight - 12
        }

        let progress = cycle / scrollDuration
        return viewportHeight - CGFloat(progress) * travel
    }

    // MARK: - Empty / hover

    private var emptyPlaceholder: some View {
        Text("Type below to preview your script…")
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.40))
    }

    private var hoverControl: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(Color.black.opacity(0.55))
                        )
                        .overlay(
                            Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .transition(.opacity)
    }

    // MARK: - State plumbing

    private func resetAnchor() {
        anchor = Date()
    }
}

/// PreferenceKey for measuring the rendered snippet height. We need
/// it to know how far to scroll.
private struct SnippetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

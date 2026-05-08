import AppKit
import Combine
import SwiftUI

/// A real macOS menu-bar item (`NSStatusItem`) that surfaces the
/// current Focus session at the top of the screen — flanking the
/// notch, where macOS's own DND indicator also lives.
///
/// Visible iff `presenter.isFocused == true`. Shows a moon glyph
/// followed by a live duration label (`23m`, `1h 14m`). Updated
/// every 30s while a session is active. Clicking the item routes
/// to nox's Focus detail panel.
///
/// Why a separate service rather than a feature of NotchOrchestrator:
/// the status item lives in `NSStatusBar.system`, completely outside
/// the panel/window pipeline — it's a sibling to the notch HUD, not
/// a child of it. Keeping its lifecycle isolated also means the
/// rest of the panel state machine doesn't need to know it exists.
@MainActor
final class FocusStatusBarItem {

    /// Closure invoked when the user clicks the status item.
    /// AppDelegate wires this to "open the Focus detail panel."
    var onClick: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var tickTimer: Timer?

    /// Last duration label rendered. Skip redundant `attributedTitle`
    /// assignments — NSStatusItem flushes layout on every set, even
    /// for identical values, so guarding here saves measurable CPU
    /// over a long Focus session.
    private var lastLabel: String = ""

    /// Bind the status item's lifetime + label to the presenter.
    /// Idempotent — calling repeatedly is safe.
    func attach(presenter: PanelPresenter) {
        // Subscribe to focus on/off for show/hide.
        presenter.$isFocused
            .removeDuplicates()
            .sink { [weak self] isFocused in
                if isFocused {
                    self?.show(presenter: presenter)
                } else {
                    self?.hide()
                }
            }
            .store(in: &cancellables)

        // Subscribe to session start so the label re-renders with
        // the new "0m → 1m → ..." cadence on each Focus turn-on.
        presenter.$focusSessionStartedAt
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshLabel(presenter: presenter)
            }
            .store(in: &cancellables)
    }

    // MARK: - Show / hide

    private func show(presenter: PanelPresenter) {
        // Reuse if already created. NSStatusItem can be hidden via
        // `isVisible = false` rather than detached/recreated each
        // toggle — cheaper, and avoids the "item jumps in/out
        // shifting other items" visual.
        if let item = statusItem {
            item.isVisible = true
            NSLog("nox: FocusStatusBarItem — re-shown, length=\(item.length)")
        } else {
            // Use a fixed-width status item sized for "🌙 12h 5m"
            // worst case (~74pt). variableLength let macOS clip the
            // label when the menu bar got crowded; fixed length
            // forces the system to allocate the full width even if
            // it has to push other items.
            let item = NSStatusBar.system.statusItem(withLength: 78)
            item.button?.target = self
            item.button?.action = #selector(handleClick)
            // Title-only mode (no separate image). Embedding the
            // moon as a unicode glyph in the attributed title means
            // the system renders the whole thing atomically — no
            // image-vs-title coordination issues, no risk of the
            // timer half being clipped while the icon shows. Makes
            // the visible label match macOS's own DND indicator
            // visually ("🌙 Focus" for them, "🌙 23m" for us).
            item.button?.imagePosition = .noImage
            statusItem = item
            NSLog("nox: FocusStatusBarItem — created status item")
        }
        refreshLabel(presenter: presenter)
        startTicking(presenter: presenter)
    }

    private func hide() {
        statusItem?.isVisible = false
        stopTicking()
        lastLabel = ""
    }

    // MARK: - Label refresh

    private func refreshLabel(presenter: PanelPresenter) {
        guard let item = statusItem, let button = item.button else { return }

        let label: String
        if let started = presenter.focusSessionStartedAt {
            label = Self.formatDuration(since: started, now: Date())
        } else {
            // Fallback when isFocused fired without a session start
            // (shouldn't happen — FSS sets focusSessionStartedAt on
            // the same transition — but stay defensive).
            label = "Focus"
        }

        guard label != lastLabel else { return }
        lastLabel = label

        // Atomic moon-glyph + label as one attributed string. The
        // moon character ("🌙" U+1F319) is wide and visually loud
        // — switching to "◐" (CIRCLE WITH RIGHT HALF BLACK,
        // U+25D0) gives the same crescent vibe at less width and
        // tints with the menu bar's content color naturally.
        // Tested both: moon emoji is more recognizable, half-circle
        // is more compact. Going with the moon emoji because the
        // user pointed at macOS's own Focus indicator (which uses
        // a moon glyph) as the reference visual.
        let title = "🌙 \(label)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: attributes
        )
        button.toolTip = "Focus mode is on — \(label) so far. Click to open Focus details."
        NSLog("nox: FocusStatusBarItem — label='\(title)'")
    }

    // MARK: - Ticking

    /// Start a 30s timer to refresh the label. 30s gives sub-minute
    /// catch-up — the displayed minute can be at most 30s stale,
    /// which is invisible to the human eye since we only render
    /// minute-granularity.
    private func startTicking(presenter: PanelPresenter) {
        stopTicking()
        let timer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self, weak presenter] _ in
            guard let self, let presenter else { return }
            Task { @MainActor in
                self.refreshLabel(presenter: presenter)
            }
        }
        // .common run-loop mode so the timer keeps firing while the
        // user is interacting with menus / scrolling — `.default`
        // pauses during tracking, which would freeze the timer
        // while the user has any menu open.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        onClick?()
    }

    // MARK: - Format

    /// Same formatter rules as the resting-pill timer label:
    /// `1m` for the first minute, `Mm` up to 60, `Hh Mm` past that,
    /// `Hh` if the minute component is 0.
    static func formatDuration(since start: Date, now: Date) -> String {
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
}

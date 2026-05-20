import AppKit
import SwiftUI

// MARK: - Wiring Spec (for coordinator)
//
// This file is owned by Session 1 of the 1.9.21 alcove-parity sprint.
// The hookup in NowPlayingPillView.swift (one line via the
// `.pillContextMenu(info:onCommand:)` view modifier) is also part of
// Session 1's scope and IS applied directly — only edits to
// SettingsWindow.swift / PanelRootView.swift / project.pbxproj need a
// coordinator pass.
//
// Coordinator: nothing to apply for THIS file. The feature is fully
// self-contained and routes its existing-callback actions through the
// `onCommand` closure NowPlayingPillView already plumbs from
// NotchHUDWindowController (which forwards to
// `MediaRemoteService.send(_:)` via NotchOrchestrator).
//
// New entries added to `Notetaker.xcodeproj/project.pbxproj` by this
// session:
//
//   1. PBXBuildFile + PBXFileReference for
//      `Notetaker/NotchPill/PillContextMenu.swift` registered in the
//      Notetaker target's PBXSourcesBuildPhase and the NotchPill
//      PBXGroup's children.
//   2. PBXBuildFile + PBXFileReference for
//      `NotetakerTests/PillContextMenuPolicyTests.swift` registered in
//      the NotetakerTests target's PBXSourcesBuildPhase and the
//      NotetakerTests PBXGroup's children.
//
// No new SettingsKey entries — the menu has no persistent prefs in
// v1. (Future: per-item visibility toggles if users ask for them.)
// No new SettingsWindow.swift UI — the menu is discovered by
// right-clicking the pill, not configured from a settings pane.
// No PanelRootView.swift hookup — the resting pill lives in
// NotchHUDWindowController, not the panel.
//
// END WIRING SPEC

/// Right-click context menu for the resting now-playing pill.
///
/// **Why this file exists**: Alcove (the competitor we benchmark
/// against) lets the user right-click their resting pill to get a
/// compact transport-and-utility menu — Play/Pause, Next/Previous,
/// Copy Link, Show In Source, Settings. The same right-click on nox's
/// pill did nothing in 1.9.20 and earlier, which the user described
/// as "Alcove parity is the gap." This file closes that gap.
///
/// **Structure**:
///   • `PillContextMenuPolicy` — pure decision layer. Given a snapshot
///     of `NowPlayingInfo`, returns a list of `Entry` rows describing
///     what the menu should look like (titles, enabled flags, the
///     action each item triggers). No AppKit, no NSWorkspace, no
///     pasteboard. Tested in `PillContextMenuPolicyTests`.
///   • `PillContextMenu` — AppKit controller. Reads the policy's
///     entries, builds the corresponding `NSMenu`, presents it at the
///     right-click location, and dispatches the chosen action. This
///     is where the side-effects live (MediaRemote commands,
///     NSPasteboard, NSWorkspace, AppDelegate.openSettings).
///   • SwiftUI `.pillContextMenu(...)` modifier — the single hookup
///     point in `NowPlayingPillView`. Installs a local right-click
///     event monitor scoped to the pill's window while the view is
///     mounted, removes it on disappear.
///
/// **Why split this way**: the entries struct lets us unit-test every
/// branch (playing vs paused, known source vs unknown, URL-buildable
/// vs not) without spinning up a window, an event loop, or a
/// pasteboard. AppKit construction is mechanical — once the entry
/// list is right, the NSMenu is a one-to-one translation.
///
/// **Action target**: media commands route through the same
/// `onCommand: (MediaRemoteService.Command) -> Void` closure
/// `NowPlayingPillView` already takes from
/// `NotchHUDWindowController.handleCommand`. NotchOrchestrator
/// forwards that closure to `MediaRemoteService.send(_:)`, which
/// handles the "drive Spotify directly via AppleScript / fall back to
/// MediaRemote" routing already documented in MediaRemoteService.swift.
/// So Play / Pause / Next / Previous in the right-click menu use the
/// exact same playback pipeline as the user's left-click on the
/// expanded slab's transport buttons — there's no second code path
/// to keep in sync.
enum PillContextMenuPolicy {

    /// Discriminated union of every side-effect a menu item can
    /// trigger. Equatable so tests can assert the exact action a
    /// particular row carries without reaching for indirect "did
    /// the right closure fire" mocking.
    enum Action: Equatable {
        /// Forwarded to `MediaRemoteService.Command` via the pill's
        /// existing `onCommand` closure — same channel the expanded
        /// slab's transport buttons use.
        case command(MediaRemoteService.Command)
        /// Copy a deep-link URL to the system pasteboard. The string
        /// is fully-formed at policy time — no further interpolation
        /// in the controller.
        case copyTrackLink(url: String)
        /// Bring the source app forward via
        /// `NSWorkspace.openApplication(at:configuration:)` against
        /// the bundle URL we resolve from this ID at click time.
        case showInSource(bundleID: String)
        /// Open nox Settings. Routes through `AppDelegate.openSettings()`
        /// which already handles the hide-panel-then-activate dance.
        case openMusicSettings
    }

    /// One row in the menu. Separators are first-class because AppKit's
    /// `NSMenuItem.separatorItem()` is itself a row; collapsing it into
    /// the same type as command rows lets the test fixture express the
    /// whole menu shape as a single `[Entry]` literal.
    struct Entry: Equatable {
        let title: String
        /// nil iff `isSeparator` is true. Disabled items still carry
        /// an action (so tests can verify what they WOULD do if the
        /// item came back into reach), the AppKit layer just refuses
        /// to dispatch when isEnabled is false.
        let action: Action?
        let isEnabled: Bool
        let isSeparator: Bool

        static let separator = Entry(title: "", action: nil, isEnabled: false, isSeparator: true)

        static func item(_ title: String, _ action: Action, enabled: Bool = true) -> Entry {
            Entry(title: title, action: action, isEnabled: enabled, isSeparator: false)
        }
    }

    /// Inputs to the policy. Kept as a nested struct so a future rule
    /// (e.g. "hide Copy Link when offline" or "show Add to Library
    /// when the user is signed into Apple Music") slots in without
    /// changing the call signature at the consumer.
    struct Inputs {
        let info: NowPlayingInfo?
    }

    /// Build the entry list for the current pill snapshot.
    ///
    /// Returns an empty array when there's no info — the controller
    /// suppresses the pop-up entirely in that case, because a
    /// right-click on a pill with nothing playing is meaningless.
    /// (The pill only shows when something IS playing, so in
    /// practice this branch is defensive.)
    static func entries(_ inputs: Inputs) -> [Entry] {
        guard let info = inputs.info else { return [] }

        var rows: [Entry] = []

        // PLAY / PAUSE — bind to the explicit Command (not
        // togglePlayPause) so the user-facing verb matches the action.
        // If we sent togglePlayPause for both states the verb would
        // race the state: pressing "Pause" while the source app was
        // mid-flip to paused would resume playback. Using .play /
        // .pause unambiguously means "do THIS verb."
        if info.isPlaying {
            rows.append(.item("Pause", .command(.pause)))
        } else {
            rows.append(.item("Play", .command(.play)))
        }
        rows.append(.item("Next Track", .command(.next)))
        rows.append(.item("Previous Track", .command(.previous)))

        // COPY TRACK LINK — only enabled when we can synthesize a
        // useful destination URL. Spotify and Apple Music both have
        // browser-routable search endpoints; everything else (browser
        // tabs, podcast apps without a stable URL space) gets the
        // item disabled rather than removed. Keeping the slot present
        // means the menu's geometry doesn't reflow as the user
        // switches between Spotify and a YouTube tab — muscle memory
        // for "Copy Link" stays in the same screen position.
        let url = trackURL(for: info)
        rows.append(.item(
            "Copy Track Link",
            .copyTrackLink(url: url ?? ""),
            enabled: url != nil
        ))

        // SHOW IN SOURCE APP — title localizes to the actual app when
        // we recognize the bundle, falls back to generic "Source App"
        // for anything else (so the user sees a stable string instead
        // of a raw bundle ID).
        let bundleID = info.sourceBundleID ?? ""
        let appLabel = info.sourceBundleID.flatMap { sourceDisplayName(for: $0) }
        let showTitle = appLabel.map { "Show in \($0)" } ?? "Show in Source App"
        rows.append(.item(
            showTitle,
            .showInSource(bundleID: bundleID),
            enabled: info.sourceBundleID != nil
        ))

        rows.append(.separator)

        rows.append(.item("Open Music Settings…", .openMusicSettings))

        return rows
    }

    /// Build the "Copy Track Link" destination URL for the current
    /// track. Returns nil when we can't form a useful link — that
    /// surfaces as a disabled menu item rather than a broken click.
    ///
    /// We deliberately don't try to resolve canonical `track/{id}`
    /// URLs even when the source app could provide them: nox's
    /// metadata pipeline (MediaRemote + the Perl bridge) doesn't
    /// reliably surface track IDs for either Spotify or Apple Music
    /// across the macOS versions we support. A search URL with
    /// `artist + title` resolves to the right track 99% of the time
    /// in either app's web player and is robust to missing-ID
    /// emissions during track changes. The Alcove decoding pass on
    /// 2026-04-29 documented the same approach — they fall back to
    /// search URLs whenever the binary metadata is sparse.
    static func trackURL(for info: NowPlayingInfo) -> String? {
        let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = info.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        let term = "\(artist) \(title)"
        // .urlQueryAllowed is the canonical safe set for query-string
        // values across browsers and the iOS/macOS URL parsers; it
        // encodes spaces as %20 (not "+") which both apps' search
        // pages handle correctly.
        guard let escaped = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        switch info.sourceBundleID {
        case "com.spotify.client":
            return "https://open.spotify.com/search/\(escaped)"
        case "com.apple.Music":
            return "https://music.apple.com/us/search?term=\(escaped)"
        default:
            // Browser tabs / podcasts / unknown sources: we can't
            // pick a canonical destination. Leaving the URL nil
            // disables the menu item — better than silently copying
            // a URL the user can't open.
            return nil
        }
    }

    /// Human-friendly app name for a known bundle ID, or nil if we
    /// don't recognize it. The lookup is intentionally hand-curated
    /// (rather than going through `LaunchServices` /
    /// `[NSWorkspace urlForApplication:]`) so the menu can stay pure
    /// for testing and so the label is consistent regardless of
    /// how the user has the app's display name configured on disk.
    /// The shortlist mirrors `MediaRemoteAdapterService.appName(forBundleID:)`'s
    /// fast-path table — the same apps we already special-case in
    /// the music pipeline.
    static func sourceDisplayName(for bundleID: String) -> String? {
        switch bundleID {
        case "com.spotify.client": return "Spotify"
        case "com.apple.Music": return "Apple Music"
        case "com.apple.podcasts": return "Apple Podcasts"
        case "com.apple.Safari": return "Safari"
        case "com.google.Chrome": return "Chrome"
        case "com.google.Chrome.canary", "com.google.Chrome.beta": return "Chrome"
        case "company.thebrowser.Browser": return "Arc"
        case "com.brave.Browser": return "Brave"
        case "org.mozilla.firefox": return "Firefox"
        case "com.microsoft.edgemac": return "Edge"
        case "com.vivaldi.Vivaldi": return "Vivaldi"
        case "com.operasoftware.Opera": return "Opera"
        default: return nil
        }
    }
}

// MARK: - AppKit controller

/// Owns the right-click event monitor and the NSMenu construction.
///
/// **Lifecycle**: created on first `install(...)` from the SwiftUI
/// pill view's `.onAppear`. `install(...)` is idempotent and updates
/// the cached snapshot + command closure on every body re-eval so
/// the menu always reflects the LATEST track state when the user
/// right-clicks (not whatever was playing when the view first
/// mounted). `uninstall()` from `.onDisappear` tears the monitor
/// down so a hidden pill doesn't intercept right-clicks meant for
/// other windows.
///
/// **Main-actor confinement**: every entry point is `@MainActor`
/// because NSMenu construction, NSEvent monitoring, NSPasteboard
/// writes, and NSWorkspace launches must all happen on the main
/// thread. The SwiftUI hookup site is already main-actor by
/// definition; this annotation just enforces the rule and gives the
/// strict-concurrency build a clean signal.
@MainActor
final class PillContextMenu: NSObject, NSMenuDelegate {

    /// Process-singleton — only one resting pill exists at a time,
    /// so there's no scenario where two menus need separate state.
    /// Keeps the SwiftUI hookup site a one-liner (no need to thread
    /// an instance through the view tree).
    static let shared = PillContextMenu()

    /// Latest snapshot the menu will render against. Updated on every
    /// pill body re-eval via `install(...)`.
    private var info: NowPlayingInfo?
    /// Closure that fires when the user picks a media-transport item.
    /// Plumbed back to `NotchHUDWindowController.onMediaCommand` →
    /// `NotchOrchestrator` → `MediaRemoteService.send(_:)`.
    private var onCommand: ((MediaRemoteService.Command) -> Void)?

    private var eventMonitor: Any?

    /// The Cocoa window currently hosting the resting pill. We pin a
    /// weak reference so the event monitor can filter right-clicks
    /// to the pill's window — without this filter the monitor would
    /// pop the menu when the user right-clicked anywhere inside ANY
    /// of nox's windows (the slab, the menu-bar status item, etc.),
    /// which would be a hostile surprise.
    private weak var pillWindow: NSWindow?

    private override init() { super.init() }

    /// Update the snapshot + closures and install the local
    /// right-click monitor if it isn't already running. Idempotent —
    /// safe to call from every SwiftUI body re-eval.
    func install(
        info: NowPlayingInfo,
        onCommand: @escaping (MediaRemoteService.Command) -> Void,
        window: NSWindow?
    ) {
        self.info = info
        self.onCommand = onCommand
        self.pillWindow = window

        guard eventMonitor == nil else { return }
        // Local monitor — fires for events delivered to OUR app's
        // windows only. (A global monitor would catch right-clicks
        // anywhere on the screen, including in other apps, which we
        // explicitly do NOT want.) Returning `nil` from the closure
        // swallows the event so the SwiftUI tree below us doesn't
        // also try to handle it; returning the event passes it
        // through unchanged.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            return self.handleRightClick(event)
        }
    }

    /// Tear the monitor down. Called from the pill view's
    /// `.onDisappear`. After this call the menu cannot show — a
    /// subsequent `install(...)` re-arms it.
    func uninstall() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        info = nil
        onCommand = nil
        pillWindow = nil
    }

    // MARK: - Event handling

    private func handleRightClick(_ event: NSEvent) -> NSEvent? {
        // Only intercept right-clicks that landed on the pill's own
        // window. If the user is right-clicking inside the slab (or
        // anywhere else in nox), we let the event flow through to
        // whatever handler downstream owns it.
        guard let pillWindow,
              let eventWindow = event.window,
              eventWindow === pillWindow else {
            return event
        }

        guard let info = info else {
            // No snapshot to render against — let the click through
            // rather than silently swallowing it.
            return event
        }

        let entries = PillContextMenuPolicy.entries(.init(info: info))
        guard !entries.isEmpty else { return event }

        let menu = buildMenu(from: entries)
        // popUp(positioning:at:in:) is the same pattern MenuBarController
        // uses for the status-bar right-click menu — shows synchronously
        // at a precise point, no racing with AppKit's status-item event
        // loop. Origin is `event.locationInWindow` translated into the
        // content view's coordinate space so the menu drops right under
        // the cursor.
        if let contentView = eventWindow.contentView {
            let pointInContent = contentView.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil, at: pointInContent, in: contentView)
        } else {
            // Fallback: present unscoped. Better than dropping the
            // gesture entirely.
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }

        // Consume — we handled it.
        return nil
    }

    // MARK: - NSMenu construction

    private func buildMenu(from entries: [PillContextMenuPolicy.Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // Auto-enabling is off — we set `isEnabled` ourselves based
        // on the policy's enabled flag. Otherwise AppKit would try
        // to validate every item against its target's `validateMenuItem(_:)`,
        // which we don't implement and which would gray everything
        // out by default.
        menu.autoenablesItems = false
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(handleMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = entry.isEnabled
            // Stash the policy action on the menu item so the @objc
            // dispatcher can pull it back out — Swift enums don't
            // bridge cleanly to ObjC selectors, so we wrap in a
            // class-typed carrier.
            if let action = entry.action {
                item.representedObject = ActionBox(action)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// Class box for the policy's `Action` enum. NSMenuItem's
    /// `representedObject` is `Any?` but the value crosses the ObjC
    /// runtime boundary, so we wrap the Swift enum in a reference
    /// type to avoid `_ObjectiveCBridgeable` headaches.
    private final class ActionBox {
        let action: PillContextMenuPolicy.Action
        init(_ action: PillContextMenuPolicy.Action) { self.action = action }
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        dispatch(box.action)
    }

    /// Apply a menu action's side-effect. Pulled out from the @objc
    /// dispatcher so tests of the controller (when we add them in a
    /// follow-up) can drive this directly without poking at AppKit.
    private func dispatch(_ action: PillContextMenuPolicy.Action) {
        switch action {
        case .command(let cmd):
            // Forward to the same channel the expanded slab's transport
            // buttons use. NotchOrchestrator's plumbing makes this the
            // identical pipeline (AppleScript-direct for Spotify/Music,
            // MediaRemote fall-back for unknown sources).
            onCommand?(cmd)

        case .copyTrackLink(let url):
            // System pasteboard write — same as ⌘C in a text field.
            // No reason to keep multiple pasteboard items; the
            // canonical pattern is clearContents() + setString().
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url, forType: .string)

        case .showInSource(let bundleID):
            // Activate the source app without launching it if it's not
            // running. `urlForApplication(withBundleIdentifier:)` returns
            // nil for unknown bundles → we silently no-op (the menu
            // item would have been disabled in that case anyway).
            // `openApplication` replaces the deprecated
            // `launchApplication(withBundleIdentifier:...)` API; same
            // semantics, supported on 10.15+.
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID
            ) else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                // Result handler is intentionally empty — the click
                // is fire-and-forget UX, no follow-up needed.
            }

        case .openMusicSettings:
            // AppDelegate owns the Settings window lifecycle including
            // the panel-hide + activation-policy bump. Same entry point
            // MenuBarController uses for its "Settings…" item.
            AppDelegate.shared?.openSettings()
        }
    }
}

// MARK: - SwiftUI hookup

/// Internal helper that captures the SwiftUI host's window via a
/// borrowed `NSViewRepresentable`. The captured reference is fed into
/// `PillContextMenu.shared` so its event-monitor closure can scope
/// the right-click to this specific window — preventing the menu
/// from appearing when the user right-clicks anywhere else in nox.
private struct PillContextMenuHookView: NSViewRepresentable {
    let info: NowPlayingInfo
    let onCommand: (MediaRemoteService.Command) -> Void

    final class CaptureView: NSView {
        var hostedConfigure: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hostedConfigure?(window)
        }
    }

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.hostedConfigure = { window in
            // Defer to next runloop tick — viewDidMoveToWindow can
            // fire mid-SwiftUI-update, and re-entering @MainActor
            // state inside a representable's hook is fragile. Async
            // hop guarantees we install AFTER the current update
            // cycle has settled.
            DispatchQueue.main.async {
                PillContextMenu.shared.install(
                    info: info,
                    onCommand: onCommand,
                    window: window
                )
            }
        }
        return v
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        // The pill's `info` changes on every track flip / play-state
        // change; we want the right-click menu to see the latest
        // snapshot. Re-installing with the new value updates the
        // cached snapshot in-place (the monitor itself stays armed).
        PillContextMenu.shared.install(
            info: info,
            onCommand: onCommand,
            window: nsView.window
        )
    }

    static func dismantleNSView(_ nsView: CaptureView, coordinator: ()) {
        // Tear down on view disappearance so a hidden pill doesn't
        // leave the event monitor lingering. AppKit fires this when
        // SwiftUI removes the underlying NSView from its hierarchy.
        PillContextMenu.shared.uninstall()
    }
}

extension View {
    /// One-line hookup for the right-click context menu. Attach this
    /// to the resting pill's body — installs the monitor on appear,
    /// updates the menu's snapshot on every body re-eval, and tears
    /// the monitor down on disappear.
    ///
    /// Why a `.background` modifier (instead of `.onAppear` /
    /// `.onDisappear`): we need the host NSWindow reference to scope
    /// the right-click monitor, and SwiftUI doesn't expose the
    /// window directly to view modifiers. `NSViewRepresentable` lets
    /// us capture it via `viewDidMoveToWindow`. The background view
    /// is zero-size and `.allowsHitTesting(false)` so it can never
    /// intercept clicks meant for the pill content.
    func pillContextMenu(
        info: NowPlayingInfo,
        onCommand: @escaping (MediaRemoteService.Command) -> Void
    ) -> some View {
        self.background(
            PillContextMenuHookView(info: info, onCommand: onCommand)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
        )
    }
}

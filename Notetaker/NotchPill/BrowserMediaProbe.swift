import AppKit
import Foundation

/// Fallback "what's playing" detector for browsers when MediaRemote
/// is restricted (macOS 15.4+ revokes the private framework access
/// for unsigned third-party apps). Scans every running browser once
/// per tick, looks for a tab whose URL matches a known media site
/// (YouTube, SoundCloud, Twitch, Spotify Web, Apple Music Web), and
/// publishes that tab's title as the now-playing info.
///
/// Earlier versions only inspected the active tab of the frontmost
/// window of the frontmost app — which silently broke whenever
/// YouTube was playing in a background tab or background window.
/// User: "When I'm playing a YouTube video, the pill … nothing is
/// working." The full-scan path fixes that.
///
/// Once a tab is detected, its window/tab indices are remembered so
/// MusicPanelView can offer click-to-open ("jump to the YouTube
/// tab") and the transport buttons can drive playback by activating
/// the tab and synthesizing the page's keyboard shortcut (k for
/// play/pause, shift+n / shift+p for next/prev video).
@MainActor
final class BrowserMediaProbe {

    /// Bundle IDs we know how to interrogate, plus the AppleScript
    /// app name needed to address them via OSA.
    ///
    /// Dia (`company.thebrowser.dia`) uses the same Chromium-style
    /// tabs/windows AppleScript dictionary as Chrome / Arc / Edge —
    /// confirmed via Alcove's binary which addresses it as
    /// `tell application "Dia"`.
    private static let browserMap: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.apple.Safari": "Safari",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "org.mozilla.firefox": "Firefox" // doesn't expose tabs via AppleScript; skipped
    ]

    /// Probe interval — once every 1.5s. Slightly slower than the
    /// previous 1s because each tick now scans every running browser
    /// (instead of just the frontmost), and AppleScript dispatch is
    /// the dominant cost. 1.5s is still well under the threshold for
    /// the pill to feel "live."
    private let interval: TimeInterval = 1.5

    /// Latest synthesized info we've published. Used to skip
    /// duplicate publishes (so the pill doesn't redraw every poll).
    private var lastPublishedKey: String?

    /// Cached reference to the most-recently-detected audible tab.
    /// Consumed by `openAudibleTab` and `sendCommandToAudibleTab` so
    /// they don't need a fresh scan to act. Cleared when the scan
    /// stops finding anything.
    private(set) var lastAudibleTab: AudibleTabRef?

    /// Resolved by URL pattern. `windowIndex` and `tabIndex` are the
    /// 1-based AppleScript indices the activate script will use; if
    /// the tab moves around the user's reordering will desync these
    /// for one tick before the next scan rebinds them.
    struct AudibleTabRef {
        let bundleID: String
        let scriptName: String
        let windowIndex: Int
        let tabIndex: Int
        /// Lowercased URL — used to pick site-appropriate keystrokes
        /// (YouTube uses k/j/l, everything else uses spacebar +
        /// ←/→ as a generic HTML-video fallback).
        let urlLowercased: String
    }

    /// True if `bundleID` is one of the browsers we know how to drive
    /// via AppleScript. Used by the orchestrator to decide whether
    /// it's worth kicking off a title-based tab scan after a
    /// MediaRemote publish (no point trying for Spotify or Music).
    /// Excludes Firefox — its AppleScript dictionary doesn't expose
    /// tabs, so even though we list it for documentation we can't
    /// drive it.
    static func isKnownBrowser(bundleID: String) -> Bool {
        guard let name = browserMap[bundleID] else { return false }
        return name != "Firefox"
    }

    private var timer: Timer?
    var onChange: ((NowPlayingInfo?) -> Void)?

    func start() {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        // Add to .common modes so the timer keeps firing even when
        // the user has menus or scroll-tracking active. The default
        // .scheduledTimer adds to .default mode only, which can
        // suspend the timer during system UI interactions.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSLog("nox: BrowserMediaProbe started (interval=\(interval)s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Optional gate set by the orchestrator. When MediaRemote is
    /// publishing real data we don't want to clobber it with our
    /// AppleScript-derived fallback.
    var isMediaRemoteSilent: Bool = true

    private func tick() {
        if !isMediaRemoteSilent { return }

        // Snapshot the running-browser list on main (NSRunningApplication
        // queries hit AppKit state), then hand the actual AppleScript
        // scans off to a background queue. The synchronous
        // `executeAndReturnError` calls block whatever thread runs
        // them for 50–200ms each — running on main here was visibly
        // hitching the panel open animation every 1.5s. The result
        // hops back to main to update lastAudibleTab and call onChange.
        let frontmostBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let runningBrowsers = NSWorkspace.shared.runningApplications.filter { app in
            guard let bid = app.bundleIdentifier else { return false }
            guard let name = Self.browserMap[bid], name != "Firefox" else { return false }
            return true
        }
        let ordered = runningBrowsers.sorted { a, _ in
            a.bundleIdentifier == frontmostBundle
        }
        // Capture lightweight metadata on main; pass to background.
        let candidates: [(bundleID: String, scriptName: String, displayName: String)] = ordered.compactMap { app in
            guard let bid = app.bundleIdentifier,
                  let scriptName = Self.browserMap[bid] else { return nil }
            return (bid, scriptName, app.localizedName ?? bid)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for candidate in candidates {
                if let detection = self.findAudibleTab(in: candidate.scriptName) {
                    DispatchQueue.main.async {
                        self.lastAudibleTab = AudibleTabRef(
                            bundleID: candidate.bundleID,
                            scriptName: candidate.scriptName,
                            windowIndex: detection.window,
                            tabIndex: detection.tab,
                            urlLowercased: detection.url.lowercased()
                        )
                        self.publishFromBackground(
                            bundleID: candidate.bundleID,
                            displayName: candidate.displayName,
                            title: detection.title
                        )
                    }
                    return
                }
            }
            // Nothing matched on any browser — clear our slot.
            DispatchQueue.main.async {
                if self.lastPublishedKey != nil {
                    self.lastPublishedKey = nil
                    self.lastAudibleTab = nil
                    self.onChange?(nil)
                }
            }
        }
    }

    /// Publish path used by the new background-thread tick. The
    /// app's display name was snapshotted on main before the
    /// background AppleScript scan started, so we don't need to
    /// touch NSRunningApplication here.
    private func publishFromBackground(bundleID: String, displayName: String, title: String) {
        let cleaned = Self.cleanTitle(title)
        let key = "\(bundleID)|\(cleaned)"
        if key == lastPublishedKey { return }
        lastPublishedKey = key

        let info = NowPlayingInfo(
            title: cleaned,
            artist: displayName,
            album: nil,
            artworkData: nil,
            isPlaying: true,
            sourceBundleID: bundleID,
            duration: nil,
            elapsedTime: nil,
            infoTimestamp: Date()
        )
        NSLog("nox: BrowserMediaProbe → \(bundleID) title=\"\(cleaned)\"")
        onChange?(info)
    }

    // MARK: - Tab activation / keystroke

    /// Bring the most-recently-detected audible tab to the front. Used
    /// by MusicPanelView's click-on-artwork affordance for browser-
    /// sourced audio. Returns false if no audible tab is currently
    /// known (caller falls back to plain NSWorkspace open).
    @discardableResult
    func openAudibleTab() -> Bool {
        guard let ref = lastAudibleTab else { return false }
        return runActivateScript(ref: ref, keystroke: nil)
    }

    /// Activate the audible tab and synthesize the page's keystroke
    /// for the given transport command. Returns false if no audible
    /// tab is known (caller falls back to MediaRemote).
    @discardableResult
    func sendCommandToAudibleTab(_ command: MediaRemoteService.Command) -> Bool {
        guard let ref = lastAudibleTab else { return false }
        guard let stroke = keystroke(for: command, ref: ref) else { return false }
        return runActivateScript(ref: ref, keystroke: stroke)
    }

    /// What to type at the page once it's focused. YouTube has
    /// well-known shortcuts (k/j/l/shift+n/shift+p). For unknown
    /// sites, fall back to spacebar (HTML5 video play/pause when the
    /// player has focus) and arrow keys for seek.
    private func keystroke(for command: MediaRemoteService.Command, ref: AudibleTabRef) -> Keystroke? {
        let isYouTube = ref.urlLowercased.contains("youtube.com") ||
                        ref.urlLowercased.contains("music.youtube.com")
        switch command {
        case .togglePlayPause, .play, .pause:
            return isYouTube ? Keystroke(key: "k", shift: false) : Keystroke(key: " ", shift: false)
        case .next:
            return isYouTube ? Keystroke(key: "n", shift: true) : Keystroke(keyCode: 124, shift: false) // right arrow
        case .previous:
            return isYouTube ? Keystroke(key: "p", shift: true) : Keystroke(keyCode: 123, shift: false) // left arrow
        case .stop:
            return nil
        case .toggleShuffle:
            // No standard shuffle keystroke for browser-based media
            // (YouTube's "shuffle" depends on the playlist context).
            // Skip — MediaRemoteService still routes through to the
            // private command for non-browser apps.
            return nil
        }
    }

    private struct Keystroke {
        var key: String? = nil
        var keyCode: Int? = nil
        var shift: Bool

        init(key: String, shift: Bool) {
            self.key = key
            self.shift = shift
        }
        init(keyCode: Int, shift: Bool) {
            self.keyCode = keyCode
            self.shift = shift
        }
    }

    nonisolated private func runActivateScript(ref: AudibleTabRef, keystroke: Keystroke?) -> Bool {
        let activatePart: String
        if ref.scriptName == "Safari" {
            activatePart = """
            tell application "Safari"
                activate
                tell window \(ref.windowIndex)
                    set current tab to tab \(ref.tabIndex)
                    set index to 1
                end tell
            end tell
            """
        } else {
            activatePart = """
            tell application "\(ref.scriptName)"
                activate
                set active tab index of window \(ref.windowIndex) to \(ref.tabIndex)
                set index of window \(ref.windowIndex) to 1
            end tell
            """
        }

        var script = activatePart
        if let stroke = keystroke {
            // Small delay so System Events sends the key after the
            // browser has actually become frontmost. 0.18s is the
            // smallest value that's reliable across Chrome / Arc /
            // Safari on M-series macs in informal testing.
            let strokeLine: String
            if let key = stroke.key {
                let escaped = key.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
                if stroke.shift {
                    strokeLine = "keystroke \"\(escaped)\" using shift down"
                } else {
                    strokeLine = "keystroke \"\(escaped)\""
                }
            } else if let code = stroke.keyCode {
                if stroke.shift {
                    strokeLine = "key code \(code) using shift down"
                } else {
                    strokeLine = "key code \(code)"
                }
            } else {
                return false
            }
            script += """

            delay 0.18
            tell application "System Events"
                \(strokeLine)
            end tell
            """
        }

        var error: NSDictionary?
        guard let osa = NSAppleScript(source: script) else { return false }
        _ = osa.executeAndReturnError(&error)
        if let error {
            FileHandle.standardError.write("BROWSERPROBE: activate/keystroke script failed: \(error)\n".data(using: .utf8)!)
            return false
        }
        return true
    }

    // MARK: - Audible tab discovery

    /// Find the first tab in this browser whose URL matches a known
    /// media site. Returns 1-based window/tab indices plus the title
    /// and URL we matched against. AppleScript-only; no JavaScript-
    /// from-Apple-Events flag required.
    nonisolated private func findAudibleTab(in appScriptName: String) -> (window: Int, tab: Int, title: String, url: String)? {
        let titleProperty: String
        let tabRef: String
        if appScriptName == "Safari" {
            titleProperty = "name"
            tabRef = "tab T of window W"
        } else {
            titleProperty = "title"
            tabRef = "tab T of window W"
        }

        // Returns either "" (nothing playing) or a payload string
        // "W|T|title|URL" — split on the first three pipes so titles
        // containing "|" survive.
        let script = """
        tell application "\(appScriptName)"
            if (count of windows) is 0 then return ""
            repeat with W from 1 to count of windows
                repeat with T from 1 to count of tabs of window W
                    try
                        set tURL to URL of \(tabRef)
                    on error
                        set tURL to ""
                    end try
                    set tURLlower to my toLower(tURL)
                    if tURLlower contains "youtube.com/watch" or ¬
                       tURLlower contains "music.youtube.com" or ¬
                       tURLlower contains "soundcloud.com/" or ¬
                       tURLlower contains "twitch.tv/" or ¬
                       tURLlower contains "open.spotify.com/" or ¬
                       tURLlower contains "music.apple.com" or ¬
                       tURLlower contains "vimeo.com/" then
                        try
                            set tTitle to \(titleProperty) of \(tabRef)
                        on error
                            set tTitle to ""
                        end try
                        return (W as string) & "|" & (T as string) & "|" & tTitle & "|" & tURL
                    end if
                end repeat
            end repeat
            return ""
        end tell

        on toLower(s)
            set lower to ""
            repeat with c in s
                set ascii to id of c
                if ascii ≥ 65 and ascii ≤ 90 then
                    set lower to lower & character id (ascii + 32)
                else
                    set lower to lower & c
                end if
            end repeat
            return lower
        end toLower
        """

        var error: NSDictionary?
        guard let osa = NSAppleScript(source: script) else { return nil }
        let result = osa.executeAndReturnError(&error)
        if let error {
            // -1743 = TCC denied for this browser. The user gets
            // prompted on first probe; if they declined, we'll keep
            // hitting this. Log once-ish via stderr (not NSLog, which
            // gets <private>-redacted).
            let msg = "BROWSERPROBE: scan failed for \(appScriptName): \(error)\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
            return nil
        }
        guard let payload = result.stringValue, !payload.isEmpty else { return nil }
        let parts = payload.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let w = Int(parts[0]),
              let t = Int(parts[1])
        else { return nil }
        return (window: w, tab: t, title: String(parts[2]), url: String(parts[3]))
    }

    // MARK: - Title-based tab discovery (MediaRemote-driven)

    /// Find the first tab in `bundleID`'s browser whose title contains
    /// `titleHint`, then update `lastAudibleTab` so subsequent
    /// `openAudibleTab` / `sendCommandToAudibleTab` calls land on the
    /// exact tab that's actually playing the audio.
    ///
    /// Why this is needed even though we already have `findAudibleTab`:
    /// the URL-pattern scanner only runs when MediaRemote is silent
    /// (it's the fallback path). When MediaRemote IS publishing — the
    /// common case for a YouTube tab — the orchestrator knows the
    /// browser bundle and the song title, but doesn't know WHICH tab.
    /// Without this, "click the pill to jump back to my video" just
    /// activates Chrome at whatever tab was most recently focused.
    ///
    /// Title matching is what Alcove does (decoded from their binary:
    /// `if (title of t as text) contains "<song>"`). It correctly
    /// identifies the actually-playing tab even when the user has
    /// 10 other YouTube tabs open. URL-pattern matching can't do
    /// that — it'd just pick the first YouTube tab.
    ///
    /// Runs the AppleScript on a background queue (same pattern as
    /// `tick`); calls back to main to assign `lastAudibleTab`.
    /// `completion` fires on main when the scan completes (true if
    /// a tab was found and stored).
    func refreshAudibleTab(forBundleID bundleID: String, titleHint: String, completion: ((Bool) -> Void)? = nil) {
        guard let scriptName = Self.browserMap[bundleID], scriptName != "Firefox" else {
            completion?(false)
            return
        }
        // Strip suffix junk so "Cruel Summer - YouTube" matches a tab
        // titled "(2) Cruel Summer - Taylor Swift - YouTube" by the
        // shared "Cruel Summer" core.
        let needle = Self.cleanTitle(titleHint)
        guard !needle.isEmpty else {
            completion?(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let detection = self.findTabByTitle(in: scriptName, needle: needle)
            DispatchQueue.main.async {
                if let detection {
                    self.lastAudibleTab = AudibleTabRef(
                        bundleID: bundleID,
                        scriptName: scriptName,
                        windowIndex: detection.window,
                        tabIndex: detection.tab,
                        urlLowercased: detection.url.lowercased()
                    )
                    completion?(true)
                } else {
                    completion?(false)
                }
            }
        }
    }

    /// Background-queue worker for the title-based scan. Mirrors the
    /// shape of `findAudibleTab` so error handling is consistent.
    /// Returns nil if no tab matches or if AppleScript was denied
    /// (TCC error -1743 — same as the URL scanner).
    nonisolated private func findTabByTitle(in appScriptName: String, needle: String) -> (window: Int, tab: Int, title: String, url: String)? {
        let titleProperty = appScriptName == "Safari" ? "name" : "title"
        let tabRef = "tab T of window W"
        // Escape for AppleScript string literal (backslash, quote).
        // Newlines and control chars are uncommon in song titles but
        // we strip them to be safe.
        let escaped = needle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let script = """
        tell application "\(appScriptName)"
            if (count of windows) is 0 then return ""
            repeat with W from 1 to count of windows
                repeat with T from 1 to count of tabs of window W
                    try
                        set tTitle to \(titleProperty) of \(tabRef)
                    on error
                        set tTitle to ""
                    end try
                    if tTitle contains "\(escaped)" then
                        try
                            set tURL to URL of \(tabRef)
                        on error
                            set tURL to ""
                        end try
                        return (W as string) & "|" & (T as string) & "|" & tTitle & "|" & tURL
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """

        var error: NSDictionary?
        guard let osa = NSAppleScript(source: script) else { return nil }
        let result = osa.executeAndReturnError(&error)
        if let error {
            let msg = "BROWSERPROBE: title scan failed for \(appScriptName): \(error)\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
            return nil
        }
        guard let payload = result.stringValue, !payload.isEmpty else { return nil }
        let parts = payload.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let w = Int(parts[0]),
              let t = Int(parts[1])
        else { return nil }
        return (window: w, tab: t, title: String(parts[2]), url: String(parts[3]))
    }

    private static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading "(N) " notification badge.
        if t.hasPrefix("(") {
            if let close = t.firstIndex(of: ")") {
                let after = t.index(after: close)
                if after < t.endIndex && t[after] == " " {
                    t = String(t[t.index(after: after)...])
                }
            }
        }
        let suffixes = [" - YouTube", " — YouTube", " | YouTube",
                        " - SoundCloud", " | SoundCloud",
                        " - Twitch", " | Twitch",
                        " - Spotify", " | Spotify",
                        " - Apple Music", " | Apple Music",
                        " on Vimeo"]
        for suffix in suffixes {
            if t.hasSuffix(suffix) {
                t = String(t.dropLast(suffix.count))
                break
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

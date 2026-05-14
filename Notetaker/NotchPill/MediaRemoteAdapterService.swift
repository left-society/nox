import AppKit
import Foundation

/// Bridge to `ungive/mediaremote-adapter` — the canonical macOS
/// 15.4+ workaround for reading Now-Playing info from MediaRemote
/// once Apple tightened the entitlement check.
///
/// **Why this exists**: Console.app shows this error in our process
/// when we call `MRMediaRemoteGetNowPlayingInfo` directly:
/// ```
/// Error Domain=kMRMediaRemoteFrameworkErrorDomain Code=3
/// "Operation not permitted"
/// ```
/// Our app lacks the `com.apple.private.mediaremote` entitlement, so
/// the system blocks `playbackQueue` reads. We can still SEND
/// commands (TogglePlayPause works fine), but we can't READ what's
/// playing — including no artwork bytes for Spotify, no metadata
/// for browser tabs that have a MediaSession.
///
/// **The workaround**: `/usr/bin/perl` IS entitled. The
/// `mediaremote-adapter` project ships a Perl script + Objective-C
/// framework. We spawn perl as a subprocess with the script + the
/// framework path, and it runs in stream mode emitting JSON-lines
/// to stdout — one JSON object per now-playing change. The bytes
/// flow through the Perl process boundary and reach us as plain
/// stdout data.
///
/// Every modern open-source notch HUD (boring.notch, Atoll,
/// DynamicNotch) integrates this same wrapper for the same reason.
///
/// **Lifecycle**: spawned on `start()`, terminated on `stop()` /
/// deinit. The subprocess runs for the lifetime of the app —
/// reusing one long-lived stream is the canonical pattern (vs
/// spawning per-poll).
///
/// **Output stream**: each line on stdout is a JSON object. Fields
/// match the adapter's `NowPlayingPayload` struct. Type-decoded
/// to `AdapterPayload` below.
///
/// **Bundle setup required**:
///   1. `mediaremote-adapter.pl` is bundled at
///      `Notetaker/Resources/mediaremote-adapter/mediaremote-adapter.pl`
///   2. `MediaRemoteAdapter.framework` at
///      `Notetaker/Resources/mediaremote-adapter/MediaRemoteAdapter.framework`
///   3. Both must be in the Xcode project's "Copy Bundle Resources"
///      build phase so they end up in `Notetaker.app/Contents/Resources/`
///      at runtime.
@MainActor
final class MediaRemoteAdapterService {
    /// Wrapper envelope emitted by `mediaremote-adapter.pl` stream
    /// mode. Each line on stdout is `{"type":"data","diff":bool,"payload":{...}}`.
    /// I missed this on first pass and the inner-payload decoder
    /// was failing silently on every emit (the AdapterPayload
    /// expected the top-level fields directly). This envelope
    /// matches the upstream Perl wrapper's actual output.
    struct AdapterMessage: Codable {
        let type: String?
        let diff: Bool?
        let payload: AdapterPayload?
    }

    /// JSON payload structure emitted by `mediaremote-adapter.pl` in
    /// stream mode. Field names match the Perl wrapper's output —
    /// see `src/adapter/stream.m` in the upstream repo for canonical
    /// field set. All Optional because partial updates omit fields
    /// the adapter hasn't observed yet.
    struct AdapterPayload: Codable {
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTime: Double?
        let shuffleMode: Int?
        let repeatMode: Int?
        /// Base64-encoded JPEG bytes when the source provides
        /// artwork. Decoded into `Data` before being passed up.
        let artworkData: String?
        let artworkMimeType: String?
        /// ISO 8601 timestamp string of the snapshot.
        let timestamp: String?
        let playbackRate: Double?
        let playing: Bool?
        /// Bundle ID of the source app. For Spotify this is
        /// `com.spotify.client`; for Apple Music `com.apple.Music`.
        /// Browsers (Chrome, Safari) only populate this if the page
        /// has an active MediaSession — most YouTube tabs do not.
        let parentApplicationBundleIdentifier: String?
        let bundleIdentifier: String?
        let processIdentifier: Int?
    }

    /// Closure invoked when the adapter publishes a new snapshot.
    /// Wired by `NotchOrchestrator` to feed the existing
    /// `MediaRemoteService.publish()` pipeline.
    var onSnapshot: ((NowPlayingInfo?) -> Void)?

    /// True once `start()` succeeded and the perl subprocess is
    /// running. Public so callers can check before falling back
    /// to the dlsym path.
    private(set) var isRunning: Bool = false

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    /// Buffer for partial JSON lines that arrive split across
    /// multiple read events. We scan for newline boundaries and
    /// only decode complete lines.
    private var lineBuffer = Data()

    // MARK: - Lifecycle

    /// Start the perl subprocess and begin reading the stream.
    /// Returns false if the bundled resources are missing — caller
    /// should fall back to the dlsym MediaRemote path or distributed
    /// notifications.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }

        // Locate bundled resources. Both must be inside the .app's
        // Resources directory; the build's "Copy Bundle Resources"
        // phase puts them there.
        guard let resourceURL = Bundle.main.resourceURL else {
            NSLog("nox: MRA — Bundle.main.resourceURL is nil")
            return false
        }
        // Resolve resource paths. Xcode's "Copy Bundle Resources"
        // phase flattens paths by default, so the .pl + .framework
        // land at the Resources root rather than in a subfolder.
        // Try both locations so a future migration to a Copy-Files
        // phase that preserves structure won't break the lookup.
        func resolve(_ name: String) -> URL? {
            let flat = resourceURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
            let nested = resourceURL
                .appendingPathComponent("mediaremote-adapter")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
            return nil
        }
        guard let scriptURL = resolve("mediaremote-adapter.pl") else {
            NSLog("nox: MRA — script not found in Resources/")
            return false
        }
        guard let frameworkURL = resolve("MediaRemoteAdapter.framework") else {
            NSLog("nox: MRA — framework not found in Resources/")
            return false
        }

        // Spawn /usr/bin/perl with the script and framework path.
        // Stream mode keeps the process alive emitting JSON lines.
        //
        // 2026-04-29: dropped --debounce 150 → 50. The 150ms
        // smoothed Spotify's title/artist/artwork burst into a
        // single event but added noticeable lag for podcast
        // start ("loads but too late"). 50ms is enough to
        // collapse the artwork-arrives-200ms-after-title burst
        // for Spotify (it's measured at ~80ms gap typically)
        // without the user-visible delay on track start.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // CRITICAL: `--no-diff` makes every emission a FULL snapshot.
        //
        // Without this flag, the adapter's default behaviour is to
        // emit only the fields that changed since the last emission
        // for the same track. Spotify's first emission for a track
        // carries title+artist+elapsedTime+timestamp+duration+playing;
        // every subsequent emission for the same track carries only
        // the diff (often just `playing`, or nothing useful at all
        // when the change was internal to MediaRemote). Our
        // `AdapterPayload` decoder treats missing fields as `nil`
        // and the translator drops emissions where title/artist
        // are nil — so every diff frame got swallowed, leaving the
        // FIRST snapshot's `infoTimestamp` and `elapsedTime` frozen
        // forever in `presenter.nowPlaying`. `currentPosition()`
        // then extrapolates `elapsed + (now - frozen_timestamp)`,
        // which after a few minutes clamps at `duration` — exactly
        // the screenshot bug ("bar at 100%, song actually at 0:21").
        //
        // With `--no-diff`, EVERY emission is a complete snapshot,
        // so the timestamp re-anchors on every tick and the bar
        // tracks the actual playback. This is what
        // ungive/mediaremote-adapter's README + every working
        // open-source notch HUD (boring.notch, DynamicNotch,
        // Alcove via process inspection) does.
        //
        // Bandwidth cost: artwork bytes resend on every emission
        // for the same track — adds ~150 KB/s while a track plays.
        // Acceptable; we already cap on infrequent debounce.
        process.arguments = [
            scriptURL.path,
            frameworkURL.path,
            "stream",
            "--no-diff",
            "--debounce=50"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout incrementally — JSON lines arrive whenever
        // the source app publishes a metadata change. The handler
        // accumulates partial bytes in `lineBuffer` and decodes
        // complete lines on every newline.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                self?.handleStdoutChunk(chunk)
            }
        }
        // Stderr — log everything for diagnostics. The adapter
        // writes warnings here when MediaRemote denies a request
        // or when JSON decode fails.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let str = String(data: chunk, encoding: .utf8) else { return }
            NSLog("nox: MRA stderr: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        process.terminationHandler = { [weak self] proc in
            NSLog("nox: MRA perl exited status=\(proc.terminationStatus) reason=\(proc.terminationReason.rawValue)")
            Task { @MainActor in
                self?.isRunning = false
            }
        }

        do {
            try process.run()
        } catch {
            NSLog("nox: MRA failed to spawn perl: \(error)")
            return false
        }

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.isRunning = true
        NSLog("nox: MRA started (pid=\(process.processIdentifier))")
        return true
    }

    // MARK: - Sending commands

    /// Resolved paths to the bundled adapter resources, captured on
    /// `start()`. We hold them so `send()` doesn't repeat the
    /// Bundle-lookup dance per command. Re-resolved each `start()`
    /// in case the .app moved between launches.
    private var resolvedScriptURL: URL?
    private var resolvedFrameworkURL: URL?

    /// Send a one-shot media command via the entitled Perl helper.
    ///
    /// The streaming `start()` Process is read-only; we spawn a
    /// short-lived perl invocation per command instead of trying to
    /// stuff input into the long-lived stream. ~30ms per call,
    /// fire-and-forget — much faster than a user can press another
    /// button, no queueing concerns in practice.
    ///
    /// **Why this exists**: as of macOS 15.4 the OS gates
    /// `MRMediaRemoteSendCommand` against the
    /// `com.apple.private.mediaremote` entitlement that only Apple
    /// system processes carry. Loading MediaRemote.framework directly
    /// from this app and calling sendCommand returns silently —
    /// `mediaremoted` drops the request. The bundled `mediaremote-adapter.pl`
    /// runs under `/usr/bin/perl`, which IS entitled, so commands sent
    /// from inside it reach the daemon and route to whatever app owns
    /// the active Now Playing session — including YouTube/SoundCloud/
    /// any browser tab that publishes Media Session, plus Spotify and
    /// Apple Music.
    ///
    /// Result: a single send() route works for every source the
    /// adapter can already display. No Accessibility permission,
    /// no per-browser AppleScript, no foreground-app flash.
    ///
    /// Returns true if the subprocess launched (not whether the
    /// command was actually accepted by the source — Perl exits 0
    /// either way; failure modes are silent in mediaremoted itself).
    @discardableResult
    func send(_ command: MediaRemoteService.Command) -> Bool {
        guard let scriptURL = resolvedScriptURL ?? bundleResolvedScriptURL(),
              let frameworkURL = resolvedFrameworkURL ?? bundleResolvedFrameworkURL() else {
            NSLog("nox: MRA send(\(command)) — adapter resources not found, dropping command")
            return false
        }
        // Cache for next call.
        resolvedScriptURL = scriptURL
        resolvedFrameworkURL = frameworkURL

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            scriptURL.path,
            frameworkURL.path,
            "send",
            String(command.rawValue)
        ]
        // Discard stdout/stderr — `send` mode emits nothing useful
        // on success, and we don't want a stalled pipe holding
        // the subprocess open.
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null") ?? Pipe()
        process.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? Pipe()

        do {
            try process.run()
            // Don't waitUntilExit — let it complete in the background.
            // Subprocess is short-lived (~30ms) and nothing depends on
            // the result. Holding the main actor here would defeat
            // the whole point of this being snappy.
            Self.fileLog("MRA send command=\(command) (\(command.rawValue))")
            return true
        } catch {
            NSLog("nox: MRA send(\(command)) — failed to spawn perl: \(error)")
            return false
        }
    }

    /// Re-run the same Bundle path resolution `start()` does.
    /// Pulled out so `send()` works even if called before `start()`
    /// (defensive — orchestrator should always start the streamer
    /// first, but cheap to handle the out-of-order case).
    private func bundleResolvedScriptURL() -> URL? {
        return bundleResolve("mediaremote-adapter.pl")
    }
    private func bundleResolvedFrameworkURL() -> URL? {
        return bundleResolve("MediaRemoteAdapter.framework")
    }
    private func bundleResolve(_ name: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let flat = resourceURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: flat.path) { return flat }
        let nested = resourceURL
            .appendingPathComponent("mediaremote-adapter")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        return nil
    }

    // MARK: - Lifecycle (cont'd)

    /// Terminate the subprocess and drop all state. Idempotent —
    /// safe to call when not running.
    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        lineBuffer.removeAll()
        isRunning = false
    }

    deinit {
        // Process is bound to its own lifetime; SIGTERM it via
        // weak reference cleanup. Can't call MainActor `stop()` from
        // deinit (which isn't isolated), so do the bare-bones
        // termination here.
        process?.terminate()
    }

    // MARK: - Stream parsing

    /// Accumulate stdout bytes and decode any newline-terminated
    /// JSON objects. Partial trailing bytes stay buffered until
    /// the next chunk completes the line.
    private func handleStdoutChunk(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIndex)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            handleLine(lineData)
        }
    }

    /// Decode one complete JSON line into an AdapterMessage,
    /// extract its inner payload, translate to NowPlayingInfo,
    /// publish via `onSnapshot`. Lines with `type != "data"` (e.g.
    /// the adapter's diagnostic / ready messages) are skipped.
    private func handleLine(_ data: Data) {
        guard !data.isEmpty else { return }
        let message: AdapterMessage
        do {
            message = try JSONDecoder().decode(AdapterMessage.self, from: data)
        } catch {
            return
        }
        guard message.type == "data", let payload = message.payload else {
            return
        }

        // 2026-05-13 — browser tab-title pollution filter.
        //
        // Bug repro from /tmp/nox-mra.log:
        //
        //   01:30:26 MRA snapshot: bundle=com.spotify.client title="Opalite" ...
        //   01:30:55 MRA snapshot: bundle=com.google.Chrome title="Subedit:
        //            Viral style captions for shorts, reels and TikTok"
        //            artist="" art=0b
        //   01:30:58 updatePillVisibility: ... mrSaysPlaying=false
        //            effectivelyPlaying=false
        //   → Spotify still playing, but pill hides.
        //
        // Chrome (and other modern browsers) register a MediaRemote
        // session for EVERY tab that has a <title> — even tabs with
        // no <audio>/<video> and no MediaSession metadata at all.
        // When the user opens such a tab, MR's "active session"
        // flips from Spotify (which is still playing in the
        // background) to Chrome (the new tab). Chrome's session
        // has only the tab's page title — empty artist, no
        // artwork — and when the tab navigates/closes it emits
        // `isPlaying=false`. Our prior logic trusted MR's authority
        // and hid the pill, even though Spotify was still streaming.
        //
        // The signature is highly specific: a browser bundle ID
        // + entirely-empty `artist` + entirely-empty `artworkData`
        // (the raw base64 string, before the post-translate
        // fallback fills artist with "Chrome"). Real media plays
        // ALWAYS provide at least one of these — YouTube videos
        // have channel names + thumbnails, SoundCloud has artist
        // names + cover art, Spotify Web has both, even bare
        // <audio> tags can set MediaSession metadata. The empty-
        // empty signature uniquely identifies tab-title noise.
        //
        // What "suppress" means here: we return WITHOUT calling
        // `onSnapshot`. That is critical — calling `onSnapshot(nil)`
        // would clear `presenter.nowPlaying`, dropping the real
        // Spotify metadata that the pill needs. Suppression keeps
        // the prior good snapshot cached. `lastAdapterEmitAt`
        // doesn't get bumped downstream either, so the
        // DistributedNotification path stays unblocked for Spotify
        // updates that DO arrive while Chrome is registered.
        //
        // Worst-case false positive: a Chrome tab plays audio
        // without setting any MediaSession metadata (bare <audio>
        // tag, dev page). We drop the snapshot, but SystemAudioWatcher
        // will still pick up Chrome's CoreAudio output and synthesize
        // a "Google Chrome" snapshot. Pill shows the app name
        // instead of the page title — slightly degraded but
        // acceptable, and rare.
        let resolvedBundle = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier
        let rawArtistEmpty = (payload.artist ?? "").isEmpty
        let rawArtworkEmpty = (payload.artworkData ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if let bundle = resolvedBundle,
           Self.browserBundlesWithStaleSessions.contains(bundle),
           rawArtistEmpty,
           rawArtworkEmpty {
            Self.fileLog("MRA suppress: browser tab-title pollution from \(bundle) — title=\"\(payload.title ?? "")\" isPlaying=\(payload.playing ?? false)")
            return
        }

        let info = translate(payload)
        Self.fileLog("MRA snapshot: bundle=\(payload.bundleIdentifier ?? "nil") title=\"\(payload.title ?? "")\" artist=\"\(payload.artist ?? "")\" art=\(payload.artworkData?.count ?? 0)b → out art=\(info?.artworkData?.count ?? 0)b")
        onSnapshot?(info)
    }

    /// Browser bundle IDs whose MediaRemote sessions are known to
    /// pollute the now-playing slot with bare tab titles when the
    /// user opens a tab without media. Cross-checked against the
    /// real-media-with-metadata case via the empty-artist + empty-
    /// artwork signature in `handleLine`.
    private static let browserBundlesWithStaleSessions: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "company.thebrowser.Browser", // Arc
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    /// Diagnostic file logger to /tmp/nox-mra.log. Re-enabled
    /// 2026-04-29 to trace why Spotify thumbnails aren't reaching
    /// the pill. Will be reset to no-op once we find the drop point.
    static func fileLog(_ message: String) {
        let path = "/tmp/nox-mra.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Convert the adapter's payload struct to our existing
    /// NowPlayingInfo type. nil-out for empty session ("nothing
    /// playing") signals — the caller's grace-period guard will
    /// debounce these.
    private func translate(_ payload: AdapterPayload) -> NowPlayingInfo? {
        var title = payload.title ?? ""
        var artist = payload.artist ?? ""
        let isPlaying = payload.playing ?? false

        // Decode base64 artwork string back to bytes when present.
        // The adapter strips whitespace already, but we trim defensively
        // since some Perl encoders insert line breaks at 76-char columns.
        let artworkData: Data?
        if let b64 = payload.artworkData, !b64.isEmpty {
            let cleaned = b64.trimmingCharacters(in: .whitespacesAndNewlines)
            artworkData = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters)
        } else {
            artworkData = nil
        }

        // Empty payload + not playing → signal "nothing playing"
        // by returning nil. The orchestrator's existing grace-period
        // guard treats this as a deferred clear.
        if title.isEmpty && artist.isEmpty && !isPlaying && artworkData == nil {
            return nil
        }

        // SPARSE-PAYLOAD FALLBACKS (2026-04-29). Apple Podcasts
        // sometimes emits payloads with album/artwork/bundle but
        // no title — verified via direct Perl-bridge capture. Without
        // a title the upstream `isPresentable` check rejects the
        // info and the user sees "Nothing playing" even though a
        // podcast is loaded. Synthesize useful defaults from what
        // we DO have so the slab always shows something meaningful:
        //   • Title falls back to album (often the episode date or
        //     show name for podcasts)
        //   • Artist falls back to the localized app name when we
        //     can resolve it from the bundle ID
        let source = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier
        if title.isEmpty {
            if let album = payload.album, !album.isEmpty {
                title = album
            } else if let bundle = source, let name = appName(forBundleID: bundle) {
                title = name
            }
        }
        if artist.isEmpty, let bundle = source, let name = appName(forBundleID: bundle) {
            artist = name
        }

        // Parse ISO 8601 timestamp into Date for elapsed-time math.
        let timestamp: Date?
        if let ts = payload.timestamp, !ts.isEmpty {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        } else {
            timestamp = nil
        }

        // (Source bundle ID was already resolved above for the
        // sparse-payload fallback. Re-using it here.)

        return NowPlayingInfo(
            title: title,
            artist: artist,
            album: payload.album,
            artworkData: artworkData,
            isPlaying: isPlaying,
            sourceBundleID: source,
            duration: payload.duration,
            elapsedTime: payload.elapsedTime,
            infoTimestamp: timestamp
        )
    }

    /// Resolve a bundle ID to its localized display name via
    /// LaunchServices. Used as a sparse-payload fallback so the
    /// HUD can show "Apple Podcasts" / "Music" / "Spotify" when
    /// MediaRemote omits title/artist for a particular emission.
    /// Returns nil for unknown bundles so the caller can decide
    /// whether to show a placeholder.
    private func appName(forBundleID bundleID: String) -> String? {
        // Hardcoded shortcuts for the apps the adapter sees most
        // often — saves a LaunchServices roundtrip on the hot
        // path. Fall through to NSWorkspace for everything else.
        switch bundleID {
        case "com.apple.podcasts": return "Apple Podcasts"
        case "com.apple.Music": return "Apple Music"
        case "com.spotify.client": return "Spotify"
        case "com.apple.Safari": return "Safari"
        case "com.google.Chrome": return "Chrome"
        case "company.thebrowser.Browser": return "Arc"
        default: break
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else {
            return nil
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name
    }
}

import AppKit
import CoreAudio
import Foundation

/// Universal "what app is producing audio right now" detector. Uses
/// CoreAudio's process object APIs (macOS 14.2+, no entitlement)
/// to enumerate all processes that are currently outputting audio,
/// pick the most relevant one, and publish a synthesized
/// `NowPlayingInfo` so the pill shows the app's name and icon.
///
/// User: "see the source and get the thumbnail for it and where
/// from. I think that's the easiest way, because right now nothing
/// is working." This bypasses MediaRemote (restricted on this
/// macOS) entirely — instead of asking "what TRACK is playing?"
/// (which only Spotify and Apple Music answer reliably), we ask
/// "what APP is producing audio right now?" and that works for
/// EVERY audio source: YouTube in Chrome, WhatsApp audio, Discord
/// calls, VLC, IINA, Music.app, anything.
///
/// Trade-off: we don't know the track title (Chrome doesn't give
/// us "Sakamoto Days [AMV]" from CoreAudio — that's only available
/// via DOM scraping). But we DO know the app, and the existing
/// MusicPanelView fallback shows the app icon as the artwork
/// thumbnail. Click-to-open jumps straight to whichever app is
/// playing, which was the user's main ask.
@MainActor
final class SystemAudioWatcher {
    var onChange: ((NowPlayingInfo?) -> Void)?

    /// Fired whenever the "is any user-facing app outputting audio
    /// right now?" signal flips. Updated on every tick, but only
    /// invoked when the value actually changes (true→false or
    /// false→true). The waveform animation in PanelRootView uses
    /// THIS as its authoritative `isPlaying` signal — CoreAudio
    /// can't lie about whether bytes are flowing to the output
    /// device, unlike MediaRemote's `isPlaying` flag which Spotify
    /// flickers during track transitions.
    var onAudioFlowingChange: ((Bool) -> Void)?

    /// Last value sent through `onAudioFlowingChange`. Updated on
    /// every tick.
    private(set) var isAudioFlowing: Bool = false

    /// Bundle ID of the FIRST resolvable user-facing process
    /// currently producing audio output (filtered against
    /// `systemSounds` so coreaudiod / WindowServer / PowerChime
    /// chimes don't qualify). Updated every tick. Used by
    /// `NotchOrchestrator.handleNowPlayingChange` to gate the
    /// "MR went nil but the same source is still alive →
    /// transform nil to paused" transformation against the
    /// cross-source-switch case (user pauses Spotify, plays
    /// YouTube — bundles differ, gate doesn't apply).
    private(set) var currentAudioBundleID: String?

    private var timer: Timer?
    // 2026-05-01: tightened from 1.0s → 0.4s so the play/pause icon
    // and waveform animation react snappily when the user pauses in
    // the source app (especially browsers where MediaRemote's
    // isPlaying flag lags by 2-4 seconds for YouTube tabs). The
    // CoreAudio APIs called per tick (`kAudioProcessPropertyIsRunningOutput`,
    // PID resolve) are cheap — the HAL is designed for this kind of
    // polling — so the cost is negligible.
    private let interval: TimeInterval = 0.4
    private var lastPublishedBundleID: String?

    /// Bundle IDs for which we'd RATHER let MediaRemote / browser-
    /// probe publish — those code paths give better metadata
    /// (real track titles, real artwork) than what we can synthesize
    /// from CoreAudio. We still detect them for "is something
    /// playing?" purposes but skip the publish.
    private static let deferredToBetterSource: Set<String> = [
        "com.spotify.client",     // covered by MediaRemote/DistributedNotification
        "com.apple.Music",        // covered by MediaRemote/DistributedNotification
    ]

    /// Bundle IDs for our own process — we never want to publish
    /// "Notetaker is playing audio."
    private static let selfBundleIDs: Set<String> = [
        "com.aritradebnath.notetaker"
    ]

    /// Audio that comes out of these processes is system-level
    /// noise, not user-perceived "media playback." Filtering them
    /// out prevents the pill from flapping to "coreaudiod" or
    /// "WindowServer" when the system makes a UI sound. PowerChime
    /// is the cable-plug-in jingle — it lit up the pill as
    /// "PowerChime is playing audio" the instant the user plugged
    /// in their charger, which looks dumb.
    private static let systemSounds: Set<String> = [
        "com.apple.coreaudiod",
        "com.apple.WindowServer",
        "com.apple.audio.AudioComponentRegistrar",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.PowerChime",
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
        "com.apple.speech.speechsynthesisd",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.SiriNCService",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.audio.SystemSoundServer-macOS",
        "com.apple.ScreenshotServicesService"
    ]

    func start() {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Per BUG-029 fix: route through NSLog instead of writing
        // to stderr directly. Avoids the force-unwrap on
        // .data(using: .utf8) (the literal string would never fail
        // to encode, but the pattern is fragile if someone copies
        // it for a non-static string later) AND stops spamming
        // the user's Console.app with low-signal start/publish
        // chatter. NSLog respects unified logging filters.
        NSLog("AUDIOWATCHER: started (interval=\(interval)s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pids = activeAudioPIDs()

        // 2026-05-01: isAudioFlowing is now derived directly from
        // PID count, NOT from NSRunningApplication resolution.
        // Reason: Chrome routes audio through a helper process
        // ("Google Chrome Helper (Audio)") whose bundle ID is
        // com.google.Chrome.helper.AudioService and which doesn't
        // always resolve via NSRunningApplication(processIdentifier:).
        // Same for some Electron apps and Slack/Discord call
        // helpers. Filtering through NSRunningApplication first
        // dropped these to nil, leaving isAudioFlowing=false even
        // when audio was clearly streaming. CoreAudio's pid list
        // is the ground truth — if any PID is in it, bytes are
        // hitting the output device this tick.
        //
        // Self-process check is preserved by filtering OUR pid out.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let externalPIDs = pids.filter { $0 != myPID }
        let nowFlowing = !externalPIDs.isEmpty

        // Resolve current audio source bundle (for the orchestrator's
        // nil→paused gate). 2026-05-01: Chrome routes audio through a
        // helper process ("Google Chrome Helper (Audio)") whose PID
        // doesn't resolve via NSRunningApplication(processIdentifier:)
        // — `pids=[2053(?)]` in /tmp/notetaker-mra.log was the proof.
        // The fallback walks up the parent-process chain via sysctl
        // until we hit a PID that DOES resolve. Chrome Helper's
        // parent is Google Chrome.app → resolves to com.google.Chrome.
        // Generalizes to any app that routes through helpers.
        var resolvedBundle: String?
        for pid in externalPIDs {
            guard let bid = Self.bundleIDForPID(pid),
                  !Self.systemSounds.contains(bid),
                  !Self.selfBundleIDs.contains(bid) else { continue }
            resolvedBundle = bid
            break
        }
        currentAudioBundleID = resolvedBundle

        if nowFlowing != isAudioFlowing {
            isAudioFlowing = nowFlowing
            // 2026-05-01 diagnostic — when the user pauses YouTube
            // and the waveform doesn't freeze, we need to see whether
            // CoreAudio actually flipped this signal or not. PID list
            // included so we can identify which process is keeping
            // the output IO alive.
            let pidNames = externalPIDs.map { pid -> String in
                "\(pid)(\(Self.bundleIDForPID(pid) ?? "?"))"
            }.joined(separator: ", ")
            // Mirror to file log so we can correlate with MRA timeline
            // even when os_log redacts NSLog format strings.
            MediaRemoteAdapterService.fileLog("AUDIOWATCHER: isAudioFlowing \(nowFlowing) pids=[\(pidNames)]")
            onAudioFlowingChange?(nowFlowing)
        }

        // Publish candidates still need to resolve to running
        // applications because the synthetic NowPlayingInfo we
        // ship downstream needs a bundle ID + display name.
        var publishCandidates: [(pid_t, NSRunningApplication)] = []
        for pid in externalPIDs {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let bundle = app.bundleIdentifier ?? ""
            if Self.selfBundleIDs.contains(bundle) { continue }
            if Self.systemSounds.contains(bundle) { continue }
            if !Self.deferredToBetterSource.contains(bundle) {
                publishCandidates.append((pid, app))
            }
        }

        let candidates = publishCandidates
        if candidates.isEmpty {
            // Nothing user-relevant is producing audio. Clear the
            // last-published state so the next non-nil publish is
            // recognized as fresh.
            if lastPublishedBundleID != nil {
                lastPublishedBundleID = nil
                onChange?(nil)
            }
            return
        }

        // Pick the candidate that's frontmost — if the user is
        // looking at Chrome AND has Discord open in the background,
        // they almost certainly mean "show Chrome." Falls back to
        // the first detected if no candidate is frontmost.
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let chosen = candidates.first(where: { $0.1.bundleIdentifier == frontmostBundleID })
                  ?? candidates.first!

        let app = chosen.1
        let bundleID = app.bundleIdentifier ?? "unknown"
        if bundleID == lastPublishedBundleID {
            // Same app, no change. Skip publish to avoid view churn.
            return
        }
        lastPublishedBundleID = bundleID

        let displayName = app.localizedName ?? bundleID
        // Per BUG-029 fix: see start() for rationale.
        NSLog("AUDIOWATCHER: publishing \(bundleID) (\(displayName))")

        let info = NowPlayingInfo(
            title: displayName,
            artist: "",
            album: nil,
            artworkData: nil,
            isPlaying: true,
            sourceBundleID: bundleID,
            duration: nil,
            elapsedTime: nil,
            infoTimestamp: Date()
        )
        onChange?(info)
    }

    // MARK: - CoreAudio enumeration

    /// Return PIDs of all processes currently outputting audio.
    /// Uses `kAudioHardwarePropertyProcessObjectList` (macOS 14.2+)
    /// + `kAudioProcessPropertyIsRunningOutput` to filter for
    /// active output. No entitlement required.
    private func activeAudioPIDs() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize,
            &processObjectIDs
        )
        guard status == noErr else { return [] }

        var pids: [pid_t] = []
        for objID in processObjectIDs {
            // Is this process actively producing audio output?
            var isRunning: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioProcessPropertyIsRunningOutput),
                mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
            )
            let runStatus = AudioObjectGetPropertyData(objID, &runAddr, 0, nil, &runSize, &isRunning)
            guard runStatus == noErr, isRunning != 0 else { continue }

            // Resolve to PID.
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioProcessPropertyPID),
                mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
            )
            let pidStatus = AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &pid)
            if pidStatus == noErr, pid > 0 {
                pids.append(pid)
            }
        }
        return pids
    }

    // MARK: - Bundle resolution with parent-walk fallback

    /// Resolve a PID to its top-level app bundle ID. For helper
    /// processes (Chrome Helper, Slack Helper, Electron renderers,
    /// etc.) NSRunningApplication(processIdentifier:) frequently
    /// returns nil because helpers aren't registered as standalone
    /// apps. The fallback uses sysctl(KERN_PROC_PID) to walk up the
    /// parent-process chain until we hit a PID that DOES resolve —
    /// that's the helper's parent app. Chrome Helper (Audio)'s
    /// parent is Google Chrome (PID resolves → com.google.Chrome).
    ///
    /// Bounded loop (10 hops max) protects against pathological
    /// cases (orphaned process adopted by launchd, fork bomb).
    static func bundleIDForPID(_ pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid),
           let bid = app.bundleIdentifier,
           !bid.isEmpty {
            return bid
        }
        var current = pid
        for _ in 0..<10 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            let status = mib.withUnsafeMutableBufferPointer { mibPtr -> Int32 in
                withUnsafeMutablePointer(to: &info) { infoPtr in
                    sysctl(mibPtr.baseAddress, UInt32(mibPtr.count),
                           infoPtr, &size, nil, 0)
                }
            }
            guard status == 0, size > 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            // launchd is PID 1; we've walked off the top.
            if parent <= 1 { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               let bid = app.bundleIdentifier,
               !bid.isEmpty {
                return bid
            }
            current = parent
        }
        return nil
    }
}

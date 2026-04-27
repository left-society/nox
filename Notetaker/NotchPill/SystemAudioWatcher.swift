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

    private var timer: Timer?
    private let interval: TimeInterval = 1.0
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
        FileHandle.standardError.write("AUDIOWATCHER: started (interval=\(interval)s)\n".data(using: .utf8)!)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pids = activeAudioPIDs()
        // Filter PIDs to interesting ones: drop self, drop deferred
        // sources, drop system sounds. Whatever's left is real
        // user-facing media.
        let candidates: [(pid_t, NSRunningApplication)] = pids.compactMap { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            let bundle = app.bundleIdentifier ?? ""
            if Self.selfBundleIDs.contains(bundle) { return nil }
            if Self.systemSounds.contains(bundle) { return nil }
            if Self.deferredToBetterSource.contains(bundle) { return nil }
            return (pid, app)
        }

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
        FileHandle.standardError.write("AUDIOWATCHER: publishing \(bundleID) (\(displayName))\n".data(using: .utf8)!)

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
}

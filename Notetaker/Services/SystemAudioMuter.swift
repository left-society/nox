import CoreAudio
import Foundation

/// Silences the **system audio output** on demand — used during
/// dictation so the mic doesn't pick up the user's speakers /
/// headphones, AND, critically, so background videos in browsers
/// don't get *paused* (which is what the old "tell Spotify to pause"
/// approach did). Muting at the device layer just stops sound from
/// coming out — the video keeps playing, the song keeps streaming,
/// nothing knows it was silenced. When we restore, audio is back
/// instantly with no "now resuming…" stutter from the source app.
///
/// Why CoreAudio over AppleScript:
///   • `osascript -e 'set volume with output muted'` works, but the
///     subprocess launch costs ~300–500ms — noticeable on every Fn
///     press. CoreAudio is instant.
///   • CoreAudio also gives us proper read-back (was the user
///     already muted before we touched it?) which AppleScript fakes.
///
/// Device-support reality:
///   • Built-in MacBook speakers, AirPods, most USB DACs → support
///     `kAudioDevicePropertyMute` directly. Fast path.
///   • Some Bluetooth/aggregate devices → don't expose `Mute`. For
///     those we fall back to "set volume to 0, save the original to
///     restore later." Functionally identical from the user's POV.
///
/// All operations no-op gracefully if there's no default output
/// device or if CoreAudio returns an error — we'd rather skip the
/// mute step than crash the dictation flow.
enum SystemAudioMuter {

    /// Snapshot of what we changed. Pass to `restore(_:)` to undo.
    struct State {
        /// The user already had system muted before we started — so
        /// when we restore, we leave it muted.
        let alreadyMuted: Bool
        /// We toggled the mute property (fast path).
        let mutedViaProperty: Bool
        /// We zeroed the volume because mute property wasn't
        /// available. Holds the level we need to restore.
        let originalVolume: Float32?
    }

    // MARK: - Default output device discovery

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Read the device's transport type. We use this to detect
    /// Bluetooth output (headphones / wireless speakers) — those
    /// devices have notoriously unreliable volume-property sync
    /// with macOS. Verified via /tmp/nox-mute.log on the
    /// user's soundcore Space One: we write vol=1.0, postVol
    /// reads back 1.0 confirming the write — yet 4 seconds later
    /// the next silence() read is back at 0.0. The device's
    /// internal volume state isn't actually reflecting our writes.
    /// For these devices we skip the mute step entirely (the user
    /// is wearing headphones anyway, so mic doesn't pick up
    /// speakers and muting was never strictly necessary).
    private static func transportType(_ device: AudioDeviceID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        return transport
    }

    /// True if the device is wireless (Bluetooth or AirPlay) where
    /// volume writes don't reliably "stick" — see `transportType`
    /// for the rationale.
    private static func isWirelessDevice(_ device: AudioDeviceID) -> Bool {
        guard let t = transportType(device) else { return false }
        return t == kAudioDeviceTransportTypeBluetooth
            || t == kAudioDeviceTransportTypeBluetoothLE
            || t == kAudioDeviceTransportTypeAirPlay
    }

    // MARK: - Mute property (fast path)

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func deviceSupportsMute(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress()
        // Both `HasProperty` and `IsPropertySettable` matter — some
        // devices report having the property but won't accept a write.
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private static func readMuted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }

    @discardableResult
    private static func writeMuted(_ device: AudioDeviceID, mute: Bool) -> Bool {
        var address = muteAddress()
        var muteValue: UInt32 = mute ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size),
            &muteValue
        )
        return status == noErr
    }

    // MARK: - Volume fallback
    //
    // Used only when `kAudioDevicePropertyMute` isn't supported on
    // the current device (rare — built-in speakers, AirPods, and
    // most USB DACs all expose mute). We try element 0 (master),
    // then fall back to channels 1+2 (left+right stereo) which
    // some devices use exclusively.

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    /// Find which element exposes a settable volume scalar — main,
    /// or one of the stereo channels (1, 2). Returns the first
    /// element that has the property AND is settable. nil if none.
    private static func volumeControlElement(_ device: AudioDeviceID) -> AudioObjectPropertyElement? {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var address = volumeAddress(element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable: DarwinBoolean = false
            let status = AudioObjectIsPropertySettable(device, &address, &settable)
            if status == noErr && settable.boolValue { return element }
        }
        return nil
    }

    private static func readVolume(_ device: AudioDeviceID) -> Float32? {
        guard let element = volumeControlElement(device) else { return nil }
        var address = volumeAddress(element: element)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    @discardableResult
    private static func writeVolume(_ device: AudioDeviceID, _ value: Float32) -> Bool {
        // Write to ALL volume-controlling elements that exist —
        // some stereo devices need both channels written, not just
        // master, to actually take effect.
        var wrote = false
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var address = volumeAddress(element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var v: Float32 = value
            let status = AudioObjectSetPropertyData(
                device, &address, 0, nil,
                UInt32(MemoryLayout<Float32>.size),
                &v
            )
            if status == noErr { wrote = true }
        }
        return wrote
    }

    // MARK: - Public API

    /// Read whether the system is currently muted. Returns nil if we
    /// can't tell (no device, no readable mute or volume property).
    static func isMuted() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        if let m = readMuted(device) { return m }
        if let v = readVolume(device) { return v == 0 }
        return nil
    }

    /// Silence the default output. Returns a `State` snapshot that
    /// `restore(_:)` uses to put things back exactly how they were.
    ///
    /// 2026-04-29: switched from mute-property-first to
    /// volume-property-first. The mute property
    /// (`kAudioDevicePropertyMute`) is not universally interpreted
    /// the same way across audio devices — some Bluetooth devices
    /// (AirPods, third-party headphones) and some virtual devices
    /// (BlackHole, Loopback, Krisp) treat the property as
    /// "muted=1, unmuted=0" while others treat it inverse, and
    /// some accept the write but don't actually silence anything.
    /// User reported "music plays during dictation, stops after"
    /// which is exactly the inverted-mute symptom.
    ///
    /// Volume-scalar (0.0 = silent, 1.0 = full) IS universally
    /// interpreted correctly. Slightly slower fade-down
    /// perceptually (couple of frames) but rock-solid.
    static func silence() -> State {
        guard let device = defaultOutputDevice() else {
            audioLog("silence: no default output device")
            return State(alreadyMuted: false, mutedViaProperty: false, originalVolume: nil)
        }

        let preMute = readMuted(device)
        let preVol = readVolume(device)
        let wireless = isWirelessDevice(device)
        audioLog("silence ENTER: device=\(device) wireless=\(wireless) preMute=\(String(describing: preMute)) preVol=\(String(describing: preVol))")

        // 2026-05-02 wireless-device skip.
        //
        // Bluetooth (and AirPlay) output devices don't reliably
        // honor CoreAudio volume writes — the property API
        // accepts the write and reports the new value, but the
        // device's internal state often reverts within seconds.
        // Verified end-to-end in /tmp/nox-mute.log on the
        // user's soundcore Space One:
        //   silence wrote vol=0 successfully
        //   restore wrote vol=1.0 successfully (postVol=1.0 confirmed)
        //   4 seconds later, next silence reads vol=0.0
        //
        // For wireless devices we skip the mute entirely. The user
        // is wearing headphones — mic doesn't pick up the speakers,
        // so the original "mute speakers so mic doesn't capture
        // them" rationale doesn't apply. Returning alreadyMuted=true
        // makes restore() a no-op too, leaving the device's volume
        // entirely under user/device control.
        if wireless {
            audioLog("silence: SKIPPING — wireless device (volume writes don't reliably stick). User is on headphones; mic isn't picking up speakers anyway.")
            return State(alreadyMuted: true, mutedViaProperty: false, originalVolume: nil)
        }

        // 2026-05-02 stale-capture skip.
        //
        // If preVol reads suspiciously low (< 0.05), one of two
        // things is true:
        //   • User genuinely has the volume muted/near-zero.
        //   • Bluetooth device is mid-sync and CoreAudio's
        //     volume property hasn't settled yet (stale read).
        //
        // In BOTH cases, the right behavior is: don't write 0
        // (the user is already silent / about to be), and don't
        // capture anything to restore (a captured 0 will lock
        // the volume at 0 after recording, which is the recurring
        // bug we keep coming back to).
        //
        // `alreadyMuted=true` makes restore() a no-op — whatever
        // value the device settles to after our silence window
        // (Bluetooth sync, user adjustment, etc.) stays put.
        if let v = preVol, v < 0.05 {
            audioLog("silence: skipping — preVol=\(v) is suspiciously low (genuine mute or stale Bluetooth read). Recording silence is a no-op.")
            return State(alreadyMuted: true, mutedViaProperty: false, originalVolume: nil)
        }

        if let originalVolume = preVol {
            let wrote = writeVolume(device, 0)
            let postVol = readVolume(device)
            audioLog("silence: wrote vol=0 (success=\(wrote)) original=\(originalVolume) postVol=\(String(describing: postVol))")
            return State(alreadyMuted: false, mutedViaProperty: false, originalVolume: originalVolume)
        }

        if deviceSupportsMute(device) && writeMuted(device, mute: true) {
            audioLog("silence: fell back to mute property (volume not readable)")
            return State(alreadyMuted: false, mutedViaProperty: true, originalVolume: nil)
        }

        audioLog("silence: COULD NOT silence — no usable property")
        return State(alreadyMuted: false, mutedViaProperty: false, originalVolume: nil)
    }

    private static func audioLog(_ msg: String) {
        let path = "/tmp/nox-mute.log"
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let h = FileHandle(forWritingAtPath: path) {
                    h.seekToEndOfFile()
                    h.write(data)
                    try? h.close()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Reverse whatever `silence()` did. Safe to call with any state.
    static func restore(_ state: State) {
        guard let device = defaultOutputDevice() else {
            audioLog("restore: no device")
            return
        }
        let preVol = readVolume(device)
        audioLog("restore ENTER: alreadyMuted=\(state.alreadyMuted) viaProp=\(state.mutedViaProperty) origVol=\(String(describing: state.originalVolume)) preVol=\(String(describing: preVol))")
        if state.alreadyMuted {
            audioLog("restore: alreadyMuted=true, skipping")
            return
        }
        if state.mutedViaProperty {
            let wrote = writeMuted(device, mute: false)
            audioLog("restore: wrote mute=false (success=\(wrote))")
            return
        }
        if let originalVolume = state.originalVolume {
            // 2026-05-02 belt-and-suspenders. The silence-side skip
            // (preVol < 0.05) prevents low/stale captures from making
            // it into the State at all, but if anything DOES sneak
            // through (race with another silence call, future code
            // change), guard here too: never write a captured 0 back
            // — it can only harm. Real captured volumes are >= 0.05
            // by the silence-side filter.
            if originalVolume <= 0.01 {
                audioLog("restore: SKIPPING — originalVolume=\(originalVolume) is too low to be a real user volume (likely a stale capture)")
                return
            }
            // Also keep the "preVol > original" skip from the prior
            // fix: if the volume was bumped externally during the
            // silence window (volume keys, OS auto-restore, app set
            // it), respect that current level instead of clobbering
            // back to the captured value.
            if let preVol = preVol, preVol > originalVolume + 0.01 {
                audioLog("restore: SKIPPING write — preVol=\(preVol) > origVol=\(originalVolume) (current level is higher; user/system has set it since silence)")
                return
            }
            let wrote = writeVolume(device, originalVolume)
            let postVol = readVolume(device)
            audioLog("restore: wrote vol=\(originalVolume) (success=\(wrote)) postVol=\(String(describing: postVol))")
        }
    }
}

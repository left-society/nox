import CoreAudio
import Foundation
import AppKit

/// Watches the system's default-output device for VOLUME and MUTE
/// changes and fires a callback so AppDelegate can pop the
/// notch-anchored volume HUD pill.
///
/// Mirrors what Alcove's `VolumeManager` does — its binary exposes
/// `SimplyCoreAudio.defaultOutputDeviceChanged` and per-device
/// volume scalar listeners. We use plain CoreAudio HAL instead of
/// pulling in SimplyCoreAudio (zero-dependency policy + we only
/// need ~3 properties).
///
/// What this fires for:
///   • Volume up / Volume down / Volume mute keys on the keyboard
///   • Any app or AppleScript adjusting the system output volume
///   • The user dragging the menu-bar volume slider
///   • Output device switch (re-attaches listeners; first-fire
///     of the new device's level is suppressed so we don't
///     spuriously pop the HUD when the user just plugged in
///     headphones — that gets its own bluetoothConnected event)
///
/// What this DOESN'T fire for:
///   • Per-app volume changes (those don't go through HAL)
///   • Input-device (microphone) volume — separate property on a
///     different selector; not what the system HUD covers
///
/// ─── Implementation notes
///
/// The HAL property listener fires ONCE immediately after attach
/// (a "current-state hand-off" so listeners can sync up without a
/// poll). We suppress that first fire with `suppressNextFire` so
/// the HUD doesn't pop on app launch / device switch with the
/// volume the user already had set.
///
/// Volume + mute listeners are attached as TWO separate properties
/// because `kAudioDevicePropertyVolumeScalar` doesn't reflect mute
/// state — when muted, the scalar still reads the pre-mute level.
/// We OR the two signals together: any change to either fires the
/// callback with the current (level, muted) tuple.
///
/// Coalescing: a held volume key sends ~10–30 changes per second.
/// We don't throttle here — the AppDelegate-side push to
/// `setPendingSystemEvent` already acts as a per-event timer
/// reset (each push extends the visible window), so the HUD
/// stays visible the whole time the user holds the key and
/// auto-dismisses after they release.
@MainActor
final class SystemVolumeWatcher {
    /// Fired whenever volume scalar OR mute flag changes on the
    /// current default output device. `level` is 0.0–1.0, `muted`
    /// is the device's mute state (independent of level — when
    /// muted, level still reflects the pre-mute setting so the HUD
    /// can show "muted at 60%" cleanly).
    var onVolumeChange: ((_ level: Float, _ muted: Bool) -> Void)?

    /// Current default output device ID. Tracked so we can detach
    /// listeners from the OLD device when the user switches output
    /// (plugs in headphones, etc.) and re-attach to the NEW one.
    private var currentDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// Set true right before we attach a listener to a fresh
    /// device — the HAL fires the listener once on attach with the
    /// current level. Without suppression we'd get a spurious HUD
    /// pop on every device switch (and at app launch).
    private var suppressNextFire: Bool = false

    /// Held strongly so the listener block doesn't get deallocated.
    /// One block per (device, property) pair.
    private var listenerBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        Self.log("init starting")
        attachDefaultDeviceChangeListener()
        rebindToCurrentDefaultDevice()
        Self.log("init done — currentDeviceID=\(currentDeviceID), listenerCount=\(listenerBlocks.count)")
    }

    static func log(_ msg: String) {
        let line = "[\(Date())] SystemVolumeWatcher: \(msg)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/nox-volume.log"
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    deinit {
        // Best-effort cleanup. Listener blocks are keyed on the
        // (device, property) pair so we have to remove each
        // explicitly — there's no global "detach all my listeners"
        // hook. If this fails (device already gone), the HAL just
        // returns an error which we ignore.
        for (deviceID, addr, block) in listenerBlocks {
            var addressCopy = addr
            AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &addressCopy,
                DispatchQueue.main,
                block
            )
        }
    }

    // MARK: - Default-device change tracking
    //
    // The OS changes the default output device when the user
    // switches output via the menu-bar widget, plugs in headphones,
    // or routes audio to AirPlay. We listen for that, detach our
    // volume/mute listeners from the OLD device, and re-attach to
    // the NEW one. Without this, plugging headphones in would
    // leave us listening to the built-in speaker forever.

    private func attachDefaultDeviceChangeListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Hop to MainActor to mutate state — HAL invokes the
            // block on the dispatch queue we passed in (main), but
            // Swift concurrency still requires the explicit jump
            // because AudioObjectPropertyListenerBlock is C-typed.
            DispatchQueue.main.async {
                self?.rebindToCurrentDefaultDevice()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            listenerBlocks.append((AudioObjectID(kAudioObjectSystemObject), addr, block))
        }
    }

    private func rebindToCurrentDefaultDevice() {
        let newDevice = fetchDefaultOutputDevice()
        guard newDevice != kAudioObjectUnknown else { return }

        if newDevice == currentDeviceID {
            return  // No change — keep existing listeners.
        }

        // Detach listeners from the old device, if any.
        detachListeners(from: currentDeviceID)
        currentDeviceID = newDevice

        // Attach to the new device. Suppress the first fire so the
        // initial "here's the current level" callback doesn't pop
        // the HUD spuriously.
        suppressNextFire = true
        attachVolumeAndMuteListeners(to: newDevice)
    }

    private func fetchDefaultOutputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0, nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    // MARK: - Volume + mute listener attach/detach

    private func attachVolumeAndMuteListeners(to deviceID: AudioDeviceID) {
        // Volume scalar — element 0 is "main / master." Some
        // devices (multi-channel pro audio interfaces) only
        // expose per-channel volume; for those, master may
        // not be present. We fall back to channel 1 if 0 fails.
        var attached = attachListener(
            to: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            element: kAudioObjectPropertyElementMain
        )
        if !attached {
            attached = attachListener(
                to: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                element: 1
            )
        }
        // Mute flag — same fallback pattern.
        var muteAttached = attachListener(
            to: deviceID,
            selector: kAudioDevicePropertyMute,
            element: kAudioObjectPropertyElementMain
        )
        if !muteAttached {
            muteAttached = attachListener(
                to: deviceID,
                selector: kAudioDevicePropertyMute,
                element: 1
            )
        }
        _ = attached
        _ = muteAttached
    }

    @discardableResult
    private func attachListener(
        to deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handlePropertyChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID, &addr, DispatchQueue.main, block
        )
        if status == noErr {
            listenerBlocks.append((deviceID, addr, block))
            return true
        }
        return false
    }

    private func detachListeners(from deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        let kept = listenerBlocks.filter { entry in
            let (entryDevice, addr, block) = entry
            if entryDevice == deviceID && addr.mSelector != kAudioHardwarePropertyDefaultOutputDevice {
                var addressCopy = addr
                AudioObjectRemovePropertyListenerBlock(
                    deviceID, &addressCopy, DispatchQueue.main, block
                )
                return false  // drop from list
            }
            return true  // keep
        }
        listenerBlocks = kept
    }

    // MARK: - Property-change handling

    private func handlePropertyChange() {
        if suppressNextFire {
            // First fire after attach — HAL's mandatory
            // current-state handoff. Eat it so the HUD doesn't
            // pop on launch / device switch.
            suppressNextFire = false
            return
        }
        // Skip the HUD pop when WE wrote the property
        // programmatically (e.g. SystemAudioMuter silencing audio
        // for dictation). Without this, every dictation start/stop
        // flashes the volume HUD because the listener can't tell
        // user-initiated changes from our own mute/restore writes.
        if SystemAudioMuter.isPerformingProgrammaticChange {
            Self.log("handlePropertyChange — SUPPRESSED (SystemAudioMuter active)")
            return
        }
        // Also skip while dictation is active (any non-idle state) —
        // covers the user's configured hotkey regardless of whether
        // it's Fn, ⌘⇧D, or a custom binding. This is more robust
        // than the SystemAudioMuter-only check because it covers
        // the entire dictation lifecycle (record → transcribe →
        // error-recovery), not just the brief mute/restore window.
        if DictationOrchestrator.isActive {
            Self.log("handlePropertyChange — SUPPRESSED (dictation active)")
            return
        }
        let level = fetchVolume(deviceID: currentDeviceID)
        let muted = fetchMute(deviceID: currentDeviceID)
        Self.log("firing onVolumeChange level=\(level) muted=\(muted)")
        onVolumeChange?(level, muted)
    }

    private func fetchVolume(deviceID: AudioDeviceID) -> Float {
        // Try main element first, fall back to channel 1.
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID, &addr, 0, nil, &size, &value
            )
            if status == noErr {
                return max(0, min(1, value))
            }
        }
        return 0
    }

    private func fetchMute(deviceID: AudioDeviceID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID, &addr, 0, nil, &size, &value
            )
            if status == noErr {
                return value != 0
            }
        }
        return false
    }
}

import AppKit
import CoreAudio
import ApplicationServices

/// Replace macOS's system volume HUD with nox's pill.
///
/// **Why this exists**
/// When you press F10/F11/F12 (volume mute/down/up) on a MacBook,
/// macOS draws its own white volume box in the lower-middle of the
/// screen via OSDUIHelper. nox already has a tasteful volume pill
/// in the notch (driven by `SystemVolumeWatcher`'s CoreAudio
/// listener) — but it appears IN ADDITION to Apple's overlay, not
/// instead of it. The result is two pieces of UI fighting for the
/// user's attention.
///
/// This interceptor closes the gap: it installs a `CGEventTap` on
/// systemDefined events, intercepts the media-key keypresses BEFORE
/// macOS routes them to OSDUIHelper, mutates the system volume
/// directly via CoreAudio, and consumes the event. Net effect:
///   • Apple's white box never appears
///   • CoreAudio's volume actually changes
///   • SystemVolumeWatcher's listener notices and fires nox's pill
///
/// Inspired by SuperIsland's `MediaKeyInterceptor.swift` (similar
/// mechanism, similar key codes).
///
/// **Permissions**
/// CGEventTap requires Accessibility permission. If it's not
/// granted, `start()` schedules a retry every 5 seconds so the
/// moment the user grants it, the tap activates without an app
/// restart.
///
/// **Settings**
/// Off by default — opt-in via Settings → General → "Replace
/// system volume HUD". The toggle controls `start()` / `stop()`.
@MainActor
final class MediaKeyInterceptor {

    static let shared = MediaKeyInterceptor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive: Bool = false
    private var retryWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - Lifecycle

    /// Install the event tap. Returns true on success. If Accessibility
    /// permission isn't granted, schedules a retry every 5 seconds.
    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }

        // First gate: Accessibility permission. CGEventTap on the
        // session event tap with cghidEventTap-level events
        // requires this and silently returns nil otherwise.
        guard AXIsProcessTrustedWithOptions(nil) else {
            NSLog("nox: MediaKeyInterceptor — Accessibility not granted, retrying in 5s")
            scheduleRetry()
            return false
        }

        // CGEventType doesn't expose `.systemDefined` as a Swift case
        // — but its raw value is `NX_SYSDEFINED` from IOKit, which is
        // 14. Constructing the mask manually is the canonical way to
        // tap system-defined events from a third-party app.
        let mask: CGEventMask = (1 << 14)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                return me.handle(eventType: type, event: event)
            },
            userInfo: userInfo
        )

        guard let tap else {
            NSLog("nox: MediaKeyInterceptor — CGEvent.tapCreate returned nil (likely an OS-level deny)")
            scheduleRetry()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isActive = true
        NSLog("nox: MediaKeyInterceptor — installed (Accessibility OK)")
        return true
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
        NSLog("nox: MediaKeyInterceptor — stopped")
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.start()
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - Event handling

    /// Called from the CGEventTap callback. Returns the event
    /// (passes it through) or `nil` (consumes it so macOS never
    /// sees the keypress).
    fileprivate func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the OS disabled it for any reason
        // (timeout, user input event we missed, etc.). Returning
        // the event unchanged is fine here — these aren't volume
        // events we'd want to consume.
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // 14 = NX_SYSDEFINED — see comment in start() about why we
        // compare on raw value instead of using a CGEventType case.
        guard eventType.rawValue == 14 else {
            return Unmanaged.passUnretained(event)
        }

        // Convert CGEvent to NSEvent so we can read the
        // system-defined subtype + payload. Subtype 8 is
        // `NSEventSubtypeAuxiliaryControlButtons` per AppKit's
        // (private) header — that's the one that carries media
        // and brightness key events.
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        // 0xA (10) is key-down for systemDefined events; 0xB is
        // key-up. We only act on key-down so a press doesn't fire
        // the action twice.
        let pressState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = pressState == 0xA

        // NX_KEYTYPE_* constants from <IOKit/hidsystem/ev_keymap.h>:
        //   SOUND_UP   = 0
        //   SOUND_DOWN = 1
        //   MUTE       = 7
        // These are the F12 / F11 / F10 functional keys on MacBooks
        // when not using fn-as-function-keys. brightness/illumination
        // and other media keys travel through the same channel but
        // we don't intercept them — leave them to the OS.
        let isVolumeKey = (keyCode == 0 || keyCode == 1 || keyCode == 7)
        guard isVolumeKey else {
            return Unmanaged.passUnretained(event)
        }

        if isKeyDown {
            adjustVolume(keyCode: keyCode)
        }

        // Consume the event by returning nil. macOS never sees the
        // keypress, OSDUIHelper never draws the white overlay, and
        // CoreAudio's listener — which we triggered above with our
        // own volume mutation — fires nox's pill via the existing
        // SystemVolumeWatcher path.
        return nil
    }

    // MARK: - CoreAudio plumbing

    /// Step size per volume key press. SuperIsland uses 1/16; we
    /// match. macOS's own step is also 1/16 by default
    /// (kAudioDevicePropertyVolumeRangeDecibels divided into 16
    /// "ticks"), so this matches the user's muscle memory.
    private static let volumeStep: Float32 = 1.0 / 16.0

    private func adjustVolume(keyCode: Int32) {
        guard let device = systemOutputDevice() else { return }
        switch keyCode {
        case 0:                     // NX_KEYTYPE_SOUND_UP
            setVolume(device: device, delta: Self.volumeStep)
        case 1:                     // NX_KEYTYPE_SOUND_DOWN
            setVolume(device: device, delta: -Self.volumeStep)
        case 7:                     // NX_KEYTYPE_MUTE
            toggleMute(device: device)
        default:
            break
        }
    }

    /// Resolve the system's current default output device — this
    /// is what 'Sound' in System Settings calls "Output Device,"
    /// and it's the one whose volume the F-keys would normally
    /// adjust.
    private func systemOutputDevice() -> AudioObjectID? {
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else {
            return nil
        }
        return device
    }

    /// Read current volume, clamp `current + delta` into [0, 1],
    /// write it back. Some output devices (HDMI, AirPlay, certain
    /// USB DACs) don't expose a writable VolumeScalar — for those
    /// we fail soft and let macOS's actual logic run on the next
    /// keypress (the user just sees their existing volume HUD
    /// once and the interceptor is a no-op).
    private func setVolume(device: AudioObjectID, delta: Float32) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &addr) else { return }

        var current: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &current) == noErr else {
            return
        }
        var next = max(0.0, min(1.0, current + delta))
        AudioObjectSetPropertyData(
            device, &addr, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &next
        )
    }

    private func toggleMute(device: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &addr) else { return }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr else {
            return
        }
        var next: UInt32 = muted == 0 ? 1 : 0
        AudioObjectSetPropertyData(
            device, &addr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &next
        )
    }
}

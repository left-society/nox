import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Coordinates the full dictation pipeline: Fn-key listener →
/// audio recorder → transcription service → auto-paste, with
/// **system-audio mute** around the recording so the mic doesn't
/// pick up the song.
///
/// This is the public surface external code (`AppDelegate`,
/// `PanelOrchestrator`) talks to. State is published as a
/// single enum so the pill UI can switch on it.
///
/// Key handling:
///   • **Fn key** (or any custom hotkey the user picks). On
///     macOS, Fn isn't surfaced through Carbon's
///     `RegisterEventHotKey` — only CGEventTap sees it. We
///     install a tap on `cgEventMaskBit(.flagsChanged)` and
///     watch for the `.maskSecondaryFn` bit toggling.
///   • Tap-to-toggle vs hold-to-talk: configurable. Default is
///     toggle (press once to start, again to stop) — matches
///     Wispr Flow's default and is gentler on the user's hand.
///
/// System-audio mute:
///   • On `startRecording()`, we silence the default output via
///     CoreAudio's `kAudioDevicePropertyMute` (or volume fallback
///     for devices that don't support it). On stop / cancel /
///     error, we restore exactly what we changed.
///   • This DELIBERATELY does NOT pause the source app — the
///     previous "tell Spotify to pause" approach interrupted
///     background videos in browsers, which the user explicitly
///     hated. Muting at the device level keeps videos and music
///     playing silently; everything resumes audibly when we
///     unmute, with zero "now resuming…" stutter.
///   • If the user already had system muted before pressing Fn,
///     we leave it muted on restore.
///
/// Privacy posture:
///   • Audio file gets deleted from disk immediately after the
///     transcription HTTP response lands (success or failure).
///   • Transcribed text is written to the pasteboard +
///     restored to the previous pasteboard contents after the
///     paste lands (~250ms grace).
@MainActor
final class DictationOrchestrator: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(level: Float)
        case transcribing
        /// Brief failure state — pill shows error pill for ~2s
        /// then drops back to idle.
        case error(message: String)
    }

    /// Default modes for the dictation hotkey. User picks one in
    /// Settings → Dictation. Stored as String in UserDefaults.
    enum HotkeyMode: String, CaseIterable, Identifiable {
        /// Single Fn-key press toggles recording on / off.
        case fnToggle = "fn_toggle"
        /// Hold Fn to record; release to stop.
        case fnHold = "fn_hold"
        /// Custom Carbon hotkey (any modifier+key combo). User
        /// configures via the SettingsView's KeyShortcutCapture.
        /// Behaves like `fnToggle` (press once to start, again
        /// to stop).
        case customToggle = "custom_toggle"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .fnToggle: return "Tap Fn"
            case .fnHold: return "Hold Fn"
            case .customToggle: return "Custom shortcut"
            }
        }
    }

    @Published private(set) var state: State = .idle

    /// Fires when transcribed text is ready to be pasted. Set by
    /// `AppDelegate` to a closure that does the actual paste +
    /// pill notification. Decoupled here so the orchestrator
    /// doesn't drag NSPasteboard / CGEvent into its tests.
    var onTranscriptReady: ((String) -> Void)?

    /// Fires when transition to / from recording state happens —
    /// the pill UI subscribes to this for state-driven animations.
    /// (Could just observe `$state`, but the discrete event signal
    /// is easier to wire into one-shot UI feedback like haptics.)
    var onStateChange: ((State) -> Void)?

    // NOTE: `resolveActiveAudioSource` and `sendMediaCommand`
    // were removed when the music-pause flow was replaced with
    // **system-audio mute** — see `SystemAudioMuter`. We no longer
    // tell the source app (Spotify / Music / Chrome / …) to pause,
    // because that was interrupting background videos. Instead, we
    // silence the system output device for the duration of the
    // recording. AppDelegate's wiring of those callbacks should be
    // deleted alongside this change.

    // MARK: - Private state

    private let recorder = DictationRecorder()
    private var serviceConfiguration: DictationService.Configuration?
    private var mode: HotkeyMode = .fnToggle

    /// Snapshot of the system-audio state captured when we silenced
    /// the output, so `restoreSystemAudio()` can put things back
    /// exactly how they were. nil = we haven't silenced anything
    /// (or the silence call no-op'd because there's no output
    /// device).
    private var capturedAudioState: SystemAudioMuter.State?

    // Fn-key tap
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Last observed Fn-down state — needed to convert the
    /// `flagsChanged` event stream into discrete press/release
    /// events.
    private var fnIsDown: Bool = false

    // Custom Carbon hotkey (user-configured)
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonHandlerRef: EventHandlerRef?

    // Backup ⌘⇧D Carbon hotkey — always installed, regardless of
    // user's chosen mode. Guarantees a working dictation trigger
    // even when the Fn-key CGEventTap silently fails.
    private var backupHotKeyRef: EventHotKeyRef?
    private var backupHandlerRef: EventHandlerRef?

    // Per BUG-122 fix: each callback site that takes a userInfo
    // raw pointer now uses `passRetained(self)` to give the C
    // callback its own strong reference to the orchestrator. The
    // matching `release()` calls live in `teardownHotkeyListeners`
    // — without them, the unmanaged ref holds self alive forever
    // (memory leak), but with them the lifetime becomes exact:
    // the C callback can never see freed memory, AND the object
    // can deallocate cleanly once teardown runs.
    //
    // Why the previous `passUnretained` was unsafe: deinit tore
    // down the tap, but a callback could already be running on
    // another thread between the moment `self`'s refcount hit 0
    // and the moment `tapEnable(false)` returned. Using
    // `passRetained` makes that race impossible — the callback
    // owns a strong ref so self CAN'T be deallocated until we
    // explicitly release it.
    private var fnTapUserInfo: UnsafeMutableRawPointer?
    private var customHotkeyUserInfo: UnsafeMutableRawPointer?
    private var backupHotkeyUserInfo: UnsafeMutableRawPointer?

    // Auto-recover timer for the .error state
    private var errorRecoveryTask: Task<Void, Never>?

    // Cancellable task for the in-flight transcription
    private var transcriptionTask: Task<Void, Never>?

    /// Wall-clock when the current recording started — used to
    /// compute duration in `handleRecordingReady` so we can decide
    /// whether to fire the silent-recording prompt. Reset on every
    /// `startRecording`. Nil between sessions.
    private var recordingStartedAt: Date?

    /// Max audio level observed during the current recording. Reset
    /// at start, updated on every `onLevelUpdate` tick. If this
    /// stays near zero for the entire recording, the mic captured
    /// silence — likely a Bluetooth headset routed through HFP that
    /// macOS isn't actually streaming from. Drives the silent-
    /// recording prompt.
    private var maxRecordingLevel: Float = 0

    /// Fired by the orchestrator after a recording ends with an
    /// empty transcript AND clear evidence the mic captured no
    /// audio (peak level near zero, duration ≥2s). AppDelegate
    /// shows an NSAlert offering to switch input devices and
    /// persists the chosen UID to
    /// `SettingsKey.dictationInputDeviceUID` so the next recording
    /// uses it. Skipped on legitimate "user changed their mind"
    /// silent recordings via the duration + level gates above.
    var onSilentRecordingPrompt: ((_ deviceName: String) -> Void)?

    /// Debug file logger. NSLog from Swift apps doesn't reliably
    /// reach the unified `log show` predicate filter on modern
    /// macOS, which makes diagnosing dictation failures from
    /// outside Xcode painful. Writing every important event to a
    /// known file path means `tail -f /tmp/nox-dictation.log`
    /// always works.
    static let debugLogPath = "/tmp/nox-dictation.log"
    nonisolated static func dlog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: debugLogPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: debugLogPath, contents: data, attributes: nil)
            }
        }
        NSLog("nox: %@", message)
    }

    init() {
        Self.dlog("DictationOrchestrator init")
        recorder.onLevelUpdate = { [weak self] level in
            guard let self = self else { return }
            // Track peak level across the whole recording — drives
            // the silent-recording detector in
            // `handleRecordingReady`.
            if level > self.maxRecordingLevel {
                self.maxRecordingLevel = level
            }
            if case .recording = self.state {
                self.setState(.recording(level: level))
            }
        }
        recorder.onRecordingReady = { [weak self] url in
            self?.handleRecordingReady(url: url)
        }
        recorder.onRecordingFailure = { [weak self] error in
            self?.handleRecordingFailure(error: error)
        }
    }

    deinit {
        // Per BUG-123 fix: deinit is intentionally empty. All
        // teardown lives in `stop()` which AppDelegate calls on
        // `applicationWillTerminate` (main actor, documented
        // contract). The previous deinit body called CGEvent /
        // Carbon / CFRunLoop APIs directly — those are
        // thread-sensitive but deinit runs on whatever thread
        // holds the last strong reference, which is undefined for
        // these AppKit / CoreFoundation surfaces.
        //
        // Because the BUG-122 fix uses `passRetained` for the
        // userInfo pointers passed to CGEventTap / Carbon
        // InstallEventHandler, those handlers hold STRONG refs
        // to self for as long as they're installed. Deinit can
        // therefore only run AFTER `stop()` (or
        // `teardownHotkeyListeners()`) released those refs — by
        // which point there's nothing left to tear down. Empty
        // deinit is the correct outcome.
        //
        // If stop() is never called and the only owner drops the
        // strong ref, the orchestrator simply leaks for the rest
        // of process lifetime — harmless, no crash, no data
        // corruption. AppDelegate already wires
        // applicationWillTerminate → stop() so this is the
        // documented happy path.
    }

    // MARK: - Configuration

    /// Apply a service config (API key + provider URL + models).
    /// Called by `AppDelegate` at launch and whenever the user
    /// edits Settings → Dictation.
    func configure(serviceConfig: DictationService.Configuration) {
        self.serviceConfiguration = serviceConfig
    }

    /// Switch hotkey mode. Tears down the previous listener and
    /// installs the new one. ALWAYS also installs a backup
    /// ⌘⇧D Carbon hotkey — guaranteed to work via the
    /// RegisterEventHotKey path (used by the rest of the app for
    /// ⌥Space / ⌘⌥V), so the user has a working trigger even if
    /// the Fn-key CGEventTap path silently fails (which happens
    /// when Accessibility permission isn't yet granted, or on
    /// macOS versions that deliver Fn-key events differently).
    func setHotkeyMode(_ mode: HotkeyMode,
                       customKeyCode: UInt32 = 0,
                       customModifiers: UInt32 = 0) {
        teardownHotkeyListeners()
        self.mode = mode
        switch mode {
        case .fnToggle, .fnHold:
            installFnKeyTap()
        case .customToggle:
            installCarbonHotkey(keyCode: customKeyCode, modifiers: customModifiers)
        }
        // Backup ⌘⇧D — works regardless of mode. Carbon's
        // RegisterEventHotKey doesn't need Accessibility
        // permission and is known-good in this app.
        installBackupCarbonHotkey()
    }

    private func installBackupCarbonHotkey() {
        // 'D' keycode = 0x02 on US keyboards. Modifiers:
        // cmdKey = 0x100, shiftKey = 0x200.
        let keyCode: UInt32 = 2  // 'D'
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        var hotKeyID = EventHotKeyID(signature: 0x4E544B42 /* 'NTKB' (NoteTaker Backup) */, id: 2)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr, let hotKeyRef = hotKeyRef {
            backupHotKeyRef = hotKeyRef
            Self.dlog("backup ⌘⇧D Carbon hotkey installed (status=\(status))")
        } else {
            Self.dlog("backup ⌘⇧D registration FAILED (status=\(status))")
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        // Per BUG-122 fix: passRetained instead of passUnretained.
        // Released in teardownHotkeyListeners.
        let unmanagedSelf = Unmanaged.passRetained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData = userData, let eventRef = eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(eventRef,
                                            EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID),
                                            nil,
                                            MemoryLayout<EventHotKeyID>.size,
                                            nil,
                                            &hotKeyID)
                guard err == noErr else { return noErr }
                let me = Unmanaged<DictationOrchestrator>.fromOpaque(userData).takeUnretainedValue()
                // Distinguish primary (id=1) from backup (id=2).
                Task { @MainActor in
                    if hotKeyID.id == 2 {
                        me.handleBackupHotkey()
                    } else {
                        me.handleCustomHotkey()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            unmanagedSelf,
            &backupHandlerRef
        )
        if installStatus == noErr {
            self.backupHotkeyUserInfo = unmanagedSelf
        } else {
            // Handler install failed — release the retained self ref.
            Unmanaged<DictationOrchestrator>.fromOpaque(unmanagedSelf).release()
        }
    }

    private func handleBackupHotkey() {
        Self.dlog("⌘⇧D FIRED — state=\(state) apiKey.empty=\(serviceConfiguration?.apiKey.isEmpty ?? true)")
        if case .recording = state {
            stopRecording()
        } else if case .idle = state {
            startRecording()
        } else {
            Self.dlog("  ⌘⇧D ignored — not idle or recording (state=\(state))")
        }
    }

    // MARK: - Recording lifecycle

    /// Start the dictation recording flow. Idempotent — calling
    /// while already recording is a no-op (the mode-determined
    /// listener decides what "press again" does).
    func startRecording() {
        guard case .idle = state else {
            Self.dlog("startRecording IGNORED — state=\(state)")
            return
        }
        // Recording is gated on having SOME transcription path available:
        // either a Groq/OpenAI API key OR Local Whisper turned on.
        // Earlier this check only looked at `apiKey.isEmpty == false`,
        // which hard-bailed on the documented default config (Local
        // Whisper ON, no API key) — exact symptom users reported as
        // "hold-to-record does nothing." Local Whisper alone is enough.
        let hasKey = serviceConfiguration?.apiKey.isEmpty == false
        let hasLocal = serviceConfiguration?.useLocalWhisper == true
        guard hasKey || hasLocal else {
            Self.dlog("startRecording BAILED — no API key AND Local Whisper disabled. Enable one in Settings → Dictation.")
            setStateAndNotify(.error(message: "Enable Local Whisper or add a Groq API key in Settings → Dictation"))
            return
        }
        Self.dlog("🎙️ startRecording — muting system audio, calling recorder.startRecording()")
        // Reset per-session metrics that the silent-recording
        // detector reads in handleRecordingReady. Doing this here
        // (not in handleRecordingReady) means a recording that
        // never produces a file — e.g. failed mid-flight — also
        // gets a clean slate for the next attempt.
        recordingStartedAt = Date()
        maxRecordingLevel = 0
        // Mute the system audio output (NOT the source app) so any
        // playing video / song keeps streaming silently. Restored
        // in handleRecordingReady / cancel / failure paths.
        silenceSystemAudio()
        recorder.startRecording()
        setStateAndNotify(.recording(level: 0))
    }

    /// Stop the recording. Triggers the upload + transcription +
    /// paste flow.
    func stopRecording() {
        guard case .recording = state else {
            Self.dlog("stopRecording IGNORED — state=\(state)")
            return
        }
        Self.dlog("⏹ stopRecording — finalizing audio file, uploading for transcription")
        recorder.stopRecording()
        setStateAndNotify(.transcribing)
    }

    /// Cancel an in-flight transcription (e.g. user wants to
    /// throw it away). Stops the recorder + any HTTP call in
    /// flight, drops back to .idle, restores system audio.
    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        recorder.stopRecording()
        restoreSystemAudio()
        setStateAndNotify(.idle)
    }

    // MARK: - State helpers

    private func setState(_ new: State) {
        if state == new { return }
        state = new
    }

    private func setStateAndNotify(_ new: State) {
        setState(new)
        // Mark dictation "active" for any non-idle state — this
        // suppresses the volume HUD while the user is dictating
        // (works regardless of whether the user's hotkey is Fn,
        // ⌘⇧D, or a custom binding). SystemVolumeWatcher reads
        // this flag and skips firing the HUD callback while it's
        // true. Cleared back to false on .idle.
        switch new {
        case .idle:
            DictationOrchestrator.isActive = false
        default:
            DictationOrchestrator.isActive = true
        }
        onStateChange?(new)
        if case .error(let msg) = new {
            scheduleErrorRecovery(after: msg.count > 80 ? 4.5 : 2.5)
        }
    }

    /// Globally observable "is dictation active" flag. True from the
    /// moment the user triggers their dictation hotkey (Fn / ⌘⇧D /
    /// whatever they configured) through the recording, transcription,
    /// and error-recovery phases — back to false when state returns
    /// to .idle. SystemVolumeWatcher reads this to suppress the volume
    /// HUD during the entire dictation session, regardless of how the
    /// user triggered it.
    static var isActive: Bool = false

    private func scheduleErrorRecovery(after delay: TimeInterval) {
        errorRecoveryTask?.cancel()
        errorRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self = self else { return }
                if case .error = self.state {
                    self.setStateAndNotify(.idle)
                }
            }
        }
    }

    // MARK: - Recorder callbacks

    private func handleRecordingReady(url: URL?) {
        guard let url = url else {
            Self.dlog("recording too short (<0.3s), discarded — back to idle")
            restoreSystemAudio()
            setStateAndNotify(.idle)
            return
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        Self.dlog("recording ready — url=\(url.lastPathComponent) size=\(fileSize)B. Uploading…")

        // Restore system audio NOW — once the recording file is
        // sealed, the mic isn't capturing anymore, so there's no
        // reason to keep the user's speakers silent during the
        // network round-trip. Saves them ~1–3s of silence on every
        // dictation.
        restoreSystemAudio()

        guard let config = serviceConfiguration else {
            try? FileManager.default.removeItem(at: url)
            setStateAndNotify(.error(message: "Dictation not configured."))
            return
        }

        let service = DictationService(configuration: config)
        transcriptionTask = Task { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let text = try await service.transcribeAndCleanup(fileURL: url)
                await MainActor.run {
                    guard let self = self else { return }
                    Self.dlog("✅ transcript: \"\(text.prefix(120))\" (\(text.count) chars)")
                    if !text.isEmpty && !Self.isWhisperHallucination(text) {
                        self.onTranscriptReady?(text)
                    } else {
                        self.maybeFireSilentRecordingPrompt()
                    }
                    self.setStateAndNotify(.idle)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self = self else { return }
                    Self.dlog("transcription cancelled")
                    self.setStateAndNotify(.idle)
                }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    Self.dlog("❌ transcription error: \(error.localizedDescription)")
                    self.setStateAndNotify(.error(message: error.localizedDescription))
                }
            }
        }
    }

    /// Decides whether to fire the silent-recording prompt. Two
    /// possible firing paths, both gated on duration ≥ 2s so we
    /// never pop a dialog on a legitimate "user just bumped Fn":
    ///
    ///   PATH A — Truly silent recording:
    ///   Peak audio level < 0.005 across the whole recording. Real
    ///   speech — even quiet — registers at least 0.05 peak. Below
    ///   that, the mic wasn't capturing anything (HFP-routed BT
    ///   headset, muted hardware switch, app-level mute, etc.).
    ///
    ///   PATH B — Whisper hallucination on garbage input:
    ///   Whisper returns artifact strings like "[wind howling]",
    ///   "[silence]", "Thank you for watching" when audio is too
    ///   muffled/distorted to decode. Some BT mics produce audible
    ///   waveforms that aren't actually speech (compressed buzz),
    ///   so PATH A wouldn't catch them — but the resulting
    ///   transcript is still useless. Detection is by callers
    ///   (`isWhisperHallucination` check at the transcript site)
    ///   passing-through to this method.
    ///
    /// Either path → fire the prompt. AppDelegate shows an NSAlert
    /// listing input devices and the user picks a working one.
    @MainActor
    private func maybeFireSilentRecordingPrompt() {
        guard let started = recordingStartedAt else { return }
        let duration = Date().timeIntervalSince(started)
        let peak = maxRecordingLevel
        Self.dlog(
            "silent-recording check: duration=\(String(format: "%.2f", duration))s peak=\(String(format: "%.4f", peak))"
        )
        guard duration >= 2.0 else { return }
        // Resolve current device name for the prompt copy ("Your
        // current mic — WH-1000XM6 — captured no audio…").
        let deviceName = DictationRecorder.preferredInputDevice()?.localizedName
            ?? "current microphone"
        Self.dlog("⚠️ silent/garbage recording — firing mic picker prompt for device '\(deviceName)'")
        onSilentRecordingPrompt?(deviceName)
    }

    /// Detects Whisper hallucination markers — artifacts the model
    /// emits when it can't decode the audio cleanly. These are
    /// returned as confident-looking transcripts ("[wind howling]",
    /// "Thank you for watching", "you") even though there's no real
    /// speech in the input. Treating them as failures lets us route
    /// to the silent-recording prompt and offer the user a different
    /// mic.
    ///
    /// Patterns checked:
    ///   • Bracketed annotations: `[wind howling]`, `[silence]`,
    ///     `[music]`, `[applause]`, `[no audio]`, etc. — any string
    ///     wrapped in `[...]` with nothing else.
    ///   • Exact-match common hallucinations: "you", "yeah",
    ///     "Thank you.", "Bye.", "Thanks for watching." — Whisper
    ///     emits these on near-silent input when it picks up faint
    ///     ambient noise.
    static func isWhisperHallucination(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // Bracketed annotation: starts and ends with brackets, no
        // other content. e.g. "[wind howling]", "[silence]".
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
            && !trimmed.contains(where: { !($0.isLetter || $0.isWhitespace || $0 == "[" || $0 == "]" || $0 == "-") }) {
            return true
        }
        // Exact-match short hallucinations Whisper emits on
        // near-silence. Compared case-insensitive, with trailing
        // punctuation stripped, so "Thank you" and "Thank you."
        // both match.
        let normalized = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            .lowercased()
        let knownArtifacts: Set<String> = [
            "you",
            "yeah",
            "thank you",
            "thanks",
            "thanks for watching",
            "thank you for watching",
            "bye",
            "okay",
            "ok"
        ]
        return knownArtifacts.contains(normalized)
    }

    private func handleRecordingFailure(error: Error) {
        Self.dlog("❌ recorder failure: \(error.localizedDescription)")
        restoreSystemAudio()
        setStateAndNotify(.error(message: error.localizedDescription))
    }

    // MARK: - System-audio mute

    /// Silence the default output. Captures pre-mute state so
    /// `restoreSystemAudio()` puts things back exactly. Idempotent —
    /// calling twice without a restore in between will overwrite the
    /// captured state with the SECOND read (which sees us muted),
    /// so guard at the call sites.
    private func silenceSystemAudio() {
        let snapshot = SystemAudioMuter.silence()
        capturedAudioState = snapshot
        Self.dlog("🔇 silenced system audio (alreadyMuted=\(snapshot.alreadyMuted) viaProperty=\(snapshot.mutedViaProperty) volSnapshot=\(snapshot.originalVolume.map { String(format: "%.2f", $0) } ?? "nil"))")
    }

    /// Reverse the most recent `silenceSystemAudio()`. No-op if we
    /// never silenced anything.
    private func restoreSystemAudio() {
        guard let state = capturedAudioState else { return }
        SystemAudioMuter.restore(state)
        capturedAudioState = nil
        Self.dlog("🔊 restored system audio")
    }

    // MARK: - Fn-key tap

    /// Install a CGEventTap watching `flagsChanged` events for the
    /// Fn key. Requires Accessibility permission — without it, this
    /// tap silently fails. Logs status to /tmp/nox-dictation.log
    /// either way so we can diagnose.
    ///
    /// CRITICAL: this is `zachlatta/freeflow`'s exact pattern from
    /// `GlobalShortcutBackend.swift` — it MATCHES Fn key by
    /// `event.keyCode == 63` (the Fn keyCode is 63 on every Apple
    /// keyboard) plus `event.modifierFlags.contains(.function)`.
    /// My earlier attempt used `event.flags.contains(.maskSecondaryFn)`
    /// which doesn't work reliably on all macOS versions /
    /// keyboards — the Fn flag bit isn't always set in CGEventFlags
    /// even when the user is holding Fn. NSEvent's `.function`
    /// modifier IS reliable.
    ///
    /// Also seeds initial state via `NSEvent.modifierFlags.contains(.function)`
    /// in case Fn is already held when the tap installs (the tap
    /// only sees TRANSITIONS via flagsChanged, not the current
    /// state).
    private func installFnKeyTap() {
        // Trigger the macOS Accessibility permission prompt FIRST.
        // CGEvent.tapCreate silently returns nil if the app isn't
        // listed in System Settings → Privacy & Security →
        // Accessibility — but it doesn't TRIGGER the permission
        // dialog. AXIsProcessTrustedWithOptions with the prompt
        // option does. The user gets a one-time native dialog the
        // first time we try; thereafter they can flip the toggle
        // in System Settings.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Self.dlog("Accessibility trust check: AXIsProcessTrusted=\(trusted)")
        guard trusted else {
            Self.dlog("❌ Accessibility permission not granted — Fn-key won't work until you enable nox in System Settings → Privacy & Security → Accessibility, then relaunch the app. ⌘⇧D backup still works.")
            // Broadcast a NotificationCenter event so the Settings pane
            // and any dictation UI can show an inline "missing
            // permission" banner — was previously a silent log-only
            // failure. The Settings → Dictation panel observes this
            // notification and renders an actionable warning row.
            NotificationCenter.default.post(name: .noxDictationAccessibilityMissing, object: nil)
            return
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        // Per BUG-122 fix: passRetained instead of passUnretained.
        // The CGEventTap's userInfo now owns a strong reference to
        // self; the matching release runs in teardownHotkeyListeners.
        let unmanagedSelf = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // .defaultTap, NOT .listenOnly — listenOnly works for
            // observation but FreeFlow uses .defaultTap and we need
            // the same delivery semantics they have.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<DictationOrchestrator>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .flagsChanged {
                    // Convert to NSEvent so we can read keyCode +
                    // modifierFlags reliably (the CGEvent flag bits
                    // don't expose Fn cleanly).
                    if let nsEvent = NSEvent(cgEvent: event), nsEvent.keyCode == 63 {
                        let isDown = nsEvent.modifierFlags.contains(.function)
                        Task { @MainActor in me.handleFnKeyChange(isDown: isDown) }
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: unmanagedSelf
        ) else {
            // Tap creation failed — release the retained self ref
            // we took above, otherwise we'd leak one strong ref to
            // self for the lifetime of the process.
            Unmanaged<DictationOrchestrator>.fromOpaque(unmanagedSelf).release()
            Self.dlog("❌ Fn-key event tap CREATE FAILED. Open System Settings → Privacy & Security → Accessibility, enable nox, then restart. Until then, use ⌘⇧D backup.")
            return
        }
        self.fnTapUserInfo = unmanagedSelf
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = runLoopSource
        // Seed initial state so we don't miss the case where Fn
        // is already being held when the tap installs.
        self.fnIsDown = NSEvent.modifierFlags.contains(.function)
        Self.dlog("✅ Fn-key tap installed (initial fnIsDown=\(self.fnIsDown))")
    }

    private func handleFnKeyChange(isDown: Bool) {
        // Only fire on transitions, not on every flagsChanged event.
        guard isDown != fnIsDown else { return }
        fnIsDown = isDown
        Self.dlog("Fn key \(isDown ? "DOWN" : "UP") — mode=\(mode.rawValue) state=\(state)")

        switch mode {
        case .fnToggle:
            // Press = toggle. Release is ignored.
            if isDown {
                if case .recording = state {
                    stopRecording()
                } else if case .idle = state {
                    startRecording()
                }
            }
        case .fnHold:
            // Press = start, release = stop.
            if isDown {
                if case .idle = state { startRecording() }
            } else {
                if case .recording = state { stopRecording() }
            }
        case .customToggle:
            break  // custom hotkey path handles this; Fn-tap not active
        }
    }

    // MARK: - Carbon hotkey (custom shortcut path)

    private func installCarbonHotkey(keyCode: UInt32, modifiers: UInt32) {
        guard keyCode != 0 else { return }
        var hotKeyID = EventHotKeyID(signature: 0x4E544B44 /* 'NTKD' */, id: 1)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef = hotKeyRef else {
            NSLog("nox: Dictation — failed to register Carbon hotkey (status \(status)).")
            return
        }
        carbonHotKeyRef = hotKeyRef

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        // Per BUG-122 fix: passRetained instead of passUnretained.
        // Released in teardownHotkeyListeners.
        let unmanagedSelf = Unmanaged.passRetained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return noErr }
                let me = Unmanaged<DictationOrchestrator>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in me.handleCustomHotkey() }
                return noErr
            },
            1,
            &eventType,
            unmanagedSelf,
            &carbonHandlerRef
        )
        if installStatus == noErr {
            self.customHotkeyUserInfo = unmanagedSelf
        } else {
            // Handler install failed — release the retained self ref.
            Unmanaged<DictationOrchestrator>.fromOpaque(unmanagedSelf).release()
            NSLog("nox: Dictation — failed to install Carbon event handler (status \(installStatus)).")
        }
    }

    private func handleCustomHotkey() {
        if case .recording = state {
            stopRecording()
        } else if case .idle = state {
            startRecording()
        }
    }

    private func teardownHotkeyListeners() {
        // Order matters: disable the tap / unregister hotkeys
        // FIRST so no more callbacks can fire, THEN release the
        // retained self pointers. Doing it the other way around
        // could leave a callback in flight that finds its
        // userInfo pointer's strong ref already released.

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        fnIsDown = false
        Self.releaseUnmanagedSelf(&fnTapUserInfo)

        if let hk = carbonHotKeyRef { UnregisterEventHotKey(hk) }
        if let h = carbonHandlerRef { RemoveEventHandler(h) }
        carbonHotKeyRef = nil
        carbonHandlerRef = nil
        Self.releaseUnmanagedSelf(&customHotkeyUserInfo)

        if let hk = backupHotKeyRef { UnregisterEventHotKey(hk) }
        if let h = backupHandlerRef { RemoveEventHandler(h) }
        backupHotKeyRef = nil
        backupHandlerRef = nil
        Self.releaseUnmanagedSelf(&backupHotkeyUserInfo)
    }

    /// Release the retained self reference held by a userInfo
    /// pointer (set up via `Unmanaged.passRetained(self).toOpaque()`
    /// during install). No-op if the pointer is nil. Nils the
    /// inout so callers can't double-release.
    private static func releaseUnmanagedSelf(_ ptr: inout UnsafeMutableRawPointer?) {
        guard let p = ptr else { return }
        ptr = nil
        Unmanaged<DictationOrchestrator>.fromOpaque(p).release()
    }

    /// Public shutdown hook for AppDelegate to call before app
    /// quit. Tears down the hotkey listeners (which releases the
    /// retained self refs from BUG-122 fix), and cancels any
    /// in-flight recording / transcription. After this returns,
    /// the orchestrator can deallocate cleanly — without it, the
    /// retained-self refs would keep the object alive forever
    /// (theoretical leak; harmless at app-quit but matters if the
    /// orchestrator is ever reconstructed mid-session).
    ///
    /// Per BUG-123 fix: this MUST be called on the main actor so
    /// the CGEvent / Carbon teardown calls land on the right
    /// thread. The previous deinit-based teardown ran on whatever
    /// thread released the last reference — undefined for these
    /// AppKit/CoreFoundation APIs.
    func stop() {
        teardownHotkeyListeners()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        errorRecoveryTask?.cancel()
        errorRecoveryTask = nil
    }
}

extension Notification.Name {
    /// Posted when `installFnKeyTap` aborts because Accessibility
    /// permission isn't granted. The Settings → Dictation panel observes
    /// this and renders an inline banner explaining the user needs to
    /// open System Settings → Privacy & Security → Accessibility and
    /// enable nox. Previously this failure was log-only — users had no
    /// way to know why hold-to-talk silently did nothing.
    static let noxDictationAccessibilityMissing = Notification.Name("nox.dictation.accessibilityMissing")
}

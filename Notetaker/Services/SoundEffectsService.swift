import AppKit
import Foundation

// MARK: - Wiring Spec (for coordinator)
//
// This file ships the audio side of the 1.9.21 ambient-sound pack:
// a singleton service that plays a built-in macOS system sound when
// the user plugs in a charger, connects a Bluetooth audio device,
// or locks / unlocks their Mac. ALL emissions default OFF — the
// master toggle is on by default, but every individual event is
// off, so existing users get zero behavior change after upgrade.
//
// ─── 1. SettingsKey additions (apply in SettingsWindow.swift, in
// the central `enum SettingsKey { ... }` block near the top):
//
//     // Sound effects (1.9.21)
//     /// Master kill-switch for the ambient-sound pack. Default
//     /// true so the per-event toggles can opt in individually
//     /// without a second hop through this gate. Modeled on the
//     /// existing `hapticsEnabled` pattern — see `HapticFeedback`.
//     static let enableSoundEffects = "enableSoundEffects"
//     /// Plays NSSound "Tink" the moment IOKit reports the charger
//     /// plugged in (rising edge of `PowerState.isCharging`).
//     /// Default false — opt-in.
//     static let playSoundOnCharging = "playSoundOnCharging"
//     /// Plays NSSound "Glass" on `BluetoothDeviceService.
//     /// onDeviceConnected`. Default false — opt-in.
//     static let playSoundOnBluetoothConnect = "playSoundOnBluetoothConnect"
//     /// Plays NSSound "Funk" when LockScreenWatcher reports the
//     /// screen has locked. Default false — opt-in.
//     static let playSoundOnLock = "playSoundOnLock"
//     /// Plays NSSound "Pop" when LockScreenWatcher reports the
//     /// screen has unlocked. Default false — opt-in.
//     static let playSoundOnUnlock = "playSoundOnUnlock"
//
// ─── 2. SettingsWindow.swift UI additions (in `GeneralSettings`,
// directly after the existing "Behaviour" `SettingsCard`):
//
//     GroupTitle(title: "Sound")
//     SettingsCard {
//         SettingsRow(title: "Play sound effects",
//                     subtitle: "Master switch for the ambient sound pack. Off here means none of the per-event toggles fire.") {
//             Toggle("", isOn: $enableSoundEffects).labelsHidden()
//         }
//         SettingsRow(title: "Charging",
//                     subtitle: "NSSound \"Tink\" when you plug in.") {
//             Toggle("", isOn: $playSoundOnCharging).labelsHidden()
//                 .disabled(!enableSoundEffects)
//         }
//         SettingsRow(title: "Bluetooth connect",
//                     subtitle: "NSSound \"Glass\" when AirPods (or any BT audio device) connect.") {
//             Toggle("", isOn: $playSoundOnBluetoothConnect).labelsHidden()
//                 .disabled(!enableSoundEffects)
//         }
//         SettingsRow(title: "Lock",
//                     subtitle: "NSSound \"Funk\" when the screen locks.") {
//             Toggle("", isOn: $playSoundOnLock).labelsHidden()
//                 .disabled(!enableSoundEffects)
//         }
//         SettingsRow(title: "Unlock",
//                     subtitle: "NSSound \"Pop\" when you wake from lock.",
//                     divider: false) {
//             Toggle("", isOn: $playSoundOnUnlock).labelsHidden()
//                 .disabled(!enableSoundEffects)
//         }
//     }
//
// Add the matching @AppStorage properties at the top of
// `GeneralSettings`:
//
//     @AppStorage(SettingsKey.enableSoundEffects) private var enableSoundEffects: Bool = true
//     @AppStorage(SettingsKey.playSoundOnCharging) private var playSoundOnCharging: Bool = false
//     @AppStorage(SettingsKey.playSoundOnBluetoothConnect) private var playSoundOnBluetoothConnect: Bool = false
//     @AppStorage(SettingsKey.playSoundOnLock) private var playSoundOnLock: Bool = false
//     @AppStorage(SettingsKey.playSoundOnUnlock) private var playSoundOnUnlock: Bool = false
//
// ─── 3. Trigger-point edits (one line each):
//
// (a) Charging — `AppDelegate.swift`, inside
//     `orchestrator.onChargingChange = { [weak self] percent, plugged in ... }`
//     (currently ~line 1341). Add an early branch BEFORE the pill
//     push, so the sound fires on the rising edge only:
//
//         if plugged {
//             SoundEffectsService.shared.playIfEnabled(.charging)
//         }
//
//     NotchOrchestrator already gates this callback on
//     `chargingChanged` (line 565), so we only get here on real
//     plug/unplug transitions — no need for a second edge guard.
//
// (b) Bluetooth — `AppDelegate.swift`, inside
//     `env.bluetoothDeviceService.onDeviceConnected = { [weak self] device in ... }`
//     (currently ~line 618). Add at the start of the closure (after
//     the `bluetoothPillEnabled` guard is fine — the service has
//     its own gate so doubling up is harmless):
//
//         SoundEffectsService.shared.playIfEnabled(.bluetoothConnect)
//
//     (No `onDeviceDisconnected` sound this round — spec scopes to
//     connect only.)
//
// (c) Lock / Unlock — `AppDelegate.swift`, inside
//     `orchestrator.onLockStateChange = { [weak self] locked in ... }`
//     (currently ~line 1322). Add at the start of the closure:
//
//         SoundEffectsService.shared.playIfEnabled(locked ? .lock : .unlock)
//
// ─── 4. Test target wiring
//
// Add `NotetakerTests/SoundEffectsPolicyTests.swift` to the
// NotetakerTests target's Compile Sources phase (alongside
// `TimingPollPolicyTests.swift` and `ScreenshotPillPolicyTests.swift`).
// Add THIS file (`Notetaker/Services/SoundEffectsService.swift`) to
// the Notetaker target's Compile Sources phase under the `Services`
// PBXGroup.
//
// END WIRING SPEC

// MARK: - Policy

/// Decides whether a system-event sound should actually play.
/// Pure boolean logic, no AppKit / NSSound coupling, so the
/// `SoundEffectsPolicyTests` exercise every branch without
/// having to mock the audio pipeline.
///
/// Modeled on `TimingPollPolicy` and `ScreenshotPillPolicy` — the
/// service-side call site composes `Inputs` from UserDefaults +
/// `FocusStatusService.isFocused`, calls `shouldPlay`, and (if
/// true) plays the preloaded NSSound for the event.
///
/// **Rule:** play iff the master sound-effects toggle AND the
/// per-event toggle are both on, AND we're not being suppressed
/// by macOS Focus (which suppresses iff Focus is active AND the
/// user has the "auto-hide pills during Focus" preference on —
/// the same preference that gates ambient pill notifications).
///
/// Why two layers (master + per-event)? Mirrors `HapticFeedback`'s
/// shape: `hapticsEnabled` is a single kill-switch, and individual
/// `hapticOnChargingChange` / `hapticOnBluetoothChange` flags
/// silence specific moments without touching the master. For
/// sounds the surprise factor is higher (audible vs. tactile) so
/// the per-event toggles default OFF — but keeping the master
/// toggle ON-by-default means a user who enables one specific
/// event doesn't have to flip two switches to hear it.
enum SoundEffectsPolicy {
    struct Inputs {
        /// `SettingsKey.enableSoundEffects` — the master kill-switch.
        /// Default true (so per-event toggles aren't double-gated by
        /// default), but ON means "per-event toggles decide"; OFF
        /// means "no sound ever, regardless of per-event flags."
        let masterEnabled: Bool
        /// The specific `playSoundOn*` flag for the event being
        /// considered. Default false for every event in the v1
        /// rollout — opt-in is the trust-preserving choice when
        /// adding audible feedback to an app that previously had
        /// none. The service maps each `SoundEvent` to its own
        /// UserDefaults key before composing this struct.
        let eventEnabled: Bool
        /// `FocusStatusService.isFocused` at the moment the event
        /// fires. False when Focus authorization is denied /
        /// undetermined (fail-open — the gating becomes a no-op
        /// and the user just gets the configured sounds).
        let isFocused: Bool
        /// `SettingsKey.respectFocusMode` — whether the user wants
        /// nox to suppress ambient notifications during Focus.
        /// Default true. When the user explicitly disables this we
        /// follow their preference even for sounds: the user is
        /// signaling "I want notifications even while Focused,"
        /// and sounds are the audible flavor of the same channel.
        let respectFocusMode: Bool
    }

    static func shouldPlay(_ inputs: Inputs) -> Bool {
        guard inputs.masterEnabled else { return false }
        guard inputs.eventEnabled else { return false }
        if inputs.isFocused && inputs.respectFocusMode { return false }
        return true
    }
}

// MARK: - Service

/// Singleton that owns the preloaded NSSound instances and routes
/// each `SoundEvent` through `SoundEffectsPolicy` before playing.
///
/// Why a singleton instead of an `enum` like `HapticFeedback`?
/// NSSound preload cost: instantiating `NSSound(named:)` walks
/// `/System/Library/Sounds/` to resolve the .aiff and parses its
/// header. Doing that lazily on every event would flash the
/// playback latency (10-30ms cold-load on the first plug-in after
/// boot) right when we want a snappy response. Preloading at app
/// launch under a shared instance is the standard fix.
///
/// **What this service does NOT do:**
///   • Add files to the bundle. Every sound is a macOS built-in
///     (`/System/Library/Sounds/*.aiff`), resolved via
///     `NSSound(named:)`. No app-bundle entitlements, no .caf
///     payload, no signing implications.
///   • Manage volume per-event. A 0.4 baseline is set at preload
///     time — quiet enough to read as confirmation, loud enough
///     to be heard at a normal system-volume setting. A future
///     "intensity" picker is explicitly out of scope per the
///     sprint doc.
///   • Override system mute. NSSound.play() honors the system
///     output device's mute state natively, so when the user has
///     muted their Mac the call is silently a no-op. We rely on
///     that rather than reading mute state synchronously from
///     `SystemVolumeWatcher` (which is callback-driven and
///     doesn't expose a sync getter).
@MainActor
final class SoundEffectsService {
    static let shared = SoundEffectsService()

    /// One of the four ambient events nox emits a sound for in
    /// 1.9.21. The raw value is the macOS built-in sound name
    /// passed to `NSSound(named:)` — these live in
    /// `/System/Library/Sounds/` and ship with every supported
    /// macOS release back to Big Sur, so we don't need a
    /// fallback / availability check.
    ///
    /// Sound choices match the sprint doc §3 mapping and follow
    /// macOS UI vocabulary:
    ///   • `.charging` → "Tink" — high, crisp, single ping;
    ///     reads as "small positive confirmation" (Apple uses
    ///     Tink for charging in its own Catalyst-y surfaces).
    ///   • `.bluetoothConnect` → "Glass" — clean two-note rise;
    ///     same sound macOS uses for screenshot save, which has
    ///     a positive-event association.
    ///   • `.lock` → "Funk" — descending bloom; reads as "going
    ///     to sleep."
    ///   • `.unlock` → "Pop" — short percussive blip; reads as
    ///     "waking up."
    enum SoundEvent {
        case charging
        case bluetoothConnect
        case lock
        case unlock

        /// `NSSound(named:)` key for the system sound this event
        /// plays. Centralized here so the mapping is one obvious
        /// place to change (e.g. if a future user wants to pick
        /// from the full ["Basso", "Blow", "Bottle", "Frog",
        /// "Funk", "Glass", "Hero", "Morse", "Ping", "Pop",
        /// "Purr", "Sosumi", "Submarine", "Tink"] catalog).
        var systemSoundName: String {
            switch self {
            case .charging: return "Tink"
            case .bluetoothConnect: return "Glass"
            case .lock: return "Funk"
            case .unlock: return "Pop"
            }
        }

        /// UserDefaults key for the per-event toggle. Each event
        /// has its own `playSoundOn*` flag (default false) so
        /// users can opt in selectively. Centralizing the mapping
        /// here keeps SettingsKey ↔ SoundEvent in sync via one
        /// switch statement instead of a parallel-keyed dict.
        var preferenceKey: String {
            switch self {
            case .charging: return "playSoundOnCharging"
            case .bluetoothConnect: return "playSoundOnBluetoothConnect"
            case .lock: return "playSoundOnLock"
            case .unlock: return "playSoundOnUnlock"
            }
        }
    }

    /// UserDefaults key for the master toggle. 2026-05-17 review N3:
    /// originally inlined as a literal during the parallel-sprint
    /// integration window. Coordinator merged the SettingsKey
    /// entries, so we now route through `SettingsKey.enableSoundEffects`
    /// — keeps key strings in one place and benefits from any future
    /// rename automatically.
    private static let masterEnabledKey = SettingsKey.enableSoundEffects

    /// Baseline volume for every preloaded sound. 0.4 was picked
    /// against the system Tink/Glass/Funk/Pop levels at the
    /// "Medium" output-volume setting on a 14" MacBook Pro: loud
    /// enough to read as confirmation when the user is looking
    /// at the screen, quiet enough to not startle when they're
    /// across the room. Lower than the default 1.0 because the
    /// system sounds were tuned for occasional event ringers,
    /// not the frequent ambient cadence we'll trigger at.
    private static let baselineVolume: Float = 0.4

    /// Preloaded `NSSound` instances, keyed by event. Built at
    /// `init` so the first `.play()` per event is on a warm,
    /// header-parsed instance instead of paying the cold-load
    /// latency at user-visible event time. Map omits any event
    /// whose `NSSound(named:)` returns nil (would only happen on
    /// a hypothetical macOS version that drops one of these
    /// sounds — defensive, but documented).
    private let preloaded: [SoundEvent: NSSound]

    private init() {
        var built: [SoundEvent: NSSound] = [:]
        let events: [SoundEvent] = [.charging, .bluetoothConnect, .lock, .unlock]
        for event in events {
            guard let sound = NSSound(named: NSSound.Name(event.systemSoundName)) else {
                NSLog("nox: SoundEffectsService failed to preload \(event.systemSoundName)")
                continue
            }
            sound.volume = Self.baselineVolume
            built[event] = sound
        }
        self.preloaded = built
    }

    /// Public entry point — one-liner call sites in
    /// `AppDelegate`'s charging / bluetooth / lock handlers.
    /// Composes the policy inputs from UserDefaults +
    /// `FocusStatusService.isFocused`, asks the policy, and (if
    /// approved) plays the preloaded sound. No-op if the policy
    /// vetoes or the sound failed to preload.
    func playIfEnabled(_ event: SoundEvent) {
        let inputs = SoundEffectsPolicy.Inputs(
            masterEnabled: Self.readMasterEnabled(),
            eventEnabled: UserDefaults.standard.bool(forKey: event.preferenceKey),
            isFocused: Self.readFocusedState(),
            respectFocusMode: Self.readRespectFocusMode()
        )
        guard SoundEffectsPolicy.shouldPlay(inputs) else { return }
        guard let sound = preloaded[event] else { return }
        // NSSound.play() is documented as a no-op when the same
        // instance is already playing, so a rapid plug-replug
        // (which IOKit can emit as two transitions within ~20ms)
        // produces at most one audible Tink rather than overlapping
        // playback. Good enough — we'd otherwise have to clone
        // the NSSound, which defeats the preload optimization.
        sound.play()
    }

    // MARK: - State reads

    /// Mirror of `HapticFeedback.isEnabled`'s default-true-on-missing
    /// pattern. The master toggle ships true so users who opt in to
    /// one specific event don't have to flip a second switch to
    /// hear it.
    private static func readMasterEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: masterEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: masterEnabledKey)
    }

    /// Mirror of the gate used by `AppDelegate.recomputeQuietState`
    /// and `pillHasAnyAnchor` (~AppDelegate.swift line 197-204):
    /// default true when the key is missing, otherwise the stored
    /// value. Centralizing the rule means we'll move in lockstep
    /// with any future change to the existing pill gate without
    /// re-deriving it.
    private static func readRespectFocusMode() -> Bool {
        if UserDefaults.standard.object(forKey: "respectFocusMode") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "respectFocusMode")
    }

    /// Reads `FocusStatusService.isFocused` through the AppDelegate-
    /// owned singleton. Returns false when the service hasn't been
    /// instantiated yet (early-launch / tests / preview mode), which
    /// fails open — the policy still consults its other gates, so
    /// the user just sees the same behavior as "Focus is off."
    /// Matches how `AppDelegate.recomputeQuietState` queries the
    /// flag.
    private static func readFocusedState() -> Bool {
        AppDelegate.shared?.focusStatusService?.isFocused ?? false
    }
}

import AppKit

/// Settings-aware wrapper around `NSHapticFeedbackManager`. Every
/// haptic moment in the app routes through this so the user's
/// "Haptic feedback" toggle in Settings → General actually gates
/// every emission, not just the one site we wired first. When the
/// toggle is off, calls become no-ops; when on, they pass through
/// to the system performer.
@MainActor
enum HapticFeedback {
    /// User-facing toggle. Read from UserDefaults each call so a
    /// flip in Settings takes effect immediately without needing
    /// any subscriber wiring.
    private static var isEnabled: Bool {
        // Default to true so first-launch users get the feedback.
        // UserDefaults.bool returns false for missing keys, so we
        // detect "missing" by checking object presence.
        if UserDefaults.standard.object(forKey: "hapticsEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "hapticsEnabled")
    }

    /// `.alignment` — the firmest pattern. Use for snap/threshold
    /// events: panel open, charging plug/unplug, copy confirmed,
    /// seek release.
    static func alignment() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// `.generic` — the lightest pattern. Use for repeated/tap
    /// events: transport buttons, tab switches.
    static func generic() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// `.levelChange` — middle pattern. Use for value-cycle events
    /// (none currently — reserved).
    static func levelChange() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Charging-specific gate. Distinct from the global haptics
    /// toggle so the user can keep haptics enabled generally but
    /// silence the cable-plug bump if they find it noisy.
    static func chargingChange() {
        guard isEnabled else { return }
        if UserDefaults.standard.object(forKey: "hapticOnChargingChange") != nil,
           UserDefaults.standard.bool(forKey: "hapticOnChargingChange") == false {
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Bluetooth connect/disconnect gate. Same pattern as charging —
    /// the user can keep global haptics on while silencing the
    /// pairing bump (some users find it noisy when AirPods auto-
    /// reconnect mid-meeting).
    static func bluetoothChange() {
        guard isEnabled else { return }
        if UserDefaults.standard.object(forKey: "hapticOnBluetoothChange") != nil,
           UserDefaults.standard.bool(forKey: "hapticOnBluetoothChange") == false {
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

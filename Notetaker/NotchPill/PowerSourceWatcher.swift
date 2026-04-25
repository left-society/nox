import Foundation
import IOKit
import IOKit.ps

/// Snapshot of the system's power source at a single point in time.
/// Equatable so the orchestrator can debounce identical follow-up
/// notifications (IOKit fires several within a few ms when the user
/// plugs in — we only want to drive one HUD presentation per real
/// state change).
struct PowerState: Equatable {
    let isCharging: Bool
    let percent: Int
}

/// Event-driven wrapper around IOKit's power-source notification
/// pipeline. Polling `IOPSCopyPowerSourcesInfo` on a timer would either
/// cost battery (tight loop) or miss the plug-in moment we actually
/// care about (loose loop). `IOPSNotificationCreateRunLoopSource`
/// gives us a CFRunLoopSource that fires the moment IOKit posts a
/// power-source change — exactly when we want to bloom the HUD.
///
/// The callback is delivered on whatever runloop we add the source to;
/// we add it to the main runloop in common modes so it fires reliably
/// even while the user is dragging a window or scrolling. The closure
/// hops to the main actor because `onChange` is called from non-isolated
/// CFRunLoop callback context but writes UI-facing state.
@MainActor
final class PowerSourceWatcher {
    private let onChange: (PowerState) -> Void
    private var runLoopSource: CFRunLoopSource?
    private var lastEmitted: PowerState?

    init(onChange: @escaping (PowerState) -> Void) {
        self.onChange = onChange
    }

    // MARK: - Lifecycle

    /// Registers the IOKit notification source with the main runloop
    /// and emits the current state immediately so callers can render a
    /// correct initial UI without waiting for the user to plug/unplug.
    func start() {
        guard runLoopSource == nil else { return }

        // The callback fires on the runloop we attach to. We pass `self`
        // through Unmanaged so the C-style callback can resolve back to
        // the Swift instance. Retained here, released in stop().
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(
            { ctx in
                guard let ctx else { return }
                let watcher = Unmanaged<PowerSourceWatcher>.fromOpaque(ctx).takeUnretainedValue()
                // Hop to the main actor — the callback runs on whatever
                // thread CFRunLoop dispatches it on, but `onChange`
                // ultimately writes UI state.
                Task { @MainActor in
                    watcher.refreshAndEmit()
                }
            },
            context
        )?.takeRetainedValue() else {
            NSLog("Notetaker: PowerSourceWatcher failed to create runloop source")
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        // Emit once on start so the orchestrator has a baseline.
        refreshAndEmit()
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        lastEmitted = nil
    }

    // MARK: - State read

    /// Reads the current power source via IOKit, builds a PowerState,
    /// and forwards it to the callback. Defensive: if IOKit returns
    /// nothing or the keys are missing (rare on a Mac with a battery,
    /// possible on a desktop Mac with no battery), we silently return.
    private func refreshAndEmit() {
        guard let snapshot = currentState() else { return }
        // IOKit can fire several notifications in rapid succession for
        // a single physical event — drop exact duplicates so the
        // orchestrator only sees real transitions.
        if snapshot == lastEmitted { return }
        lastEmitted = snapshot
        onChange(snapshot)
    }

    /// Returns nil if there's no battery (e.g. Mac mini/Studio) or if
    /// IOKit can't read the keys — callers should treat that as
    /// "nothing to display" rather than an error.
    private func currentState() -> PowerState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        // Walk every reported source. On a notebook there's typically
        // one (the internal battery); we pick the first one that has
        // both capacity keys, which is what the user expects to see.
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            guard let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = desc[kIOPSMaxCapacityKey] as? Int,
                  capacity > 0 else {
                continue
            }

            // Two charging signals from IOKit:
            // - kIOPSIsChargingKey: actively pumping electrons in.
            // - kIOPSPowerSourceStateKey == kIOPSACPowerValue: AC adapter
            //   is connected (might be plugged in but at 100% / not
            //   charging).
            // We treat "is charging" as either: actively charging OR on
            // AC power. The pill reads "Charging" when either is true so
            // the user gets feedback the moment they plug in, even
            // before the kernel flips kIOPSIsChargingKey.
            let isChargingFlag = desc[kIOPSIsChargingKey] as? Bool ?? false
            let psState = desc[kIOPSPowerSourceStateKey] as? String ?? ""
            let onAC = (psState == kIOPSACPowerValue)

            let percent = Int((Double(current) / Double(capacity)) * 100.0)
            return PowerState(
                isCharging: isChargingFlag || onAC,
                percent: max(0, min(100, percent))
            )
        }
        return nil
    }
}

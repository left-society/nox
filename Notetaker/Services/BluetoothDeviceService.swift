import Foundation
import Combine

/// Polls `system_profiler SPBluetoothDataType -json` on a background
/// queue and republishes the parsed device list as a `@Published`
/// property so SwiftUI views (the music slab's Devices row) can
/// react.
///
/// Why not IOBluetooth or `IOBluetoothDevice.pairedDevices()`? Both
/// give us connection state but not battery levels for AirPods,
/// AirPods Max, BeatsX, etc. — Apple stores those readings under
/// device-specific IORegistry keys that change per device family
/// and per macOS release. `system_profiler`'s consolidated JSON
/// output is the only stable, public, version-tolerant source. The
/// process is slow (~1-2s) but we only need a refresh every 30s
/// and we run it off-main, so it doesn't impact UI responsiveness.
///
/// Polling cadence: 30s. AirPods battery readings update at most
/// every ~10s on the OS side anyway; polling faster wastes CPU
/// without giving fresher data.
@MainActor
final class BluetoothDeviceService: ObservableObject {

    struct Device: Identifiable, Equatable {
        /// Bluetooth address — stable across reconnects, unique per
        /// pair of buds. Used as `id` so SwiftUI's diffing tracks
        /// the same row across battery updates.
        let id: String
        let name: String
        /// True iff `minorType` is one of the AirPods family
        /// (AirPods, AirPods Pro, AirPods Pro 2, AirPods Max,
        /// AirPods 3). Drives the icon choice in the SwiftUI row.
        let isAirPods: Bool
        let batteryMain: Int?
        let batteryLeft: Int?
        let batteryRight: Int?
        let batteryCase: Int?

        /// True iff at least one battery field has a reading.
        /// Devices without any battery data (cars, speakers,
        /// keyboards on some macOS versions) are filtered out
        /// upstream so they don't show as empty rows.
        var hasBattery: Bool {
            batteryMain != nil || batteryLeft != nil ||
            batteryRight != nil || batteryCase != nil
        }
    }

    @Published private(set) var devices: [Device] = []

    /// Fires once per device when a NEW device first appears in the
    /// connected list (i.e. the device just got paired/connected to
    /// this Mac since our last poll). Used by the orchestrator to
    /// show a brief "AirPods connected" pill in the notch.
    /// Deduplicated against the previous device list — re-running
    /// `refresh()` with an unchanged list won't refire this.
    var onDeviceConnected: ((Device) -> Void)?

    /// Fires once per device when it disappears from the connected
    /// list (disconnected, powered off, walked out of range).
    var onDeviceDisconnected: ((Device) -> Void)?

    private var timer: Timer?
    /// 8 seconds. Slow enough not to thrash `system_profiler`
    /// (each invocation is ~50–80ms of CPU on Apple silicon),
    /// fast enough that the connect HUD feels responsive — when
    /// the user puts on AirPods, the pill appears within a few
    /// seconds, not half a minute. Was 30s before this feature
    /// landed (battery-readout-only didn't need responsiveness).
    private let interval: TimeInterval = 8

    /// True after the very first refresh has landed. Used so we
    /// don't fire a flurry of "connected" pills on app launch
    /// for every device that was already paired before we
    /// started observing.
    private var hasSeenInitialState = false

    func start() {
        stop()
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Off-main shell-out to `system_profiler`, parse JSON, hop
    /// back to main to publish + emit connect/disconnect deltas.
    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let parsed = Self.fetchAndParse()
            DispatchQueue.main.async {
                let previous = self.devices
                let alreadyAnnounced = self.hasSeenInitialState
                if parsed != previous {
                    self.devices = parsed
                }
                self.hasSeenInitialState = true

                // Compute deltas. Only fire HUD events AFTER the
                // first poll — the initial poll's "appearances"
                // are devices that were already paired before we
                // started; not user-initiated connects.
                guard alreadyAnnounced else { return }
                let prevIDs = Set(previous.map { $0.id })
                let newIDs = Set(parsed.map { $0.id })
                for device in parsed where !prevIDs.contains(device.id) {
                    self.onDeviceConnected?(device)
                }
                for device in previous where !newIDs.contains(device.id) {
                    self.onDeviceDisconnected?(device)
                }
            }
        }
    }

    /// Synchronous, blocking — must be called off the main queue.
    /// `nonisolated` so the background DispatchQueue closure can
    /// invoke it without a Swift Concurrency actor-hop warning;
    /// the function only touches local Process/Pipe state and
    /// pure functions (parse/parsePercent), no shared mutable
    /// state, so it's safe to run off-main.
    nonisolated private static func fetchAndParse() -> [Device] {
        let task = Process()
        // Per BUG-068: prefer the modern `executableURL` API.
        // `launchPath` is deprecated as of macOS 10.13.
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        // No `-detailLevel basic` — basic mode strips the
        // battery fields. Default detail level surfaces them
        // for AirPods (other devices may not report battery
        // at all; that's a per-device limitation, not ours).
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        // Route stderr to /dev/null so a verbose warning from
        // system_profiler can't fill its pipe and block the child
        // process. Earlier `Pipe()` would have eventually backed
        // up; FileHandle.nullDevice has unlimited drain.
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            NSLog("BluetoothDeviceService: process failed: \(error)")
            return []
        }
        // Per BUG-033 fix: hard timeout instead of an unbounded
        // `waitUntilExit()`. system_profiler can hang for tens of
        // seconds in certain Bluetooth driver states (corrupted
        // pairing records, scanning hung-up between sleep cycles)
        // — the old code would block the utility-queue worker
        // thread forever, eventually exhausting the pool if
        // multiple polls stacked up. 10s is comfortably above the
        // 1-2s normal completion time for system_profiler with
        // SPBluetoothDataType but well below the human notice
        // threshold for "the pill froze."
        let watchdog = DispatchWorkItem {
            if task.isRunning {
                NSLog("BluetoothDeviceService: system_profiler exceeded 10s, terminating")
                task.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
        task.waitUntilExit()
        watchdog.cancel()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bt = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }
        return parse(btSection: bt)
    }

    /// Walk the SPBluetoothDataType array. Each top-level object
    /// has keys like `device_connected` / `device_not_connected`,
    /// each holding an array of `[name: deviceDict]` pairs. We
    /// only care about connected devices with battery info.
    nonisolated private static func parse(btSection: [[String: Any]]) -> [Device] {
        var out: [Device] = []
        for entry in btSection {
            guard let connectedList = entry["device_connected"] as? [[String: Any]] else { continue }
            for deviceWrapper in connectedList {
                // Each entry is a single-key dict where the key is
                // the device name and the value is its info dict.
                for (name, raw) in deviceWrapper {
                    guard let info = raw as? [String: Any] else { continue }
                    if let device = parse(name: name, info: info) {
                        out.append(device)
                    }
                }
            }
        }
        return out
    }

    nonisolated private static func parse(name: String, info: [String: Any]) -> Device? {
        let address = (info["device_address"] as? String) ?? name
        let minorType = (info["device_minorType"] as? String) ?? ""
        let isAirPods = minorType.lowercased().contains("airpod") ||
                        name.lowercased().contains("airpods")

        // Battery keys vary across macOS versions:
        //   • macOS 14+: device_batteryLevelMain / Left / Right / Case
        //   • older: device_BatteryPercentLeft / Right / Case
        // Try both, take whichever yields a value.
        let main = readPercent(info, keys: [
            "device_batteryLevelMain",
            "device_BatteryLevelMain",
            "device_batteryPercentSingle",
        ])
        let left = readPercent(info, keys: [
            "device_batteryLevelLeft",
            "device_BatteryPercentLeft",
        ])
        let right = readPercent(info, keys: [
            "device_batteryLevelRight",
            "device_BatteryPercentRight",
        ])
        let kase = readPercent(info, keys: [
            "device_batteryLevelCase",
            "device_BatteryPercentCase",
        ])

        let device = Device(
            id: address,
            name: name,
            isAirPods: isAirPods,
            batteryMain: main,
            batteryLeft: left,
            batteryRight: right,
            batteryCase: kase
        )
        return device.hasBattery ? device : nil
    }

    /// Battery percent values in the JSON come either as `"83%"`
    /// strings or bare integers depending on macOS version.
    /// Tolerant of both shapes; returns nil if neither parses.
    nonisolated private static func readPercent(_ info: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let raw = info[key] {
                if let num = raw as? Int { return num }
                if let dbl = raw as? Double { return Int(dbl) }
                if let str = raw as? String {
                    let trimmed = str.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
                    if let n = Int(trimmed) { return n }
                }
            }
        }
        return nil
    }
}

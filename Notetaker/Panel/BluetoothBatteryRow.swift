import SwiftUI

/// Compact "what's connected" strip that lives below the music card's
/// source badge. Shows the AirPods/headphones currently connected
/// with their battery levels — a feature consistently asked-for in
/// notch HUD app reviews ("AirPods battery widget" is the #1 thing
/// MacNotch sells around). Hidden when no device with a battery
/// reading is connected, so it never draws empty space.
struct BluetoothBatteryRow: View {
    @EnvironmentObject var bluetooth: BluetoothDeviceService

    /// Filter to devices with at least one battery reading. The
    /// service already drops batteryless devices, but defensive
    /// filter here too so a future refactor of the service can't
    /// suddenly start showing a row for the trackpad.
    private var visible: [BluetoothDeviceService.Device] {
        bluetooth.devices.filter { $0.hasBattery }
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(spacing: 6) {
                ForEach(visible) { device in
                    DeviceTile(device: device)
                }
            }
            .padding(.horizontal, 16)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private struct DeviceTile: View {
    let device: BluetoothDeviceService.Device

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isAirPods ? "airpodspro" : "headphones")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 18)

            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // Per-bud / case readings when AirPods, single number
            // otherwise. Mini battery glyphs (filled rectangle whose
            // width tracks the percent) keep the row scannable.
            HStack(spacing: 8) {
                if let l = device.batteryLeft {
                    BatteryPill(label: "L", percent: l)
                }
                if let r = device.batteryRight {
                    BatteryPill(label: "R", percent: r)
                }
                if let c = device.batteryCase {
                    BatteryPill(label: "C", percent: c)
                }
                if device.batteryLeft == nil && device.batteryRight == nil,
                   let main = device.batteryMain {
                    BatteryPill(label: nil, percent: main)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

private struct BatteryPill: View {
    let label: String?
    let percent: Int

    /// Color follows the percent: green ≥ 30%, amber ≥ 15%, red
    /// below. Same threshold convention macOS uses on the menu-bar
    /// battery icon.
    private var color: Color {
        if percent < 15 { return Color(red: 0.95, green: 0.30, blue: 0.30) }
        if percent < 30 { return Color(red: 0.99, green: 0.72, blue: 0.20) }
        return Color(red: 0.30, green: 0.85, blue: 0.45)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 10, alignment: .leading)
            }
            // Bar that fills proportionally to `percent`.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 22, height: 6)
                Capsule()
                    .fill(color)
                    .frame(width: max(2, 22 * CGFloat(percent) / 100), height: 6)
            }
            Text("\(percent)%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 30, alignment: .trailing)
        }
    }
}

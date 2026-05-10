import SwiftUI
import AppKit
import Carbon.HIToolbox

/// SwiftUI control for capturing a global-hotkey combo.
///
/// User clicks the chip → the chip enters "recording" mode, an
/// embedded NSView claims first responder, and the next non-modifier
/// keypress (with whatever modifiers are held) becomes the bound
/// shortcut. The captured combo is converted to Carbon `keyCode` +
/// `modifiers` (the format `RegisterEventHotKey` consumes) and
/// written to the bindings the parent owns.
///
/// Used by Settings → Dictation → Hotkey when the user picks the
/// "Custom shortcut" trigger mode. Lets users on non-Apple keyboards
/// (no Fn key) bind any combination — `⌃⌥M`, `F19`, `⇧Space`,
/// whatever feels right on their hardware.
///
/// Carbon vs Cocoa modifiers: NSEvent reports modifier flags as
/// `NSEvent.ModifierFlags` (Cocoa). Carbon's RegisterEventHotKey
/// wants its own bitmask (`cmdKey | shiftKey | optionKey | controlKey`).
/// `cocoaToCarbonModifiers(_:)` handles the conversion.
struct KeyShortcutCapture: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    /// True while the embedded view is the first responder and
    /// listening for the next keypress. Click the chip to start
    /// capturing; click outside or press Escape to cancel.
    @State private var capturing: Bool = false

    var body: some View {
        Button {
            capturing = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: capturing ? "circle.fill" : "command")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(capturing ? .red : .white.opacity(0.55))
                Text(displayText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if hasBinding && !capturing {
                    Button {
                        keyCode = 0
                        modifiers = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(capturing
                          ? Color.red.opacity(0.10)
                          : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(capturing
                                  ? Color.red.opacity(0.45)
                                  : Color.white.opacity(0.12),
                                  lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .background(
            // Hidden NSView that captures the actual keyDown event.
            // Stays in the view tree always so the responder chain
            // reaches it; only listens when `capturing` is true.
            KeyCaptureRepresentable(
                capturing: $capturing,
                onCapture: { code, mods in
                    keyCode = Int(code)
                    modifiers = Int(mods)
                    capturing = false
                }
            )
            .frame(width: 0, height: 0)
        )
    }

    private var hasBinding: Bool {
        keyCode != 0
    }

    /// Pretty-prints the current binding as `⌘⇧D` etc. When
    /// recording, shows a prompt instead. When unbound, shows
    /// "Click to record."
    private var displayText: String {
        if capturing {
            return "Press a key…"
        }
        if !hasBinding {
            return "Click to record"
        }
        return Self.formatShortcut(keyCode: UInt32(keyCode),
                                   modifiers: UInt32(modifiers))
    }

    /// Format a Carbon keyCode + modifier mask as a human-readable
    /// string like `⌘⇧D` or `⌃⌥F19`. Used by the chip label and
    /// could be exposed to other surfaces (e.g. a tooltip on the
    /// dictation pill saying "Press ⌘⇧D again to stop").
    static func formatShortcut(keyCode: UInt32, modifiers: UInt32) -> String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        out += keyCodeName(keyCode)
        return out
    }

    /// Maps Carbon keyCodes to display strings. Covers the common
    /// keys; falls back to "key 42" for anything weird so the user
    /// at least sees the binding worked.
    private static func keyCodeName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space:        return "Space"
        case kVK_Return:       return "Return"
        case kVK_Tab:          return "Tab"
        case kVK_Escape:       return "Esc"
        case kVK_Delete:       return "Delete"
        case kVK_ForwardDelete: return "Fwd Del"
        case kVK_LeftArrow:    return "←"
        case kVK_RightArrow:   return "→"
        case kVK_UpArrow:      return "↑"
        case kVK_DownArrow:    return "↓"
        case kVK_F1:  return "F1"
        case kVK_F2:  return "F2"
        case kVK_F3:  return "F3"
        case kVK_F4:  return "F4"
        case kVK_F5:  return "F5"
        case kVK_F6:  return "F6"
        case kVK_F7:  return "F7"
        case kVK_F8:  return "F8"
        case kVK_F9:  return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_ANSI_Comma:        return ","
        case kVK_ANSI_Period:       return "."
        case kVK_ANSI_Slash:        return "/"
        case kVK_ANSI_Semicolon:    return ";"
        case kVK_ANSI_Quote:        return "'"
        case kVK_ANSI_LeftBracket:  return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash:    return "\\"
        case kVK_ANSI_Minus:        return "-"
        case kVK_ANSI_Equal:        return "="
        case kVK_ANSI_Grave:        return "`"
        default: return "key \(code)"
        }
    }
}

// MARK: - NSView bridge

/// Bridges an NSView's keyDown handler to SwiftUI. Becomes first
/// responder while `capturing == true`; releases on capture or
/// cancel. Filters out modifier-only presses (e.g. just ⌘) since
/// those alone aren't a usable hotkey.
private struct KeyCaptureRepresentable: NSViewRepresentable {
    @Binding var capturing: Bool
    let onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = { code, mods in
            onCapture(code, mods)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = { code, mods in
            onCapture(code, mods)
        }
        if capturing && nsView.window?.firstResponder !== nsView {
            // Hop async so SwiftUI's render pass settles first; without
            // this, makeFirstResponder runs while the view tree is
            // still mid-update and the responder change is dropped.
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        } else if !capturing && nsView.window?.firstResponder === nsView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nil)
            }
        }
    }
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Cocoa → Carbon modifier conversion.
        let cocoa = event.modifierFlags
        var carbon: UInt32 = 0
        if cocoa.contains(.command)  { carbon |= UInt32(cmdKey) }
        if cocoa.contains(.shift)    { carbon |= UInt32(shiftKey) }
        if cocoa.contains(.option)   { carbon |= UInt32(optionKey) }
        if cocoa.contains(.control)  { carbon |= UInt32(controlKey) }

        // Escape cancels capture without binding anything.
        if event.keyCode == kVK_Escape {
            window?.makeFirstResponder(nil)
            return
        }

        // Modifier-only presses (e.g. tapping ⌘) aren't valid
        // shortcuts — they'd never fire because there's no key. The
        // event we want is when a real key is pressed WITH modifiers.
        let keyCode = UInt32(event.keyCode)
        onCapture?(keyCode, carbon)
    }

    /// Required to handle keyDown without an NSError beep.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // We accept keyEquivalents while capturing so the user can
        // bind even system-level combos (⌘W, ⌘Q etc.) — though doing
        // so is at the user's own risk; their bound combo will
        // shadow nox's own behavior of those keys.
        if window?.firstResponder === self {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

import Foundation

// MARK: - Wiring Spec (for coordinator)
//
// Per Sprint 2026-05-17 §4 Session 4. The policy itself ships
// stand-alone; this block lists the four shared-file edits the
// coordinator session must apply for the feature to surface.
//
// 1. SettingsKeys to add (Notetaker/Settings/SettingsWindow.swift,
//    inside the `enum SettingsKey` block — group them right after
//    the existing `respectFocusMode` constant at ~line 128):
//
//       /// Per-pill "allow during Focus" exceptions. When the
//       /// master `respectFocusMode` is on AND macOS Focus is
//       /// active, ambient pills are normally suppressed; each
//       /// of these allows ONE pill type to punch through. All
//       /// default false (current behavior — full suppression
//       /// — is preserved for users who don't visit the new
//       /// indented rows).
//       static let allowChargingDuringFocus    = "allowChargingDuringFocus"
//       static let allowAirDropDuringFocus     = "allowAirDropDuringFocus"
//       static let allowBluetoothDuringFocus   = "allowBluetoothDuringFocus"
//       static let allowScreenshotDuringFocus  = "allowScreenshotDuringFocus"
//
// 2. SettingsWindow.swift UI additions, inside `GeneralSettings`,
//    under the existing "Behaviour" `GroupTitle` / `SettingsCard`
//    (~lines 819-851). The four new rows slot directly UNDER the
//    "Auto-hide pills during Focus" row (~line 825-835), and read
//    as visually-indented children of it. Use a leading 18pt
//    padding on the row's title block to match the Settings.app
//    "indented sub-toggle" convention (System Settings →
//    Notifications → per-app summary rows use ~18pt).
//
//       @AppStorage(SettingsKey.allowChargingDuringFocus)    private var allowChargingDuringFocus:    Bool = false
//       @AppStorage(SettingsKey.allowAirDropDuringFocus)     private var allowAirDropDuringFocus:     Bool = false
//       @AppStorage(SettingsKey.allowBluetoothDuringFocus)   private var allowBluetoothDuringFocus:   Bool = false
//       @AppStorage(SettingsKey.allowScreenshotDuringFocus)  private var allowScreenshotDuringFocus:  Bool = false
//
//    Rows (insert AFTER the `Auto-hide pills during Focus`
//    SettingsRow, BEFORE the "AirDrop arrival pill" row). Each
//    is a child toggle of the master one — they only have an
//    effect when the master is on AND macOS Focus is active, so
//    the subtitle should make that obvious:
//
//       SettingsRow(title: "    Charging",
//                   subtitle: "Show charging pill even while a Focus mode is active.") {
//           Toggle("", isOn: $allowChargingDuringFocus).labelsHidden()
//       }
//       SettingsRow(title: "    AirDrop",
//                   subtitle: "Show AirDrop arrival pill even while a Focus mode is active.") {
//           Toggle("", isOn: $allowAirDropDuringFocus).labelsHidden()
//       }
//       SettingsRow(title: "    Bluetooth",
//                   subtitle: "Show Bluetooth connect / disconnect pill even while a Focus mode is active.") {
//           Toggle("", isOn: $allowBluetoothDuringFocus).labelsHidden()
//       }
//       SettingsRow(title: "    Screenshot",
//                   subtitle: "Show screenshot-saved pill even while a Focus mode is active.") {
//           Toggle("", isOn: $allowScreenshotDuringFocus).labelsHidden()
//       }
//
//    (Four-space prefix on `title` is the cheap indent trick that
//    works inside the existing SettingsRow without adding a new
//    indented-row variant. If the coordinator prefers a structural
//    indent, wrap the four rows in a `Group { ... }.padding(.leading,
//    18)` inside the same `SettingsCard` — but the prefix-spaces
//    approach is one diff line per row and stays inside the existing
//    SettingsCard separator pattern.)
//
// 3. Call-site rewrite in Notetaker/Panel/PanelPresenter.swift
//    `setPendingSystemEvent(_:)` (~lines 735-778). The current
//    inline `muteByFocus` closure (lines 763-767) does:
//
//       let muteByFocus: Bool = {
//           guard isFocused else { return false }
//           if UserDefaults.standard.object(forKey: "respectFocusMode") == nil { return true }
//           return UserDefaults.standard.bool(forKey: "respectFocusMode")
//       }()
//
//    Replace the muteByFocus block with the per-pill gate below.
//    AirDrop / download / note-saved events keep their current
//    behavior (they fall through `pillForEvent == nil` and so the
//    gate returns "show" — matching their current isMutedByFocus
//    exclusions). When the coordinator later wants AirDrop to
//    also become focus-gated, all that's needed is mapping
//    `.airDropReceived` / `.airDropSent` / `.airDropFailed` to
//    `.airdrop` in `pillForEvent` and adding `.airDropReceived`
//    et al to `isMutedByFocus`.
//
//       let pillForEvent: PillType? = {
//           switch event {
//           case .charging:                                 return .charging
//           case .screenshotSaved:                          return .screenshot
//           case .bluetoothConnected, .bluetoothDisconnected: return .bluetooth
//           default: return nil
//           }
//       }()
//       let allowDuringFocus: Set<PillType> = {
//           let d = UserDefaults.standard
//           var s = Set<PillType>()
//           if d.bool(forKey: SettingsKey.allowChargingDuringFocus)   { s.insert(.charging) }
//           if d.bool(forKey: SettingsKey.allowAirDropDuringFocus)    { s.insert(.airdrop) }
//           if d.bool(forKey: SettingsKey.allowBluetoothDuringFocus)  { s.insert(.bluetooth) }
//           if d.bool(forKey: SettingsKey.allowScreenshotDuringFocus) { s.insert(.screenshot) }
//           return s
//       }()
//       let muteByFocus: Bool = {
//           guard let pill = pillForEvent else { return false }
//           let respect: Bool = {
//               if UserDefaults.standard.object(forKey: "respectFocusMode") == nil { return true }
//               return UserDefaults.standard.bool(forKey: "respectFocusMode")
//           }()
//           return !FocusGatingPolicy.shouldShow(
//               pill: pill,
//               isFocused: isFocused,
//               respectFocus: respect,
//               allowList: allowDuringFocus)
//       }()
//
//    Leave the `muteByQuiet` and `muteByStudy` branches untouched —
//    they aren't per-pill and don't route through this policy.
//
// 4. Xcode project membership (Notetaker.xcodeproj/project.pbxproj):
//    Register both files in the Compile Sources phase, matching the
//    pattern coordinator uses for the other three new sprint files.
//
//       Notetaker/Services/FocusGatingPolicy.swift   → Notetaker target
//       NotetakerTests/FocusGatingPolicyTests.swift  → NotetakerTests target
//
// END WIRING SPEC

/// Per-pill Focus-mode visibility gate.
///
/// nox has shipped a master "Auto-hide pills during Focus"
/// toggle (`SettingsKey.respectFocusMode`, default true) since
/// before this file existed. Flipping it on makes every ambient
/// pill — charging, screenshot, Bluetooth, etc. — go quiet
/// whenever macOS Focus or DND is active. That's the right
/// default for most users; the trade is that you lose ALL
/// ambient acknowledgement, including the ones you may actually
/// want during deep work.
///
/// **Rule:** a pill is shown iff macOS Focus is OFF, OR the
/// user has disabled respect-Focus globally, OR the user has
/// granted this specific pill an exception via the indented
/// child toggle under General → Behaviour. Otherwise it's
/// suppressed (current default behavior).
///
/// Motivation (sprint doc 2026-05-17 §4 Session 4): from the
/// forensic decode of Alcove, the per-pill exception is the
/// feature users reach for after a week of living with full
/// suppression — they want chargers visible while Focused
/// (battery-anxiety beats Focus discipline) but still want
/// random Bluetooth / download chatter swallowed. Modeling the
/// exception as a `Set<PillType>` matches that mental model:
/// the master toggle is "off by default", individual pills can
/// be added back.
///
/// Extracted as a pure decision function (no UserDefaults read,
/// no @AppStorage, no AppKit / SwiftUI imports) so the four
/// branches can be exercised by `FocusGatingPolicyTests` without
/// touching the rest of the slab. Call-site reads the global
/// flags + per-pill flags as UserDefaults bools and passes them
/// in; see the Wiring Spec above for the exact
/// `PanelPresenter.setPendingSystemEvent` rewrite.
enum FocusGatingPolicy {
    /// True iff the pill should be displayed given the current
    /// Focus state and the user's exception preferences.
    ///
    /// - Parameters:
    ///   - pill: which ambient pill is asking. Affects only the
    ///     focused-AND-respecting branch — the other two short-
    ///     circuit before consulting it.
    ///   - isFocused: macOS Focus / DND is currently active (per
    ///     `FocusStatusService.isFocused`). When false, returns
    ///     true unconditionally — the gate is a no-op outside of
    ///     active Focus.
    ///   - respectFocus: the master `SettingsKey.respectFocusMode`
    ///     toggle. When false the user has globally opted out of
    ///     Focus suppression and per-pill exceptions are moot.
    ///   - allowList: the set of pill types the user has flipped
    ///     ON via the indented child toggles. Empty by default —
    ///     matches the existing "fully suppressed during Focus"
    ///     behavior for any user who never visits the new rows.
    static func shouldShow(
        pill: PillType,
        isFocused: Bool,
        respectFocus: Bool,
        allowList: Set<PillType>
    ) -> Bool {
        guard isFocused else { return true }
        guard respectFocus else { return true }
        return allowList.contains(pill)
    }
}

/// The four ambient pill types this policy covers.
///
/// Scope is intentionally narrow: music, notes, calendar, and
/// timer pills each have their own visibility rules (now-playing
/// is anchored on `presenter.nowPlaying`, calendar reminders are
/// always-show by Focus-gate exemption in
/// `PanelPresenter.isMutedByFocus`, etc.) and don't slot into
/// the per-pill exception model. Adding them would mean either
/// breaking those other rules or shipping a toggle that does
/// nothing — both worse than leaving them out.
enum PillType: Hashable {
    case charging
    case airdrop
    case bluetooth
    case screenshot
}

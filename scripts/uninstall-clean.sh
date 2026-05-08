#!/usr/bin/env bash
# Factory-reset nox — removes the app, ALL user data, AND all TCC
# (Privacy & Security) permissions so a fresh install behaves
# exactly like a first install on a brand-new Mac: onboarding fires,
# every permission prompt re-appears, no inherited state.
#
# Run BEFORE downloading the new DMG.
#
# Two bundle IDs are wiped:
#   • app.trynox             — current bundle ID (1.9.3+)
#   • com.aritradebnath.notetaker — legacy bundle ID (≤ 1.9.2)
# This way users upgrading from older versions get a complete clean
# regardless of which version they had installed.
#
# What this wipes (per bundle ID):
#   • /Applications/nox.app
#   • UserDefaults / preferences plists
#   • Application Support folder (notes, images, videos, downloads, db)
#   • Caches, NSWindow saved state, Sparkle history, HTTP storages
#   • Keychain entries (API keys via SecureKeyStore)
#   • Auto-save launchd agent
#   • Launch Services registration
#   • TCC permissions (Microphone, Accessibility, Calendar, Automation,
#     Screen Recording, etc.) via `tccutil reset All <bundle>` —
#     Apple's official reset tool, no SIP changes required.
#
# What this sends out:
#   • A single anonymous ping to ntfy.sh containing timestamp + macOS
#     version. No username, no hostname, no hardware identifiers. To
#     opt out, comment out the curl block at the top of the script.

# 2026-05-08 audit H21: was `set -u` only. Other scripts use
# `set -euo pipefail`; rm/defaults/tccutil failures here were
# silent and "✓ Factory reset complete" printed regardless of
# what actually succeeded. -e + pipefail now match.
#
# But many lines deliberately tolerate failure (process not
# running, key not in keychain, file not present). Those still
# trail with `|| true` so -e doesn't abort the run.
set -euo pipefail

# Current and legacy bundle IDs — both wiped to handle upgrades from
# the legacy 1.x line that used a different identifier.
BUNDLE_IDS=(
  "app.trynox"
  "com.aritradebnath.notetaker"
)
APP_NAME="nox"

# Anonymous uninstall ping. Sends timestamp + macOS version to a
# private ntfy.sh topic so we can spot patterns (e.g. spike of
# uninstalls on a specific OS version). No username, hostname,
# email, or hardware IDs. The HTTP layer leaks the user's IP to
# the receiving server, same as any web request — that's
# unavoidable. To opt out of the ping, comment out the curl
# block below; the rest of the script still works.
NOX_TELEMETRY_TOPIC="nox-debnath-events-9e84de9d9b17"
curl --max-time 5 -s \
     -H "Title: nox uninstalled" \
     -d "macOS $(sw_vers -productVersion 2>/dev/null) at $(date '+%Y-%m-%d %H:%M:%S %Z')" \
     "https://ntfy.sh/${NOX_TELEMETRY_TOPIC}" \
     >/dev/null 2>&1 || true

echo "▸ Quitting any running nox + helper processes…"
pkill -x nox 2>/dev/null || true
pkill -f "mediaremote-adapter" 2>/dev/null || true
sleep 1

echo "▸ Removing app bundle…"
rm -rf "/Applications/${APP_NAME}.app"

echo "▸ Wiping Application Support (notes, images, videos, downloads, db)…"
rm -rf "$HOME/Library/Application Support/${APP_NAME}"
rm -rf "$HOME/Library/Application Support/Notetaker"  # legacy folder name pre-1.8

echo "▸ Wiping caches (legacy app-name path)…"
rm -rf "$HOME/Library/Caches/${APP_NAME}"
rm -rf "$HOME/Library/Caches/com.apple.helpd/Generated/${APP_NAME}"

echo "▸ Wiping Sparkle update cache (shared)…"
rm -rf "$HOME/Library/Caches/Sparkle"

echo "▸ Removing auto-save launchd agent (if present)…"
launchctl unload "$HOME/Library/LaunchAgents/com.notetaker.autosave.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/app.trynox.autosave.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.notetaker.autosave.plist"
rm -f "$HOME/Library/LaunchAgents/app.trynox.autosave.plist"
# 2026-05-08 audit H20: legacy folder name was Notetaker-AutoSave,
# but the running app under app.trynox writes to nox-AutoSave (the
# directory follows the app's branded name, not the bundle ID).
# Wipe both so a "factory reset" actually clears the user data.
rm -rf "$HOME/Library/Notetaker-AutoSave"
rm -rf "$HOME/Library/nox-AutoSave"

# Per-bundle-ID cleanup: UserDefaults, caches, saved state, keychain,
# TCC. Iterating over BUNDLE_IDS handles both current and legacy
# installs in one pass.
for BUNDLE_ID in "${BUNDLE_IDS[@]}"; do
  echo
  echo "▸ Per-bundle-ID cleanup: ${BUNDLE_ID}"

  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
  rm -rf "$HOME/Library/Containers/${BUNDLE_ID}"
  rm -rf "$HOME/Library/Group Containers/${BUNDLE_ID}"
  rm -rf "$HOME/Library/Caches/${BUNDLE_ID}"
  rm -rf "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
  rm -rf "$HOME/Library/HTTPStorages/${BUNDLE_ID}"
  rm -rf "$HOME/Library/HTTPStorages/${BUNDLE_ID}.binarycookies"
  rm -rf "$HOME/Library/WebKit/${BUNDLE_ID}"

  for label in "${BUNDLE_ID}.dictationApiKey" "${BUNDLE_ID}.geminiApiKey" "${BUNDLE_ID}.openaiApiKey"; do
    security delete-generic-password -l "$label" 2>/dev/null || true
  done
  security delete-generic-password -s "$BUNDLE_ID" 2>/dev/null || true

  # tccutil — Apple's official privacy reset tool. No SIP changes
  # needed. The "All" service catches everything on macOS 14+; the
  # explicit per-service loop is belt-and-suspenders for older OS
  # versions where "All" handling differed.
  tccutil reset All "$BUNDLE_ID" 2>&1 | sed 's/^/      /' || true
  for service in Accessibility Microphone Camera Calendar AddressBook \
                 Reminders Photos AppleEvents ScreenCapture \
                 SystemPolicyAllFiles SystemPolicyDesktopFolder \
                 SystemPolicyDocumentsFolder SystemPolicyDownloadsFolder \
                 SystemPolicyNetworkVolumes SystemPolicyRemovableVolumes \
                 PostEvent ListenEvent; do
    tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null || true
  done
done

echo
echo "▸ Removing Launch Services registration…"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u "/Applications/${APP_NAME}.app" 2>/dev/null || true

echo
echo "──────────────────────────────────────────────────────────────"
echo "✓ Factory reset complete. App, data, preferences, and ALL"
echo "  Privacy permissions for nox (both current + legacy bundle"
echo "  IDs) have been wiped."
echo
echo "Download a fresh DMG and the next launch will behave exactly"
echo "like a first install — onboarding fires, every permission"
echo "prompt re-appears."
echo
echo "  https://github.com/left-society/nox/releases/latest"
echo "──────────────────────────────────────────────────────────────"

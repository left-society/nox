#!/usr/bin/env bash
# Factory-reset nox — removes the app, ALL user data, AND all TCC
# (Privacy & Security) permissions so a fresh install behaves
# exactly like a first install on a brand-new Mac: onboarding fires,
# every permission prompt re-appears, no inherited state.
#
# Run BEFORE downloading the new DMG.
#
# What this wipes:
#   • /Applications/nox.app
#   • UserDefaults / preferences (com.aritradebnath.notetaker.plist)
#   • Application Support folder (notes, images, videos, downloads, db)
#   • Caches, NSWindow saved state, Sparkle history, HTTP storages
#   • Keychain entries (API keys via SecureKeyStore)
#   • Auto-save launchd agent
#   • Launch Services registration
#   • TCC permissions (Microphone, Accessibility, Calendar, Automation,
#     Screen Recording, etc.) via `tccutil reset All <bundle>` —
#     Apple's official reset tool, no SIP changes required.

set -u

BUNDLE_ID="com.aritradebnath.notetaker"
APP_NAME="nox"

echo "▸ Quitting any running nox + helper processes…"
pkill -x nox 2>/dev/null || true
pkill -f "mediaremote-adapter" 2>/dev/null || true
sleep 1

echo "▸ Removing app bundle…"
rm -rf "/Applications/${APP_NAME}.app"

echo "▸ Wiping UserDefaults / preferences…"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
# Container plists for older macOS preference paths
rm -rf "$HOME/Library/Containers/${BUNDLE_ID}"
rm -rf "$HOME/Library/Group Containers/${BUNDLE_ID}"

echo "▸ Wiping Application Support (notes, images, videos, downloads, db)…"
rm -rf "$HOME/Library/Application Support/${APP_NAME}"
rm -rf "$HOME/Library/Application Support/Notetaker"  # legacy folder name

echo "▸ Wiping caches…"
rm -rf "$HOME/Library/Caches/${BUNDLE_ID}"
rm -rf "$HOME/Library/Caches/${APP_NAME}"
rm -rf "$HOME/Library/Caches/com.apple.helpd/Generated/${APP_NAME}"

echo "▸ Wiping NSWindow saved state…"
rm -rf "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"

echo "▸ Wiping Sparkle update cache…"
rm -rf "$HOME/Library/Caches/Sparkle"

echo "▸ Wiping HTTP storages (cookies, cache)…"
rm -rf "$HOME/Library/HTTPStorages/${BUNDLE_ID}"
rm -rf "$HOME/Library/HTTPStorages/${BUNDLE_ID}.binarycookies"

echo "▸ Wiping WebKit data (link previews)…"
rm -rf "$HOME/Library/WebKit/${BUNDLE_ID}"

echo "▸ Removing auto-save launchd agent (if present)…"
launchctl unload "$HOME/Library/LaunchAgents/com.notetaker.autosave.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.notetaker.autosave.plist"
# Also any lingering autosave folder
rm -rf "$HOME/Library/Notetaker-AutoSave"

echo "▸ Wiping keychain entries (API keys)…"
# nox uses SecureKeyStore which stores generic passwords keyed by
# bundle ID + slot name. Try common slots; missing entries are fine.
for label in "${BUNDLE_ID}.dictationApiKey" "${BUNDLE_ID}.geminiApiKey" "${BUNDLE_ID}.openaiApiKey"; do
  security delete-generic-password -l "$label" 2>/dev/null || true
done
# Catch-all by service name
security delete-generic-password -s "$BUNDLE_ID" 2>/dev/null || true

echo "▸ Removing Launch Services registration…"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u "/Applications/${APP_NAME}.app" 2>/dev/null || true

echo "▸ Resetting TCC (Privacy) permissions via tccutil…"
# `tccutil reset All <bundle-id>` is Apple's official tool to reset
# all privacy permissions for a single app. No SIP changes needed.
# Output looks like "Successfully reset All approval status for
# com.aritradebnath.notetaker"; redirected to keep this clean.
tccutil reset All "$BUNDLE_ID" 2>&1 | sed 's/^/      /' || true
# Belt-and-suspenders: also reset each individual service in case the
# global "All" pass missed something on this macOS version.
for service in Accessibility Microphone Camera Calendar AddressBook \
               Reminders Photos AppleEvents ScreenCapture \
               SystemPolicyAllFiles SystemPolicyDesktopFolder \
               SystemPolicyDocumentsFolder SystemPolicyDownloadsFolder \
               SystemPolicyNetworkVolumes SystemPolicyRemovableVolumes \
               PostEvent ListenEvent; do
  tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null || true
done

echo
echo "──────────────────────────────────────────────────────────────"
echo "✓ Factory reset complete. App, data, preferences, and ALL"
echo "  Privacy permissions for nox have been wiped."
echo
echo "Download a fresh DMG and the next launch will behave exactly"
echo "like a first install — onboarding fires, every permission"
echo "prompt re-appears."
echo
echo "  https://github.com/left-society/nox/releases/latest"
echo "──────────────────────────────────────────────────────────────"

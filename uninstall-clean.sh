#!/usr/bin/env bash
# Clean-uninstall nox — removes the app and ALL user data so a fresh
# install behaves like a first install (onboarding fires, permission
# prompts re-appear within their TCC-allowed scope).
#
# Run BEFORE downloading the new DMG. After this script completes,
# also follow the manual TCC step it prints at the end.
#
# What this wipes:
#   • /Applications/nox.app
#   • UserDefaults / preferences (~/Library/Preferences/com.aritradebnath.notetaker.plist)
#   • Application Support folder (notes, images, videos, downloads, SQLite db)
#   • Caches
#   • NSWindow restoration state
#   • Sparkle update history
#   • Keychain entries (API keys stored via SecureKeyStore)
#   • Auto-save launchd agent (if installed)
#
# What it CANNOT wipe (Apple privacy guarantee):
#   • TCC permissions (Privacy & Security panel) — must be removed
#     manually in System Settings, see end of script.

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

echo
echo "──────────────────────────────────────────────────────────────"
echo "✓ App + data + preferences wiped."
echo
echo "⚠️  TCC (Privacy) permissions CANNOT be cleared programmatically."
echo "    Apple intentionally locked this down — even sudo can't touch"
echo "    the TCC database without disabling SIP."
echo
echo "    Manually remove nox from each of these in System Settings →"
echo "    Privacy & Security:"
echo
echo "      • Microphone"
echo "      • Accessibility"
echo "      • Calendar"
echo "      • Automation (any apps nox controls)"
echo "      • Screen Recording (if listed)"
echo "      • Files and Folders (if listed)"
echo
echo "    For each panel, find 'nox' in the list and click the (-) button."
echo "    Or toggle off, then on, to force a re-prompt on next launch."
echo
echo "Then download a fresh DMG:"
echo "  https://github.com/left-society/nox/releases/latest"
echo "──────────────────────────────────────────────────────────────"

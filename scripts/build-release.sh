#!/usr/bin/env bash
# Build a Release .app, sign with the local NotetakerDevCert, and
# package into a DMG under dist/.
#
# Signing strategy:
#   • If `NotetakerDevCert` is in the user's login keychain, sign
#     with it. This matches the cert used during development, so
#     TCC permissions (Accessibility, Microphone) granted to dev
#     builds carry over to the shipped DMG without a re-grant
#     prompt for the same user. Released DMG installations on a
#     FRESH machine still need a one-time grant.
#   • If the cert isn't present (CI builds, fresh checkouts), fall
#     back to ad-hoc signing. First-run users on those builds
#     must right-click → Open and grant permissions normally.
#
# This is NOT Developer ID / notarization. Shipping that requires
# an Apple Developer account ($99/yr) and a notarization workflow
# — see docs/release-notarization.md (TODO) for the upgrade path.
#
# Notarization-ready hooks:
#   • Hardened runtime (`--options runtime`) is preserved in BOTH
#     signing paths so a future Developer ID + xcrun notarytool
#     pass works without re-signing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Notetaker"
CONFIG="Release"
# Product name is `nox` (set in Xcode project settings), distinct
# from the scheme name `Notetaker`. The .app file Xcode emits
# matches the product name, not the scheme.
PRODUCT_NAME="nox"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$PRODUCT_NAME.app"
# 2026-05-08 audit M29: previous fallback was `|| echo 1.0`, which
# silently produced `nox.1.0.dmg` if Info.plist was moved/missing
# / corrupted. Fail loudly instead — a bad version string here
# poisons the whole release pipeline (DMG path, appcast, etc.).
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Notetaker/Resources/Info.plist 2>/dev/null)" || {
  echo "✗ Could not read CFBundleShortVersionString from Info.plist." >&2
  echo "  Path: Notetaker/Resources/Info.plist" >&2
  exit 1
}
if [ -z "$VERSION" ]; then
  echo "✗ Empty CFBundleShortVersionString in Info.plist." >&2
  exit 1
fi
# DMG filename uses dots between the product name and the version
# (no hyphens per user direction). This also matches what GitHub
# does to filenames with spaces during release upload, so local
# and uploaded names stay identical and the publish script can
# resolve the asset URL by exact name match.
DMG_PATH="$DIST_DIR/nox.$VERSION.dmg"
STAGE="$(mktemp -d -t notetaker-dmg)"

# 2026-05-08 audit M31: clean up the staging dir on any exit
# path. Failed runs used to leak a full .app staging copy
# (~150-200 MB) under /var/folders/.../T/notetaker-dmg.XXXXXX.
trap 'rm -rf "$STAGE"' EXIT

# Signing identity selection, in priority order:
#   1. Developer ID Application (Apple-issued, notarization-eligible)
#      — proper shipping cert. Use this for any DMG that goes to
#      paying customers / public download.
#   2. NotetakerDevCert (self-signed dev cert) — used during
#      iteration so TCC permissions persist across builds, but
#      not notarization-eligible. Triggers Gatekeeper warnings.
#   3. Ad-hoc ("-") — fallback for fresh checkouts/CI without
#      either cert. Definitely not shippable.
#
# Override via env: BUILD_RELEASE_IDENTITY="..." bash build-release.sh
SIGN_IDENTITY="${BUILD_RELEASE_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')"
    echo "▸ Using Developer ID Application: $SIGN_IDENTITY"
  elif security find-certificate -c NotetakerDevCert ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    SIGN_IDENTITY="NotetakerDevCert"
    echo "▸ Using dev cert: NotetakerDevCert (NOT notarizable — dev builds only)"
  else
    SIGN_IDENTITY="-"
    echo "▸ No signing cert found — ad-hoc signing (DEFINITELY not shippable)"
  fi
fi

echo "▸ Clean + build Release…"
# 2026-05-08 audit M28: previous version redirected xcodebuild
# stdout+stderr to /dev/null. Under `set -e`, a failing build
# left the maintainer with zero diagnostic output. Capture to a
# log file alongside dist/, so failures are debuggable without
# losing the noise-free stdout for the success path.
rm -rf "$BUILD_DIR"
mkdir -p "$DIST_DIR"
XCODEBUILD_LOG="$DIST_DIR/build-xcodebuild-$VERSION.log"
if ! xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    clean build > "$XCODEBUILD_LOG" 2>&1; then
  echo "✗ xcodebuild failed — see $XCODEBUILD_LOG"
  echo "── tail of log ──"
  tail -40 "$XCODEBUILD_LOG"
  exit 1
fi

echo "▸ Sign with $SIGN_IDENTITY…"
# Sign nested binaries FIRST, then the outer app. `--deep` is
# deprecated for Developer ID + notarization (Apple's notary service
# rejects bundles where it was used) — it silently leaves nested
# binaries adhoc-signed, which Apple flags as
# "binary is not signed with a valid Developer ID certificate".
#
# Order matters: inner-out. If you sign the outer .app first, the
# embedded signature is invalidated when you re-sign the nested
# binaries afterwards, and re-signing the outer to fix that strips
# the inner signatures Apple just verified.
NESTED_BINS=(
  "$APP_PATH/Contents/Resources/bin/ffmpeg"
  "$APP_PATH/Contents/Resources/bin/yt-dlp"
)
# Helper-binary entitlements — disables library validation so
# yt-dlp can dlopen its bundled (upstream-signed) Python.framework
# at runtime. Without this, the user-reported "video downloading
# not working on client side" bug from 1.9.10: notarization passed,
# DMG installed clean, but yt-dlp died the moment it launched
# because dyld refused to load Python with a different TeamID.
# See nox-helpers.entitlements for the full backstory.
HELPERS_ENTITLEMENTS="$ROOT/Notetaker/Resources/nox-helpers.entitlements"
if [ ! -f "$HELPERS_ENTITLEMENTS" ]; then
  echo "✗ helper entitlements file missing: $HELPERS_ENTITLEMENTS"
  exit 1
fi
for bin in "${NESTED_BINS[@]}"; do
  if [ -f "$bin" ]; then
    echo "  ↳ sign nested: $(basename "$bin")"
    codesign --force \
      --sign "$SIGN_IDENTITY" \
      --options runtime \
      --timestamp \
      --entitlements "$HELPERS_ENTITLEMENTS" \
      "$bin"
  fi
done

# Re-sign every framework under Contents/Frameworks/. We do this
# generically (rather than hard-coding Sparkle) because frameworks
# come and go: MediaRemoteAdapter.framework, Sparkle.framework,
# anything we add later. Apple's notary requires every nested
# Mach-O in the bundle to carry Developer ID + hardened runtime +
# secure timestamp; and Xcode's Release build strips Headers/
# Modules/ from frameworks, breaking their `_CodeSignature` seal.
#
# For each framework:
#   1. Sign every helper Mach-O underneath (XPCServices, nested apps,
#      command-line helpers, .dylibs) — deepest first.
#   2. Re-seal the framework itself so its CodeResources manifest
#      matches the files actually present.
#
# Order is critical: parent signatures are invalidated when child
# signatures change, so we always go inner→outer.
# Walk the WHOLE bundle for frameworks — not just Contents/Frameworks/.
# MediaRemoteAdapter.framework lives under Contents/Resources/ (it's
# embedded as a resource, not a linked framework), and any other
# helper bundle could end up anywhere. A bundle-wide walk catches all.
shopt -s nullglob
while IFS= read -r -d '' fw; do
  fw_name="$(basename "$fw")"
  echo "  ↳ re-sign $fw_name (nested helpers)"
  # Find every Mach-O binary, .dylib, .xpc, and nested .app inside
  # the framework. Each gets its own signature with the same flags
  # Apple's notary requires.
  while IFS= read -r -d '' nested; do
    # Skip the framework's main binary — it's signed last (with the
    # framework itself) so its signature seals everything beneath it.
    fw_main="$fw/Versions/Current/$(basename "$fw" .framework)"
    fw_main_resolved="$(cd "$(dirname "$fw_main")" 2>/dev/null && pwd)/$(basename "$fw_main")"
    [ "$nested" = "$fw_main_resolved" ] && continue
    # Skip non-Mach-O regular files (resource assets, plists, etc.)
    file -b "$nested" 2>/dev/null | grep -q "Mach-O" || continue
    codesign --force \
      --sign "$SIGN_IDENTITY" \
      --options runtime \
      --timestamp \
      "$nested" 2>&1 | sed 's/^/      /'
  done < <(find "$fw" \( -type f -o -type l \) -print0)
  # Also walk nested .app and .xpc bundles — they need bundle-level
  # signatures, not just their executables.
  for bundle in "$fw"/Versions/*/XPCServices/*.xpc "$fw"/Versions/*/Updater.app; do
    [ -e "$bundle" ] || continue
    codesign --force \
      --sign "$SIGN_IDENTITY" \
      --options runtime \
      --timestamp \
      "$bundle" 2>&1 | sed 's/^/      /'
  done
  echo "  ↳ re-sign $fw_name (outer)"
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$fw"
done < <(find "$APP_PATH" -type d -name "*.framework" -print0)
shopt -u nullglob

# Now seal the outer .app. NO --deep here — nested components are
# already signed correctly; --deep would walk them again and could
# corrupt the signatures we just applied.
#
# CRITICAL: --entitlements MUST be passed here. Earlier builds shipped
# with hardened runtime ON and ZERO entitlements because:
#   1. The xcodebuild call uses CODE_SIGNING_ALLOWED=NO so Xcode
#      doesn't apply entitlements during build.
#   2. The manual codesign step here didn't pass --entitlements.
# Result: AppleScript bridge to Spotify/Music returned
# errAEEventNotPermitted; MediaRemote dlopen failed library
# validation; WhisperKit JIT crashed silently mid-transcription.
# Users saw "I clicked dictate but nothing happened" with no error
# bubbling up — the recording succeeded, the JIT-during-transcribe
# step took the process down quietly. nox.entitlements declares the
# four flags we need (cs.disable-library-validation,
# automation.apple-events, cs.allow-jit, cs.allow-unsigned-
# executable-memory). Apply them at sealing time.
ENTITLEMENTS="$ROOT/Notetaker/Resources/nox.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
  echo "✗ entitlements file missing: $ENTITLEMENTS"
  exit 1
fi
codesign --force \
  --sign "$SIGN_IDENTITY" \
  --identifier app.trynox \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH"

# Verify the signature so we catch failed signs before shipping a
# broken DMG.
codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1 \
  || { echo "✗ codesign verification failed"; exit 1; }

echo "▸ Stage DMG contents…"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Build compressed DMG…"
hdiutil create \
  -volname "nox" \
  -srcfolder "$STAGE" \
  -ov -format UDZO -fs APFS \
  "$DMG_PATH" >/dev/null

echo
echo "✓ $DMG_PATH"
du -sh "$DMG_PATH"
echo
echo "Signed with: $SIGN_IDENTITY"
codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true

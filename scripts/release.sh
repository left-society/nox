#!/usr/bin/env bash
# Notetaker release pipeline: build a Release DMG, notarize it, sign
# the update with Sparkle's EdDSA key, and append a fresh entry to
# the appcast.xml that gets uploaded to SUFeedURL.
#
# Prerequisites:
#   1. Developer ID Application cert in keychain (verified by
#      build-release.sh).
#   2. Sparkle signing keypair generated via
#      `scripts/sparkle-bin/generate_keys` — private key sits in
#      keychain, public key is in Notetaker/Resources/Info.plist
#      under SUPublicEDKey.
#   3. xcrun notarytool credential profile stored — see README.
#      Override the profile name via `NOTARY_PROFILE=...` env var.
#
# What it produces:
#   • dist/Notetaker-X.Y.dmg          — signed + notarized + stapled
#   • dist/appcast.xml                 — updated XML feed; upload this
#                                        to SUFeedURL
#   • dist/release-notes-X.Y.html      — placeholder release notes;
#                                        edit + host alongside the DMG
#
# Hosting:
#   • DMG  → any HTTPS URL (Sparkle downloads from URL in appcast)
#   • appcast.xml → SUFeedURL value in Info.plist
#                   (currently https://updates.notetaker.app/appcast.xml)
#
# Usage:
#   bash scripts/release.sh                    # full pipeline
#   bash scripts/release.sh --skip-notarize    # skip notarization step
#                                              # (e.g. when iterating)
#   NOTARY_PROFILE=Foo bash scripts/release.sh # use different profile

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST_DIR="$ROOT/dist"
SPARKLE_BIN="$ROOT/scripts/sparkle-bin"
INFO_PLIST="$ROOT/Notetaker/Resources/Info.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-Notetaker-Notarize}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DMG_NAME="nox.$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
APPCAST="$DIST_DIR/appcast.xml"
SUFEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-$(dirname "$SUFEED_URL")}"

SKIP_NOTARIZE=0
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --publish) PUBLISH=1 ;;
  esac
done

echo "▸ Release pipeline for nox $VERSION (build $BUILD)"
echo "  DMG → $DMG_PATH"
echo "  Appcast → $APPCAST"
echo "  SUFeedURL → $SUFEED_URL"
echo

# ────────────────────────────────────────────────────────────────────
# Step 1: Build + sign DMG (existing build-release.sh handles this)
# ────────────────────────────────────────────────────────────────────
echo "▸ [1/4] Build + sign DMG…"
bash "$ROOT/scripts/build-release.sh"

if [ ! -f "$DMG_PATH" ]; then
  echo "✗ build-release.sh did not produce $DMG_PATH"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────
# Step 2: Notarize + staple
# ────────────────────────────────────────────────────────────────────
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  echo "▸ [2/4] SKIPPED notarization (--skip-notarize)"
else
  echo "▸ [2/4] Submit to Apple notary service…"
  echo "  (this can take a few minutes; using --wait to block)"
  if ! xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --output-format json > "$DIST_DIR/notarize-$VERSION.json" 2>&1; then
    echo "✗ notarization failed — see $DIST_DIR/notarize-$VERSION.json"
    cat "$DIST_DIR/notarize-$VERSION.json"
    exit 1
  fi
  # notarytool emits JSON, not plist. PlistBuddy can't parse JSON —
  # the previous "PlistBuddy || python3" fallback mixed PlistBuddy's
  # error message ("Error Reading File: /dev/stdin") with python's
  # output, breaking the equality check below. Just use python.
  STATUS="$(python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' < "$DIST_DIR/notarize-$VERSION.json")"
  if [ "$STATUS" != "Accepted" ]; then
    echo "✗ notarization status: $STATUS"
    cat "$DIST_DIR/notarize-$VERSION.json"
    exit 1
  fi
  echo "  ✓ Notarization Accepted"

  echo "▸ Staple receipt…"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  echo "  ✓ Staple validated"

  echo "▸ Gatekeeper assessment…"
  spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" 2>&1 \
    || echo "  ⚠ spctl assessment did not return 'accepted' — investigate"
fi

# ────────────────────────────────────────────────────────────────────
# Step 3: Sparkle EdDSA-sign the DMG
# ────────────────────────────────────────────────────────────────────
echo "▸ [3/4] Sparkle-sign DMG…"
SIGN_OUTPUT="$("$SPARKLE_BIN/sign_update" "$DMG_PATH")"
# sign_update emits something like:
#   sparkle:edSignature="..." length="123456"
echo "  $SIGN_OUTPUT"

# Parse via python for reliability — bash regex pipes have edge
# cases (SIGPIPE under pipefail, locale-dependent matching) that
# python sidesteps cleanly.
read -r ED_SIG LENGTH <<< "$(python3 -c '
import re, sys
s = sys.argv[1]
sig = re.search(r"sparkle:edSignature=\"([^\"]+)\"", s)
length = re.search(r"length=\"([^\"]+)\"", s)
if not (sig and length):
    sys.exit(1)
print(sig.group(1), length.group(1))
' "$SIGN_OUTPUT")"

if [ -z "$ED_SIG" ] || [ -z "$LENGTH" ]; then
  echo "✗ failed to parse sign_update output"
  exit 1
fi
echo "  Parsed: signature ${#ED_SIG} chars, length $LENGTH bytes"

# ────────────────────────────────────────────────────────────────────
# Step 4: Append release entry to appcast.xml
# ────────────────────────────────────────────────────────────────────
echo "▸ [4/4] Update appcast.xml…"

# Bootstrap appcast.xml if it doesn't exist yet.
if [ ! -f "$APPCAST" ]; then
  cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>nox</title>
        <link>$SUFEED_URL</link>
        <description>nox app updates</description>
        <language>en</language>
    </channel>
</rss>
EOF
fi

# Build the new <item> entry. RFC822 date format is what Sparkle
# expects for pubDate.
PUB_DATE="$(LC_TIME=C date '+%a, %d %b %Y %H:%M:%S %z')"
DOWNLOAD_URL="$DOWNLOAD_BASE/$DMG_NAME"
RELEASE_NOTES_URL="$DOWNLOAD_BASE/release-notes-$VERSION.html"

NEW_ITEM=$(cat <<EOF
        <item>
            <title>nox $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>$RELEASE_NOTES_URL</sparkle:releaseNotesLink>
            <enclosure
                url="$DOWNLOAD_URL"
                length="$LENGTH"
                type="application/octet-stream"
                sparkle:edSignature="$ED_SIG" />
        </item>
EOF
)

# Insert the new item right after <language>en</language> so newest
# entries are at the top (Sparkle picks the highest version number
# regardless of order, but humans read the file in order).
python3 - <<PYEOF
import re, sys

path = "$APPCAST"
new_item = """$NEW_ITEM"""
version = "$VERSION"

with open(path, "r", encoding="utf-8") as f:
    xml = f.read()

# Strip any existing <item> block with the same version so reruns
# replace instead of duplicate.
xml = re.sub(
    r"\s*<item>\s*<title>nox " + re.escape(version) + r"</title>.*?</item>",
    "",
    xml,
    flags=re.DOTALL
)

# Insert new entry after </language>.
xml = xml.replace(
    "</language>",
    "</language>\n" + new_item,
    1
)

with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
PYEOF

echo "  ✓ Appcast updated"

# ────────────────────────────────────────────────────────────────────
# Bootstrap a release notes file if missing.
# ────────────────────────────────────────────────────────────────────
NOTES_FILE="$DIST_DIR/release-notes-$VERSION.html"
if [ ! -f "$NOTES_FILE" ]; then
  cat > "$NOTES_FILE" <<EOF
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>nox $VERSION</title></head>
<body style="font:14px/1.5 -apple-system,system-ui,sans-serif;color:#222;max-width:560px;margin:24px auto;padding:0 16px">
<h2>nox $VERSION</h2>
<p>What is new in this release.</p>
<ul>
  <li>(Edit this file before uploading.)</li>
</ul>
</body>
</html>
EOF
  echo "  ✓ Stub release notes at $NOTES_FILE. Edit before upload."
fi

echo
echo "──────────────────────────────────────────────────────────────"
echo "✓ Release $VERSION ready locally."
echo
echo "Files in dist/:"
echo "  • $DMG_PATH"
echo "  • $APPCAST"
echo "  • $NOTES_FILE"
echo "──────────────────────────────────────────────────────────────"

# Optional: hand off to scripts/publish-github.sh which creates the
# GitHub Release, uploads the DMG as a release asset, rewrites the
# appcast enclosure URL to the asset URL, and pushes the appcast +
# release notes to the Pages repo.
if [ "$PUBLISH" -eq 1 ]; then
  echo
  echo "▸ Publishing to GitHub (left-society/nox)…"
  bash "$ROOT/scripts/publish-github.sh"
else
  echo
  echo "Skipping GitHub publish (no --publish flag). To push:"
  echo "  bash scripts/publish-github.sh"
  echo "or rerun this script with --publish."
fi

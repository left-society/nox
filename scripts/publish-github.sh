#!/usr/bin/env bash
# Publish a Notetaker release to GitHub. Run AFTER scripts/release.sh
# has produced a signed/notarized DMG + appcast.xml in dist/.
#
# What it does:
#   1. Creates a tagged GitHub Release (vX.Y) on the releases repo
#   2. Uploads the DMG as a release asset (this is where Sparkle
#      downloads the actual binary from)
#   3. Rewrites the <enclosure url> in dist/appcast.xml to point at
#      the GitHub Release asset URL (instead of a placeholder)
#   4. Pushes appcast.xml + release-notes-X.Y.html to the releases
#      repo's main branch — these are served via GitHub Pages
#
# After this script completes, existing installs will pick up the
# new version on their next scheduled Sparkle check (~24h, or
# manual trigger via Settings if/when wired up).
#
# Prereqs:
#   • gh CLI authed (`gh auth login`)
#   • dist/Notetaker-X.Y.dmg exists (from build-release.sh)
#   • dist/appcast.xml has the new <item> already (from release.sh)
#   • dist/release-notes-X.Y.html exists (auto-stubbed by release.sh)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST_DIR="$ROOT/dist"
INFO_PLIST="$ROOT/Notetaker/Resources/Info.plist"
RELEASES_REPO="${RELEASES_REPO:-left-society/nox}"
RELEASES_REPO_LOCAL="${RELEASES_REPO_LOCAL:-/tmp/nox}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
TAG="v$VERSION"
DMG_NAME="nox.$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
NOTES_HTML="$DIST_DIR/release-notes-$VERSION.html"
APPCAST_LOCAL="$DIST_DIR/appcast.xml"

# Sanity: required files exist.
for f in "$DMG_PATH" "$APPCAST_LOCAL" "$NOTES_HTML"; do
  if [ ! -f "$f" ]; then
    echo "✗ missing required file: $f"
    echo "  (Run scripts/release.sh first to produce these.)"
    exit 1
  fi
done

# Sanity: gh authed.
if ! gh auth status >/dev/null 2>&1; then
  echo "✗ gh CLI not authenticated. Run: gh auth login"
  exit 1
fi

echo "▸ Publishing nox $VERSION to $RELEASES_REPO"

# ────────────────────────────────────────────────────────────────────
# Step 1: Create or update the GitHub Release.
# ────────────────────────────────────────────────────────────────────
# `gh release create` errors if the tag already exists. To make this
# script idempotent (re-runnable for fixing a borked release), check
# first and either create or upload-only.
if gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  echo "▸ [1/4] Release $TAG already exists — uploading DMG (clobber)"
  gh release upload "$TAG" "$DMG_PATH" --repo "$RELEASES_REPO" --clobber
else
  echo "▸ [1/4] Create release $TAG and upload DMG"
  # Markdown release notes shown on the GitHub Release page itself.
  # The HTML release notes (release-notes-X.Y.html) are what Sparkle
  # shows in the in-app update dialog — separate file, separate URL,
  # separate purpose.
  gh release create "$TAG" "$DMG_PATH" \
    --repo "$RELEASES_REPO" \
    --title "nox $VERSION" \
    --notes "Auto-update via Sparkle. Edit release-notes-$VERSION.html for the full changelog shown in app."
fi

# ────────────────────────────────────────────────────────────────────
# Step 2: Get the canonical asset download URL for the uploaded DMG.
# ────────────────────────────────────────────────────────────────────
# `gh release view` returns JSON listing all assets; we pick the one
# matching our DMG name. This is the URL Sparkle downloads from.
ASSET_URL="$(gh release view "$TAG" --repo "$RELEASES_REPO" --json assets \
  --jq ".assets[] | select(.name == \"$DMG_NAME\") | .url")"

if [ -z "$ASSET_URL" ]; then
  echo "✗ failed to resolve asset URL for $DMG_NAME"
  exit 1
fi
echo "  Asset URL: $ASSET_URL"

# ────────────────────────────────────────────────────────────────────
# Step 3: Rewrite the <enclosure url> in appcast.xml to the real
# asset URL. release.sh fills in a placeholder ("download base"
# derived from SUFeedURL); we replace it with the GitHub Release
# asset URL post-hoc here.
# ────────────────────────────────────────────────────────────────────
echo "▸ [2/4] Rewriting appcast.xml enclosure URL"
python3 - <<PYEOF
import re

path = "$APPCAST_LOCAL"
asset_url = "$ASSET_URL"
dmg_name = "$DMG_NAME"

with open(path, "r", encoding="utf-8") as f:
    xml = f.read()

# Find the enclosure for THIS version's DMG (matched by filename)
# and replace whatever url it currently has with the real asset URL.
# Match against the filename so we only touch the entry we just
# released, not any prior entries.
xml = re.sub(
    r'(url=")[^"]*' + re.escape(dmg_name) + r'(")',
    r'\1' + asset_url + r'\2',
    xml
)

with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
PYEOF

# ────────────────────────────────────────────────────────────────────
# Step 4: Push appcast.xml + release notes to the releases repo.
# ────────────────────────────────────────────────────────────────────
echo "▸ [3/4] Sync appcast + release notes to $RELEASES_REPO"

# Clone (or update) the local working copy.
if [ ! -d "$RELEASES_REPO_LOCAL/.git" ]; then
  rm -rf "$RELEASES_REPO_LOCAL"
  git clone "https://github.com/$RELEASES_REPO.git" "$RELEASES_REPO_LOCAL"
else
  git -C "$RELEASES_REPO_LOCAL" fetch origin
  git -C "$RELEASES_REPO_LOCAL" reset --hard origin/main
fi

cp "$APPCAST_LOCAL" "$RELEASES_REPO_LOCAL/appcast.xml"
cp "$NOTES_HTML" "$RELEASES_REPO_LOCAL/release-notes-$VERSION.html"

cd "$RELEASES_REPO_LOCAL"
git add appcast.xml "release-notes-$VERSION.html"
if git diff --cached --quiet; then
  echo "  No changes to push (appcast + notes already in sync)."
else
  git commit -m "release $VERSION: appcast + notes"
  git push origin main
fi
cd "$ROOT"

# ────────────────────────────────────────────────────────────────────
echo "▸ [4/4] Verify Pages serving updated appcast"
# GitHub Pages can take ~30s-2min to redeploy after a push. We poll
# the appcast URL for the new version; if it's still the old one,
# remind the user the propagation takes a bit.
APPCAST_URL="https://trynox.app/appcast.xml"
for attempt in 1 2 3 4 5; do
  if curl -sf "$APPCAST_URL" 2>/dev/null | grep -q ">$VERSION<"; then
    echo "  ✓ Pages serving nox $VERSION at $APPCAST_URL"
    break
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "  ⚠ Pages hasn't picked up $VERSION yet (still building)."
    echo "    The push succeeded — wait a minute and check $APPCAST_URL"
    break
  fi
  echo "  …waiting for Pages to redeploy (attempt $attempt/5)"
  sleep 15
done

echo
echo "──────────────────────────────────────────────────────────────"
echo "✓ nox $VERSION published."
echo
echo "  Release page: https://github.com/$RELEASES_REPO/releases/tag/$TAG"
echo "  Appcast:      $APPCAST_URL"
echo "  DMG asset:    $ASSET_URL"
echo
echo "Existing installs will see the update on their next Sparkle"
echo "check (every ~24h). New users downloading the DMG fresh from"
echo "the GitHub Release will get $VERSION immediately."
echo "──────────────────────────────────────────────────────────────"

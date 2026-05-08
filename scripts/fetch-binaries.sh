#!/usr/bin/env bash
# Fetch yt-dlp + ffmpeg into Notetaker/Resources/bin/.
# These get bundled into the .app at build time (see "Copy yt-dlp + ffmpeg
# binaries" build phase in Notetaker.xcodeproj). They are intentionally
# .gitignored to keep the repo small — re-run this script on a fresh clone
# or when you want to refresh yt-dlp to its latest release.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/Notetaker/Resources/bin"
mkdir -p "$BIN_DIR"

# yt-dlp ships a single static macOS binary on each GitHub release.
YT_DLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
# ffmpeg static build from evermeet — codesigned, hardened, universal.
FFMPEG_URL="https://evermeet.cx/ffmpeg/getrelease/zip"

echo "▸ Fetching yt-dlp…"
curl -fsSL --retry 3 "$YT_DLP_URL" -o "$BIN_DIR/yt-dlp"
chmod +x "$BIN_DIR/yt-dlp"

echo "▸ Fetching ffmpeg…"
TMP="$(mktemp -d)"
# 2026-05-08 audit M31: clean up the temp dir on any exit path,
# not just the happy path. A failed download / unzip used to leak
# the temp dir.
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 "$FFMPEG_URL" -o "$TMP/ffmpeg.zip"
unzip -q "$TMP/ffmpeg.zip" -d "$TMP"
mv "$TMP/ffmpeg" "$BIN_DIR/ffmpeg"
chmod +x "$BIN_DIR/ffmpeg"

echo "✓ Binaries ready in $BIN_DIR"
"$BIN_DIR/yt-dlp" --version | sed 's/^/  yt-dlp /'
"$BIN_DIR/ffmpeg" -version | head -1 | sed 's/^/  /'

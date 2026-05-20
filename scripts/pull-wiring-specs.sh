#!/usr/bin/env bash
# pull-wiring-specs.sh — extract each session's wiring spec from their new file
#
# After the 4 parallel sessions complete, each leaves a block at the
# top of their new Swift file in this format:
#
#   // MARK: - Wiring Spec (for coordinator)
#   // ... instructions ...
#   // END WIRING SPEC
#
# This script concatenates all 4 into one document the coordinator can
# read end-to-end before applying changes to SettingsWindow.swift,
# PanelRootView.swift, and project.pbxproj.

set -euo pipefail

REPO_ROOT="/Users/apple/Note taker app"
FILES=(
  "Notetaker/NotchPill/PillContextMenu.swift"
  "Notetaker/NotchPill/SwipeGesturePolicy.swift"
  "Notetaker/Services/SoundEffectsService.swift"
  "Notetaker/Services/FocusGatingPolicy.swift"
)

cd "$REPO_ROOT"

missing=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "⚠️  MISSING: $f" >&2
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo ""
  echo "$missing of ${#FILES[@]} expected files not yet present. Sessions still working?" >&2
  exit 1
fi

echo "All 4 session files present. Extracting wiring specs:"
echo ""

for f in "${FILES[@]}"; do
  echo "════════════════════════════════════════════════════════════════"
  echo "  $f"
  echo "════════════════════════════════════════════════════════════════"
  if grep -q "MARK: - Wiring Spec" "$f"; then
    sed -n '/MARK: - Wiring Spec/,/END WIRING SPEC/p' "$f"
  else
    echo "⚠️  NO WIRING SPEC BLOCK FOUND — session may have forgotten to include it"
  fi
  echo ""
done

echo "════════════════════════════════════════════════════════════════"
echo "Test files present?"
echo "════════════════════════════════════════════════════════════════"
for f in PillContextMenuTests SwipeGesturePolicyTests SoundEffectsPolicyTests FocusGatingPolicyTests; do
  found=$(find NotetakerTests -name "${f}.swift" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    echo "✓ $f.swift at $found"
  else
    echo "⚠️  $f.swift NOT FOUND"
  fi
done

# Audit fixes 1.9.8 — STATUS

Started: 2026-05-08, while you slept.
Audit doc: `docs/bug-audit-2026-05-08.md` (in the elastic-faraday-7406a7 worktree)

## What got done

All four rounds of audit fixes are committed on `main` locally and
mirrored to `origin/app/audit-fixes-1.9.8-pending-notarize` on
GitHub for safety.

### Round 1 — quick wins + retention off-main
| ID | Fix |
|----|-----|
| C5 | website CTA was "Download nox 1.9.6" — fixed to 1.9.7 |
| H9 | sidebar toggle in PopoutNoteContainer had identical glyphs in both branches |
| H13 | Whisper hallucination filter was destroying `?` and `!` (split on `.!?` then rejoined with `". "`). Now preserves original terminators |
| H16 | website: deleted deprecated duplicate `.compare-table` CSS that was overriding the live styling |
| M25 | website: postMessage listener now allowlists Tally origins (was accepting any origin) |
| H10 | music close was using soft 158/25 spring instead of bouncy 480/40 because the height-equality test couldn't distinguish music close from notch-hidden close |
| H1 | Settings test-key task didn't check `Task.isCancelled` — stale results could overwrite fresh ones |
| H2 | `setLaunchAtLogin` toggle stayed lit even when SMAppService rejected the registration. Now rolls back + alerts |
| H3 | dead "Always-on resting pill" toggle removed (key was written, never read) |
| H4 | RetentionService.sweep was @MainActor and blocked main for hundreds of files. Now nonisolated async, runs detached |

### Round 2 — high-impact app fixes
| ID | Fix |
|----|-----|
| H5 | `VideoDownloader.lastKnownDownloadedBytes` was a static var that cross-polluted concurrent downloads. Now per-instance |
| H6 | `LockMusicCardView.cardScreenFrame` y-anchor was 0.18 but controller was 0.22 — backdrop sampled wrong region. Synced |
| H7 | `BackdropController.setShown` had a race where stale completion `orderOut`'d a now-visible window. Added generation counter |
| H8 | `NotchHUDWindowController.scheduleAutoHide` called `@MainActor hide()` without actor hop. Wrapped in `Task { @MainActor in }` |
| H11 | `LinkPreviewService.ensure` permanently trapped URLs whose fetch never returned. Added 12s watchdog |
| H12 | `LocalWhisperService.transcribe` was masking real prepare errors as `.notReady` — users told to wait when the real problem was unrecoverable. Now surfaces `.prepareFailed(Error)` |
| H14 | RetentionService trash retention treated 0 as "delete now" — latent footgun. Now `<=0` maps to infinity |
| H15 | Onboarding closed via traffic-light marked complete with no way back. Added "Show onboarding again" button in Settings → General |

### Round 3 — release pipeline integrity
| ID | Fix |
|----|-----|
| H17/H18 | `release.sh` now refuses `--skip-notarize + --publish` combination (would've shipped unstapled DMG to existing users) |
| H19 | `notarytool` stderr separated from JSON file (was breaking the json.load parse) |
| H20 | `uninstall-clean.sh` now wipes `~/Library/nox-AutoSave` (was only wiping legacy `Notetaker-AutoSave`) |
| H21 | `uninstall-clean.sh` upgraded to `set -euo pipefail` |
| M28 | `build-release.sh` xcodebuild output → log file (was `/dev/null`) |
| M29 | `build-release.sh` fails loudly if PlistBuddy can't read version (was `\|\| echo 1.0`) |
| M30 | `release.sh` python heredoc now passes vars via env (was bash-interpolated, broke on quotes/backslashes) |
| M31 | `build-release.sh` + `fetch-binaries.sh` `trap` mktemp cleanup on EXIT |

### Round 4 — settings + pbxproj sync
| ID | Fix |
|----|-----|
| M17 | Settings API key field: `.onChange` no longer fires on the keychain `.onAppear` load — validation badge stays stable when re-opening Settings |
| M18 | provider="custom" with empty/invalid URL no longer silently routes to Groq — logs the fallback decision |
| M26 | pbxproj `MARKETING_VERSION` synced from `1.0` → `1.9.7` then bumped to `1.9.8` (was decoupled from Info.plist; agvtool / xcodegen would have produced wrong builds) |

### Skipped (with reasoning)

- **C1** — `project.yml` out of sync with pbxproj. Preventive only; nobody runs xcodegen today.
- **C2/C3/M27** — `dev-deploy.sh` issues. Dev-only script, doesn't affect releases.
- **C4** — DB-init alert behind onboarding window. Rare edge case (DB failure on first launch).
- **M10** — `CalendarMonitorService.refresh` blocks main 50-200ms. Real concurrency refactor; risk vs. reward not clear.
- **M11** — `ImageStore`/`NoteStore`/`VideoStore.reload` blocks main. Async refactor cascades through @Published consumers — risky in an automated run, deferred.
- **L tier** — mostly cosmetic / dead code. Skipped per priority.

## What did NOT get done

**1.9.8 was NOT shipped.** Pipeline halted at notarization:

```
Error: No Keychain password item found for profile: Notetaker-Notarize
```

The notary credentials are not present on the machine.

The signed DMG sits at `dist/nox.1.9.8.dmg` (71MB) — built, codesigned with
Developer ID, hardened runtime, embedded entitlements — just not notarized
or stapled.

Pushing it to the website / appcast right now would break Sparkle
auto-update for every existing 1.9.x user (Gatekeeper would block the
unstapled binary), so the website + appcast were left alone.

## To finish the release when you wake up

1. **Re-store notary credentials.** Get an app-specific password at
   appleid.apple.com → Sign-In and Security → App-Specific Passwords.
   Then:

   ```bash
   xcrun notarytool store-credentials Notetaker-Notarize \
     --apple-id <your apple id> \
     --team-id RNY276VB6Q \
     --password <app-specific-password>
   ```

2. **Re-run the release pipeline:**

   ```bash
   bash scripts/release.sh --publish
   ```

   This will rebuild + re-sign + notarize + staple the DMG, write
   the appcast entry, and bootstrap a release-notes HTML stub.

3. **Push the DMG to GitHub Releases:**

   ```bash
   gh release create v1.9.8 dist/nox.1.9.8.dmg \
     --title "nox 1.9.8" \
     --notes "All audit-pass fixes from /docs/bug-audit-2026-05-08.md"
   ```

4. **Push appcast.xml + website index.html** to `origin/main` (the
   website branch). Use the same worktree pattern we used for 1.9.7
   (separate worktree on `origin/main`, edit, push).

## Repo state right now

- `main` (local): all audit fixes + version bump to 1.9.8 (not pushed
  to `origin/main` because that branch is the website history)
- `origin/app/audit-fixes-1.9.8-pending-notarize`: backup of the local
  main, in case anything happens to your machine while you sleep
- `origin/main`: untouched (still serves the live 1.9.7 site)
- `dist/nox.1.9.8.dmg`: signed but unstapled (will be replaced when
  you re-run release.sh)

Total commits today: 6 (3 audit rounds + version bump + this status doc).

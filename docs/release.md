# Notetaker — release runbook

Current shipping path: self-signed DMG, manual install, no auto-update.

## Ship a release (current state)

```bash
# 1. Bump the version in Info.plist
# Notetaker/Resources/Info.plist → CFBundleShortVersionString

# 2. Run tests — must be green before shipping
xcodebuild test -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS'

# 3. Build + sign + DMG (one command)
./scripts/build-release.sh
# → dist/Notetaker-X.Y.dmg
```

The script auto-detects `NotetakerDevCert` in the login keychain and signs with it; falls back to ad-hoc signing if the cert isn't present. Hardened runtime is enabled in both paths so a future Developer ID notarization pass works without re-signing.

## What users see

- First-launch on a fresh machine: Gatekeeper prompt because the cert isn't notarized. Right-click → Open works.
- TCC permissions (Accessibility, Microphone) need a one-time grant per machine.
- No auto-update yet. Users must download new DMGs manually.

## Score impact

The 8/10 rating breakdown called out three production-readiness gaps. This is where they stand:

| Gap | Status | What's left |
|---|---|---|
| Stable code signing | ✅ Done | `build-release.sh` uses NotetakerDevCert |
| Hardened runtime | ✅ Done | `--options runtime` set in both signing paths |
| Test coverage on dictation pipeline | ✅ Done | 7 XCTests cover the cleanup metacommentary regression + grapheme-safe chunking |
| Apple Developer ID + notarization | ❌ Open | $99/yr account required (see below) |
| Sparkle auto-update | ❌ Open | Needs hosted appcast + EdDSA key (see below) |
| On-device Whisper fallback | ❌ Open | WhisperKit integration (~3hr) |

## Future: Developer ID + notarization

When the user gets an Apple Developer account ($99/yr):

```bash
# 1. Enroll at developer.apple.com — get a "Developer ID Application" cert
#    via Xcode → Settings → Accounts → Manage Certificates.

# 2. Update build-release.sh:
#    Change `NotetakerDevCert` to "Developer ID Application: <Name> (<TeamID>)"
#    or just point it at the cert via Xcode's automatic signing.

# 3. After signing, notarize:
xcrun notarytool submit dist/Notetaker-X.Y.dmg \
  --apple-id <apple-id> \
  --team-id <team-id> \
  --password <app-specific-password> \
  --wait

# 4. Staple the notarization ticket to the DMG so it works offline:
xcrun stapler staple dist/Notetaker-X.Y.dmg
```

After that path is wired, Gatekeeper accepts the DMG silently — no right-click-Open required.

## Future: Sparkle auto-update

When ready to ship auto-updates:

1. Add Sparkle Swift Package: `https://github.com/sparkle-project/Sparkle` (Xcode → File → Add Packages).
2. Generate an EdDSA key pair: `./bin/generate_keys` from the Sparkle distribution.
   - Public key → embed in `Info.plist` under `SUPublicEDKey`.
   - Private key → keep secret, used to sign every release DMG via `./bin/sign_update`.
3. Wire `SPUStandardUpdaterController` in `AppDelegate` and add a "Check for Updates…" menu item.
4. Host an `appcast.xml` (e.g. on the existing `notetaker-website` static site).
5. Set `SUFeedURL` in `Info.plist` to the appcast URL.
6. Each release: append a new `<item>` to `appcast.xml` with the DMG URL + `sparkle:edSignature` from `sign_update`.

## Future: On-device Whisper

The current dictation pipeline depends on Groq's hosted Whisper API — needs an API key and an internet connection. WhisperKit ([github.com/argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit)) runs Whisper locally on Apple Silicon via CoreML.

Integration sketch:
- Add WhisperKit Swift Package.
- Add a `DictationService` provider option `"on-device"` that uses `WhisperKit.transcribe(audioPath:)` instead of POSTing to `/audio/transcriptions`.
- Settings → Dictation: provider picker gains a fourth option ("On-device — slower, no API key, fully private").
- Audio file path: same 16 kHz mono PCM16 WAV the recorder already writes.
- Cleanup pass: still runs through Groq/OpenAI for the LLM polish, OR can be skipped.

## Tests

7 unit tests cover the dictation cleanup-pass metacommentary detection (`looksLikeMetacommentary`) plus the grapheme-safe `String.unicodeChunks` used by the typing pipeline. The metacommentary test file IS the regression test for the "I will process the raw transcript..." failure we hit in production — adding new prefaces to the heuristic should always come with a corresponding test case.

Run: `xcodebuild test -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS'`

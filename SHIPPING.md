# nox — Shipping playbook

Single source of truth for releasing nox.app. Save this. Everything you
need to ship a new version is here.

---

## 1. Apple Developer account

| | |
|---|---|
| **Apple ID (developer)** | `djoy.agbd@gmail.com` |
| **Account name** | Dhananjoy Debnath |
| **Team ID** | `RNY276VB6Q` |
| **Membership** | Apple Developer Program, Individual, paid ($99/yr) |
| **Renewal date** | May 1, 2027 |
| **Portal** | https://developer.apple.com/account |

When the renewal hits, all existing certs and the membership stay
active as long as the renewal is paid. If it lapses, the Developer ID
Application cert becomes useless on the day of expiry.

---

## 2. Signing identity (Developer ID Application)

The cert that signs nox.app for **direct distribution outside the
Mac App Store** (the same channel Alcove, NotchNook, BoringNotch use).

| | |
|---|---|
| **Identity name** | `Developer ID Application: Dhananjoy Debnath (RNY276VB6Q)` |
| **SHA-1 hash** | `6217FE8CBA4DD23DB7DBB3D2D94F974787082FDA` |
| **Cert valid until** | May 3, 2031 |
| **Issuer chain** | Developer ID Certification Authority → Apple Root CA |
| **Private key** | `~/.nox-developer-id/nox-devid.key` (chmod 600, never check in) |
| **Original CSR** | `~/.nox-developer-id/nox-devid.csr` |
| **Cert from Apple** | `~/Downloads/developerID_application.cer` (also in Keychain) |
| **Keychain location** | login keychain (`~/Library/Keychains/login.keychain-db`) |

To verify the identity is still good on this Mac:
```bash
security find-identity -p codesigning -v | grep "Developer ID Application"
```

If you ever migrate to a new Mac:
1. Export the cert + private key from Keychain Access → "Developer ID
   Application: Dhananjoy Debnath" → File → Export Items → save as
   `.p12` with a password.
2. Move the `.p12` to the new Mac.
3. Double-click to import; enter the password.

---

## 3. Notarization credentials

App-specific password generated at https://appleid.apple.com →
Sign-In and Security → App-Specific Passwords.

| | |
|---|---|
| **Apple ID** | `djoy.agbd@gmail.com` |
| **Team ID** | `RNY276VB6Q` |
| **Password label** | `nox-notarization` (visible in App-Specific Passwords list) |
| **Stored as keychain profile** | `nox-notarization` |

The password itself lives encrypted in the system keychain via
`xcrun notarytool store-credentials`. **NEVER commit it to git, never
paste it in chat, never put it in this doc.** If lost or compromised,
revoke at appleid.apple.com → App-Specific Passwords → delete →
regenerate, then run `store-credentials` again with the new password.

To verify the keychain profile is set up:
```bash
xcrun notarytool history --keychain-profile "nox-notarization" 2>&1 | head -5
```

---

## 4. Hardened-runtime entitlements

File: `Notetaker/Resources/nox.entitlements`. Required for
notarization to accept the bundle.

```
com.apple.security.cs.disable-library-validation       true
com.apple.security.automation.apple-events             true
com.apple.security.cs.allow-jit                        true
com.apple.security.cs.allow-unsigned-executable-memory true
```

App Sandbox is **OFF** (no `app-sandbox` key). nox needs unsandboxed
access to: global event tap, status bar APIs, cross-app paste, dlopen
of MediaRemote private framework, AppleEvents to Spotify/Music.
That's why we ship direct, not via the Mac App Store.

---

## 5. Xcode build settings (Release config)

In `Notetaker.xcodeproj/project.pbxproj`:

```
CODE_SIGN_STYLE        = Manual
CODE_SIGN_IDENTITY     = "Developer ID Application"
CODE_SIGN_ENTITLEMENTS = "Notetaker/Resources/nox.entitlements"
DEVELOPMENT_TEAM       = RNY276VB6Q
ENABLE_HARDENED_RUNTIME = YES
PRODUCT_NAME           = nox
PRODUCT_BUNDLE_IDENTIFIER = com.aritradebnath.notetaker
```

The bundle ID stays at `com.aritradebnath.notetaker` for backwards
compatibility (changing it orphans existing user data in
`~/Library/Application Support/`).

---

## 6. Release-build pipeline

A single `scripts/release.sh` script (TODO: write this) should run
the whole chain. For now, here are the manual steps in order:

### Step A — clean and archive
```bash
cd "/Users/apple/Note taker app"
xcodebuild -scheme Notetaker -configuration Release clean
rm -rf /tmp/nox.xcarchive
xcodebuild \
  -scheme Notetaker \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/nox.xcarchive \
  archive
```

### Step B — re-sign every nested binary with Developer ID
**Critical**: every executable inside the bundle must be signed with
Developer ID + `--options runtime` + `--timestamp`. Apple rejects
notarization if any nested helper is missing any of these.

Known nested binaries in nox:
- `Contents/Resources/bin/yt-dlp`
- `Contents/Resources/bin/ffmpeg`
- `Contents/Resources/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter`
- `Contents/MacOS/__preview.dylib` (Xcode debug helper, present in
  Debug builds; not in Release)

Sign in this order (leaves first, wrapper last):
```bash
APP=/tmp/nox.xcarchive/Products/Applications/nox.app
ID="Developer ID Application: Dhananjoy Debnath (RNY276VB6Q)"

# Helper executables
codesign --force --options runtime --timestamp --sign "$ID" \
  "$APP/Contents/Resources/bin/yt-dlp"
codesign --force --options runtime --timestamp --sign "$ID" \
  "$APP/Contents/Resources/bin/ffmpeg"

# Embedded framework
codesign --force --options runtime --timestamp --sign "$ID" \
  "$APP/Contents/Resources/MediaRemoteAdapter.framework"

# Re-sign the wrapper with entitlements
codesign --force --options runtime --timestamp \
  --entitlements "/Users/apple/Note taker app/Notetaker/Resources/nox.entitlements" \
  --sign "$ID" "$APP"

# Verify
codesign --verify --deep --strict --verbose=4 "$APP"
```

### Step C — package as DMG
```bash
DMG=/tmp/nox.dmg
STAGE=/tmp/nox-dmg-staging
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

create-dmg \
  --volname "nox" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "nox.app" 175 200 \
  --hide-extension "nox.app" \
  --app-drop-link 425 200 \
  --no-internet-enable \
  --skip-jenkins \
  "$DMG" "$STAGE/"
```

### Step D — sign the DMG
```bash
codesign --force --sign "$ID" --timestamp "$DMG"
```

### Step E — notarize
```bash
xcrun notarytool submit "$DMG" \
  --keychain-profile "nox-notarization" \
  --wait
```
Apple processes for 5–15 minutes. If it returns **Accepted**, continue.
If **Invalid**, fetch the log:
```bash
xcrun notarytool log <submission-id> --keychain-profile "nox-notarization"
```
Read the JSON, fix what it complains about, re-archive, re-submit.
Common issues:
- nested binary missing `--options runtime`
- nested binary missing `--timestamp`
- nested binary signed by a different identity (ad-hoc / self-signed
  leftover from dev)
- entitlements file referencing something disallowed for hardened
  runtime apps

### Step F — staple
```bash
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
```
Stapling embeds the notarization ticket so Gatekeeper can verify
offline. Without it, first-launch on a Mac with no internet would fail.

### Step G — distribute
- Upload `nox.dmg` to your hosting (the website's download URL).
- Update `index.html` so the "Download for Mac" button links to it.
- Bump `CFBundleShortVersionString` in `Info.plist` for the next
  release so users get an automatic update prompt (if/when we add
  Sparkle or similar).

---

## 7. File locations cheat-sheet

| Thing | Path |
|---|---|
| Developer ID private key | `~/.nox-developer-id/nox-devid.key` |
| Developer ID CSR | `~/.nox-developer-id/nox-devid.csr` |
| Developer ID cert from Apple | `~/Downloads/developerID_application.cer` |
| nox source | `/Users/apple/Note taker app/` |
| Xcode project | `/Users/apple/Note taker app/Notetaker.xcodeproj` |
| Entitlements file | `/Users/apple/Note taker app/Notetaker/Resources/nox.entitlements` |
| Build archive | `/tmp/nox.xcarchive` |
| Final DMG | `/tmp/nox.dmg` |
| Dev-deploy script | `/Users/apple/Note taker app/dev-deploy.sh` |
| Backup of old website | `/Users/apple/Note taker app/website/.backup-pre-cinema/` |

---

## 8. What's done vs what's left

### Done (as of this writing)
- [x] Apple Developer Program active, Team ID `RNY276VB6Q`
- [x] Developer ID Application cert created + installed in Keychain
- [x] Apple intermediate CAs installed (Developer ID G2 + WWDR + Root)
- [x] Xcode project signing settings switched from ad-hoc to Developer ID
- [x] Hardened-runtime entitlements file added
- [x] App-specific password generated, stored as keychain profile
- [x] First archive build successful
- [x] First notarization attempt — **Invalid**, due to unsigned nested
      binaries (yt-dlp, ffmpeg, MediaRemoteAdapter.framework)

### Remaining
- [ ] Re-sign nested binaries with Developer ID + hardened runtime
- [ ] Re-archive, re-DMG, re-submit notarization → wait for **Accepted**
- [ ] Staple ticket to DMG
- [ ] Test the DMG on a different Mac (Gatekeeper acceptance)
- [ ] Upload `nox.dmg` to website download URL
- [ ] Wire the website's "Download for Mac" button to that URL
- [ ] Set up Sparkle for in-app updates (post-v1.0)

---

## 9. If something breaks

| Symptom | Fix |
|---|---|
| `notarytool` says credentials invalid | Regenerate app-specific password, re-run `store-credentials` |
| Notarization rejected with "not signed with valid Developer ID" | Find which nested binary, re-sign with `--sign "Developer ID Application…"` |
| Notarization rejected with "secure timestamp missing" | Add `--timestamp` to every codesign call |
| Notarization rejected with "hardened runtime not enabled" | Add `--options runtime` to every nested codesign call |
| User sees "nox is damaged" on launch | DMG wasn't stapled. Run `xcrun stapler staple nox.dmg` |
| User sees "nox can't be opened because it can't be verified" | Notarization didn't complete, or staple failed. Check `spctl --assess` |
| Keychain prompts for codesign password every build | Run `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <login-pwd> ~/Library/Keychains/login.keychain-db` |

---

## 10. Useful debugging commands

```bash
# What identities are available?
security find-identity -p codesigning -v

# What's the codesign state of a built app?
codesign -dvvv /path/to/nox.app

# What entitlements are embedded?
codesign -d --entitlements - /path/to/nox.app

# Will Gatekeeper accept this app?
spctl --assess --type execute --verbose=4 /path/to/nox.app

# Notarization history
xcrun notarytool history --keychain-profile "nox-notarization"

# Notarization log for a specific submission
xcrun notarytool log <UUID> --keychain-profile "nox-notarization"

# Verify a stapled ticket
xcrun stapler validate /path/to/nox.dmg
```

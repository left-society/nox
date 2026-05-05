# Notetaker — Auto-update Feed

This repository hosts the [Sparkle](https://sparkle-project.org) appcast and release notes for [Notetaker](https://github.com/left-society/notetaker).

- **Appcast URL:** https://left-society.github.io/notetaker-releases/appcast.xml
- **DMGs:** attached to each [GitHub Release](https://github.com/left-society/notetaker-releases/releases)

The Notetaker app polls `appcast.xml` daily and downloads new versions automatically.

## Verifying a download

Every DMG is signed with both Apple's Developer ID notarization stamp AND a Sparkle EdDSA signature. The public key embedded in the app verifies each download before installing — this protects users from MITM/CDN compromise even if a release file is replaced on the server.

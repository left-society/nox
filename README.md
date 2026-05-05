# nox

Auto update feed for the nox macOS app. This repo holds the [Sparkle](https://sparkle-project.org) appcast and per release notes. The actual DMG files live as assets on each [GitHub Release](https://github.com/left-society/nox/releases).

The nox app polls `appcast.xml` daily and downloads new versions automatically.

**Appcast URL:** https://left-society.github.io/nox/appcast.xml

## How updates are verified

Every DMG is signed two ways. First, with Apple's Developer ID, then notarized and stapled by Apple's notary service so macOS Gatekeeper trusts it without warnings. Second, with a Sparkle EdDSA signature so the embedded public key inside the app verifies each download before installing. This protects users from a CDN compromise or anyone replacing a release file on the server.
